// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title  ExecuteAndSeed
 * @notice Step 2 of 2 — Seeds all three vaults with initial deposits,
 *         allocations, demo utilization, and supply rates.
 *
 *  Run immediately after DeployAndSubmit.s.sol (no timelock to wait for).
 *
 *    source .env
 *    forge script script/ExecuteAndSeed.s.sol \
 *      --rpc-url somnia_testnet \
 *      --broadcast \
 *      --private-key $PRIVATE_KEY \
 *      --gas-estimate-multiplier 3000
 *
 *  Requires the following .env vars to be set from Step 1 output:
 *    USDC_VAULT_ADDRESS, WETH_VAULT_ADDRESS, WBTC_VAULT_ADDRESS
 *    MOCK_USDC_ADDRESS, MOCK_WETH_ADDRESS, MOCK_WBTC_ADDRESS
 *    USDC_MARKET_A_ADDRESS, USDC_MARKET_B_ADDRESS
 *    WETH_MARKET_A_ADDRESS, WETH_MARKET_B_ADDRESS
 *    WBTC_MARKET_A_ADDRESS, WBTC_MARKET_B_ADDRESS
 *    VAULT_SENTINEL_ADDRESS, USDC_STRATEGIST_ADDRESS
 */

import {Script, console} from "forge-std/Script.sol";
import "../src/Mock/MockERC20.sol";
import "../src/Mock/MockUSDC.sol";
import "../src/Mock/MockLendingMarket.sol";
import "../src/CuratedVault.sol";
import "../src/VaultSentinel.sol";
import {AllocationStrategist} from "../src/AllocationStrategist.sol";

