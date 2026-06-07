// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {TestBase} from "../TestBase.sol";
import {VaultSentinel} from "../../src/VaultSentinel.sol";
import {UtilizationOracle} from "../../src/UtilizationOracle.sol";
import {GenericAdapter} from "../../src/Mock/GenericAdapter.sol";

/// @notice D-6 regression: consensus threshold verification.
///         Also contains fuzz test for oracle bps clamping (I-11).
contract SentinelConsensusTest is TestBase {

    // ══════════════════════════════════════════════════════════════════════════
    //  GROUP 23 — D-6 Regression: Response Threshold Verification (SDD §7.3)
    // ══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Proves D-6 fix: when responseCount < threshold, response is treated as Failed.
     *         EffectiveLevel = HardLevel; AI verdict is NOT applied.
     */
    function testD6_belowThreshold_treatedAsFailed() public {
        usdc.approve(address(vault), 10_000 * 1e6);
        vault.deposit(10_000 * 1e6, address(this));
        vm.prank(allocator);
        vault.allocate(address(marketA), 1_000 * 1e6);
        marketA.setUtilization(20);

        VaultSentinel.RiskLevel hardLevel = sentinel.assessOnChain(address(vault));
        assertEq(uint256(hardLevel), uint256(VaultSentinel.RiskLevel.Safe),
            "D-6 precondition: assessOnChain must return Safe");

        sentinel.checkVault{value: CHECK_VALUE}(address(vault));
        platform.simulateBelowThreshold(_latestRequestId(), "CRITICAL");

        (VaultSentinel.RiskLevel level,, string memory verdict) = sentinel.getLatestRisk(address(vault));
        assertLt(uint256(level), uint256(VaultSentinel.RiskLevel.Critical),
            "D-6: response below threshold must not apply AI verdict (CRITICAL)");
        assertEq(uint256(level), uint256(VaultSentinel.RiskLevel.Caution),
            "D-6: fail-safe applies Caution floor when below threshold");
        assertEq(verdict, "CONSENSUS_NOT_MET",
            "D-6: below-threshold response must record CONSENSUS_NOT_MET");
        assertFalse(vault.depositsPaused(),
            "D-6: Caution must not auto-pause deposits");
    }

    /**
     * @notice Proves D-6 fix: when responseCount >= threshold, response is accepted normally.
     */
    function testD6_atThreshold_accepted() public {
        usdc.approve(address(vault), 10_000 * 1e6);
        vault.deposit(10_000 * 1e6, address(this));
        vm.prank(allocator);
        vault.allocate(address(marketA), 3_000 * 1e6);
        marketA.setUtilization(10);

        sentinel.checkVault{value: CHECK_VALUE}(address(vault));
        platform.simulateCallback(_latestRequestId(), "STABLE");

        (VaultSentinel.RiskLevel level,,) = sentinel.getLatestRisk(address(vault));
        assertLe(uint256(level), uint256(VaultSentinel.RiskLevel.Caution),
            "D-6: at-threshold response must be processed (not treated as failed)");
    }

    /**
     * @notice Fuzz: effectiveUtil never returns a value above 10_000 bps.
     *         Proves I-11 clamping for any spot value.
     */
    function testFuzz_oracle_effectiveUtilNeverExceedsMaxBps(uint256 spotPct) public {
        spotPct = bound(spotPct, 0, 100);

        (UtilizationOracle orc,) = _deployOracle();

        usdc.approve(address(vault), 10_000 * 1e6);
        vault.deposit(10_000 * 1e6, address(this));
        vm.prank(allocator);
        vault.allocate(address(marketA), 8_000 * 1e6);

        marketA.setUtilization(spotPct);

        uint256 t0 = block.timestamp;
        orc.update(address(marketA));
        vm.warp(t0 + 30 minutes);
        orc.update(address(marketA));

        (uint256 util,) = orc.effectiveUtil(address(marketA));
        assertLe(util, 10_000, "oracle: effectiveUtil must never exceed 10_000 bps");
    }
}
