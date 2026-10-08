// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {TestBase} from "../TestBase.sol";
import {CuratedVault} from "../../src/CuratedVault.sol";

/// @title  VaultReallocateTest
/// @notice Tests for CuratedVault.reallocate() invariant system (Phase 2).
///         Each test references the SDD §10 invariant it proves.
contract VaultReallocateTest is TestBase {
    // Deposit size used in most tests: 100_000 USDC
    uint256 constant DEPOSIT = 100_000 * 1e6;

    // Helper: build a valid guard for the current vault state.
    function _makeGuard() internal view returns (CuratedVault.RebalanceGuard memory) {
        return
            CuratedVault.RebalanceGuard({snapshotTotalAssets: vault.totalAssets(), snapshotEpoch: vault.currentEpoch()});
    }

    // Helper: single-market target.
    function _target(address mkt, uint256 amt) internal pure returns (CuratedVault.MarketTarget[] memory) {
        CuratedVault.MarketTarget[] memory t = new CuratedVault.MarketTarget[](1);
        t[0] = CuratedVault.MarketTarget({market: mkt, targetAmount: amt});
        return t;
    }

    // Helper: two-market target.
    function _targets2(address m1, uint256 a1, address m2, uint256 a2)
        internal
        pure
        returns (CuratedVault.MarketTarget[] memory)
    {
        CuratedVault.MarketTarget[] memory t = new CuratedVault.MarketTarget[](2);
        t[0] = CuratedVault.MarketTarget({market: m1, targetAmount: a1});
        t[1] = CuratedVault.MarketTarget({market: m2, targetAmount: a2});
        return t;
    }

    // Helper: warp past the epoch cooldown.
    function _warpPastEpoch() internal {
        vm.warp(block.timestamp + vault.rebalanceEpochLength() + 1);
    }

    // ── setUp ────────────────────────────────────────────────────────────────

    function setUp() public override {
        super.setUp();

        // Mint + deposit so vault has assets
        usdc.mint(address(this), DEPOSIT);
        usdc.approve(address(vault), DEPOSIT);
        vault.deposit(DEPOSIT, address(this));

        // Raise maxTurnoverBps to 9000 so tests can move large amounts.
        // (Individual invariant tests override as needed.)
        vm.prank(curator);
        vault.setMaxTurnoverBps(9_000);

        // Lower idle floor to 500 bps (5%) to give allocation room.
        vm.prank(curator);
        vault.setMinIdleBufferBps(500);

        // Warp past the initial epoch cooldown (lastRebalanceTime == 0, so
        // any timestamp >= 0 + epochLength satisfies I-8).
        _warpPastEpoch();
    }

    // ════════════════════════════════════════════════════════════════
    //  HAPPY PATH
    // ════════════════════════════════════════════════════════════════

    /// @notice Reallocate to two markets, verify balances and epoch increment.
    ///         Proves I-1..I-8 satisfied simultaneously.
    function testReallocate_happyPath() public {
        uint256 ta = vault.totalAssets(); // 100_000e6
        // Target: 30% to A, 40% to B, 30% idle — respects 5% floor and 50% maxMarket
        uint256 aAmt = ta * 30 / 100;
        uint256 bAmt = ta * 40 / 100;

        CuratedVault.MarketTarget[] memory tgts = _targets2(address(marketA), aAmt, address(marketB), bAmt);
        CuratedVault.RebalanceGuard memory guard = _makeGuard();

        uint256 epochBefore = vault.currentEpoch();
        vm.prank(allocator);
        vault.reallocate(tgts, guard);

        // Post-state: balances match targets
        assertEq(marketA.balanceOf(address(vault)), aAmt, "marketA balance"); // Proves I-1, I-7
        assertEq(marketB.balanceOf(address(vault)), bAmt, "marketB balance"); // Proves I-1, I-7
        assertEq(vault.currentEpoch(), epochBefore + 1, "epoch incremented"); // Proves I-8
        assertGe(vault.idleBufferBps(), vault.minIdleBufferBps(), "idle floor"); // Proves I-3
    }

    /// @notice After a rebalance the epoch is updated; warp and rebalance again.
    function testReallocate_successiveCycles() public {
        uint256 ta = vault.totalAssets();
        uint256 aAmt = ta * 20 / 100;

        CuratedVault.RebalanceGuard memory guard0 = _makeGuard();
        vm.prank(allocator);
        vault.reallocate(_target(address(marketA), aAmt), guard0);

        // Warp past next epoch and rebalance to zero
        _warpPastEpoch();

        CuratedVault.MarketTarget[] memory tgts = _target(address(marketA), aAmt);
        // Guard must reflect CURRENT epoch (now 1) and totalAssets
        CuratedVault.RebalanceGuard memory guard = _makeGuard();
        vm.prank(allocator);
        vault.reallocate(tgts, guard);

        assertEq(vault.currentEpoch(), 2, "two epochs"); // Proves I-8 not stuck
    }

    // ════════════════════════════════════════════════════════════════
    //  ROLE GATING
    // ════════════════════════════════════════════════════════════════

    /// @notice Non-ALLOCATOR_ROLE address cannot call reallocate.
    function testReallocate_roleGating() public {
        CuratedVault.RebalanceGuard memory guard = _makeGuard();
        vm.expectRevert();
        vm.prank(attacker);
        vault.reallocate(_target(address(marketA), 1e6), guard);
    }

    // ════════════════════════════════════════════════════════════════
    //  I-1  CONSERVATION
    // ════════════════════════════════════════════════════════════════

    /// @notice targetSum > totalAssets + 1 must revert with I-1.
    function testReallocate_I1_conservation() public {
        uint256 ta = vault.totalAssets();
        // Target more than totalAssets (ignores idle)
        CuratedVault.MarketTarget[] memory tgts = _targets2(address(marketA), ta / 2, address(marketB), ta / 2 + 2);
        CuratedVault.RebalanceGuard memory guard = _makeGuard();

        vm.expectRevert(abi.encodeWithSelector(CuratedVault.InvariantViolation.selector, bytes32("I-1")));
        vm.prank(allocator);
        vault.reallocate(tgts, guard);
    }

    // ════════════════════════════════════════════════════════════════
    //  I-2  CAP COMPLIANCE
    // ════════════════════════════════════════════════════════════════

    /// @notice target > supplyCap must revert with I-2.
    function testReallocate_I2_capExceeded() public {
        // First raise maxMarketBps so I-4 doesn't fire first
        vm.prank(curator);
        vault.setMaxMarketBps(9_000);

        // Lower marketA's supply cap to 10_000e6 (a cap decrease is immediate).
        // Use SENTINEL_ROLE path (cap decrease) via curator direct call.
        vm.prank(curator);
        vault.setSupplyCap(address(marketA), 10_000 * 1e6);

        // Try to allocate 10_001e6 — just over the new cap.
        // totalAssets = 100_000e6, so I-1 is fine (idle = 89_999e6).
        uint256 overCap = 10_001 * 1e6;

        CuratedVault.RebalanceGuard memory guard = _makeGuard();
        CuratedVault.MarketTarget[] memory tgts = _target(address(marketA), overCap);

        vm.expectRevert(abi.encodeWithSelector(CuratedVault.InvariantViolation.selector, bytes32("I-2")));
        vm.prank(allocator);
        vault.reallocate(tgts, guard);
    }

    // ════════════════════════════════════════════════════════════════
    //  I-3  IDLE FLOOR
    // ════════════════════════════════════════════════════════════════

    /// @notice Targets that leave < minIdleBufferBps idle must revert with I-3.
    function testReallocate_I3_idleFloor() public {
        // Set idle floor to 20% (2000 bps)
        vm.prank(curator);
        vault.setMinIdleBufferBps(2_000);

        uint256 ta = vault.totalAssets();
        // Allocate 90% across two markets — leaves only 10% idle < 20% floor
        uint256 aAmt = ta * 45 / 100;
        uint256 bAmt = ta * 45 / 100;
        CuratedVault.RebalanceGuard memory guard = _makeGuard();

        vm.expectRevert(abi.encodeWithSelector(CuratedVault.InvariantViolation.selector, bytes32("I-3")));
        vm.prank(allocator);
        vault.reallocate(_targets2(address(marketA), aAmt, address(marketB), bAmt), guard);
    }

    /// @notice A market left out of `targets` keeps its balance. That balance
    ///         is not idle, so it must not count toward the I-3 floor.
    function testReallocate_I3_unlistedMarketIsNotIdle() public {
        vm.prank(curator);
        vault.setMinIdleBufferBps(2_000);
        uint256 ta = vault.totalAssets();

        // Step 1: A = 45%, B = 35%, idle = 20% (exactly the floor).
        CuratedVault.RebalanceGuard memory first = _makeGuard();
        vm.prank(allocator);
        vault.reallocate(_targets2(address(marketA), ta * 45 / 100, address(marketB), ta * 35 / 100), first);
        _warpPastEpoch();

        // Step 2: list only B at 45%. A keeps 45%, so real idle would be 10%.
        CuratedVault.RebalanceGuard memory guard = _makeGuard();
        vm.expectRevert(abi.encodeWithSelector(CuratedVault.InvariantViolation.selector, bytes32("I-3")));
        vm.prank(allocator);
        vault.reallocate(_target(address(marketB), ta * 45 / 100), guard);
    }

    /// @notice Listing a market twice would double-count it in the I-1 sum.
    function testReallocate_I1_duplicateMarketRejected() public {
        uint256 ta = vault.totalAssets();
        CuratedVault.RebalanceGuard memory guard = _makeGuard();
        vm.expectRevert(abi.encodeWithSelector(CuratedVault.InvariantViolation.selector, bytes32("I-1")));
        vm.prank(allocator);
        vault.reallocate(_targets2(address(marketA), ta * 20 / 100, address(marketA), ta * 20 / 100), guard);
    }

    // ════════════════════════════════════════════════════════════════
    //  I-4  MAX CONCENTRATION
    // ════════════════════════════════════════════════════════════════

    /// @notice target > maxMarketBps × totalAssets must revert with I-4.
    function testReallocate_I4_concentration() public {
        // Lower maxMarketBps to 30% so I-4 fires at 31%, which is under the
        // 50_000e6 supply cap (I-2 won't fire first).
        vm.prank(curator);
        vault.setMaxMarketBps(3_000);

        uint256 ta = vault.totalAssets();
        uint256 overConc = ta * 31 / 100; // 31% > 30% maxMarketBps, within 50k cap
        CuratedVault.RebalanceGuard memory guard = _makeGuard();

        vm.expectRevert(abi.encodeWithSelector(CuratedVault.InvariantViolation.selector, bytes32("I-4")));
        vm.prank(allocator);
        vault.reallocate(_target(address(marketA), overConc), guard);
    }

    // ════════════════════════════════════════════════════════════════
    //  I-5  WHITELIST
    // ════════════════════════════════════════════════════════════════

    /// @notice Target for a non-enabled market must revert with I-5.
    function testReallocate_I5_whitelist_disabledMarket() public {
        address fakeMarket = address(0xdead);
        CuratedVault.MarketTarget[] memory tgts = _target(fakeMarket, 1e6);
        CuratedVault.RebalanceGuard memory guard = _makeGuard();

        vm.expectRevert(abi.encodeWithSelector(CuratedVault.InvariantViolation.selector, bytes32("I-5")));
        vm.prank(allocator);
        vault.reallocate(tgts, guard);
    }

    /// @notice Target of zero amount for an enabled market must revert with I-5.
    function testReallocate_I5_whitelist_zeroAmount() public {
        CuratedVault.MarketTarget[] memory tgts = _target(address(marketA), 0);
        CuratedVault.RebalanceGuard memory guard = _makeGuard();

        vm.expectRevert(abi.encodeWithSelector(CuratedVault.InvariantViolation.selector, bytes32("I-5")));
        vm.prank(allocator);
        vault.reallocate(tgts, guard);
    }

    // ════════════════════════════════════════════════════════════════
    //  I-6  TURNOVER BOUND
    // ════════════════════════════════════════════════════════════════

    /// @notice Total absolute movement > maxTurnoverBps × totalAssets must revert with I-6.
    function testReallocate_I6_turnover() public {
        // Set maxTurnoverBps to 10% (1000 bps)
        vm.prank(curator);
        vault.setMaxTurnoverBps(1_000);

        uint256 ta = vault.totalAssets();
        // Try to move 30% to A — exceeds 10% turnover limit
        uint256 aAmt = ta * 30 / 100;
        CuratedVault.RebalanceGuard memory guard = _makeGuard();

        vm.expectRevert(abi.encodeWithSelector(CuratedVault.InvariantViolation.selector, bytes32("I-6")));
        vm.prank(allocator);
        vault.reallocate(_target(address(marketA), aAmt), guard);
    }

    // ════════════════════════════════════════════════════════════════
    //  I-8  EPOCH COOLDOWN
    // ════════════════════════════════════════════════════════════════

    /// @notice Second rebalance before epochLength elapses must revert with I-8.
    function testReallocate_I8_cooldown() public {
        uint256 ta = vault.totalAssets();
        uint256 aAmt = ta * 20 / 100;

        // First rebalance succeeds
        CuratedVault.RebalanceGuard memory guard1 = _makeGuard();
        vm.prank(allocator);
        vault.reallocate(_target(address(marketA), aAmt), guard1);

        // Second rebalance immediately after — should fail with I-8
        CuratedVault.RebalanceGuard memory guard2 = _makeGuard();
        vm.expectRevert(abi.encodeWithSelector(CuratedVault.InvariantViolation.selector, bytes32("I-8")));
        vm.prank(allocator);
        vault.reallocate(_target(address(marketA), aAmt), guard2);
    }

    // ════════════════════════════════════════════════════════════════
    //  I-9  PAUSE RESPECT
    // ════════════════════════════════════════════════════════════════

    /// @notice When depositsPaused, increasing any market balance must revert with I-9.
    function testReallocate_I9_paused_noNewAllocation() public {
        // Pause deposits via sentinel
        vm.prank(address(sentinel));
        vault.pauseDeposits();
        assertTrue(vault.depositsPaused(), "should be paused");

        uint256 ta = vault.totalAssets();
        uint256 aAmt = ta * 20 / 100; // market A currently has 0 — this is an increase
        CuratedVault.RebalanceGuard memory guard = _makeGuard();

        vm.expectRevert(abi.encodeWithSelector(CuratedVault.InvariantViolation.selector, bytes32("I-9")));
        vm.prank(allocator);
        vault.reallocate(_target(address(marketA), aAmt), guard);
    }

    /// @notice When depositsPaused, reducing a market balance is allowed (deallocation).
    function testReallocate_I9_paused_deallocationAllowed() public {
        // First allocate some funds while not paused
        uint256 ta = vault.totalAssets();
        uint256 aAmt = ta * 20 / 100;
        CuratedVault.RebalanceGuard memory guard0 = _makeGuard();
        vm.prank(allocator);
        vault.reallocate(_target(address(marketA), aAmt), guard0);

        // Now pause
        vm.prank(address(sentinel));
        vault.pauseDeposits();

        // Warp past next epoch cooldown
        _warpPastEpoch();

        // Try to reduce market A allocation — allowed even when paused
        uint256 smaller = aAmt / 2;
        CuratedVault.RebalanceGuard memory guard = _makeGuard();
        vm.prank(allocator);
        vault.reallocate(_target(address(marketA), smaller), guard);

        assertEq(marketA.balanceOf(address(vault)), smaller, "partial dealloc"); // Proves I-9
    }

    // ════════════════════════════════════════════════════════════════
    //  I-10  STALENESS
    // ════════════════════════════════════════════════════════════════

    /// @notice Snapshot totalAssets deviating > driftToleranceBps must revert with I-10.
    function testReallocate_I10_staleness_drift() public {
        // Default driftToleranceBps is 500 (5%)
        uint256 ta = vault.totalAssets();
        // Snapshot is 10% off — beyond 5% tolerance
        uint256 staleSnapshot = ta * 90 / 100;

        CuratedVault.RebalanceGuard memory guard =
            CuratedVault.RebalanceGuard({snapshotTotalAssets: staleSnapshot, snapshotEpoch: vault.currentEpoch()});

        vm.expectRevert(abi.encodeWithSelector(CuratedVault.InvariantViolation.selector, bytes32("I-10")));
        vm.prank(allocator);
        vault.reallocate(_target(address(marketA), ta * 10 / 100), guard);
    }

    /// @notice Snapshot epoch mismatch must revert with I-10.
    function testReallocate_I10_epochMismatch() public {
        CuratedVault.RebalanceGuard memory guard = CuratedVault.RebalanceGuard({
            snapshotTotalAssets: vault.totalAssets(),
            snapshotEpoch: 999 // wrong epoch
        });

        vm.expectRevert(abi.encodeWithSelector(CuratedVault.InvariantViolation.selector, bytes32("I-10")));
        vm.prank(allocator);
        vault.reallocate(_target(address(marketA), 1e6), guard);
    }

    // ════════════════════════════════════════════════════════════════
    //  CURATOR SETTERS
    // ════════════════════════════════════════════════════════════════

    function testSetMaxMarketBps() public {
        vm.prank(curator);
        vault.setMaxMarketBps(4_000);
        assertEq(vault.maxMarketBps(), 4_000);
    }

    function testSetMaxMarketBps_tooHigh() public {
        vm.expectRevert();
        vm.prank(curator);
        vault.setMaxMarketBps(9_001);
    }

    function testSetMaxTurnoverBps() public {
        vm.prank(curator);
        vault.setMaxTurnoverBps(2_000);
        assertEq(vault.maxTurnoverBps(), 2_000);
    }

    function testSetDriftToleranceBps() public {
        vm.prank(curator);
        vault.setDriftToleranceBps(1_000);
        assertEq(vault.driftToleranceBps(), 1_000);
    }

    function testSetDriftToleranceBps_tooHigh() public {
        vm.expectRevert();
        vm.prank(curator);
        vault.setDriftToleranceBps(2_001);
    }

    function testSetRebalanceEpochLength() public {
        vm.prank(curator);
        vault.setRebalanceEpochLength(2 hours);
        assertEq(vault.rebalanceEpochLength(), 2 hours);
    }

    function testSetRebalanceEpochLength_tooLong() public {
        vm.expectRevert();
        vm.prank(curator);
        vault.setRebalanceEpochLength(7 days + 1);
    }

    // ════════════════════════════════════════════════════════════════
    //  FUZZ
    // ════════════════════════════════════════════════════════════════

    /// @notice Any valid single-market target satisfying I-1..I-6 must succeed;
    ///         post-state satisfies all invariants.
    ///         Proves I-1, I-3, I-4, I-6 simultaneously via fuzzing.
    function testFuzz_reallocate_validSingleMarket(uint256 pct) public {
        // pct in [1, 40] — keeps us inside idle floor (5%), maxMarket (50%), and
        // inside any reasonable turnover bound.
        pct = bound(pct, 1, 40);

        uint256 ta = vault.totalAssets();
        uint256 aAmt = ta * pct / 100;

        // Ensure turnover can accommodate this (set maxTurnoverBps = 5000)
        vm.prank(curator);
        vault.setMaxTurnoverBps(5_000);

        CuratedVault.RebalanceGuard memory guard = _makeGuard();
        vm.prank(allocator);
        vault.reallocate(_target(address(marketA), aAmt), guard);

        // Post-state invariant checks
        uint256 actualBal = marketA.balanceOf(address(vault));
        assertEq(actualBal, aAmt, "balance matches target"); // Proves I-1
        assertGe(vault.idleBufferBps(), vault.minIdleBufferBps(), "idle floor preserved"); // Proves I-3
        assertLe(actualBal * 10_000, vault.maxMarketBps() * vault.totalAssets(), "concentration within limit"); // Proves I-4
    }

    /// @notice Fuzz two-market split: both markets get valid targets.
    function testFuzz_reallocate_twoMarkets(uint256 pctA, uint256 pctB) public {
        // pctA + pctB <= 90, each >= 1
        pctA = bound(pctA, 1, 40);
        pctB = bound(pctB, 1, 40);

        uint256 ta = vault.totalAssets();
        uint256 aAmt = ta * pctA / 100;
        uint256 bAmt = ta * pctB / 100;

        // Raise maxTurnover to allow the full movement
        vm.prank(curator);
        vault.setMaxTurnoverBps(9_000);

        CuratedVault.RebalanceGuard memory guard = _makeGuard();
        vm.prank(allocator);
        vault.reallocate(_targets2(address(marketA), aAmt, address(marketB), bAmt), guard);

        assertEq(marketA.balanceOf(address(vault)), aAmt, "A balance"); // Proves I-1
        assertEq(marketB.balanceOf(address(vault)), bAmt, "B balance"); // Proves I-1
        assertGe(vault.idleBufferBps(), vault.minIdleBufferBps(), "idle floor"); // Proves I-3
    }
}
