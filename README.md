# 🚀 LuxExecutor 

Multicall-style DEX Executor smart contract. Pulls funds from users, executes swap operations through DEX routers, and returns output tokens back to the caller.

## 📋 Table of Contents

- [What Does It Do?](#-what-does-it-do)
- [Features](#-features)
- [Offset Logic](#-offset-logic)
- [Installation](#-installation)
- [Deployment Instructions](#-deployment-instructions)
- [Constructor Parameters](#-constructor-parameters)
- [Usage](#-usage)

---

## 🎯 What Does It Do?

**LuxExecutor** is a **multicall executor** contract that enables users to perform multiple DEX swap operations in a single transaction.

### Workflow:
```
1. User → Sends tokens to the contract (pull)
2. Contract → Approves DEX routers
3. Contract → Executes DEX swap calls
4. Contract → Returns output tokens to user (flush)
```

### Use Cases:
- 🔄 **Multi-hop Swap**: Token A → Token B → Token C
- ⚡ **Aggregation**: Split swaps across multiple DEXes
- 🛡️ **Stateless Design**: Funds always return to user after each execution

---

## ✨ Features

| Feature | Description |
|---------|-------------|
| 🔒 **Reentrancy Guard** | Protection against reentrancy attacks |
| ⚪ **Target Whitelist** | Only approved DEX routers can be called |
| 📊 **Selector Whitelist** | Injection only for known function selectors |
| 💉 **Amount Injection** | Dynamic token amount injection into calldata |
| 🚿 **Token Flush** | All tokens return to user after execution |
| 🆘 **Emergency Withdraw** | Owner can withdraw funds in emergencies |

---

## 🧮 Offset Logic

### What Is It?

**Offset** specifies the **byte position** of the `amountIn` parameter within the calldata of DEX router function calls. This allows the contract to dynamically inject the token amount into the calldata during swap execution.

### Why Is It Needed?

When a user sends a swap request, the actual token amount may not be known in advance (e.g., slippage, amount from previous hop). The contract checks its own balance, determines the real amount, and writes it to the correct position in the calldata.

### Calldata Structure

```
┌──────────────────────────────────────────────────────────────────┐
│ Byte 0-3   │ Byte 4+                                             │
│ Selector   │ Encoded Parameters                                  │
│ (4 bytes)  │ (32 bytes per parameter)                            │
└──────────────────────────────────────────────────────────────────┘
```

### Default Selector Offsets

| Selector | Function | Offset | Description |
|----------|----------|--------|-------------|
| `0x38ed1739` | `swapExactTokensForTokens` (V2) | **4** | First parameter (amountIn) |
| `0x04e45aaf` | `exactInputSingle` (V3, deadline) | **132** | amountIn inside struct |
| `0xc04b8d59` | `exactInput` (V3, multi-hop) | **100** | amountIn in Params struct |
| `0x414bf389` | `exactInputSingle` (V3, no deadline) | **164** | ExactInputSingleParams.amountIn |

### Offset Calculation Example

**V2 Router - `swapExactTokensForTokens`:**
```solidity
function swapExactTokensForTokens(
    uint amountIn,      // ← Offset 4 (first param after selector)
    uint amountOutMin,  // ← Offset 36
    address[] path,     // ← Offset 68 (pointer)
    address to,         // ← Offset 100
    uint deadline       // ← Offset 132
)
```

**V3 Router - `exactInputSingle` (SwapRouter02):**
```solidity
struct ExactInputSingleParams {
    address tokenIn;     // Offset 4 (struct start)
    address tokenOut;    // Offset 36
    uint24 fee;          // Offset 68
    address recipient;   // Offset 100
    uint256 amountIn;    // Offset 132 ← WRITTEN TO THIS POSITION
    uint256 amountOutMin;// Offset 164
    uint160 sqrtPriceLimit; // Offset 196
}
```

### Injection Process

```
1. Contract extracts selector from call.data
2. Gets expected offset from selectorOffsets mapping
3. Compares with call.injectOffset (security check)
4. Gets token balance
5. Writes amount to calldata[offset:offset+32] using assembly
6. Makes DEX call with modified calldata
```

### Adding New Selectors

```solidity
// Define new selector offset as owner
executor.setSelectorOffset(
    0xDEADBEEF,  // Function selector
    68          // amountIn offset position
);

// To remove, send offset 0
executor.setSelectorOffset(0xDEADBEEF, 0);
```

---

## 🛠️ Installation

### Requirements
- Node.js >= 18.0.0
- npm or yarn

### Steps

```bash
# 1. Install dependencies
npm install

# 2. Create .env file
cp .env.example .env

# 3. Edit .env file
# PRIVATE_KEY=your_private_key_here
# BSCSCAN_API_KEY=your_api_key_here

# 4. Compile
npm run compile
```

---

## 🚀 Deployment Instructions

### BSC Mainnet

```bash
npm run deploy:bsc
```

### BSC Testnet

```bash
npm run deploy:bsc-testnet
```

### Local Development

```bash
# Terminal 1: Start Hardhat node
npx hardhat node

# Terminal 2: Deploy
npm run deploy:local
```

### Contract Verification (BSCScan)

Run the command printed in the console after deployment:

```bash
npx hardhat verify --network bsc <CONTRACT_ADDRESS> '["0x10ED43C718714eb63d5aA57B78B54704E256024E","0x1b81D678ffb9C0263b24A97847620C99d213eB14","0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24","0xB971eF87ede563556b2ED4b1C0b0019111Dd85d2"]'
```

---

## 📦 Constructor Parameters

The constructor takes a single parameter:

```solidity
constructor(address[] memory initialTargets)
```

### Default Values for BSC Mainnet:

```javascript
const initialTargets = [
    "0x10ED43C718714eb63d5aA57B78B54704E256024E",  // PancakeSwap V2 Router
    "0x1b81D678ffb9C0263b24A97847620C99d213eB14",  // PancakeSwap V3 SwapRouter
    "0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24",  // Uniswap V3 Router (BSC)
    "0xB971eF87ede563556b2ED4b1C0b0019111Dd85d2",  // Biswap Router
];
```

### For Other Chains:

When deploying on different chains, update the `initialTargets` array in `scripts/deploy.js` with the DEX router addresses for that chain.

---

## 📖 Usage

### Execute Function

```solidity
function execute(
    TokenPull[] calldata pulls,      // Tokens to pull from user
    Approval[] calldata approvals,   // Approvals for DEXes
    Call[] calldata calls,           // DEX swap calls
    address[] calldata tokensToFlush // Tokens to return to user
) external payable returns (bytes[] memory results)
```

### Example Call (JavaScript)

```javascript
const executor = await ethers.getContractAt("LuxExecutor", EXECUTOR_ADDRESS);

// Token A -> Token B swap
const tx = await executor.execute(
    // pulls: Pull 100 USDT from user
    [{ token: USDT_ADDRESS, amount: ethers.parseUnits("100", 18) }],
    
    // approvals: Approve PancakeSwap router
    [{ 
        token: USDT_ADDRESS, 
        spender: PANCAKE_ROUTER, 
        amount: ethers.parseUnits("100", 18),
        revokeAfter: true  // Revoke approval after execution
    }],
    
    // calls: Swap call
    [{
        target: PANCAKE_ROUTER,
        value: 0,
        data: swapCalldata,
        injectToken: USDT_ADDRESS,    // This token amount will be injected
        injectOffset: 4               // Offset for V2
    }],
    
    // tokensToFlush: Send output token to user
    [BUSD_ADDRESS]
);
```

---

## ⚠️ Security Notes

1. **Whitelisted Targets Only**: Contract only interacts with whitelisted addresses
2. **Selector Validation**: Injection only happens for known selectors
3. **Amount Capping**: Injected amount cannot exceed pulled amount
4. **Stateless**: All funds return to user after each execution
5. **Reentrancy Protection**: Protection against recursive calls

---

## 📄 License

MIT License
