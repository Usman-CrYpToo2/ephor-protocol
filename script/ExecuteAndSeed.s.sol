// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title  ExecuteAndSeed
 * @notice Step 2 of 3 for testnet deployment.
 *
 *         Run this AT LEAST 1 MINUTE after DeployAndSubmit.s.sol.
 *         Executes the timelocked market additions, mints USDC, deposits into
 *         the vault, allocates to both markets, and sets demo utilization so
 *         the AI sentinel has something meaningful to evaluate.
 *
 *  Run:
 *    source .env
 *    forge script script/ExecuteAndSeed.s.sol \
 *      --rpc-url $SOMNIA_TESTNET_RPC \
 *      --broadcast \
 *      --private-key $PRIVATE_KEY \
 *      -vvvv
 *
 *  STT required: ~0.05 STT for gas.
 */

import {Script, console} from "forge-std/Script.sol";
import "../src/Mock/MockUSDC.sol";
import "../src/Mock/MockLendingMarket.sol";
import "../src/CuratedVault.sol";
import "../src/VaultSentinel.sol";
import {UtilizationOracle} from "../src/UtilizationOracle.sol";

contract ExecuteAndSeed is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");

        address usdcAddr = vm.envAddress("MOCK_USDC_ADDRESS");
        address vaultAddr = vm.envAddress("CURATED_VAULT_ADDRESS");
        address marketAAddr = vm.envAddress("MARKET_A_ADDRESS");
        address marketBAddr = vm.envAddress("MARKET_B_ADDRESS");

        MockUSDC usdc = MockUSDC(usdcAddr);
        CuratedVault vault = CuratedVault(vaultAddr);
        MockLendingMarket marketA = MockLendingMarket(marketAAddr);
        MockLendingMarket marketB = MockLendingMarket(marketBAddr);

        vm.startBroadcast(deployerKey);

        // ── 1. Execute timelocked market additions ─────────────────────────────
        vault.executeAddMarket(address(marketA), 50_000 * 1e6);
        vault.executeAddMarket(address(marketB), 50_000 * 1e6);
        console.log("Markets added to vault");

        // ── 2. Mint test USDC to deployer ──────────────────────────────────────
        usdc.mint(deployer, 100_000 * 1e6); // 100k USDC (6 decimals)
        console.log("Minted 100,000 USDC to deployer");

        // ── 3. Deposit into vault ──────────────────────────────────────────────
        usdc.approve(address(vault), 50_000 * 1e6);
        vault.deposit(50_000 * 1e6, deployer);
        console.log("Deposited 50,000 USDC into vault");

        // ── 4. Allocate to markets ─────────────────────────────────────────────
        // Market A: 30,000 USDC (60% of vault assets - will trigger CRITICAL)
        // Market B: 10,000 USDC (20%)
        // Idle:      10,000 USDC (20%)
        vault.allocate(address(marketA), 30_000 * 1e6);
        vault.allocate(address(marketB), 10_000 * 1e6);
        console.log("Allocated: 30k to Market A, 10k to Market B");

        // ── 5. Set demo utilization ────────────────────────────────────────────
        // Market A: 96% utilization (>95% = CRITICAL per system prompt)
        // Market B: 50% utilization (safe)
        marketA.setUtilization(96);
        marketB.setUtilization(50);
        console.log("Market A utilization set to 96% (should trigger CRITICAL verdict)");
        console.log("Market B utilization set to 50% (safe)");

        // ── 6. Seed oracle with initial observations ──────────────────────────
        // NOTE: oracle.update() requires an IMarketAdapter registered per market
        // via oracle.setAdapter(market, adapter).  MockLendingMarket does not
        // implement IMarketAdapter (signature mismatch), so these calls are
        // wrapped in try/catch.  On a production deployment with real adapters
        // registered, both calls succeed and prime the TWAP accumulator.
        UtilizationOracle oracle = UtilizationOracle(vm.envAddress("ORACLE_ADDRESS"));
        try oracle.update(address(marketA)) {
            console.log("Oracle seeded for Market A");
        } catch {
            console.log("Oracle seed skipped for Market A (no adapter registered - set via oracle.setAdapter)");
        }
        try oracle.update(address(marketB)) {
            console.log("Oracle seeded for Market B");
        } catch {
            console.log("Oracle seed skipped for Market B (no adapter registered - set via oracle.setAdapter)");
        }

        vm.stopBroadcast();

        // ── Verify expected state ──────────────────────────────────────────────
        uint256 totalAssets = vault.totalAssets();
        uint256 idlePct = vault.idleBufferBps();
        uint256 mktAPct = vault.marketAllocationBps(address(marketA));
        uint256 mktBPct = vault.marketAllocationBps(address(marketB));
        uint256 mktAUtil = marketA.utilizationBps();
        uint256 mktBUtil = marketB.utilizationBps();

        console.log("\n========= VAULT STATE =========");
        console.log("totalAssets (USDC units):  ", totalAssets / 1e6);
        console.log("idleBufferBps:             ", idlePct, "bps");
        console.log("Market A allocation:       ", mktAPct, "%  (CRITICAL threshold: >40%)");
        console.log("Market B allocation:       ", mktBPct, "%");
        console.log("Market A utilization (bps):", mktAUtil, " (CRITICAL threshold: >9500)");
        console.log("Market B utilization (bps):", mktBUtil);
        console.log("================================");
        console.log("\nNEXT STEP: run TriggerCheck.s.sol (requires 0.25 STT)");
    }
}
