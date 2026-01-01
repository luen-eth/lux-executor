// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
// const ["0xBB4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c","0x10ED43C718714eb63d5aA57B78B54704E256024E","0x1b81D678ffb9C0263b24A97847620C99d213eB14","0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24","0xB971eF87ede563556b2ED4b1C0b0019111Dd85d2"]
/// @notice Minimal ERC-20 interface subset used by the executor.
interface IERC20Minimal {
    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @notice Lightweight multicall-style executor that pulls funds from the caller, forwards
/// them through arbitrary calls (e.g. DEX routers), and flushes specified tokens back to the caller.
/// @dev SECURITY: Stateless design - funds are returned to msg.sender after each execution.
contract LuxExecutor {
    /// @dev Simple non-reentrancy guard.
    uint256 private constant _UNLOCKED = 1;
    uint256 private constant _LOCKED = 2;
    uint256 private _status = _UNLOCKED;

    /// @dev Array length limits to prevent DoS
    uint256 private constant MAX_PULLS = 10;
    uint256 private constant MAX_APPROVALS = 20;
    uint256 private constant MAX_CALLS = 10;
    uint256 private constant MAX_FLUSH_TOKENS = 20;
    uint256 private constant MAX_BATCH_WHITELIST = 50;

    /// @dev Dynamic selector whitelist: selector => expected amountIn offset (0 = not whitelisted)
    mapping(bytes4 => uint256) public selectorOffsets;

    error ReentrancyGuard();
    error TokenPullFailed(address token, uint256 amount);
    error TokenFlushFailed(address token);
    error TokenApprovalFailed(address token, address spender, uint256 amount);
    error NativeTransferFailed(address recipient, uint256 amount);
    error ZeroAmountNotAllowed();
    error InvalidInjectionOffset(uint256 offset, uint256 dataLength);
    error ArrayLengthExceeded(string arrayName, uint256 length, uint256 max);
    error SpenderNotWhitelisted(address spender);
    error DuplicateTokenInFlush(address token);
    error InvalidSelectorForInjection(bytes4 selector);
    error OffsetMismatchForSelector(
        bytes4 selector,
        uint256 providedOffset,
        uint256 expectedOffset
    );
    error TargetNotWhitelisted(address target);
    error InvalidOffset(uint256 offset);

    struct TokenPull {
        address token;
        uint256 amount;
    }

    struct Approval {
        address token;
        address spender;
        uint256 amount;
        bool revokeAfter;
    }

    struct Call {
        address target;
        uint256 value;
        bytes data;
        address injectToken;
        uint256 injectOffset;
    }

    /// @notice Contract owner for emergency functions
    address public owner;

    /// @notice Whitelisted targets that are allowed to be called
    mapping(address => bool) public whitelistedTargets;

    event OwnershipTransferred(
        address indexed previousOwner,
        address indexed newOwner
    );
    event EmergencyWithdrawETH(address indexed to, uint256 amount);
    event EmergencyWithdrawToken(
        address indexed token,
        address indexed to,
        uint256 amount
    );
    event TargetWhitelisted(address indexed target, bool status);
    event SelectorWhitelisted(bytes4 indexed selector, uint256 offset);
    event Executed(
        address indexed user,
        uint256 pullCount,
        uint256 callCount,
        uint256 ethReturned
    );

    modifier nonReentrant() {
        if (_status != _UNLOCKED) revert ReentrancyGuard();
        _status = _LOCKED;
        _;
        _status = _UNLOCKED;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "NOT_OWNER");
        _;
    }

    constructor(address[] memory initialTargets) {
        owner = msg.sender;

        // Whitelist initial DEX routers (passed as parameter for chain flexibility)
        for (uint256 i = 0; i < initialTargets.length; i++) {
            if (initialTargets[i] != address(0)) {
                whitelistedTargets[initialTargets[i]] = true;
            }
        }

        // Initialize default selector offsets
        // V2: swapExactTokensForTokens -> amountIn at offset 4
        selectorOffsets[0x38ed1739] = 4;
        // V3: exactInputSingle (with deadline) -> amountIn at offset 164
        selectorOffsets[0x04e45aaf] = 132;
        // V3: exactInput (multi-hop) -> amountIn at offset 100
        selectorOffsets[0xc04b8d59] = 100;
        // V3: exactInputSingle (SwapRouter02, no deadline) -> amountIn at offset 132
        selectorOffsets[0x414bf389] = 164;
    }

