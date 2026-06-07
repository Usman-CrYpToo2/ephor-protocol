// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {TestBase} from "../TestBase.sol";
import {MockUSDC} from "../../src/Mock/MockUSDC.sol";

/// @notice Tests for ERC-4626 core (deposit/redeem/shares/yield) and MockUSDC sanity.
contract VaultCoreTest is TestBase {

    // ══════════════════════════════════════════════════════════════════════════
    //  GROUP 1 — MockUSDC sanity checks
    // ══════════════════════════════════════════════════════════════════════════

    function testUSDC_mint() public {
        uint256 before = usdc.balanceOf(address(this));
        usdc.mint(address(this), 1_000 * 1e6);
        assertEq(usdc.balanceOf(address(this)), before + 1_000 * 1e6);
    }

    function testUSDC_transfer() public {
        usdc.transfer(user1, 100 * 1e6);
        assertEq(usdc.balanceOf(user1), 10_100 * 1e6);
    }

    function testUSDC_approve_and_transferFrom() public {
        usdc.approve(user1, 200 * 1e6);
        assertEq(usdc.allowance(address(this), user1), 200 * 1e6);

        vm.prank(user1);
        usdc.transferFrom(address(this), user1, 50 * 1e6);

        assertEq(usdc.balanceOf(user1), 10_050 * 1e6);
        assertEq(usdc.allowance(address(this), user1), 150 * 1e6);
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  GROUP 2 — ERC-4626 core: deposit, redeem, share price
    // ══════════════════════════════════════════════════════════════════════════

    function testVault_depositMintsShares() public {
        usdc.approve(address(vault), 1_000 * 1e6);
        uint256 shares = vault.deposit(1_000 * 1e6, address(this));
        assertGt(shares, 0);
        assertEq(vault.totalAssets(), 1_000 * 1e6);
    }

    function testVault_sharePriceNearOneAfterDeposit() public {
        usdc.approve(address(vault), 1_000 * 1e6);
        vault.deposit(1_000 * 1e6, address(this));
        assertApproxEqAbs(vault.sharePrice(), 1e18, 1e15);
    }

    function testVault_redeemReturnsUSDC() public {
        usdc.approve(address(vault), 1_000 * 1e6);
        uint256 shares = vault.deposit(1_000 * 1e6, address(this));
        uint256 before = usdc.balanceOf(address(this));
        vault.redeem(shares, address(this), address(this));
        assertGt(usdc.balanceOf(address(this)), before);
    }

    function testVault_previewMatchesActual() public {
        usdc.approve(address(vault), 5_000 * 1e6);
        vault.deposit(5_000 * 1e6, address(this));

        uint256 previewed = vault.previewDeposit(1_000 * 1e6);
        usdc.approve(address(vault), 1_000 * 1e6);
        uint256 actual = vault.deposit(1_000 * 1e6, address(this));

        assertApproxEqAbs(previewed, actual, 1);
    }

    function testVault_depositRevertsWhenPaused() public {
        vm.prank(admin);
        vault.grantRole(SENTINEL_ROLE, address(this));
        vault.pauseDeposits();

        usdc.approve(address(vault), 100 * 1e6);
        vm.expectRevert();
        vault.deposit(100 * 1e6, address(this));

        vm.prank(admin);
        vault.unpauseDeposits();
        vm.prank(admin);
        vault.revokeRole(SENTINEL_ROLE, address(this));
    }

    function testVault_depositZeroReverts() public {
        vm.expectRevert();
        vault.deposit(0, address(this));
    }

    function testVault_redeemZeroReverts() public {
        usdc.approve(address(vault), 1_000 * 1e6);
        vault.deposit(1_000 * 1e6, address(this));
        vm.expectRevert();
        vault.redeem(0, address(this), address(this));
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  GROUP 4 — Yield and interest accrual
    // ══════════════════════════════════════════════════════════════════════════

    function testMarket_interestAccruesAfterFastForward() public {
        usdc.approve(address(vault), 10_000 * 1e6);
        vault.deposit(10_000 * 1e6, address(this));
        vm.prank(allocator);
        vault.allocate(address(marketA), 8_000 * 1e6);

        uint256 before = marketA.balanceOf(address(vault));
        marketA.fastForwardDays(30);
        assertGt(marketA.balanceOf(address(vault)), before);
    }

    function testVault_totalAssetsGrowsWithYield() public {
        usdc.approve(address(vault), 10_000 * 1e6);
        vault.deposit(10_000 * 1e6, address(this));
        vm.prank(allocator);
        vault.allocate(address(marketA), 8_000 * 1e6);

        uint256 before = vault.totalAssets();
        marketA.fastForwardDays(365);
        assertGt(vault.totalAssets(), before);
    }

    function testVault_sharePriceRisesWithYield() public {
        usdc.approve(address(vault), 10_000 * 1e6);
        vault.deposit(10_000 * 1e6, address(this));
        vm.prank(allocator);
        vault.allocate(address(marketA), 8_000 * 1e6);

        uint256 before = vault.sharePrice();
        marketA.fastForwardDays(365);
        assertGt(vault.sharePrice(), before);
    }
}