contract ExecuteAndSeed is Script {
    bytes32 constant ALLOCATOR_ROLE = keccak256("ALLOCATOR_ROLE");

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");

        // ── USDC vault ────────────────────────────────────────────────────────
        address usdcAddr = vm.envAddress("MOCK_USDC_ADDRESS");
        address usdcVaultAddr = vm.envAddress("USDC_VAULT_ADDRESS");
        address usdcMarketA = vm.envAddress("USDC_MARKET_A_ADDRESS");
        address usdcMarketB = vm.envAddress("USDC_MARKET_B_ADDRESS");
        address usdcStratAddr = vm.envAddress("USDC_STRATEGIST_ADDRESS");

        // ── WETH vault ────────────────────────────────────────────────────────
        address wethAddr = vm.envAddress("MOCK_WETH_ADDRESS");
        address wethVaultAddr = vm.envAddress("WETH_VAULT_ADDRESS");
        address wethMarketA = vm.envAddress("WETH_MARKET_A_ADDRESS");
        address wethMarketB = vm.envAddress("WETH_MARKET_B_ADDRESS");

        // ── WBTC vault ────────────────────────────────────────────────────────
        address wbtcAddr = vm.envAddress("MOCK_WBTC_ADDRESS");
        address wbtcVaultAddr = vm.envAddress("WBTC_VAULT_ADDRESS");
        address wbtcMarketA = vm.envAddress("WBTC_MARKET_A_ADDRESS");
        address wbtcMarketB = vm.envAddress("WBTC_MARKET_B_ADDRESS");

        // ── Cast to contract types ─────────────────────────────────────────────
        MockUSDC usdc = MockUSDC(usdcAddr);
        MockERC20 weth = MockERC20(wethAddr);
        MockERC20 wbtc = MockERC20(wbtcAddr);

        CuratedVault vaultUSDC = CuratedVault(usdcVaultAddr);
        CuratedVault vaultWETH = CuratedVault(wethVaultAddr);
        CuratedVault vaultWBTC = CuratedVault(wbtcVaultAddr);

        MockLendingMarket mktUsdcA = MockLendingMarket(usdcMarketA);
        MockLendingMarket mktUsdcB = MockLendingMarket(usdcMarketB);
        MockLendingMarket mktWethA = MockLendingMarket(wethMarketA);
        MockLendingMarket mktWethB = MockLendingMarket(wethMarketB);
        MockLendingMarket mktWbtcA = MockLendingMarket(wbtcMarketA);
        MockLendingMarket mktWbtcB = MockLendingMarket(wbtcMarketB);

        vm.startBroadcast(deployerKey);

        // ══════════════════════════════════════════════════════════════════════
        // USDC VAULT — seed
        // ══════════════════════════════════════════════════════════════════════

        usdc.mint(deployer, 200_000 * 1e6); // 200k USDC
        usdc.approve(usdcVaultAddr, 100_000 * 1e6);
        vaultUSDC.deposit(100_000 * 1e6, deployer); // deposit 100k
        vaultUSDC.allocate(usdcMarketA, 30_000 * 1e6); // 30k to A (30%)
        vaultUSDC.allocate(usdcMarketB, 20_000 * 1e6); // 20k to B (20%)
        // 50k idle (50%)

        // Demo utilization + supply rates
        mktUsdcA.setUtilization(45); // 45% — safe, moderate yield
        mktUsdcB.setUtilization(72); // 72% — approaching caution
        mktUsdcA.setSupplyRate(300); // 3.0% APY
        mktUsdcB.setSupplyRate(520); // 5.2% APY

        console.log("USDC vault seeded: 100k deposited, 30k+20k allocated");
        console.log("  Market A: util=45%, APY=3.0%");
        console.log("  Market B: util=72%, APY=5.2%");

        // ══════════════════════════════════════════════════════════════════════
        // WETH VAULT — seed
        // ══════════════════════════════════════════════════════════════════════

        weth.mint(deployer, 200 * 1e18); // 200 WETH
        weth.approve(wethVaultAddr, 100 * 1e18);
        vaultWETH.deposit(100 * 1e18, deployer); // deposit 100 WETH
        vaultWETH.allocate(wethMarketA, 30 * 1e18); // 30 WETH to A
        vaultWETH.allocate(wethMarketB, 20 * 1e18); // 20 WETH to B

        mktWethA.setUtilization(55); // 55%
        mktWethB.setUtilization(68); // 68%
        mktWethA.setSupplyRate(380); // 3.8% APY
        mktWethB.setSupplyRate(510); // 5.1% APY

        console.log("WETH vault seeded: 100 WETH deposited, 30+20 allocated");
        console.log("  Market A: util=55%, APY=3.8%");
        console.log("  Market B: util=68%, APY=5.1%");

        // ══════════════════════════════════════════════════════════════════════
        // WBTC VAULT — seed
        // ══════════════════════════════════════════════════════════════════════

        wbtc.mint(deployer, 20 * 1e8); // 20 WBTC (8 dec)
        wbtc.approve(wbtcVaultAddr, 10 * 1e8);
        vaultWBTC.deposit(10 * 1e8, deployer); // deposit 10 WBTC
        vaultWBTC.allocate(wbtcMarketA, 3 * 1e8); // 3 WBTC to A
        vaultWBTC.allocate(wbtcMarketB, 2 * 1e8); // 2 WBTC to B

        mktWbtcA.setUtilization(40); // 40%
        mktWbtcB.setUtilization(62); // 62%
        mktWbtcA.setSupplyRate(280); // 2.8% APY
        mktWbtcB.setSupplyRate(450); // 4.5% APY

        console.log("WBTC vault seeded: 10 WBTC deposited, 3+2 allocated");
        console.log("  Market A: util=40%, APY=2.8%");
        console.log("  Market B: util=62%, APY=4.5%");

        vm.stopBroadcast();

        // ── Verification printout ─────────────────────────────────────────────
        console.log("\n====================================================");
        console.log("VAULT STATE AFTER SEED");
        console.log("====================================================");

        console.log("\n[ USDC Vault ]");
        console.log("  totalAssets (USDC):  ", vaultUSDC.totalAssets() / 1e6);
        console.log("  idle buffer (bps):   ", vaultUSDC.idleBufferBps());
        console.log("  alloc A (bps):       ", vaultUSDC.marketAllocationBps(usdcMarketA));
        console.log("  alloc B (bps):       ", vaultUSDC.marketAllocationBps(usdcMarketB));
        console.log("  share price:         ", vaultUSDC.sharePrice());
        console.log("  epoch:               ", vaultUSDC.currentEpoch());

        console.log("\n[ WETH Vault ]");
        console.log("  totalAssets (wei):   ", vaultWETH.totalAssets());
        console.log("  idle buffer (bps):   ", vaultWETH.idleBufferBps());
        console.log("  alloc A (bps):       ", vaultWETH.marketAllocationBps(wethMarketA));
        console.log("  alloc B (bps):       ", vaultWETH.marketAllocationBps(wethMarketB));

        console.log("\n[ WBTC Vault ]");
        console.log("  totalAssets (sat):   ", vaultWBTC.totalAssets());
        console.log("  idle buffer (bps):   ", vaultWBTC.idleBufferBps());
        console.log("  alloc A (bps):       ", vaultWBTC.marketAllocationBps(wbtcMarketA));
        console.log("  alloc B (bps):       ", vaultWBTC.marketAllocationBps(wbtcMarketB));

        // Verify strategist wiring
        address usdcStrat = vm.envOr("USDC_STRATEGIST_ADDRESS", address(0));
        if (usdcStrat != address(0)) {
            console.log("\n[ Strategist wiring ]");
            console.log("  USDC strategist has ALLOCATOR_ROLE:", vaultUSDC.hasRole(ALLOCATOR_ROLE, usdcStrat));
        }

        console.log("\n====================================================");
        console.log("DEPLOYMENT COMPLETE");
        console.log("====================================================");
        console.log("");
        console.log("Next steps:");
        console.log("  1. Update frontend/src/config.js VAULTS array with new addresses");
        console.log("  2. Trigger AI risk check:");
        console.log("     cast send $VAULT_SENTINEL_ADDRESS 'checkVault(address)'");
        console.log("       $USDC_VAULT_ADDRESS --value 0.25ether");
        console.log("       --rpc-url $SOMNIA_TESTNET_RPC --private-key $PRIVATE_KEY");
        console.log("  3. Trigger AI rebalance:");
        console.log("     cast send $USDC_STRATEGIST_ADDRESS 'requestRebalance(address)'");
        console.log("       $USDC_VAULT_ADDRESS --value 0.5ether");
        console.log("       --rpc-url $SOMNIA_TESTNET_RPC --private-key $PRIVATE_KEY");
    }
}
