// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {TestBase} from "../TestBase.sol";
import {CuratedVault} from "../../src/CuratedVault.sol";
import {VaultSentinel} from "../../src/VaultSentinel.sol";
import {MockERC20} from "../../src/Mock/MockERC20.sol";
import {MockUSDC} from "../../src/Mock/MockUSDC.sol";

/// @notice Regression tests for defects D-3, D-4, D-7, D-9.
contract VaultDefectsTest is TestBase {

    // ══════════════════════════════════════════════════════════════════════════
    //  GROUP 17 — D-3 Regression: BPS Precision (AC-4)
    // ══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Regression for D-3: marketAllocationBps distinguishes 40.5% (4050 bps)
     *         from 40.0% (4000 bps).
     *
     *         The old *100 formula would truncate both to 40, making them
     *         indistinguishable. The new *10000 formula preserves the difference.
     *         Proves AC-4: all ratio metrics are bps; no integer-percent path.
     */
    function testD3_marketAllocationBps_distinguishes4050From4000() public {
        usdc.approve(address(vault), 10_000 * 1e6);
        vault.deposit(10_000 * 1e6, address(this));

        vm.prank(allocator);
        vault.allocate(address(marketA), 4_050 * 1e6);

        uint256 bps = vault.marketAllocationBps(address(marketA));

        assertEq(bps, 4_050, "D-3 regression: 40.5% must be 4050 bps");
        assertTrue(bps != 4_000, "D-3 regression: 40.5% must be distinguishable from 40.0%");
    }

    /**
     * @notice Regression for D-3: idleBufferBps distinguishes 40.5% (4050 bps)
     *         from 40.0% (4000 bps) for the idle buffer.
     */
    function testD3_idleBufferBps_distinguishes4050From4000() public {
        usdc.approve(address(vault), 10_000 * 1e6);
        vault.deposit(10_000 * 1e6, address(this));

        vm.prank(allocator);
        vault.allocate(address(marketA), 5_950 * 1e6);

        uint256 idleBps = vault.idleBufferBps();

        assertEq(idleBps, 4_050, "D-3 regression: idle 40.5% must be 4050 bps");
        assertTrue(idleBps != 4_000, "D-3 regression: idle 40.5% must be distinguishable from 40.0%");
    }

    /**
     * @notice Explicitly documents the old bug and the fix.
     *
     *         Old code: balanceOf * 100 / totalAssets → truncates 4050 to 40
     *         New code: balanceOf * 10_000 / totalAssets → returns 4050
     */
    function testD3_oldPctWouldHaveLostPrecision() public {
        usdc.approve(address(vault), 10_000 * 1e6);
        vault.deposit(10_000 * 1e6, address(this));
        vm.prank(allocator);
        vault.allocate(address(marketA), 4_050 * 1e6);

        uint256 marketBal = 4_050 * uint256(1e6);
        uint256 totalBal = 10_000 * uint256(1e6);
        uint256 oldStylePct = marketBal * 100 / totalBal;
        assertEq(oldStylePct, 40, "Documents the old precision loss: 40.5% truncated to 40");

        uint256 newBps = vault.marketAllocationBps(address(marketA));
        assertEq(newBps, 4_050, "New bps formula returns lossless 4050");
        assertTrue(newBps != oldStylePct * 100, "4050 bps != 4000 (which is what 40*100 gives)");
    }

    /**
     * @notice Fuzz test: marketAllocationBps is consistent with the underlying balance.
     *         For any deposit and allocation, bps == balance * 10_000 / totalAssets.
     *         Proves P-4 (lossless canonical inputs) and AC-4.
     */
    function testFuzz_marketAllocationBps_isConsistentWithBalance(uint256 depositAmount, uint256 allocAmount) public {
        depositAmount = bound(depositAmount, 1_000 * 1e6, 100_000 * 1e6);
        uint256 maxAlloc = depositAmount * 9_000 / 10_000;
        if (maxAlloc > 49_999 * 1e6) maxAlloc = 49_999 * 1e6;
        allocAmount = bound(allocAmount, 0, maxAlloc);

        usdc.mint(address(this), depositAmount);
        usdc.approve(address(vault), depositAmount);
        vault.deposit(depositAmount, address(this));

        if (allocAmount > 0) {
            vm.prank(allocator);
            vault.allocate(address(marketA), allocAmount);
        }

        uint256 actualBal = marketA.balanceOf(address(vault));
        uint256 totalA = vault.totalAssets();
        uint256 expectedBps = totalA == 0 ? 0 : actualBal * 10_000 / totalA;
        uint256 reportedBps = vault.marketAllocationBps(address(marketA));

        assertApproxEqAbs(reportedBps, expectedBps, 1, "bps must match balance * 10_000 / totalAssets");
    }

    /**
     * @notice End-to-end: the sentinel history snapshot stores idleBps (not the old idlePct).
     *         Proves the struct rename is correct and the field stores bps values end-to-end.
     */
    function testD3_sentinelHistoryStoresIdleBps() public {
        usdc.approve(address(vault), 10_000 * 1e6);
        vault.deposit(10_000 * 1e6, address(this));
        vm.prank(allocator);
        vault.allocate(address(marketA), 6_000 * 1e6);

        uint256 expectedIdleBps = vault.idleBufferBps();
        assertEq(expectedIdleBps, 4_000, "precondition: idle should be 4000 bps");

        sentinel.checkVault{value: CHECK_VALUE}(address(vault));
        platform.simulateCallback(_latestRequestId(), "SAFE");

        VaultSentinel.RiskSnapshot[] memory history = sentinel.getHistory(address(vault));
        assertEq(history.length, 1, "should have exactly one snapshot");
        assertEq(history[0].idleBps, expectedIdleBps, "snapshot idleBps must match vault.idleBufferBps()");
        assertGe(history[0].idleBps, 100, "idleBps must be bps-scale, not integer-percent-scale");
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  GROUP 18 — D-4 Regression: maxDeposit respects supply caps (AC-4)
    // ══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Proves D-4 fix: maxDeposit returns 0 when totalAssets() >= totalCap.
     */
    function testD4_maxDeposit_returnsZeroWhenAtCap() public {
        usdc.approve(address(vault), 100_000 * 1e6);
        vault.deposit(100_000 * 1e6, address(this));

        uint256 available = vault.maxDeposit(address(this));
        assertEq(available, 0, "D-4 regression: maxDeposit must be 0 when at cap");
    }

    /**
     * @notice Proves D-4 fix: maxDeposit returns totalCap - totalAssets when below capacity.
     */
    function testD4_maxDeposit_accountsForExistingAssets() public {
        uint256 partialDeposit = 30_000 * 1e6;
        usdc.approve(address(vault), partialDeposit);
        vault.deposit(partialDeposit, address(this));

        uint256 available = vault.maxDeposit(address(this));
        uint256 totalCap = 100_000 * 1e6;
        uint256 expectedHeadroom = totalCap - vault.totalAssets();

        assertApproxEqAbs(available, expectedHeadroom, 1, "D-4 regression: maxDeposit must equal remaining headroom");
        assertGt(available, 0, "D-4 regression: maxDeposit must be positive when below cap");
    }

    /**
     * @notice Proves D-4 fix: deposit reverts when requested amount exceeds maxDeposit.
     */
    function testD4_deposit_revertsWhenAboveCap() public {
        usdc.approve(address(vault), 100_000 * 1e6);
        vault.deposit(100_000 * 1e6, address(this));

        usdc.mint(address(this), 1 * 1e6);
        usdc.approve(address(vault), 1 * 1e6);
        vm.expectRevert(abi.encodeWithSelector(CuratedVault.DepositExceedsCap.selector, 1 * 1e6, 0));
        vault.deposit(1 * 1e6, address(this));
    }

    /**
     * @notice Fuzz: any deposit of amount <= maxDeposit() always succeeds.
     */
    function testFuzz_maxDeposit_neverExceedsCap(uint256 rawAmount) public {
        usdc.approve(address(vault), 10_000 * 1e6);
        vault.deposit(10_000 * 1e6, address(this));

        uint256 available = vault.maxDeposit(address(this));
        uint256 amount = bound(rawAmount, 1, available > 0 ? available : 1);

        if (available == 0) return;

        usdc.mint(address(this), amount);
        usdc.approve(address(vault), amount);

        uint256 shares = vault.deposit(amount, address(this));
        assertGt(shares, 0, "fuzz: deposit within maxDeposit must mint shares");
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  GROUP 19 — D-7 Regression: minIdleBufferBps idle floor (AC-7 / I-3)
    // ══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Proves D-7 fix: allocating too much reverts when it would breach the idle floor.
     */
    function testD7_allocate_revertsWhenBreachesIdleFloor() public {
        vm.prank(curator);
        vault.setMinIdleBufferBps(2_000);

        usdc.approve(address(vault), 10_000 * 1e6);
        vault.deposit(10_000 * 1e6, address(this));

        vm.prank(allocator);
        vm.expectRevert(
            abi.encodeWithSelector(
                CuratedVault.IdleFloorBreached.selector,
                1_000,
                2_000
            )
        );
        vault.allocate(address(marketA), 9_000 * 1e6);

        assertEq(vault.idleBufferBps(), 10_000, "D-7: vault must be fully idle after revert");
    }

    /**
     * @notice Proves D-7 fix: allocating exactly to the floor succeeds (boundary condition).
     */
    function testD7_allocate_succeedsAtExactFloor() public {
        vm.prank(curator);
        vault.setMinIdleBufferBps(2_000);

        usdc.approve(address(vault), 10_000 * 1e6);
        vault.deposit(10_000 * 1e6, address(this));

        vm.prank(allocator);
        vault.allocate(address(marketA), 8_000 * 1e6);

        uint256 idleBps = vault.idleBufferBps();
        assertGe(idleBps, 2_000, "D-7: idle must be >= floor after allocation at boundary");
    }

    /**
     * @notice Proves D-7 fix: setMinIdleBufferBps is restricted to CURATOR_ROLE.
     */
    function testD7_setMinIdleBufferBps_curatorOnly() public {
        vm.prank(attacker);
        vm.expectRevert();
        vault.setMinIdleBufferBps(500);

        vm.prank(allocator);
        vm.expectRevert();
        vault.setMinIdleBufferBps(500);

        vm.prank(curator);
        vault.setMinIdleBufferBps(500);
        assertEq(vault.minIdleBufferBps(), 500, "D-7: curator must be able to set floor");
    }

    /**
     * @notice Proves D-7 fix: setting minIdleBufferBps > 5000 reverts.
     */
    function testD7_setMinIdleBufferBps_maxFiftyPercent() public {
        vm.prank(curator);
        vault.setMinIdleBufferBps(5_000);
        assertEq(vault.minIdleBufferBps(), 5_000, "D-7: 5000 bps must be accepted");

        vm.prank(curator);
        vm.expectRevert();
        vault.setMinIdleBufferBps(5_001);

        assertEq(vault.minIdleBufferBps(), 5_000, "D-7: floor must be unchanged after failed set");
    }

    /**
     * @notice Proves D-7 fix: at 0 bps the floor is disabled — full allocation succeeds.
     */
    function testD7_idleFloor_disabledAtZero() public {
        vm.prank(curator);
        vault.setMinIdleBufferBps(0);
        assertEq(vault.minIdleBufferBps(), 0, "floor must be 0 after set");

        usdc.approve(address(vault), 10_000 * 1e6);
        vault.deposit(10_000 * 1e6, address(this));

        vm.startPrank(allocator);
        vault.allocate(address(marketA), 9_000 * 1e6);
        vault.allocate(address(marketB), 1_000 * 1e6);
        vm.stopPrank();

        assertEq(vault.idleBufferBps(), 0, "D-7: at 0 bps floor, 0% idle must be allowed");
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  GROUP 20 — D-9 Regression: Asset-agnostic MockERC20 (AC-22)
    // ══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Proves D-9 fix: MockERC20 accepts configurable name/symbol/decimals.
     */
    function testD9_mockERC20_configurable() public {
        MockERC20 token = new MockERC20("Test Token", "TT", 18);

        assertEq(token.name(), "Test Token", "D-9: name must match constructor arg");
        assertEq(token.symbol(), "TT", "D-9: symbol must match constructor arg");
        assertEq(token.decimals(), 18, "D-9: decimals must match constructor arg");

        token.mint(address(this), 1000 * 1e18);
        assertEq(token.balanceOf(address(this)), 1000 * 1e18, "D-9: mint must credit correct balance");
    }

    /**
     * @notice Proves D-9 fix: MockUSDC is a backward-compatible wrapper over MockERC20.
     */
    function testD9_mockUSDC_isBackwardCompatible() public {
        MockUSDC usdc2 = new MockUSDC();

        assertEq(usdc2.decimals(), 6, "D-9: MockUSDC must still have 6 decimals");
        assertEq(usdc2.symbol(), "USDC", "D-9: MockUSDC must still have USDC symbol");
        assertEq(usdc2.name(), "Mock USDC", "D-9: MockUSDC must still have Mock USDC name");

        usdc2.mint(address(this), 500 * 1e6);
        assertEq(usdc2.balanceOf(address(this)), 500 * 1e6, "D-9: MockUSDC mint must still work");
    }
}
