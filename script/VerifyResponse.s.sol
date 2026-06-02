// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title  VerifyResponse
 * @notice Read-only verification script - run after TriggerCheck.s.sol
 *         once you believe the Somnia platform has delivered the callback.
 *
 *         This script does NOT broadcast any transactions.
 *         It reads on-chain state and prints a full diagnostic report.
 *
 *  Run (no --broadcast needed):
 *    source .env
 *    forge script script/VerifyResponse.s.sol \
 *      --rpc-url $SOMNIA_TESTNET_RPC \
 *      -vvv
 *
 *  What to look for:
 *    - isPending = false         -> callback was received
 *    - latestVerdict != ""       -> LLM returned a verdict
 *    - latestLevel in (0,1,2)    -> 0=Safe, 1=Caution, 2=Critical
 *    - depositsPaused = true     -> CRITICAL path fired (if vault had autoPause)
 *    - historyLength >= 1        -> audit trail entry was written
 */

import {Script, console} from "forge-std/Script.sol";
import "../src/CuratedVault.sol";
import "../src/VaultSentinel.sol";
import "../src/Mock/MockLendingMarket.sol";

contract VerifyResponse is Script {
    function run() external view {
        address vaultAddr = vm.envAddress("CURATED_VAULT_ADDRESS");
        address sentinelAddr = vm.envAddress("VAULT_SENTINEL_ADDRESS");
        address marketAAddr = vm.envAddress("MARKET_A_ADDRESS");
        address marketBAddr = vm.envAddress("MARKET_B_ADDRESS");

        VaultSentinel sentinel = VaultSentinel(payable(sentinelAddr));
        CuratedVault vault = CuratedVault(vaultAddr);
        MockLendingMarket marketA = MockLendingMarket(marketAAddr);
        MockLendingMarket marketB = MockLendingMarket(marketBAddr);

        console.log("\n========= EPHOR PROTOCOL - TESTNET VERIFICATION =========\n");

        bool done = _printRequestStatus(sentinel, vaultAddr);
        if (!done) return;

        _printVerdict(sentinel, vaultAddr);
        _printVaultState(vault, marketA, marketB, vaultAddr);
        _printAnalysis(sentinel, vault, marketA, vaultAddr);
        _printAuditTrail(sentinel, vaultAddr);

        console.log("\n=========================================================\n");
    }

    function _printRequestStatus(VaultSentinel sentinel, address vaultAddr)
        internal
        view
        returns (bool callbackReceived)
    {
        bool isPending = sentinel.isCheckPending(vaultAddr);
        uint256 activeReqId = sentinel.activeRequest(vaultAddr);

        console.log("--- REQUEST STATUS ---");
        console.log("isPending:", isPending ? "YES (callback not yet received)" : "NO (callback received)");
        if (isPending) {
            console.log("activeRequestId:", activeReqId);
            console.log("STATUS: Waiting for Somnia validators. Check again in a few minutes.");
            return false;
        }
        return true;
    }

    function _printVerdict(VaultSentinel sentinel, address vaultAddr) internal view {
        (VaultSentinel.RiskLevel latestLevel, uint256 latestTs, string memory latestVerdict) =
            sentinel.getLatestRisk(vaultAddr);

        VaultSentinel.RiskSnapshot[] memory history = sentinel.getHistory(vaultAddr);

        (,, VaultSentinel.RiskLevel lastLevel, uint256 lastCheckedAt, uint256 totalChecks, uint256 criticalCount) =
            sentinel.vaultInfo(vaultAddr);

        string memory levelStr;
        if (uint256(latestLevel) == 0) levelStr = "SAFE";
        else if (uint256(latestLevel) == 1) levelStr = "CAUTION";
        else levelStr = "CRITICAL";

        console.log("\n--- AI VERDICT ---");
        console.log("latestLevel:        ", levelStr);
        console.log("rawVerdict:         ", latestVerdict);
        console.log("timestamp:          ", latestTs);
        console.log("historyLength:      ", history.length);
        console.log("totalChecks:        ", totalChecks);
        console.log("criticalCount:      ", criticalCount);
        console.log("lastCheckedAt:      ", lastCheckedAt);
        console.log("lastLevel (stored): ", uint256(lastLevel));
    }

    function _printVaultState(
        CuratedVault vault,
        MockLendingMarket marketA,
        MockLendingMarket marketB,
        address vaultAddr
    ) internal view {
        bool paused = vault.depositsPaused();
        uint256 totalA = vault.totalAssets();
        uint256 idlePct = vault.idleBufferPct();
        uint256 mktAPct = vault.marketAllocationPct(address(marketA));
        uint256 mktBPct = vault.marketAllocationPct(address(marketB));
        uint256 mktABal = marketA.balanceOf(vaultAddr);
        uint256 mktBBal = marketB.balanceOf(vaultAddr);
        uint256 mktAUtil = marketA.utilizationBps();
        uint256 mktBUtil = marketB.utilizationBps();

        console.log("\n--- VAULT STATE ---");
        console.log("depositsPaused:     ", paused);
        console.log("totalAssets (USDC): ", totalA / 1e6);
        console.log("idleBufferPct:      ", idlePct, "%");
        console.log("Market A alloc:     ", mktAPct, "%");
        console.log("Market B alloc:     ", mktBPct, "%");
        console.log("Market A balance:   ", mktABal / 1e6, "USDC");
        console.log("Market B balance:   ", mktBBal / 1e6, "USDC");
        console.log("Market A util (bps):", mktAUtil);
        console.log("Market B util (bps):", mktBUtil);
    }

    function _printAnalysis(VaultSentinel sentinel, CuratedVault vault, MockLendingMarket marketA, address vaultAddr)
        internal
        view
    {
        (VaultSentinel.RiskLevel latestLevel,,) = sentinel.getLatestRisk(vaultAddr);
        bool paused = vault.depositsPaused();
        uint256 mktABal = marketA.balanceOf(vaultAddr);

        console.log("\n--- ANALYSIS ---");
        if (uint256(latestLevel) == 2) {
            console.log("RESULT: CRITICAL verdict received.");
            if (paused) {
                console.log("PASS: Deposits are paused (autoPause fired correctly).");
            } else {
                console.log("NOTE: Deposits not paused - autoPause may be disabled for this vault.");
            }
            if (mktABal < 30_000 * 1e6) {
                console.log("PASS: Market A position was reduced (emergency deallocate executed).");
            }
        } else if (uint256(latestLevel) == 1) {
            console.log("RESULT: CAUTION verdict. No automated action taken.");
            console.log("NOTE: Vault is operating normally - CAUTION triggers only an event.");
        } else if (uint256(latestLevel) == 0) {
            console.log("RESULT: SAFE verdict. Vault is healthy.");
        } else {
            console.log("RESULT: Unknown state - latestTs may be 0 if no check has completed.");
        }
    }

    function _printAuditTrail(VaultSentinel sentinel, address vaultAddr) internal view {
        VaultSentinel.RiskSnapshot[] memory history = sentinel.getHistory(vaultAddr);
        if (history.length == 0) return;

        VaultSentinel.RiskSnapshot memory snap = history[history.length - 1];
        console.log("\n--- AUDIT TRAIL (latest entry) ---");
        console.log("timestamp:          ", snap.timestamp);
        console.log("rawVerdict:         ", snap.rawVerdict);
        console.log("totalAssets snap:   ", snap.totalAssets / 1e6, "USDC");
        console.log("idlePct snap:       ", snap.idlePct, "%");
    }
}
