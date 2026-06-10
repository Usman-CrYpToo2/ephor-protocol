// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {TestBase} from "../TestBase.sol";
import {CuratedVault} from "../../src/CuratedVault.sol";
import {AllocationStrategist} from "../../src/AllocationStrategist.sol";
import {AllocationProjection} from "../../src/AllocationProjection.sol";

/// @title  StrategistTest
/// @notice Tests for AllocationStrategist stub and AllocationProjection library (Phase 2).
contract StrategistTest is TestBase {
    AllocationStrategist strategist;

    uint256 constant DEPOSIT = 100_000 * 1e6;

    function setUp() public override {
        super.setUp();

        // Deploy strategist; admin is this test contract
        // Phase 3 constructor: (platform, llmAgentId, vault, admin)
        strategist = new AllocationStrategist(address(platform), 1, address(vault), address(this));

        // Grant ALLOCATOR_ROLE to the strategist (use constant to avoid consuming vm.prank)
        vm.prank(admin);
        vault.grantRole(ALLOCATOR_ROLE, address(strategist));

        // Seed vault
        usdc.mint(address(this), DEPOSIT);
        usdc.approve(address(vault), DEPOSIT);
        vault.deposit(DEPOSIT, address(this));

        // Raise turnover limit for easy testing
        vm.prank(curator);
        vault.setMaxTurnoverBps(9_000);

        // Lower idle floor to 5% (500 bps)
        vm.prank(curator);
        vault.setMinIdleBufferBps(500);

        // Warp past initial epoch cooldown
        vm.warp(block.timestamp + vault.rebalanceEpochLength() + 1);
    }

    // ════════════════════════════════════════════════════════════════
    //  STRATEGIST HAPPY PATH
    // ════════════════════════════════════════════════════════════════

    /// @notice Strategist can call reallocate via executeRebalance.
    function testStrategist_executeRebalance() public {
        uint256 ta = vault.totalAssets();
        uint256 aAmt = ta * 30 / 100;

        CuratedVault.MarketTarget[] memory tgts = new CuratedVault.MarketTarget[](1);
        tgts[0] = CuratedVault.MarketTarget({market: address(marketA), targetAmount: aAmt});

        CuratedVault.RebalanceGuard memory guard =
            CuratedVault.RebalanceGuard({snapshotTotalAssets: ta, snapshotEpoch: vault.currentEpoch()});

        uint256 epochBefore = vault.currentEpoch();
        // admin == address(this)
        strategist.executeRebalance(tgts, guard);

        assertEq(marketA.balanceOf(address(vault)), aAmt, "balance matches target");
        assertEq(vault.currentEpoch(), epochBefore + 1, "epoch incremented");
    }

    // ════════════════════════════════════════════════════════════════
    //  STRATEGIST ACCESS CONTROL
    // ════════════════════════════════════════════════════════════════

    /// @notice Non-admin cannot call executeRebalance.
    function testStrategist_nonAdminReverts() public {
        CuratedVault.MarketTarget[] memory tgts = new CuratedVault.MarketTarget[](0);
        CuratedVault.RebalanceGuard memory guard = CuratedVault.RebalanceGuard({
            snapshotTotalAssets: vault.totalAssets(), snapshotEpoch: vault.currentEpoch()
        });

        vm.expectRevert(AllocationStrategist.NotAdmin.selector);
        vm.prank(attacker);
        strategist.executeRebalance(tgts, guard);
    }

    // ════════════════════════════════════════════════════════════════
    //  ALLOCATION PROJECTION — helper shims
    // ════════════════════════════════════════════════════════════════

    // We test AllocationProjection as an internal library by creating
    // a thin harness contract in the test.

    /// @notice Zero weights -> all targets are 0 (everything idle).
    function testProjection_zeroWeights() public pure {
        address[] memory mkts = new address[](2);
        mkts[0] = address(0x1);
        mkts[1] = address(0x2);

        uint256[] memory weights = new uint256[](2);
        // weights[0] = weights[1] = 0

        uint256[] memory bals = new uint256[](2);
        uint256[] memory caps = new uint256[](2);
        caps[0] = 50_000e6;
        caps[1] = 50_000e6;

        uint256[] memory targets = AllocationProjection.project(
            mkts,
            weights,
            bals,
            caps,
            100_000e6, // totalAssets
            1_000, // minIdleBps 10%
            5_000, // maxMktBps 50%
            3_000 // maxTurnBps 30%
        );

        assertEq(targets[0], 0, "zero weights -> idle"); // Proves: zero weight = no allocation
        assertEq(targets[1], 0, "zero weights -> idle");
    }

    /// @notice Equal weights -> proportional split within caps.
    function testProjection_equalWeights() public pure {
        address[] memory mkts = new address[](2);
        mkts[0] = address(0x1);
        mkts[1] = address(0x2);

        uint256[] memory weights = new uint256[](2);
        weights[0] = 1;
        weights[1] = 1;

        uint256[] memory bals = new uint256[](2); // both zero
        uint256[] memory caps = new uint256[](2);
        caps[0] = 50_000e6;
        caps[1] = 50_000e6;

        uint256 totalAssets_ = 100_000e6;
        uint256 minIdleBps = 1_000; // 10%
        // Budget = 100_000e6 - ceil(10% * 100_000e6) = 100_000e6 - 10_000e6 = 90_000e6
        // Each market gets 45_000e6

        uint256[] memory targets =
            AllocationProjection.project(mkts, weights, bals, caps, totalAssets_, minIdleBps, 5_000, 9_000);

        // Both markets get 45_000e6 (half of 90_000e6 budget)
        assertEq(targets[0], 45_000e6, "equal weight A"); // Proves: proportional split
        assertEq(targets[1], 45_000e6, "equal weight B"); // Proves: proportional split
    }

    /// @notice Capped water-fill redistributes overflow to other markets.
    function testProjection_cappedWaterFill() public pure {
        address[] memory mkts = new address[](2);
        mkts[0] = address(0x1);
        mkts[1] = address(0x2);

        uint256[] memory weights = new uint256[](2);
        weights[0] = 9; // heavy weight on A
        weights[1] = 1;

        uint256[] memory bals = new uint256[](2);
        uint256[] memory caps = new uint256[](2);
        caps[0] = 20_000e6; // A is capped at 20k
        caps[1] = 50_000e6; // B can absorb more

        uint256 totalAssets_ = 100_000e6;
        // Budget = 90_000e6 (10% idle floor)
        // Proportional: A gets 81_000e6, B gets 9_000e6
        // But A is capped at 20_000e6, overflow = 61_000e6 goes to B
        // maxMktBps = 6000 -> ceiling for B = 60_000e6
        // B gets min(9_000 + 61_000, 50_000) = 50_000
        // Remaining overflow stays idle

        uint256[] memory targets =
            AllocationProjection.project(mkts, weights, bals, caps, totalAssets_, 1_000, 6_000, 9_000);

        assertLe(targets[0], 20_000e6, "A within cap"); // Proves: cap respected
        // B absorbs overflow up to its cap
        assertGt(targets[1], 9_000e6, "B absorbs overflow"); // Proves: water-fill redistribution
    }

    /// @notice Turnover scaling engages when movement exceeds maxTurnBps.
    function testProjection_turnoverScaling() public pure {
        address[] memory mkts = new address[](2);
        mkts[0] = address(0x1);
        mkts[1] = address(0x2);

        uint256[] memory weights = new uint256[](2);
        weights[0] = 1;
        weights[1] = 1;

        // Both markets currently hold 10_000e6
        uint256[] memory bals = new uint256[](2);
        bals[0] = 10_000e6;
        bals[1] = 10_000e6;

        uint256[] memory caps = new uint256[](2);
        caps[0] = 50_000e6;
        caps[1] = 50_000e6;

        uint256 totalAssets_ = 100_000e6;
        // Budget = 90_000e6 -> each target = 45_000e6
        // delta A = 45k - 10k = 35k, delta B = 45k - 10k = 35k
        // totalDelta = 70k, maxTurn = 10% * 100k = 10k
        // Scaling needed: scale factor = 10k / 70k
        // A' = 10k + 35k * 10/70 = 10k + 5k = ~15k

        uint256 maxTurnBps = 1_000; // 10%
        uint256[] memory targets =
            AllocationProjection.project(mkts, weights, bals, caps, totalAssets_, 1_000, 5_000, maxTurnBps);

        // After scaling, total movement must be <= maxTurn
        uint256 totalDelta;
        for (uint256 i; i < 2; i++) {
            uint256 d = targets[i] > bals[i] ? targets[i] - bals[i] : bals[i] - targets[i];
            totalDelta += d;
        }
        uint256 maxTurn = maxTurnBps * totalAssets_ / 10_000;
        assertLe(totalDelta, maxTurn + 2, "turnover scaled down"); // +2 for rounding // Proves: turnover scaling
    }

    /// @notice Empty markets array returns empty targets.
    function testProjection_emptyMarkets() public pure {
        address[] memory mkts = new address[](0);
        uint256[] memory weights = new uint256[](0);
        uint256[] memory bals = new uint256[](0);
        uint256[] memory caps = new uint256[](0);

        uint256[] memory targets =
            AllocationProjection.project(mkts, weights, bals, caps, 100_000e6, 1_000, 5_000, 3_000);

        assertEq(targets.length, 0, "empty result for empty markets");
    }

    /// @notice Zero totalAssets returns all-zero targets.
    function testProjection_zeroTotalAssets() public pure {
        address[] memory mkts = new address[](2);
        mkts[0] = address(0x1);
        mkts[1] = address(0x2);

        uint256[] memory weights = new uint256[](2);
        weights[0] = 1;
        weights[1] = 1;
        uint256[] memory bals = new uint256[](2);
        uint256[] memory caps = new uint256[](2);
        caps[0] = 50_000e6;
        caps[1] = 50_000e6;

        uint256[] memory targets = AllocationProjection.project(
            mkts,
            weights,
            bals,
            caps,
            0, // totalAssets_ == 0
            1_000,
            5_000,
            3_000
        );

        assertEq(targets[0], 0, "zero assets -> zero target");
        assertEq(targets[1], 0, "zero assets -> zero target");
    }
}
