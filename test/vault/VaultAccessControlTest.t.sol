// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {TestBase} from "../TestBase.sol";

/// @notice Tests for role-based access control, config functions, and security edge cases.
contract VaultAccessControlTest is TestBase {
    // ══════════════════════════════════════════════════════════════════════════
    //  GROUP 7 — Role-based access control
    // ══════════════════════════════════════════════════════════════════════════

    function testVault_nonAllocatorCannotAllocate() public {
        usdc.approve(address(vault), 10_000 * 1e6);
        vault.deposit(10_000 * 1e6, address(this));

        vm.expectRevert();
        vault.allocate(address(marketA), 1_000 * 1e6);
    }

    function testVault_allocatorCanAllocate() public {
        usdc.approve(address(vault), 10_000 * 1e6);
        vault.deposit(10_000 * 1e6, address(this));

        vm.prank(admin);
        vault.grantRole(ALLOCATOR_ROLE, address(this));
        vault.allocate(address(marketA), 5_000 * 1e6);
        assertGe(marketA.balanceOf(address(vault)), 4_999 * 1e6);
        vm.prank(admin);
        vault.revokeRole(ALLOCATOR_ROLE, address(this));
    }

    function testVault_nonCuratorCannotAddMarket() public {
        vm.expectRevert();
        vault.submitAddMarket(address(0xCAFE), 1_000 * 1e6);
    }

    function testVault_curatorCanAddMarket() public {
        address fake = address(0xCAFE);
        vm.prank(admin);
        vault.grantRole(CURATOR_ROLE, address(this));

        vault.submitAddMarket(fake, 1_000 * 1e6);
        vm.warp(block.timestamp + vault.timelock());
        vault.executeAddMarket(fake, 1_000 * 1e6);

        (bool enabled,) = vault.markets(fake);
        assertTrue(enabled);

        vm.prank(admin);
        vault.revokeRole(CURATOR_ROLE, address(this));
    }

    function testVault_sentinelCanPauseDeposits() public {
        vm.prank(admin);
        vault.grantRole(SENTINEL_ROLE, address(this));
        vault.pauseDeposits();
        assertTrue(vault.depositsPaused());

        // The sentinel can pause but not unpause; only the admin can.
        vm.expectRevert();
        vault.unpauseDeposits();
        assertTrue(vault.depositsPaused(), "still paused after failed unpause");

        vm.prank(admin);
        vault.unpauseDeposits();
        assertFalse(vault.depositsPaused());

        vm.prank(admin);
        vault.revokeRole(SENTINEL_ROLE, address(this));
    }

    function testVault_sentinelCanEmergencyDeallocate() public {
        usdc.approve(address(vault), 10_000 * 1e6);
        vault.deposit(10_000 * 1e6, address(this));
        vm.prank(allocator);
        vault.allocate(address(marketA), 5_000 * 1e6);

        vm.prank(admin);
        vault.grantRole(SENTINEL_ROLE, address(this));

        uint256 idleBefore = usdc.balanceOf(address(vault));
        vault.emergencyDeallocate(address(marketA), 2_000 * 1e6);
        assertGt(usdc.balanceOf(address(vault)), idleBefore);

        vm.prank(admin);
        vault.revokeRole(SENTINEL_ROLE, address(this));
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  GROUP 8 — Curator config functions
    // ══════════════════════════════════════════════════════════════════════════

    function testVault_setPerformanceFee() public {
        vm.prank(curator);
        vault.setPerformanceFee(500); // 5%
        assertEq(vault.performanceFeeBps(), 500);
    }

    function testVault_setFeeRecipient() public {
        address newRecipient = address(0x7777);
        vm.prank(admin);
        vault.setFeeRecipient(newRecipient);
        assertEq(vault.feeRecipient(), newRecipient);
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  GROUP 15 — Security and access edge cases
    // ══════════════════════════════════════════════════════════════════════════

    function testVault_nonSentinelCannotPause() public {
        vm.prank(attacker);
        vm.expectRevert();
        vault.pauseDeposits();
    }

    function testVault_nonSentinelCannotEmergencyDeallocate() public {
        usdc.approve(address(vault), 5_000 * 1e6);
        vault.deposit(5_000 * 1e6, address(this));
        vm.prank(allocator);
        vault.allocate(address(marketA), 3_000 * 1e6);

        vm.prank(attacker);
        vm.expectRevert();
        vault.emergencyDeallocate(address(marketA), 1_000 * 1e6);
    }

    function testVault_transferFromSenderRequiresApproval() public {
        usdc.approve(address(vault), 1_000 * 1e6);
        vault.deposit(1_000 * 1e6, address(this));

        uint256 shares = vault.balanceOf(address(this));
        vm.prank(user2);
        vm.expectRevert();
        vault.redeem(shares, user2, address(this));
    }

    function testSentinel_transferZeroAdminReverts() public {
        vm.prank(admin);
        vm.expectRevert();
        sentinel.transferOwnership(address(0));
    }
}
