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
    //  GROUP 5 — Timelocked market management
    // ══════════════════════════════════════════════════════════════════════════

    function testVault_timelockBlocksImmediateExecution() public {
        address fake = address(0xBEEF);
        vm.prank(curator);
        vault.submitAddMarket(fake, 1_000 * 1e6);

        vm.expectRevert();
        vault.executeAddMarket(fake, 1_000 * 1e6);
    }

    function testVault_revokeAction() public {
        address fake = address(0xDEAD);
        vm.prank(curator);
        vault.submitAddMarket(fake, 1_000 * 1e6);

        bytes32 id = keccak256(abi.encodePacked("addMarket", fake, uint256(1_000 * 1e6)));
        vm.prank(admin);
        vault.grantRole(SENTINEL_ROLE, address(this));
        vault.revokeAction(id);
        vm.prank(admin);
        vault.revokeRole(SENTINEL_ROLE, address(this));

        (, bool exists) = vault.pendingActions(id);
        assertFalse(exists);
    }
}
