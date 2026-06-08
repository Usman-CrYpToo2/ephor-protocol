// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {TestBase} from "../TestBase.sol";
import {CuratedVault} from "../../src/CuratedVault.sol";
import {AllocationStrategist} from "../../src/AllocationStrategist.sol";
import "../../src/Interface/ISomnia.sol";

/// @title  StrategistTier1Test
/// @notice Tests for AllocationStrategist Phase 3 - full Somnia LLM lifecycle.
///
///  Covers:
///   - requestRebalance happy path
///   - cooldown enforcement
///   - handleResponse for all 4 labels (BALANCED, YIELD_TILT, DEFENSIVE, DERISK)
///   - timeout fail-safe
///   - unknown label fail-safe
///   - access control (onlyPlatform)
///   - fuzz: all labels produce valid vault state (I-1..I-3)
contract StrategistTier1Test is TestBase {
    // Redeclare events so vm.expectEmit + emit works (solc 0.8.20 doesn't resolve
    // ContractType.EventName from outside the emitting contract)
    event RebalanceRequested(address indexed vault_, uint256 indexed requestId);
    event RebalanceExecuted(address indexed vault_, string label, uint256 epoch);
    event RebalanceSkipped(address indexed vault_, string reason);

    AllocationStrategist strategist;

    uint256 constant DEPOSIT = 100_000 * 1e6;

    // Minimum deposit for the mock platform
    uint256 constant MIN_DEPOSIT = 0.01 ether;

    function setUp() public override {
        super.setUp();

        // Deploy strategist: (platform, llmAgentId, vault, admin)
        strategist = new AllocationStrategist(address(platform), 1, address(vault), address(this));

        // Grant ALLOCATOR_ROLE to the strategist
        vm.prank(admin);
        vault.grantRole(ALLOCATOR_ROLE, address(strategist));

        // Seed vault
        usdc.mint(address(this), DEPOSIT);
        usdc.approve(address(vault), DEPOSIT);
        vault.deposit(DEPOSIT, address(this));

        // Raise turnover limit for easy testing (curator role)
        vm.prank(curator);
        vault.setMaxTurnoverBps(9_000);

        // Lower idle floor to 5% (500 bps) so projection can allocate
        vm.prank(curator);
        vault.setMinIdleBufferBps(500);

        // Warp past initial epoch cooldown so reallocate won't hit I-8
        vm.warp(block.timestamp + vault.rebalanceEpochLength() + 1);

        // Fund test contract with plenty of ETH
        vm.deal(address(this), 100 ether);
    }

    // ════════════════════════════════════════════════════════════════
    //  HELPER - request and return the requestId
    // ════════════════════════════════════════════════════════════════

    function _requestRebalance() internal returns (uint256 reqId) {
        strategist.requestRebalance{value: MIN_DEPOSIT}(address(vault));
        reqId = platform.nextRequestId() - 1;
    }

    // ════════════════════════════════════════════════════════════════
    //  requestRebalance - HAPPY PATH
    // ════════════════════════════════════════════════════════════════

    /// @notice requestRebalance stores a PendingRebalance and emits RebalanceRequested.
    function testRequestRebalance_happy() public {
        vm.expectEmit(true, true, false, false);
        emit RebalanceRequested(address(vault), 1);

        strategist.requestRebalance{value: MIN_DEPOSIT}(address(vault));
        uint256 reqId = platform.nextRequestId() - 1;

        // Pending request stored correctly
        (address v, uint256 snapTA, uint256 snapEpoch, uint256 ts) = strategist.pendingRequests(reqId);
        assertEq(v, address(vault), "pending vault");
        assertEq(snapTA, vault.totalAssets(), "snapshot totalAssets captured");
        assertEq(snapEpoch, vault.currentEpoch(), "snapshot epoch captured"); // captured before createRequest
        assertGt(ts, 0, "timestamp set");

        // activeRequest tracked
        assertEq(strategist.activeRequest(address(vault)), reqId, "activeRequest set");
    }

    // ════════════════════════════════════════════════════════════════
    //  requestRebalance - COOLDOWN
    // ════════════════════════════════════════════════════════════════

    /// @notice Second requestRebalance before response (or cooldown) reverts RebalanceInProgress.
    function testRequestRebalance_cooldown() public {
        _requestRebalance();

        // Second call fails because lastRequestAt was set (RebalanceCooldown fires before
        // RebalanceInProgress — both enforce the same invariant from different angles)
        vm.expectRevert(); // RebalanceCooldown or RebalanceInProgress
        strategist.requestRebalance{value: MIN_DEPOSIT}(address(vault));
    }

    /// @notice After response clears, cooldown timer still blocks second request.
    function testRequestRebalance_cooldownAfterResponse() public {
        uint256 reqId = _requestRebalance();

        // Deliver a response to clear activeRequest
        platform.simulateCallback(reqId, "BALANCED");

        // Still within cooldown window (5 min) - should revert with RebalanceCooldown
        vm.expectRevert(); // RebalanceCooldown
        strategist.requestRebalance{value: MIN_DEPOSIT}(address(vault));
    }

    // ════════════════════════════════════════════════════════════════
    //  handleResponse - BALANCED
    // ════════════════════════════════════════════════════════════════

    /// @notice BALANCED label triggers reallocate with equal weights across markets.
    ///         Both markets should receive a nonzero allocation. Proves I-1, I-3.
    function testHandleResponse_BALANCED() public {
        uint256 reqId = _requestRebalance();
        uint256 epochBefore = vault.currentEpoch();
        uint256 taBefore = vault.totalAssets();

        platform.simulateCallback(reqId, "BALANCED");

        // Epoch incremented by reallocate
        assertEq(vault.currentEpoch(), epochBefore + 1, "epoch incremented");

        // totalAssets conserved (I-1)
        assertApproxEqAbs(vault.totalAssets(), taBefore, 1, "totalAssets conserved - I-1");

        // Idle >= minIdleFloor (I-3): 500 bps = 5%
        uint256 idleBps = vault.idleBufferBps();
        assertGe(idleBps, 500, "idle floor maintained - I-3");

        // Both markets got some allocation
        assertGt(marketA.balanceOf(address(vault)), 0, "market A allocated");
        assertGt(marketB.balanceOf(address(vault)), 0, "market B allocated");

        // Request cleared
        assertEq(strategist.activeRequest(address(vault)), 0, "activeRequest cleared");
    }

    // ════════════════════════════════════════════════════════════════
    //  handleResponse - YIELD_TILT
    // ════════════════════════════════════════════════════════════════

    /// @notice YIELD_TILT label uses utilization-weighted allocation.
    ///         Sets marketA util higher, expects A to receive more than B.
    function testHandleResponse_YIELD_TILT() public {
        // Seed assets into each market so setUtilization() sees a nonzero balance
        vm.prank(allocator);
        vault.allocate(address(marketA), 10_000 * 1e6);
        vm.prank(allocator);
        vault.allocate(address(marketB), 10_000 * 1e6);

        // Set marketA utilization to 80%, marketB to 20% (setUtilization takes pct 0-100)
        marketA.setUtilization(80);
        marketB.setUtilization(20);

        // Warp past epoch cooldown
        vm.warp(block.timestamp + vault.rebalanceEpochLength() + 1);

        uint256 reqId = _requestRebalance();
        uint256 taBefore = vault.totalAssets();
        platform.simulateCallback(reqId, "YIELD_TILT");

        // I-1: conservation
        assertApproxEqAbs(vault.totalAssets(), taBefore, 2, "totalAssets conserved - I-1");

        // I-3: idle floor
        assertGe(vault.idleBufferBps(), 500, "idle floor maintained - I-3");

        // Yield tilt: A (80% util) should have >= B (20% util)
        uint256 balA = marketA.balanceOf(address(vault));
        uint256 balB = marketB.balanceOf(address(vault));
        assertGe(balA, balB, "YIELD_TILT: high-util market A gets more");
    }

    // ════════════════════════════════════════════════════════════════
    //  handleResponse - DEFENSIVE
    // ════════════════════════════════════════════════════════════════

    /// @notice DEFENSIVE label inverts utilization weights (low util = more weight).
    function testHandleResponse_DEFENSIVE() public {
        // Seed assets into each market so setUtilization() sees a nonzero balance
        vm.prank(allocator);
        vault.allocate(address(marketA), 10_000 * 1e6);
        vm.prank(allocator);
        vault.allocate(address(marketB), 10_000 * 1e6);

        // Set marketA utilization to 80%, marketB to 20% (setUtilization takes pct 0-100)
        marketA.setUtilization(80);
        marketB.setUtilization(20);

        // Warp past epoch cooldown
        vm.warp(block.timestamp + vault.rebalanceEpochLength() + 1);

        uint256 reqId = _requestRebalance();
        uint256 taBefore = vault.totalAssets();
        platform.simulateCallback(reqId, "DEFENSIVE");

        // I-1: conservation
        assertApproxEqAbs(vault.totalAssets(), taBefore, 2, "totalAssets conserved - I-1");

        // I-3: idle floor
        assertGe(vault.idleBufferBps(), 500, "idle floor maintained - I-3");

        // Defensive: B (20% util) should have >= A (80% util)
        uint256 balA = marketA.balanceOf(address(vault));
        uint256 balB = marketB.balanceOf(address(vault));
        assertGe(balB, balA, "DEFENSIVE: low-util market B gets more");
    }

    // ════════════════════════════════════════════════════════════════
    //  handleResponse - DERISK
    // ════════════════════════════════════════════════════════════════

    /// @notice DERISK label results in no vault movement (everything idles).
    ///         No reallocate call; epoch NOT incremented.
    function testHandleResponse_DERISK() public {
        // First allocate some funds so there's something to observe
        vm.prank(allocator);
        vault.allocate(address(marketA), 20_000 * 1e6);

        uint256 epochBefore = vault.currentEpoch();

        // Warp past epoch cooldown again (epoch incremented by allocate path which doesn't use epoch)
        vm.warp(block.timestamp + vault.rebalanceEpochLength() + 1);

        uint256 reqId = _requestRebalance();
        // Capture balance just before callback to avoid interest-accrual drift
        uint256 balABefore = marketA.balanceOf(address(vault));
        platform.simulateCallback(reqId, "DERISK");

        // DERISK skips reallocate - epoch should NOT have incremented
        assertEq(vault.currentEpoch(), epochBefore, "DERISK: no reallocate, epoch unchanged");

        // Market balances unchanged (DERISK does nothing — allows tiny interest rounding)
        assertApproxEqAbs(marketA.balanceOf(address(vault)), balABefore, 1, "DERISK: market A unchanged");

        // Request cleared
        assertEq(strategist.activeRequest(address(vault)), 0, "activeRequest cleared");
    }

    // ════════════════════════════════════════════════════════════════
    //  handleResponse - TIMEOUT
    // ════════════════════════════════════════════════════════════════

    /// @notice Response after 10-minute timeout emits RebalanceSkipped and no vault movement.
    function testHandleResponse_timeout() public {
        uint256 reqId = _requestRebalance();
        uint256 epochBefore = vault.currentEpoch();
        uint256 taBefore = vault.totalAssets();

        // Warp past the 10-minute response timeout
        vm.warp(block.timestamp + strategist.RESPONSE_TIMEOUT() + 1);

        vm.expectEmit(true, false, false, false);
        emit RebalanceSkipped(address(vault), "TIMEOUT");

        platform.simulateCallback(reqId, "BALANCED");

        // No vault movement
        assertEq(vault.currentEpoch(), epochBefore, "epoch unchanged after timeout");
        assertEq(vault.totalAssets(), taBefore, "totalAssets unchanged after timeout");
        assertEq(strategist.activeRequest(address(vault)), 0, "activeRequest cleared");
    }

    // ════════════════════════════════════════════════════════════════
    //  handleResponse - UNKNOWN LABEL
    // ════════════════════════════════════════════════════════════════

    /// @notice Unknown label emits RebalanceSkipped and no vault movement.
    function testHandleResponse_unknownLabel() public {
        uint256 reqId = _requestRebalance();
        uint256 epochBefore = vault.currentEpoch();
        uint256 taBefore = vault.totalAssets();

        vm.expectEmit(true, false, false, false);
        emit RebalanceSkipped(address(vault), "UNKNOWN_LABEL");

        platform.simulateCallback(reqId, "RANDOM_GARBAGE");

        // No vault movement
        assertEq(vault.currentEpoch(), epochBefore, "epoch unchanged on unknown label");
        assertEq(vault.totalAssets(), taBefore, "totalAssets unchanged on unknown label");
        assertEq(strategist.activeRequest(address(vault)), 0, "activeRequest cleared");
    }

    // ════════════════════════════════════════════════════════════════
    //  handleResponse - ACCESS CONTROL
    // ════════════════════════════════════════════════════════════════

    /// @notice Non-platform caller cannot invoke handleResponse.
    function testHandleResponse_onlyPlatform() public {
        uint256 reqId = _requestRebalance();

        Response[] memory resps = new Response[](1);
        resps[0] = Response({
            validator: address(this),
            result: abi.encode("BALANCED"),
            status: ResponseStatus.Success,
            receipt: 0,
            timestamp: block.timestamp,
            executionCost: 0
        });

        address[] memory sub = new address[](0);
        Response[] memory empty = new Response[](0);
        Request memory req = Request({
            id: reqId,
            requester: address(this),
            callbackAddress: address(strategist),
            callbackSelector: strategist.handleResponse.selector,
            subcommittee: sub,
            responses: empty,
            responseCount: 3,
            failureCount: 0,
            threshold: 2,
            createdAt: block.timestamp - 5,
            deadline: block.timestamp + 60,
            status: ResponseStatus.Success,
            consensusType: ConsensusType.Majority,
            remainingBudget: 0,
            perAgentBudget: 0
        });

        // Non-platform caller - should revert
        vm.expectRevert(AllocationStrategist.NotPlatform.selector);
        vm.prank(attacker);
        strategist.handleResponse(reqId, resps, ResponseStatus.Success, req);
    }

    // ════════════════════════════════════════════════════════════════
    //  FUZZ - all 4 labels produce valid vault state (I-1..I-3)
    // ════════════════════════════════════════════════════════════════

    /// @notice All 4 valid labels (by index) leave vault in a valid state.
    ///         Proves I-1 (conservation) and I-3 (idle floor) hold post-rebalance.
    function testFuzz_tier1_allLabels(uint8 labelIdx) public {
        // Map fuzz input to one of 4 valid labels
        string memory label;
        uint8 idx = labelIdx % 4;
        if (idx == 0) label = "BALANCED";
        else if (idx == 1) label = "YIELD_TILT";
        else if (idx == 2) label = "DEFENSIVE";
        else label = "DERISK";

        uint256 taBefore = vault.totalAssets();
        uint256 reqId = _requestRebalance();

        platform.simulateCallback(reqId, label);

        // I-1: totalAssets conserved (within 1 wei rounding)
        assertApproxEqAbs(vault.totalAssets(), taBefore, 2, "I-1: totalAssets conserved");

        // I-3: idle buffer >= minIdleBufferBps (500 bps = 5%)
        assertGe(vault.idleBufferBps(), 500, "I-3: idle floor maintained");

        // Request state cleared
        assertEq(strategist.activeRequest(address(vault)), 0, "activeRequest cleared post-response");
    }

    // ════════════════════════════════════════════════════════════════
    //  PLATFORM TIMEOUT CALLBACK
    // ════════════════════════════════════════════════════════════════

    /// @notice Platform-delivered TimedOut status emits RebalanceSkipped (fail-safe).
    function testHandleResponse_platformTimedOut() public {
        uint256 reqId = _requestRebalance();
        uint256 epochBefore = vault.currentEpoch();

        vm.expectEmit(true, false, false, false);
        emit RebalanceSkipped(address(vault), "AI_UNAVAILABLE");

        platform.simulateTimeout(reqId);

        assertEq(vault.currentEpoch(), epochBefore, "no rebalance on platform timeout");
        assertEq(strategist.activeRequest(address(vault)), 0, "activeRequest cleared");
    }
}
