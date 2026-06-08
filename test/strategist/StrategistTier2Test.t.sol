// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {TestBase} from "../TestBase.sol";
import {CuratedVault} from "../../src/CuratedVault.sol";
import {AllocationStrategist} from "../../src/AllocationStrategist.sol";
import {AllocationProjection} from "../../src/AllocationProjection.sol";

/// @title  StrategistTier2Test
/// @notice Phase 4 — Tier-2 per-market inferNumber scoring tests.
///
///  Each test cites the spec item it proves.
contract StrategistTier2Test is TestBase {
    // Redeclare events — solc 0.8.20 cannot resolve ContractType.EventName from outside the emitter
    event AllocationModeSet(AllocationStrategist.AllocationMode mode);
    event RebalanceExecuted(address indexed vault_, string label, uint256 epoch);
    event RebalanceSkipped(address indexed vault_, string reason);
    event Tier2ScoreReceived(uint256 indexed groupId, uint256 indexed marketIndex, uint256 score);

    AllocationStrategist strategist;

    uint256 constant DEPOSIT = 100_000 * 1e6;

    function setUp() public override {
        super.setUp();

        // Deploy strategist; admin is this test contract
        strategist = new AllocationStrategist(address(platform), 1, address(vault), address(this));

        // Grant ALLOCATOR_ROLE to the strategist
        vm.prank(admin);
        vault.grantRole(ALLOCATOR_ROLE, address(strategist));

        // Seed vault
        usdc.mint(address(this), DEPOSIT);
        usdc.approve(address(vault), DEPOSIT);
        vault.deposit(DEPOSIT, address(this));

        // Raise turnover limit to 90% for testing (vault max is 9000)
        vm.prank(curator);
        vault.setMaxTurnoverBps(9_000);

        // Lower idle floor to 5% (500 bps)
        vm.prank(curator);
        vault.setMinIdleBufferBps(500);

        // Warp past initial epoch cooldown
        vm.warp(block.timestamp + vault.rebalanceEpochLength() + 1);
    }

    // ════════════════════════════════════════════════════════════════
    //  ACCESS CONTROL
    // ════════════════════════════════════════════════════════════════

    /// @notice Non-admin cannot set allocation mode.
    function testSetAllocationMode_adminOnly() public {
        vm.expectRevert(AllocationStrategist.NotAdmin.selector);
        vm.prank(attacker);
        strategist.setAllocationMode(AllocationStrategist.AllocationMode.Tier2);
        // Proves: AllocationMode gated to admin only
    }

    /// @notice Admin can switch to Tier-2 mode; event emitted.
    function testSetAllocationMode_curator() public {
        // admin in this test is address(this)
        vm.expectEmit(false, false, false, true);
        emit AllocationModeSet(AllocationStrategist.AllocationMode.Tier2);
        strategist.setAllocationMode(AllocationStrategist.AllocationMode.Tier2);

        assertEq(
            uint256(strategist.allocationMode()),
            uint256(AllocationStrategist.AllocationMode.Tier2),
            "mode updated to Tier2"
        ); // Proves: AllocationMode persisted correctly
    }

    // ════════════════════════════════════════════════════════════════
    //  TIER-2 HAPPY PATH — REQUEST
    // ════════════════════════════════════════════════════════════════

    /// @notice In Tier-2 mode, requestRebalance issues N sub-requests (one per market).
    function testTier2_requestRebalance_happy() public {
        strategist.setAllocationMode(AllocationStrategist.AllocationMode.Tier2);

        uint256 mCount = vault.marketCount(); // 2 markets
        uint256 reqsBefore = platform.nextRequestId();

        uint256 minDeposit = platform.getRequestDeposit();
        // Need minDeposit per market
        strategist.requestRebalance{value: minDeposit * mCount}(address(vault));

        uint256 reqsAfter = platform.nextRequestId();
        assertEq(reqsAfter - reqsBefore, mCount, "N sub-requests created"); // Proves: OD-1 one request per market

        // Active request set for vault
        assertNotEq(strategist.activeRequest(address(vault)), 0, "activeRequest set"); // Proves: in-flight tracking
    }

    // ════════════════════════════════════════════════════════════════
    //  TIER-2 HAPPY PATH — ALL SCORES DELIVERED
    // ════════════════════════════════════════════════════════════════

    /// @notice After all N score callbacks arrive, reallocate fires and vault state changes.
    function testTier2_allScoresDelivered_executes() public {
        strategist.setAllocationMode(AllocationStrategist.AllocationMode.Tier2);

        uint256 mCount = vault.marketCount(); // 2 markets
        uint256 minDeposit = platform.getRequestDeposit();

        uint256 firstReqId = platform.nextRequestId();
        uint256 expectedGroupId = strategist.nextGroupId(); // capture before call increments it
        strategist.requestRebalance{value: minDeposit * mCount}(address(vault));

        uint256 epochBefore = vault.currentEpoch();

        // Deliver score for market 0 (reqId = firstReqId)
        vm.expectEmit(true, true, false, true);
        emit Tier2ScoreReceived(expectedGroupId, 0, 7_000);
        platform.simulateNumberCallback(firstReqId, 7_000);

        // After first callback, active request still set
        assertNotEq(strategist.activeRequest(address(vault)), 0, "still in-flight after first callback");

        // Deliver score for market 1 (reqId = firstReqId + 1) — triggers execution
        vm.expectEmit(true, false, false, false);
        emit RebalanceExecuted(address(vault), "TIER2", epochBefore + 1);
        platform.simulateNumberCallback(firstReqId + 1, 3_000);

        // Vault epoch should have incremented (reallocate called)
        assertEq(vault.currentEpoch(), epochBefore + 1, "epoch incremented after Tier2"); // Proves: reallocate executed
        assertEq(strategist.activeRequest(address(vault)), 0, "activeRequest cleared"); // Proves: cleanup
    }

    // ════════════════════════════════════════════════════════════════
    //  TIER-2 FAIL-SAFE — PARTIAL FAILURE
    // ════════════════════════════════════════════════════════════════

    /// @notice If one sub-request fails, group is abandoned. No vault movement.
    function testTier2_partialFailure_skips() public {
        strategist.setAllocationMode(AllocationStrategist.AllocationMode.Tier2);

        uint256 mCount = vault.marketCount();
        uint256 minDeposit = platform.getRequestDeposit();
        uint256 firstReqId = platform.nextRequestId();

        strategist.requestRebalance{value: minDeposit * mCount}(address(vault));

        uint256 epochBefore = vault.currentEpoch();

        // First callback is a success
        platform.simulateNumberCallback(firstReqId, 5_000);

        // Second callback fails — group should be abandoned
        vm.expectEmit(true, false, false, true);
        emit RebalanceSkipped(address(vault), "TIER2_GROUP_ABANDONED");
        platform.simulateNumberFailed(firstReqId + 1);

        // Epoch must not have changed (no vault movement) — Proves: fail-safe
        assertEq(vault.currentEpoch(), epochBefore, "epoch unchanged on partial failure");
        assertEq(strategist.activeRequest(address(vault)), 0, "activeRequest cleared on failure");
    }

    /// @notice If the first sub-request fails, group is immediately abandoned.
    function testTier2_firstFailure_skips() public {
        strategist.setAllocationMode(AllocationStrategist.AllocationMode.Tier2);

        uint256 mCount = vault.marketCount();
        uint256 minDeposit = platform.getRequestDeposit();
        uint256 firstReqId = platform.nextRequestId();

        strategist.requestRebalance{value: minDeposit * mCount}(address(vault));

        uint256 epochBefore = vault.currentEpoch();

        // First callback fails
        platform.simulateNumberFailed(firstReqId);

        // Second callback arrives — group abandoned, silently ignored
        platform.simulateNumberCallback(firstReqId + 1, 5_000);

        assertEq(vault.currentEpoch(), epochBefore, "epoch unchanged when first score fails"); // Proves: fail-safe
        assertEq(strategist.activeRequest(address(vault)), 0, "activeRequest cleared");
    }

    // ════════════════════════════════════════════════════════════════
    //  TIER-2 FAIL-SAFE — TIMEOUT
    // ════════════════════════════════════════════════════════════════

    /// @notice Sub-request arriving after RESPONSE_TIMEOUT abandons the group.
    function testTier2_timeout_skips() public {
        strategist.setAllocationMode(AllocationStrategist.AllocationMode.Tier2);

        uint256 mCount = vault.marketCount();
        uint256 minDeposit = platform.getRequestDeposit();
        uint256 firstReqId = platform.nextRequestId();

        strategist.requestRebalance{value: minDeposit * mCount}(address(vault));

        uint256 epochBefore = vault.currentEpoch();

        // Warp past response timeout
        vm.warp(block.timestamp + strategist.RESPONSE_TIMEOUT() + 1);

        // First callback arrives after timeout
        platform.simulateNumberCallback(firstReqId, 8_000);

        // Second callback — group abandoned, cleanup
        platform.simulateNumberCallback(firstReqId + 1, 2_000);

        assertEq(vault.currentEpoch(), epochBefore, "epoch unchanged on timeout"); // Proves: fail-safe timeout
        assertEq(strategist.activeRequest(address(vault)), 0, "activeRequest cleared after timeout");
    }

    // ════════════════════════════════════════════════════════════════
    //  AC-5 — CAP ENFORCEMENT
    // ════════════════════════════════════════════════════════════════

    /// @notice High Tier-2 score on a capped market stays within supply cap.
    ///         I-2/I-4 in vault.reallocate() enforce this — Tier-2 scores cannot override.
    function testTier2_AC5_cappedMarket() public {
        // Reduce marketA cap to a small value (decrease is immediate for CURATOR_ROLE)
        vm.prank(curator);
        vault.setSupplyCap(address(marketA), 5_000 * 1e6); // only 5k cap

        strategist.setAllocationMode(AllocationStrategist.AllocationMode.Tier2);

        uint256 mCount = vault.marketCount();
        uint256 minDeposit = platform.getRequestDeposit();
        uint256 firstReqId = platform.nextRequestId();

        strategist.requestRebalance{value: minDeposit * mCount}(address(vault));

        // Give marketA a very high score (10000) and marketB a low score
        platform.simulateNumberCallback(firstReqId, 10_000);     // market A
        platform.simulateNumberCallback(firstReqId + 1, 1_000);  // market B

        // Market A balance must not exceed its cap (5k USDC)
        uint256 balA = marketA.balanceOf(address(vault));
        assertLe(balA, 5_000 * 1e6, "market A within cap despite high score"); // Proves: AC-5, I-2
    }

    // ════════════════════════════════════════════════════════════════
    //  ZERO SCORES — ALL IDLE
    // ════════════════════════════════════════════════════════════════

    /// @notice All-zero Tier-2 scores → AllocationProjection returns all-zero targets →
    ///         reallocate not called → vault stays idle.
    function testTier2_zeroScores_allIdle() public {
        strategist.setAllocationMode(AllocationStrategist.AllocationMode.Tier2);

        uint256 mCount = vault.marketCount();
        uint256 minDeposit = platform.getRequestDeposit();
        uint256 firstReqId = platform.nextRequestId();

        strategist.requestRebalance{value: minDeposit * mCount}(address(vault));

        uint256 epochBefore = vault.currentEpoch();
        uint256 balABefore = marketA.balanceOf(address(vault));
        uint256 balBBefore = marketB.balanceOf(address(vault));

        // Both scores zero
        platform.simulateNumberCallback(firstReqId, 0);
        platform.simulateNumberCallback(firstReqId + 1, 0);

        // No movement — epoch unchanged, balances unchanged (Proves: zero score = no allocation)
        assertEq(vault.currentEpoch(), epochBefore, "epoch unchanged on zero scores");
        assertEq(marketA.balanceOf(address(vault)), balABefore, "market A balance unchanged");
        assertEq(marketB.balanceOf(address(vault)), balBBefore, "market B balance unchanged");
    }

    // ════════════════════════════════════════════════════════════════
    //  FUZZ
    // ════════════════════════════════════════════════════════════════

    /// @notice Random scores produce a valid vault state (I-1: idle ≥ minIdleFloor;
    ///         I-2: no market exceeds cap; I-3: vault solvency).
    function testFuzz_tier2_scoresProduceValidState(uint256 scoreA, uint256 scoreB) public {
        // Clamp inputs to [0, SCORE_MAX]
        scoreA = scoreA % (strategist.SCORE_MAX() + 1);
        scoreB = scoreB % (strategist.SCORE_MAX() + 1);

        strategist.setAllocationMode(AllocationStrategist.AllocationMode.Tier2);

        uint256 mCount = vault.marketCount();
        uint256 minDeposit = platform.getRequestDeposit();
        uint256 firstReqId = platform.nextRequestId();

        strategist.requestRebalance{value: minDeposit * mCount}(address(vault));

        platform.simulateNumberCallback(firstReqId, scoreA);
        platform.simulateNumberCallback(firstReqId + 1, scoreB);

        // I-3: vault total assets must not decrease (no loss of funds)
        uint256 vaultTotal = vault.totalAssets();
        assertGe(vaultTotal, DEPOSIT, "vault total assets unchanged (I-3)");

        // I-1: idle buffer must be >= minIdleBufferBps of totalAssets
        uint256 idleBps = vault.idleBufferBps();
        assertGe(idleBps, vault.minIdleBufferBps(), "idle buffer above floor (I-1)");

        // I-2: no market balance exceeds its supply cap
        (bool enabledA, uint256 capA) = vault.markets(address(marketA));
        (bool enabledB, uint256 capB) = vault.markets(address(marketB));
        if (enabledA) assertLe(marketA.balanceOf(address(vault)), capA, "market A within cap (I-2)");
        if (enabledB) assertLe(marketB.balanceOf(address(vault)), capB, "market B within cap (I-2)");
    }

    // ════════════════════════════════════════════════════════════════
    //  TIER-2 — SCORE CLAMPING
    // ════════════════════════════════════════════════════════════════

    /// @notice Scores above SCORE_MAX are clamped — vault state still valid.
    function testTier2_scoreClamp_aboveMax() public {
        strategist.setAllocationMode(AllocationStrategist.AllocationMode.Tier2);

        uint256 mCount = vault.marketCount();
        uint256 minDeposit = platform.getRequestDeposit();
        uint256 firstReqId = platform.nextRequestId();

        strategist.requestRebalance{value: minDeposit * mCount}(address(vault));

        // Send a score well above SCORE_MAX — should be clamped to 10000
        platform.simulateNumberCallback(firstReqId, type(uint256).max);
        platform.simulateNumberCallback(firstReqId + 1, 5_000);

        // Vault should still be in a valid state
        assertGe(vault.totalAssets(), DEPOSIT, "vault solvent after score clamp"); // Proves: score clamping
        assertGe(vault.idleBufferBps(), vault.minIdleBufferBps(), "idle buffer preserved after clamp");
    }

    // ════════════════════════════════════════════════════════════════
    //  TIER-2 — COOLDOWN RESPECTED
    // ════════════════════════════════════════════════════════════════

    /// @notice After a successful Tier-2 group completes, the strategist cooldown re-applies.
    ///         Immediate re-request reverts; after cooldown passes it succeeds.
    function testTier2_cooldown_enforced() public {
        strategist.setAllocationMode(AllocationStrategist.AllocationMode.Tier2);

        uint256 mCount = vault.marketCount();
        uint256 minDeposit = platform.getRequestDeposit();
        uint256 firstReqId = platform.nextRequestId();

        strategist.requestRebalance{value: minDeposit * mCount}(address(vault));

        // Deliver callbacks (vault epoch cooldown irrelevant — scores may produce no movement
        // if turnover cap is tight, or group abandons on timeout — just verify cooldown state)
        platform.simulateNumberCallback(firstReqId, 5_000);
        platform.simulateNumberCallback(firstReqId + 1, 5_000);

        // Immediate second request should hit strategist cooldown
        vm.expectRevert();
        strategist.requestRebalance{value: minDeposit * mCount}(address(vault));

        // After strategist cooldown + vault epoch cooldown, second request should succeed
        vm.warp(block.timestamp + vault.rebalanceEpochLength() + strategist.REBALANCE_COOLDOWN() + 1);
        uint256 nextFirstReqId = platform.nextRequestId();
        strategist.requestRebalance{value: minDeposit * mCount}(address(vault));
        assertNotEq(platform.nextRequestId(), nextFirstReqId, "new requests created after cooldown"); // Proves: cooldown respected
    }

    // ════════════════════════════════════════════════════════════════
    //  TIER-1 BACKWARD COMPATIBILITY (sanity check)
    // ════════════════════════════════════════════════════════════════

    /// @notice After switching back from Tier-2 to Tier-1, Tier-1 flow still works.
    function testTier1_backwardCompat_afterTier2Switch() public {
        // Switch to Tier-2, then back to Tier-1
        strategist.setAllocationMode(AllocationStrategist.AllocationMode.Tier2);
        strategist.setAllocationMode(AllocationStrategist.AllocationMode.Tier1);

        assertEq(
            uint256(strategist.allocationMode()),
            uint256(AllocationStrategist.AllocationMode.Tier1),
            "back to Tier1"
        );

        uint256 minDeposit = platform.getRequestDeposit();
        uint256 reqId = platform.nextRequestId();

        // Tier-1 only sends one request
        strategist.requestRebalance{value: minDeposit}(address(vault));
        assertEq(platform.nextRequestId() - reqId, 1, "Tier-1 sends exactly one request"); // Proves: Tier-1 backward compat

        // Deliver Tier-1 response
        uint256 epochBefore = vault.currentEpoch();
        platform.simulateCallback(reqId, "BALANCED");
        assertEq(vault.currentEpoch(), epochBefore + 1, "Tier-1 reallocate after switching back");
    }
}
