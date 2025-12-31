const hre = require("hardhat");

async function main() {
    console.log("🚀 LuxExecutor (AequiExecutor) Deployment Script");
    console.log("=".repeat(50));
    console.log(`Network: ${hre.network.name}`);
    console.log(`Chain ID: ${(await hre.ethers.provider.getNetwork()).chainId}`);

    const [deployer] = await hre.ethers.getSigners();
    console.log(`Deployer: ${deployer.address}`);

    const balance = await hre.ethers.provider.getBalance(deployer.address);
    console.log(`Balance: ${hre.ethers.formatEther(balance)} BNB`);
    console.log("=".repeat(50));

    // Constructor Parameters - BSC DEX Router Addresses
    // These are the initial whitelisted targets
    const initialTargets = [
        "0x10ED43C718714eb63d5aA57B78B54704E256024E", // PancakeSwap V2 Router
        "0x1b81D678ffb9C0263b24A97847620C99d213eB14", // PancakeSwap V3 SwapRouter
        "0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24", // Uniswap V3 Router (BSC)
        "0xB971eF87ede563556b2ED4b1C0b0019111Dd85d2", // Biswap Router
    ];

    console.log("\n📋 Initial Whitelisted DEX Routers:");
    console.log("-".repeat(50));
    console.log("1. PancakeSwap V2 Router:", initialTargets[0]);
    console.log("2. PancakeSwap V3 SwapRouter:", initialTargets[1]);
    console.log("3. Uniswap V3 Router (BSC):", initialTargets[2]);
    console.log("4. Biswap Router:", initialTargets[3]);
    console.log("-".repeat(50));

    console.log("\n⏳ Deploying AequiExecutor contract...\n");

    // Deploy the contract
    const AequiExecutor = await hre.ethers.getContractFactory("AequiExecutor");
    const executor = await AequiExecutor.deploy(initialTargets);

    await executor.waitForDeployment();
    const contractAddress = await executor.getAddress();

    console.log("✅ AequiExecutor deployed successfully!");
    console.log("=".repeat(50));
    console.log(`📍 Contract Address: ${contractAddress}`);
    console.log(`👤 Owner: ${await executor.owner()}`);
    console.log("=".repeat(50));

    // Verify whitelisted targets
    console.log("\n🔍 Verifying whitelisted targets...");
    for (let i = 0; i < initialTargets.length; i++) {
        const isWhitelisted = await executor.whitelistedTargets(initialTargets[i]);
        console.log(`  ${initialTargets[i]}: ${isWhitelisted ? "✅" : "❌"}`);
    }

    // Verify default selector offsets
    console.log("\n🔍 Default Selector Offsets:");
    console.log("-".repeat(50));

    const selectors = [
        { name: "V2 swapExactTokensForTokens", selector: "0x38ed1739", expectedOffset: 4 },
        { name: "V3 exactInputSingle (deadline)", selector: "0x04e45aaf", expectedOffset: 132 },
        { name: "V3 exactInput (multi-hop)", selector: "0xc04b8d59", expectedOffset: 100 },
        { name: "V3 exactInputSingle (no deadline)", selector: "0x414bf389", expectedOffset: 164 },
    ];

    for (const { name, selector, expectedOffset } of selectors) {
        const offset = await executor.selectorOffsets(selector);
        console.log(`  ${name}`);
        console.log(`    Selector: ${selector}`);
        console.log(`    Offset: ${offset} (expected: ${expectedOffset}) ${Number(offset) === expectedOffset ? "✅" : "❌"}`);
    }

    console.log("\n" + "=".repeat(50));
    console.log("🎉 Deployment completed!");
    console.log("=".repeat(50));

    // BSCScan verification command
    if (hre.network.name === "bsc" || hre.network.name === "bscTestnet") {
        console.log("\n📝 To verify on BSCScan, run:");
        console.log(`npx hardhat verify --network ${hre.network.name} ${contractAddress} '["${initialTargets.join('","')}"]'`);
    }

    return {
        address: contractAddress,
        owner: await executor.owner(),
        initialTargets,
    };
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error("❌ Deployment failed:", error);
        process.exit(1);
    });
