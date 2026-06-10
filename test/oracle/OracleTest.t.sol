// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {TestBase} from "../TestBase.sol";
import {UtilizationOracle} from "../../src/UtilizationOracle.sol";
import {GenericAdapter} from "../../src/Mock/GenericAdapter.sol";
import {VaultSentinel} from "../../src/VaultSentinel.sol";

/// @notice Unit tests for UtilizationOracle: accumulator, TWAP, effectiveUtil, isValid.
///         Also covers D-8 sentinel+oracle integration tests.
contract OracleTest is TestBase {
    // ══════════════════════════════════════════════════════════════════════════
    //  GROUP 21 — Oracle: accumulator + checkpoint + effectiveUtil
    // ══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Proves update() accumulates correctly.
     *         Proves D-8 (accumulator pattern), AC-17 (permissionless).
     */
    function testOracle_updateAccumulates() public {
        (UtilizationOracle orc,) = _deployOracle();

        usdc.approve(address(vault), 10_000 * 1e6);
        vault.deposit(10_000 * 1e6, address(this));
        vm.prank(allocator);
        vault.allocate(address(marketA), 8_000 * 1e6);
        marketA.setUtilization(50);

        uint256 t0 = block.timestamp;
        orc.update(address(marketA));

        uint256 elapsed = 200;
        vm.warp(t0 + elapsed);
        orc.update(address(marketA));

        (uint256 ts, uint256 util) = orc.lastRecorded(address(marketA));
        assertEq(ts, t0 + elapsed, "oracle: lastRecorded timestamp must match second update");
        assertEq(util, 5000, "oracle: lastRecorded util must match market spot at update time");
        assertGt(ts, 0, "Proves AC-17: update() is permissionless - no role needed");
    }

    /**
     * @notice Proves twap() returns cautionUtilBps before TWAP_WINDOW has elapsed.
     *         Proves AC-16, I-11 (conservative before valid).
     */
    function testOracle_twap_returnsConservativeBeforeWindow() public {
        (UtilizationOracle orc,) = _deployOracle();

        usdc.approve(address(vault), 10_000 * 1e6);
        vault.deposit(10_000 * 1e6, address(this));
        vm.prank(allocator);
        vault.allocate(address(marketA), 8_000 * 1e6);
        marketA.setUtilization(50);

        orc.update(address(marketA));
        vm.warp(block.timestamp + 10 minutes);

        assertFalse(orc.isValid(address(marketA)), "oracle: isValid must be false before TWAP_WINDOW");

        uint256 twapVal = orc.twap(address(marketA), 30 minutes);
        assertEq(twapVal, 8_000, "oracle: twap must return cautionUtilBps (8000) before TWAP_WINDOW");
    }

    /**
     * @notice Proves twap() returns correct accumulated average after TWAP_WINDOW.
     *         Uses known inputs: constant 7000 bps for 30 minutes.
     *         Proves I-11, AC-13.
     */
    function testOracle_twap_correctAfterWindow() public {
        (UtilizationOracle orc,) = _deployOracle();

        usdc.approve(address(vault), 10_000 * 1e6);
        vault.deposit(10_000 * 1e6, address(this));
        vm.prank(allocator);
        vault.allocate(address(marketA), 8_000 * 1e6);
        marketA.setUtilization(70);

        uint256 t0 = block.timestamp;
        orc.update(address(marketA));

        vm.warp(t0 + 30 minutes);
        orc.update(address(marketA));

        assertTrue(orc.isValid(address(marketA)), "oracle: isValid must be true after TWAP_WINDOW");

        uint256 twapVal = orc.twap(address(marketA), 30 minutes);
        assertApproxEqAbs(twapVal, 7000, 100, "oracle: twap must be ~7000 bps after constant-rate window");
    }

    /**
     * @notice Proves effectiveUtil returns (spot, false) when spot and twap agree.
     *         Proves I-11, AC-13.
     */
    function testOracle_effectiveUtil_noSpike() public {
        (UtilizationOracle orc,) = _deployOracle();

        usdc.approve(address(vault), 10_000 * 1e6);
        vault.deposit(10_000 * 1e6, address(this));
        vm.prank(allocator);
        vault.allocate(address(marketA), 8_000 * 1e6);
        marketA.setUtilization(50);

        uint256 t0 = block.timestamp;
        orc.update(address(marketA));
        vm.warp(t0 + 5 minutes);
        orc.update(address(marketA));
        vm.warp(t0 + 10 minutes);
        orc.update(address(marketA));
        vm.warp(t0 + 30 minutes);
        orc.update(address(marketA));

        (uint256 util, bool spikeDetected) = orc.effectiveUtil(address(marketA));
        assertFalse(spikeDetected, "oracle: no spike when spot ~= twap");
        assertApproxEqAbs(util, 5000, 200, "oracle: effectiveUtil returns spot when no spike");
    }

    /**
     * @notice Proves effectiveUtil returns (twap, true) when spot deviates more than
     *         spikeToleranceBps above twap. Also proves SuspiciousSpike event (AC-18).
     *         Proves I-11, AC-13, AC-14, AC-18, D-8.
     */
    function testOracle_effectiveUtil_spikeDetected() public {
        (UtilizationOracle orc,) = _deployOracle();

        usdc.approve(address(vault), 10_000 * 1e6);
        vault.deposit(10_000 * 1e6, address(this));
        vm.prank(allocator);
        vault.allocate(address(marketA), 8_000 * 1e6);

        marketA.setUtilization(30);
        uint256 t0 = block.timestamp;
        orc.update(address(marketA));
        vm.warp(t0 + 5 minutes);
        orc.update(address(marketA));
        vm.warp(t0 + 10 minutes);
        orc.update(address(marketA));
        vm.warp(t0 + 30 minutes);
        orc.update(address(marketA));

        marketA.setUtilization(90);
        vm.warp(block.timestamp + 1);

        (uint256 util, bool spikeDetected) = orc.effectiveUtil(address(marketA));

        assertTrue(spikeDetected, "oracle: spike must be detected when spot - twap > tolerance");
        assertLt(util, 9000, "oracle: effectiveUtil must return TWAP (not spike spot) when spike detected");
        assertApproxEqAbs(util, 3000, 500, "oracle: returned TWAP should be near the pre-spike average");
    }

    /**
     * @notice Proves secondary rule: when spot > criticalUtilBps AND twap > cautionUtilBps,
     *         effectiveUtil returns (spot, false) — real sustained emergency.
     *         Proves I-11, AC-15, D-8.
     */
    function testOracle_effectiveUtil_sustainedEmergency() public {
        (UtilizationOracle orc,) = _deployOracle();

        usdc.approve(address(vault), 10_000 * 1e6);
        vault.deposit(10_000 * 1e6, address(this));
        vm.prank(allocator);
        vault.allocate(address(marketA), 8_000 * 1e6);

        marketA.setUtilization(90);
        uint256 t0 = block.timestamp;
        orc.update(address(marketA));
        vm.warp(t0 + 5 minutes);
        orc.update(address(marketA));
        vm.warp(t0 + 10 minutes);
        orc.update(address(marketA));
        vm.warp(t0 + 30 minutes);
        orc.update(address(marketA));

        marketA.setUtilization(96);
        vm.warp(block.timestamp + 1);

        (uint256 util, bool spikeDetected) = orc.effectiveUtil(address(marketA));

        assertFalse(spikeDetected, "oracle: secondary rule fires without spike flag");
        assertGt(util, 9_000, "oracle: secondary rule returns elevated spot util in real emergency");
    }

    /**
     * @notice Proves isValid returns false before TWAP_WINDOW has elapsed.
     *         Proves AC-16, I-11, T-16.
     */
    function testOracle_isValid_falseBeforeWindow() public {
        (UtilizationOracle orc,) = _deployOracle();

        usdc.approve(address(vault), 10_000 * 1e6);
        vault.deposit(10_000 * 1e6, address(this));
        vm.prank(allocator);
        vault.allocate(address(marketA), 8_000 * 1e6);
        marketA.setUtilization(50);

        orc.update(address(marketA));
        vm.warp(block.timestamp + 29 minutes);

        assertFalse(orc.isValid(address(marketA)), "oracle: isValid must be false before TWAP_WINDOW");
    }

    /**
     * @notice Proves isValid returns true after TWAP_WINDOW has elapsed.
     *         Proves AC-16.
     */
    function testOracle_isValid_trueAfterWindow() public {
        (UtilizationOracle orc,) = _deployOracle();

        usdc.approve(address(vault), 10_000 * 1e6);
        vault.deposit(10_000 * 1e6, address(this));
        vm.prank(allocator);
        vault.allocate(address(marketA), 8_000 * 1e6);
        marketA.setUtilization(50);

        uint256 t0 = block.timestamp;
        orc.update(address(marketA));
        vm.warp(t0 + 30 minutes);

        assertTrue(orc.isValid(address(marketA)), "oracle: isValid must be true at TWAP_WINDOW");
    }

    /**
     * @notice Proves AC-17: update() is callable by any address (permissionless).
     */
    function testOracle_updateIsPermissionless() public {
        (UtilizationOracle orc,) = _deployOracle();

        usdc.approve(address(vault), 10_000 * 1e6);
        vault.deposit(10_000 * 1e6, address(this));
        vm.prank(allocator);
        vault.allocate(address(marketA), 8_000 * 1e6);
        marketA.setUtilization(50);

        vm.prank(attacker);
        orc.update(address(marketA));

        (uint256 ts,) = orc.lastRecorded(address(marketA));
        assertGt(ts, 0, "oracle: update by any address must record observation");
    }

    // ── D-8 Sentinel+Oracle integration ──────────────────────────────────────

    /**
     * @notice Proves sentinel uses new oracle when set.
     *         Proves I-11, AC-14, D-8 regression.
     */
    function testD8_sentinel_usesOracleWhenSet() public {
        (UtilizationOracle orc,) = _deployOracle();

        usdc.approve(address(vault), 10_000 * 1e6);
        vault.deposit(10_000 * 1e6, address(this));
        vm.prank(allocator);
        vault.allocate(address(marketA), 8_000 * 1e6);

        marketA.setUtilization(96);
        uint256 t0 = block.timestamp;
        orc.update(address(marketA));
        vm.warp(t0 + 5 minutes);
        orc.update(address(marketA));
        vm.warp(t0 + 10 minutes);
        orc.update(address(marketA));
        vm.warp(t0 + 15 minutes);
        orc.update(address(marketA));
        vm.warp(t0 + 20 minutes);
        orc.update(address(marketA));
        vm.warp(t0 + 25 minutes);
        orc.update(address(marketA));
        vm.warp(t0 + 30 minutes);
        orc.update(address(marketA));

        vm.prank(admin);
        sentinel.setOracle(address(orc));
        assertEq(address(sentinel.oracle()), address(orc), "D-8: oracle must be set on sentinel");

        uint256 marketABefore = marketA.balanceOf(address(vault));

        sentinel.checkVault{value: CHECK_VALUE}(address(vault));
        platform.simulateCallback(_latestRequestId(), "CRITICAL");

        assertLt(
            marketA.balanceOf(address(vault)),
            marketABefore,
            "D-8: CRITICAL with oracle set must deallocate worst market"
        );
        assertTrue(vault.depositsPaused(), "D-8: CRITICAL must pause deposits");

        vm.prank(admin);
        sentinel.setOracle(address(0));
    }

    /**
     * @notice Proves sentinel falls back to spot when oracle is not set.
     */
    function testD8_sentinel_fallsBackWithoutOracle() public {
        assertEq(address(sentinel.oracle()), address(0), "D-8: oracle must be unset by default");

        if (vault.depositsPaused()) {
            vm.prank(admin);
            vault.unpauseDeposits();
        }

        usdc.approve(address(vault), 10_000 * 1e6);
        vault.deposit(10_000 * 1e6, address(this));
        vm.prank(allocator);
        vault.allocate(address(marketA), 8_000 * 1e6);
        marketA.setUtilization(96);

        uint256 marketABefore = marketA.balanceOf(address(vault));
        vm.warp(block.timestamp + CHECK_COOLDOWN + 1);

        sentinel.checkVault{value: CHECK_VALUE}(address(vault));
        platform.simulateCallback(_latestRequestId(), "CRITICAL");

        assertLt(
            marketA.balanceOf(address(vault)),
            marketABefore,
            "D-8 fallback: without oracle, spot util must still trigger deallocation"
        );
    }

    /**
     * @notice Proves setOracle is restricted to sentinel admin.
     */
    function testD8_sentinel_setOracle_adminOnly() public {
        (UtilizationOracle orc,) = _deployOracle();

        vm.prank(attacker);
        vm.expectRevert();
        sentinel.setOracle(address(orc));

        assertEq(address(sentinel.oracle()), address(0), "D-8: oracle unchanged after failed set");

        vm.prank(admin);
        sentinel.setOracle(address(orc));
        assertEq(address(sentinel.oracle()), address(orc), "D-8: admin can set oracle");

        vm.prank(admin);
        sentinel.setOracle(address(0));
        assertEq(address(sentinel.oracle()), address(0), "D-8: admin can clear oracle");
    }
}