    receive() external payable {}

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "INVALID_OWNER");
        address oldOwner = owner;
        owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }

    function emergencyWithdrawETH(address payable to) external onlyOwner {
        require(to != address(0), "INVALID_RECIPIENT");
        uint256 balance = address(this).balance;
        require(balance > 0, "NO_ETH_BALANCE");
        (bool success, ) = to.call{value: balance}("");
        require(success, "ETH_TRANSFER_FAILED");
        emit EmergencyWithdrawETH(to, balance);
    }

    function emergencyWithdrawToken(
        address token,
        address to
    ) external onlyOwner {
        require(to != address(0), "INVALID_RECIPIENT");
        uint256 balance = IERC20Minimal(token).balanceOf(address(this));
        require(balance > 0, "NO_TOKEN_BALANCE");
        (bool success, bytes memory returnData) = token.call(
            abi.encodeWithSelector(IERC20Minimal.transfer.selector, to, balance)
        );
        require(
            success &&
                (returnData.length == 0 || abi.decode(returnData, (bool))),
            "TOKEN_TRANSFER_FAILED"
        );
        emit EmergencyWithdrawToken(token, to, balance);
    }

    function setWhitelistedTarget(
        address target,
        bool status
    ) external onlyOwner {
        require(target != address(0), "INVALID_TARGET");
        whitelistedTargets[target] = status;
        emit TargetWhitelisted(target, status);
    }

    function batchWhitelistTargets(
        address[] calldata targets
    ) external onlyOwner {
        require(targets.length <= MAX_BATCH_WHITELIST, "TOO_MANY_TARGETS");
        for (uint256 i = 0; i < targets.length; i++) {
            require(targets[i] != address(0), "INVALID_TARGET");
            whitelistedTargets[targets[i]] = true;
            emit TargetWhitelisted(targets[i], true);
        }
    }

    /// @notice Add or update a whitelisted selector for injection
    /// @param selector The function selector (first 4 bytes of calldata)
    /// @param offset The expected amountIn offset. Use 0 to remove from whitelist.
    function setSelectorOffset(
        bytes4 selector,
        uint256 offset
    ) external onlyOwner {
        if (offset != 0) {
            // Validate offset is reasonable: 4 bytes selector + N*32 bytes params
            if (offset < 4) revert InvalidOffset(offset);
        }
        selectorOffsets[selector] = offset;
        emit SelectorWhitelisted(selector, offset);
    }

    /// @notice Executes a sequence of arbitrary calls after pulling ERC-20 funds from caller.
    /// @param pulls Tokens and amounts to transfer from caller into executor.
    /// @param approvals ERC-20 approvals to set. Revoked after execution if revokeAfter=true.
    /// @param calls Arbitrary calls (DEX swaps, etc.).
    /// @param tokensToFlush Token addresses to sweep to caller after execution.
    /// @return results Raw return data for each call.
    /// @dev SECURITY: Recipient is always msg.sender. tokensToFlush lets user specify output tokens.
    function execute(
        TokenPull[] calldata pulls,
        Approval[] calldata approvals,
        Call[] calldata calls,
        address[] calldata tokensToFlush
    ) external payable nonReentrant returns (bytes[] memory results) {
        // SECURITY: Array length limits
        if (pulls.length > MAX_PULLS)
            revert ArrayLengthExceeded("pulls", pulls.length, MAX_PULLS);
        if (approvals.length > MAX_APPROVALS)
            revert ArrayLengthExceeded(
                "approvals",
                approvals.length,
                MAX_APPROVALS
            );
        if (calls.length > MAX_CALLS)
            revert ArrayLengthExceeded("calls", calls.length, MAX_CALLS);
        if (tokensToFlush.length > MAX_FLUSH_TOKENS)
            revert ArrayLengthExceeded(
                "tokensToFlush",
                tokensToFlush.length,
                MAX_FLUSH_TOKENS
            );

        // SECURITY: Safe ETH tracking - avoid underflow
        uint256 preExistingEth;
        {
            uint256 ethBefore = address(this).balance;
            preExistingEth = ethBefore > msg.value ? ethBefore - msg.value : 0;
        }

        // SECURITY: Track pre-existing token balances to prevent dust sweeping
        uint256[] memory preExistingTokenBalances = new uint256[](
            tokensToFlush.length
        );
        for (uint256 i = 0; i < tokensToFlush.length; i++) {
            address token = tokensToFlush[i];
            if (token == address(0)) continue;

            // SECURITY: Check for duplicate tokens in flush list
            for (uint256 j = 0; j < i; j++) {
                if (tokensToFlush[j] == token) {
                    revert DuplicateTokenInFlush(token);
                }
            }

            preExistingTokenBalances[i] = IERC20Minimal(token).balanceOf(
                address(this)
            );
        }

        // SECURITY: Track pulled amounts per token (summed for duplicates)
        (
            address[] memory pulledTokens,
            uint256[] memory pulledAmounts
        ) = _buildPulledTracker(pulls);

        _pullTokensFromSender(pulls);
        _validateAndSetApprovals(approvals);
        results = _performCalls(calls, pulledTokens, pulledAmounts);
        _revokeApprovals(approvals);

        // SECURITY: Flush only delta (current - pre-existing) for both tokens and ETH
        uint256 ethReturned = _flushBalances(
            msg.sender,
            tokensToFlush,
            preExistingTokenBalances,
            preExistingEth
        );

        emit Executed(msg.sender, pulls.length, calls.length, ethReturned);
    }

    /// @dev Builds tracking arrays, summing duplicate tokens
    function _buildPulledTracker(
        TokenPull[] calldata pulls
    ) private pure returns (address[] memory tokens, uint256[] memory amounts) {
        // First pass: identify unique tokens
        uint256 uniqueCount = 0;
        address[] memory tempTokens = new address[](pulls.length);
        uint256[] memory tempAmounts = new uint256[](pulls.length);

        for (uint256 i = 0; i < pulls.length; i++) {
            address token = pulls[i].token;
            uint256 amount = pulls[i].amount;

            // Check if token already in list
            bool found = false;
            for (uint256 j = 0; j < uniqueCount; j++) {
                if (tempTokens[j] == token) {
                    tempAmounts[j] += amount; // Sum duplicates
                    found = true;
                    break;
                }
            }

            if (!found) {
                tempTokens[uniqueCount] = token;
                tempAmounts[uniqueCount] = amount;
                uniqueCount++;
            }
        }

        // Create correctly sized arrays
        tokens = new address[](uniqueCount);
        amounts = new uint256[](uniqueCount);
        for (uint256 i = 0; i < uniqueCount; i++) {
            tokens[i] = tempTokens[i];
            amounts[i] = tempAmounts[i];
        }
    }

    function _pullTokensFromSender(TokenPull[] calldata pulls) private {
        for (uint256 index = 0; index < pulls.length; index++) {
            TokenPull calldata entry = pulls[index];
            if (entry.amount == 0) continue;

            (bool success, bytes memory returnData) = entry.token.call(
                abi.encodeWithSelector(
                    IERC20Minimal.transferFrom.selector,
                    msg.sender,
                    address(this),
                    entry.amount
                )
            );
            if (!success) {
                revert TokenPullFailed(entry.token, entry.amount);
            }
            if (returnData.length > 0 && !abi.decode(returnData, (bool))) {
                revert TokenPullFailed(entry.token, entry.amount);
            }
        }
    }

    function _validateAndSetApprovals(Approval[] calldata approvals) private {
        for (uint256 index = 0; index < approvals.length; index++) {
            Approval calldata entry = approvals[index];
            if (entry.amount == 0) continue;

            // SECURITY: Spender must be whitelisted
            if (!whitelistedTargets[entry.spender]) {
                revert SpenderNotWhitelisted(entry.spender);
            }

            // SECURITY: Reset to 0 first (USDT compatibility)
            _callToken(
                entry.token,
                abi.encodeWithSelector(
                    IERC20Minimal.approve.selector,
                    entry.spender,
                    0
                )
            );

            (bool success, bytes memory returnData) = entry.token.call(
                abi.encodeWithSelector(
                    IERC20Minimal.approve.selector,
                    entry.spender,
                    entry.amount
                )
            );
            if (!success) {
                revert TokenApprovalFailed(
                    entry.token,
                    entry.spender,
                    entry.amount
                );
            }
            if (returnData.length > 0 && !abi.decode(returnData, (bool))) {
                revert TokenApprovalFailed(
                    entry.token,
                    entry.spender,
                    entry.amount
                );
            }
        }
    }

    function _performCalls(
        Call[] calldata calls,
        address[] memory pulledTokens,
        uint256[] memory pulledAmounts
    ) private returns (bytes[] memory results) {
        results = new bytes[](calls.length);

        for (uint256 index = 0; index < calls.length; index++) {
            Call calldata entry = calls[index];

            // SECURITY: Target must be whitelisted
            if (!whitelistedTargets[entry.target]) {
                revert TargetNotWhitelisted(entry.target);
            }

            bytes memory data = entry.data;
            if (entry.injectToken != address(0)) {
                // SECURITY: Extract selector from calldata
                if (data.length < 4) {
                    revert InvalidInjectionOffset(
                        entry.injectOffset,
                        data.length
                    );
                }
                bytes4 selector;
                assembly {
                    // CRITICAL FIX: bytes4 reads from high bytes, so DON'T shift!
                    // mload returns selector already in high bytes: 0x414bf389...00
                    // shr(224) was WRONG - it moved selector to low bytes: 0x00...414bf389
                    // but bytes4 still reads high bytes, giving 0x00000000
                    selector := mload(add(data, 32))
                }

                // SECURITY: Validate offset matches known selector
                uint256 expectedOffset = _getExpectedOffset(selector);
                if (expectedOffset == 0) {
                    revert InvalidSelectorForInjection(selector);
                }
                if (entry.injectOffset != expectedOffset) {
                    revert OffsetMismatchForSelector(
                        selector,
                        entry.injectOffset,
                        expectedOffset
                    );
                }

                // SECURITY: Cap injection to pulled amount only
                // FIX: For multi-hop swaps, intermediate tokens (swap outputs) aren't in pulledTokens
                // If token wasn't pulled, it must be from a previous swap output - use full balance
                uint256 maxInjectAmount = _getPulledAmount(
                    entry.injectToken,
                    pulledTokens,
                    pulledAmounts
                );

                // Allow full balance for intermediate tokens (not pulled, but output from previous hop)
                if (maxInjectAmount == 0) {
                    maxInjectAmount = type(uint256).max;
                }

                uint256 tokenBalance = IERC20Minimal(entry.injectToken)
                    .balanceOf(address(this));
                uint256 amountToInject = tokenBalance > maxInjectAmount
                    ? maxInjectAmount
                    : tokenBalance;

                if (amountToInject == 0) revert ZeroAmountNotAllowed();

                if (entry.injectOffset + 32 > data.length) {
                    revert InvalidInjectionOffset(
                        entry.injectOffset,
                        data.length
                    );
                }

                uint256 offset = entry.injectOffset;
                assembly {
                    mstore(add(add(data, 32), offset), amountToInject)
                }
            }

            (bool success, bytes memory returnData) = entry.target.call{
                value: entry.value
            }(data);
            if (!success) {
                assembly {
                    let ptr := add(returnData, 0x20)
                    let size := mload(returnData)
                    revert(ptr, size)
                }
            }
            results[index] = returnData;
        }
    }

    /// @dev Returns SUM of amounts for a token (handles duplicates)
    function _getPulledAmount(
        address token,
        address[] memory pulledTokens,
        uint256[] memory pulledAmounts
    ) private pure returns (uint256) {
        for (uint256 i = 0; i < pulledTokens.length; i++) {
            if (pulledTokens[i] == token) {
                return pulledAmounts[i]; // Already summed in _buildPulledTracker
            }
        }
        return 0;
    }

    /// @dev Returns expected injection offset from storage mapping
    /// @param selector The function selector to look up
    /// @return offset Expected offset, or 0 if selector is not whitelisted
    function _getExpectedOffset(
        bytes4 selector
    ) private view returns (uint256) {
        return selectorOffsets[selector];
    }

    function _revokeApprovals(Approval[] calldata approvals) private {
        for (uint256 index = 0; index < approvals.length; index++) {
            Approval calldata entry = approvals[index];
            if (!entry.revokeAfter || entry.amount == 0) continue;

            _callToken(
                entry.token,
                abi.encodeWithSelector(
                    IERC20Minimal.approve.selector,
                    entry.spender,
                    0
                )
            );
        }
    }

    function _flushBalances(
        address recipient,
        address[] calldata tokensToFlush,
        uint256[] memory preExistingTokenBalances,
        uint256 preExistingEth
    ) private returns (uint256 ethReturned) {
        require(recipient != address(0), "INVALID_RECIPIENT");

        // SECURITY: Flush only token DELTA (current - pre-existing)
        for (uint256 index = 0; index < tokensToFlush.length; index++) {
            address token = tokensToFlush[index];
            if (token == address(0)) continue;

            uint256 currentBalance = IERC20Minimal(token).balanceOf(
                address(this)
            );
            uint256 preExisting = preExistingTokenBalances[index];

            // Only flush the delta (what was added during this execution)
            if (currentBalance > preExisting) {
                uint256 deltaToFlush = currentBalance - preExisting;
                _callToken(
                    token,
                    abi.encodeWithSelector(
                        IERC20Minimal.transfer.selector,
                        recipient,
                        deltaToFlush
                    )
                );
            }
        }

        // SECURITY: Only return ETH delta (excluding pre-existing dust)
        uint256 currentEthBalance = address(this).balance;
        if (currentEthBalance > preExistingEth) {
            ethReturned = currentEthBalance - preExistingEth;
            (bool success, ) = recipient.call{value: ethReturned}("");
            if (!success) revert NativeTransferFailed(recipient, ethReturned);
        }
    }

    function _callToken(address token, bytes memory data) private {
        (bool success, bytes memory returnData) = token.call(data);
        if (!success) {
            revert TokenFlushFailed(token);
        }
        if (returnData.length > 0 && !abi.decode(returnData, (bool))) {
            revert TokenFlushFailed(token);
        }
    }
}
