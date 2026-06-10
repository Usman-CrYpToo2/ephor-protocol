// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {TestBase} from "../TestBase.sol";
import {VaultSentinel} from "../../src/VaultSentinel.sol";

/// @notice D-5 regression: on-chain precedence rule — AI can only escalate, never lower.
contract SentinelPrecedenceTest is TestBase {
    // ══════════════════════════════════════════════════════════════════════════
    //  GROUP 22 — D-5 Regression: Precedence Rule (SDD §7.4)
    // ══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Proves D-5 fix: when on-chain HardLevel is Critical, AI saying STABLE
     *         cannot lower it. EffectiveLevel stays Critical.
     *         Proves AC-12: EffectiveLevel never below HardLevel.
     */
    function testD5_hardLevelCritical_aiStable_stillCritical() public {
        usdc.approve(address(vault), 10_000 * 1e6);
        vault.deposit(10_000 * 1e6, address(this));
        vm.prank(allocator);
        vault.allocate(address(marketA), 9_000 * 1e6);
        marketA.setUtilization(96);

        VaultSentinel.RiskLevel hardLevel = sentinel.assessOnChain(address(vault));
        assertEq(
            uint256(hardLevel),
            uint256(VaultSentinel.RiskLevel.Critical),
            "D-5 precondition: assessOnChain must return Critical"
        );

        sentinel.checkVault{value: CHECK_VALUE}(address(vault));
        platform.simulateCallback(_latestRequestId(), "STABLE");

        (VaultSentinel.RiskLevel level,,) = sentinel.getLatestRisk(address(vault));
        assertEq(
            uint256(level),
            uint256(VaultSentinel.RiskLevel.Critical),
            "D-5: HardLevel=Critical must not be lowered by AI=STABLE"
        );
        assertTrue(vault.depositsPaused(), "D-5: Critical EffectiveLevel must pause deposits");
    }

    /**
     * @notice Proves D-5 fix: when HardLevel is Safe and AI says DETERIORATING,
     *         escalation requires HardLevel >= Caution. Since HardLevel=Safe,
     *         no escalation to Critical occurs.
     *         Proves AC-12: AI cannot manufacture Critical from Safe.
     */
    function testD5_hardLevelSafe_aiDeterioration_noCritical() public {
        usdc.approve(address(vault), 10_000 * 1e6);
        vault.deposit(10_000 * 1e6, address(this));
        vm.prank(allocator);
        vault.allocate(address(marketA), 1_000 * 1e6);
        marketA.setUtilization(20);

        VaultSentinel.RiskLevel hardLevel = sentinel.assessOnChain(address(vault));
        assertEq(
            uint256(hardLevel),
            uint256(VaultSentinel.RiskLevel.Safe),
            "D-5 precondition: assessOnChain must return Safe"
        );

        sentinel.checkVault{value: CHECK_VALUE}(address(vault));
        platform.simulateCallback(_latestRequestId(), "DETERIORATING");

        (VaultSentinel.RiskLevel level,,) = sentinel.getLatestRisk(address(vault));
        assertLt(
            uint256(level),
            uint256(VaultSentinel.RiskLevel.Critical),
            "D-5: AI=DETERIORATING with HardLevel=Safe cannot produce Critical"
        );
        assertFalse(vault.depositsPaused(), "D-5: Safe must not pause deposits");
    }

    /**
     * @notice Proves D-5 fix: when HardLevel is Caution and AI says DETERIORATING,
     *         EffectiveLevel escalates to Critical.
     *         SDD §7.4: AiAdjustedLevel = Critical if AI==DETERIORATING and HardLevel>=Caution.
     *         Proves D-5, AC-12.
     */
    function testD5_hardLevelCaution_aiDeterioration_becomesCritical() public {
        usdc.approve(address(vault), 10_000 * 1e6);
        vault.deposit(10_000 * 1e6, address(this));
        vm.prank(allocator);
        vault.allocate(address(marketA), 3_000 * 1e6);
        marketA.setUtilization(85);

        VaultSentinel.RiskLevel hardLevel = sentinel.assessOnChain(address(vault));
        assertEq(
            uint256(hardLevel),
            uint256(VaultSentinel.RiskLevel.Caution),
            "D-5 precondition: assessOnChain must return Caution"
        );

        sentinel.checkVault{value: CHECK_VALUE}(address(vault));
        platform.simulateCallback(_latestRequestId(), "DETERIORATING");

        (VaultSentinel.RiskLevel level,,) = sentinel.getLatestRisk(address(vault));
        assertEq(
            uint256(level),
            uint256(VaultSentinel.RiskLevel.Critical),
            "D-5: HardLevel=Caution + AI=DETERIORATING must produce Critical"
        );
        assertTrue(vault.depositsPaused(), "D-5: Critical EffectiveLevel must pause deposits");
    }

    /**
     * @notice Proves D-5 fix: when AI platform returns Failed, EffectiveLevel = HardLevel.
     *         AI failure never changes vault state beyond what on-chain guards mandate.
     *         Proves AC-8, P-5, D-5 regression.
     */
    function testD5_aiFailure_usesHardLevel() public {
        usdc.approve(address(vault), 10_000 * 1e6);
        vault.deposit(10_000 * 1e6, address(this));
        vm.prank(allocator);
        vault.allocate(address(marketA), 3_000 * 1e6);
        marketA.setUtilization(85);

        VaultSentinel.RiskLevel hardLevel = sentinel.assessOnChain(address(vault));
        assertEq(
            uint256(hardLevel),
            uint256(VaultSentinel.RiskLevel.Caution),
            "D-5 precondition: assessOnChain must return Caution"
        );

        sentinel.checkVault{value: CHECK_VALUE}(address(vault));
        platform.simulateTimeout(_latestRequestId());

        (VaultSentinel.RiskLevel level,, string memory verdict) = sentinel.getLatestRisk(address(vault));
        assertEq(
            uint256(level),
            uint256(VaultSentinel.RiskLevel.Caution),
            "D-5: AI failure must produce EffectiveLevel = HardLevel"
        );
        assertEq(verdict, "AI_UNAVAILABLE", "D-5: AI failure must record AI_UNAVAILABLE");
        assertFalse(vault.depositsPaused(), "D-5: Caution HardLevel must not auto-pause");
    }
}
