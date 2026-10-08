// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {TestBase} from "../TestBase.sol";

/// @notice Tests for allocation, deallocation, and timelocked market management.
contract VaultAllocationTest is TestBase {
    // ══════════════════════════════════════════════════════════════════════════
    //  GROUP 3 — Allocation and deallocation
    // ══════════════════════════════════════════════════════════════════════════

    function testVault_allocateToMarketA() public {
        usdc.approve(address(vault), 10_000 * 1e6);
        vault.deposit(10_000 * 1e6, address(this));

        vm.prank(allocator);
        vault.allocate(address(marketA), 6_000 * 1e6);

        assertApproxEqAbs(marketA.balanceOf(address(vault)), 6_000 * 1e6, 1e6);
    }

    function testVault_allocateToMultipleMarkets() public {
        usdc.approve(address(vault), 10_000 * 1e6);
        vault.deposit(10_000 * 1e6, address(this));

        vm.startPrank(allocator);
        vault.allocate(address(marketA), 6_000 * 1e6);
        vault.allocate(address(marketB), 3_000 * 1e6);
        vm.stopPrank();

        uint256 total = marketA.balanceOf(address(vault)) + marketB.balanceOf(address(vault));
        assertApproxEqAbs(total, 9_000 * 1e6, 2e6);
    }

    function testVault_allocateRevertsOverCap() public {
        usdc.approve(address(vault), 100_000 * 1e6);
        vault.deposit(100_000 * 1e6, address(this));

        vm.prank(allocator);
        vm.expectRevert();
        vault.allocate(address(marketA), 60_000 * 1e6); // cap is 50k
    }

    function testVault_deallocateReturnsToVault() public {
        usdc.approve(address(vault), 10_000 * 1e6);
        vault.deposit(10_000 * 1e6, address(this));

        vm.prank(allocator);
        vault.allocate(address(marketA), 5_000 * 1e6);

        uint256 idleBefore = usdc.balanceOf(address(vault));
        vm.prank(allocator);
        vault.deallocate(address(marketA), 2_000 * 1e6);
        assertGt(usdc.balanceOf(address(vault)), idleBefore);
    }

    function testVault_totalAssetsIncludesMarkets() public {
        usdc.approve(address(vault), 10_000 * 1e6);
        vault.deposit(10_000 * 1e6, address(this));

        vm.startPrank(allocator);
        vault.allocate(address(marketA), 6_000 * 1e6);
        vault.allocate(address(marketB), 3_000 * 1e6);
        vm.stopPrank();

        assertApproxEqAbs(vault.totalAssets(), 10_000 * 1e6, 2e6);
    }

    function testVault_allocateZeroReverts() public {
        usdc.approve(address(vault), 1_000 * 1e6);
        vault.deposit(1_000 * 1e6, address(this));

        vm.prank(allocator);
        vm.expectRevert();
        vault.allocate(address(marketA), 0);
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  GROUP 5 — Timelocked market and cap management
    // ══════════════════════════════════════════════════════════════════════════

    function testVault_timelockBlocksImmediateExecution() public {
        address fake = address(0xBEEF);
        vm.prank(curator);
        vault.submitAddMarket(fake, 1_000 * 1e6);

        vm.expectRevert(bytes("timelock active"));
        vault.executeAddMarket(fake, 1_000 * 1e6);

        vm.warp(block.timestamp + vault.timelock());
        vault.executeAddMarket(fake, 1_000 * 1e6);
        (bool enabled,) = vault.markets(fake);
        assertTrue(enabled);
    }

    function testVault_duplicateQueuedMarketCannotExecuteTwice() public {
        address fake = address(0xBEEF);
        vm.startPrank(curator);
        vault.submitAddMarket(fake, 1_000 * 1e6);
        vault.submitAddMarket(fake, 2_000 * 1e6);
        vm.stopPrank();
        vm.warp(block.timestamp + vault.timelock());

        uint256 countBefore = vault.marketCount();
        vault.executeAddMarket(fake, 1_000 * 1e6);
        vm.expectRevert(bytes("already enabled"));
        vault.executeAddMarket(fake, 2_000 * 1e6);
        assertEq(vault.marketCount(), countBefore + 1, "market listed once");
    }

    function testVault_revokeActionCancelsQueuedMarket() public {
        address fake = address(0xDEAD);
        vm.prank(curator);
        vault.submitAddMarket(fake, 1_000 * 1e6);

        bytes32 id = keccak256(abi.encodePacked("addMarket", fake, uint256(1_000 * 1e6)));
        vm.prank(address(sentinel));
        vault.revokeAction(id);

        (, bool exists) = vault.pendingActions(id);
        assertFalse(exists);
        vm.warp(block.timestamp + vault.timelock());
        vm.expectRevert(bytes("no pending action"));
        vault.executeAddMarket(fake, 1_000 * 1e6);
    }

    function testVault_capIncreaseIsTimelocked() public {
        vm.prank(curator);
        vault.setSupplyCap(address(marketA), 60_000 * 1e6);
        assertEq(vault.marketSupplyCap(address(marketA)), 50_000 * 1e6, "not applied yet");

        vm.expectRevert(bytes("timelock active"));
        vault.executeSetCap(address(marketA), 60_000 * 1e6);

        vm.warp(block.timestamp + vault.timelock());
        vault.executeSetCap(address(marketA), 60_000 * 1e6);
        assertEq(vault.marketSupplyCap(address(marketA)), 60_000 * 1e6);
    }

    function testVault_sentinelCanLowerButNotRaiseCap() public {
        vm.prank(address(sentinel));
        vault.setSupplyCap(address(marketA), 10_000 * 1e6);
        assertEq(vault.marketSupplyCap(address(marketA)), 10_000 * 1e6);

        vm.prank(address(sentinel));
        vm.expectRevert(bytes("curator only"));
        vault.setSupplyCap(address(marketA), 20_000 * 1e6);
    }

    function testVault_setTimelockBounds() public {
        vm.startPrank(curator);
        vault.setTimelock(2 hours);
        assertEq(vault.timelock(), 2 hours);
        vm.expectRevert(bytes("bad delay"));
        vault.setTimelock(30 seconds);
        vm.expectRevert(bytes("bad delay"));
        vault.setTimelock(4 weeks);
        vm.stopPrank();
    }

    function testVault_allocateBlockedWhilePaused() public {
        usdc.approve(address(vault), 10_000 * 1e6);
        vault.deposit(10_000 * 1e6, address(this));

        vm.prank(address(sentinel));
        vault.pauseDeposits();

        vm.prank(allocator);
        vm.expectRevert(bytes("paused: no new allocation"));
        vault.allocate(address(marketA), 1_000 * 1e6);
    }
}
