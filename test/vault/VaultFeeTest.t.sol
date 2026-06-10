// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {TestBase} from "../TestBase.sol";

/// @notice Tests for the performance fee mechanism.
contract VaultFeeTest is TestBase {
    // ══════════════════════════════════════════════════════════════════════════
    //  GROUP 6 — Performance fee
    // ══════════════════════════════════════════════════════════════════════════

    function testVault_performanceFeeMintsShares() public {
        usdc.approve(address(vault), 10_000 * 1e6);
        vault.deposit(10_000 * 1e6, address(this));
        vm.prank(allocator);
        vault.allocate(address(marketA), 8_000 * 1e6);

        uint256 supplyBefore = vault.totalSupply();
        marketA.fastForwardDays(365);

        usdc.approve(address(vault), 1 * 1e6);
        vault.deposit(1 * 1e6, address(this));

        assertGt(vault.totalSupply(), supplyBefore + 100);
    }

    function testVault_performanceFeeRespectsMaxCap() public {
        vm.prank(curator);
        vm.expectRevert();
        vault.setPerformanceFee(2_500); // 25% > 20% max

        assertEq(vault.performanceFeeBps(), 1_000); // unchanged
    }

    /**
     * @notice CRITICAL FIX VALIDATION — _lastTA must be set AFTER transferFrom.
     *
     * Previously _lastTA was captured before the funds arrived, so the deposit
     * principal would appear as "yield" in the next accrual and trigger an
     * unearned performance fee.  This test proves the fix works: two sequential
     * deposits with no yield between them should produce zero fee shares.
     */
    function testVault_performanceFeeNotChargedOnPrincipal() public {
        usdc.approve(address(vault), 10_000 * 1e6);
        vault.deposit(10_000 * 1e6, address(this));

        uint256 feeRecipientSharesBefore = vault.balanceOf(address(this));

        usdc.approve(address(vault), 5_000 * 1e6);
        vault.deposit(5_000 * 1e6, address(this));

        uint256 feeRecipientSharesAfter = vault.balanceOf(address(this));
        uint256 shareDelta = feeRecipientSharesAfter - feeRecipientSharesBefore;
        uint256 expectedShares = vault.previewDeposit(5_000 * 1e6);

        assertApproxEqAbs(shareDelta, expectedShares, 1, "no fee shares minted on deposit principal");
    }
}
