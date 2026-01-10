// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";

contract LuxExecutor is Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Address for address;

    error ExecutionFailed(uint256 index, address target, bytes reason);
    error InvalidInjectionOffset(uint256 offset, uint256 length);
    error ZeroAmountInjection();
    error TargetNotWhitelisted(address target);

    // Router whitelist for security - only approved targets can be called
    mapping(address => bool) public whitelistedTargets;

    event TargetWhitelisted(address indexed target, bool status);

    struct TokenPull {
        address token;
        uint256 amount;
    }

    struct Approval {
        address token;
        address spender;
        uint256 amount;
    }
    // Note: revokeAfter removed - always revoke for security

    struct Call {
        address target;
        uint256 value;
        bytes data;
        address injectToken; // If non-zero, injects the balance of this token into the call data
        uint256 injectOffset; // The byte offset in 'data' to overwrite with the balance
    }

    constructor(address initialOwner) Ownable(initialOwner) {
        // BSC DEX Routers - automatically whitelisted
        whitelistedTargets[0x10ED43C718714eb63d5aA57B78B54704E256024E] = true; // PancakeSwap V2 Router
        whitelistedTargets[0x1b81D678ffb9C0263b24A97847620C99d213eB14] = true; // PancakeSwap V3 Router
        whitelistedTargets[0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24] = true; // Uniswap V2 Router (BSC)
        whitelistedTargets[0xB971eF87ede563556b2ED4b1C0b0019111Dd85d2] = true; // Uniswap V3 Router (BSC)
        whitelistedTargets[0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c] = true; // WBNB (for wrap/unwrap)
    }

    receive() external payable {}

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function rescueFunds(
        address token,
        address to,
        uint256 amount
    ) external onlyOwner {
        IERC20(token).safeTransfer(to, amount);
    }

    function rescueETH(address payable to, uint256 amount) external onlyOwner {
        Address.sendValue(to, amount);
    }

    /// @notice Add or remove a target from the whitelist
    /// @param target The address to whitelist/unwhitelist
    /// @param status True to whitelist, false to remove
    function setWhitelistedTarget(
        address target,
        bool status
    ) external onlyOwner {
        whitelistedTargets[target] = status;
        emit TargetWhitelisted(target, status);
    }

    /// @notice Batch whitelist multiple targets
    /// @param targets Array of addresses to whitelist
    function batchWhitelistTargets(
        address[] calldata targets
    ) external onlyOwner {
        for (uint256 i; i < targets.length; ) {
            whitelistedTargets[targets[i]] = true;
            emit TargetWhitelisted(targets[i], true);
            unchecked {
                ++i;
            }
        }
    }

    function execute(
        TokenPull[] calldata pulls,
        Approval[] calldata approvals,
        Call[] calldata calls,
        address[] calldata tokensToFlush
    )
        external
        payable
        nonReentrant
        whenNotPaused
        returns (bytes[] memory results)
    {
        uint256 ethBalanceBefore = address(this).balance - msg.value;
        uint256[] memory tokenBalancesBefore = _snapshotBalances(tokensToFlush);

        _pullTokens(pulls);
        _setApprovals(approvals);
        results = _performCalls(calls);
        _revokeApprovals(approvals);
        _flushDeltas(
            msg.sender,
            tokensToFlush,
            tokenBalancesBefore,
            ethBalanceBefore
        );
    }

    function _snapshotBalances(
        address[] calldata tokens
    ) private view returns (uint256[] memory balances) {
        balances = new uint256[](tokens.length);
        for (uint256 i; i < tokens.length; ) {
            balances[i] = IERC20(tokens[i]).balanceOf(address(this));
            unchecked {
                ++i;
            }
        }
    }

    function _pullTokens(TokenPull[] calldata pulls) private {
        for (uint256 i; i < pulls.length; ) {
            TokenPull calldata p = pulls[i];
            IERC20(p.token).safeTransferFrom(
                msg.sender,
                address(this),
                p.amount
            );
            unchecked {
                ++i;
            }
        }
    }

    function _setApprovals(Approval[] calldata approvals) private {
        for (uint256 i; i < approvals.length; ) {
            Approval calldata a = approvals[i];
            IERC20(a.token).forceApprove(a.spender, a.amount);
            unchecked {
                ++i;
            }
        }
    }

    function _performCalls(
        Call[] calldata calls
    ) private returns (bytes[] memory results) {
        results = new bytes[](calls.length);
        for (uint256 i; i < calls.length; ) {
            Call calldata c = calls[i];

            // Security: Only allow calls to whitelisted targets
            if (!whitelistedTargets[c.target])
                revert TargetNotWhitelisted(c.target);

            bytes memory data = c.data;

            if (c.injectToken != address(0)) {
                uint256 injectedAmount = IERC20(c.injectToken).balanceOf(
                    address(this)
                );
                if (injectedAmount == 0) revert ZeroAmountInjection();

                if (c.injectOffset + 32 > data.length)
                    revert InvalidInjectionOffset(c.injectOffset, data.length);

                uint256 offset = c.injectOffset;
                assembly {
                    mstore(add(add(data, 32), offset), injectedAmount)
                }
            }

            (bool success, bytes memory ret) = c.target.call{value: c.value}(
                data
            );

            if (!success) {
                if (ret.length > 0) {
                    assembly {
                        let returndata_size := mload(ret)
                        revert(add(32, ret), returndata_size)
                    }
                } else {
                    revert ExecutionFailed(i, c.target, "");
                }
            }
            results[i] = ret;
            unchecked {
                ++i;
            }
        }
    }

    function _revokeApprovals(Approval[] calldata approvals) private {
        for (uint256 i; i < approvals.length; ) {
            Approval calldata a = approvals[i];
            // Security: ALWAYS revoke approvals to prevent hijacking
            IERC20(a.token).forceApprove(a.spender, 0);
            unchecked {
                ++i;
            }
        }
    }

    function _flushDeltas(
        address recipient,
        address[] calldata tokens,
        uint256[] memory balancesBefore,
        uint256 ethBalanceBefore
    ) private {
        for (uint256 i; i < tokens.length; ) {
            uint256 balanceAfter = IERC20(tokens[i]).balanceOf(address(this));
            // Token Dust Protection: Only flush the delta (difference)
            // This prevents dust attacks where attacker sends small amounts before tx
            if (balanceAfter > balancesBefore[i]) {
                uint256 delta = balanceAfter - balancesBefore[i];
                // Only transfer if delta is meaningful (> 0)
                if (delta > 0) {
                    IERC20(tokens[i]).safeTransfer(recipient, delta);
                }
            }
            unchecked {
                ++i;
            }
        }

        // ETH Dust Protection: Same principle
        uint256 ethBalanceAfter = address(this).balance;
        if (ethBalanceAfter > ethBalanceBefore) {
            uint256 ethDelta = ethBalanceAfter - ethBalanceBefore;
            if (ethDelta > 0) {
                Address.sendValue(payable(recipient), ethDelta);
            }
        }
    }
}
