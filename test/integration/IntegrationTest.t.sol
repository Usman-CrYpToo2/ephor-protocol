// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {TestBase} from "../TestBase.sol";
import {CuratedVault} from "../../src/CuratedVault.sol";
import {MockLendingMarket} from "../../src/Mock/MockLendingMarket.sol";
import {VaultSentinel} from "../../src/VaultSentinel.sol";

/// @notice End-to-end integration flows spanning vault + sentinel + multiple vaults.
contract IntegrationTest is TestBase {

    // ══════════════════════════════════════════════════════════════════════════
    //  GROUP 16 — Full integration flows
    // ══════════════════════════════════════════════════════════════════════════

    /**
     * @notice End-to-end: SAFE → CRITICAL → admin unpause cycle.
     */
    function testIntegration_safeToCriticalCycle() public {
        usdc.approve(address(vault), 20_000 * 1e6);
        vault.deposit(20_000 * 1e6, address(this));
        vm.startPrank(allocator);
        vault.allocate(address(marketA), 5_000 * 1e6);
        vault.allocate(address(marketB), 5_000 * 1e6);
        vm.stopPrank();
        marketA.setUtilization(20);
        marketB.setUtilization(20);

        sentinel.checkVault{value: CHECK_VALUE}(address(vault));
        platform.simulateCallback(_latestRequestId(), "SAFE");

        (VaultSentinel.RiskLevel l1,,) = sentinel.getLatestRisk(address(vault));
        assertEq(uint256(l1), uint256(VaultSentinel.RiskLevel.Safe));
        assertFalse(vault.depositsPaused());

        marketA.setUtilization(96);
        vm.warp(block.timestamp + CHECK_COOLDOWN + 1);

        sentinel.checkVault{value: CHECK_VALUE}(address(vault));
        platform.simulateCallback(_latestRequestId(), "CRITICAL");

        (VaultSentinel.RiskLevel l2,,) = sentinel.getLatestRisk(address(vault));
        assertEq(uint256(l2), uint256(VaultSentinel.RiskLevel.Critical));
        assertTrue(vault.depositsPaused());

        vm.prank(admin);
        vault.unpauseDeposits();
        assertFalse(vault.depositsPaused());

        VaultSentinel.RiskSnapshot[] memory h = sentinel.getHistory(address(vault));
        assertEq(h.length, 2);
    }

    /**
     * @notice Two independent vaults — one SAFE, one CRITICAL — do not interfere.
     */
    function testIntegration_multipleVaultsIndependent() public {
        CuratedVault vault2 = new CuratedVault(address(usdc), "Vault 2", "V2", admin, curator, allocator, address(this));
        MockLendingMarket marketC = new MockLendingMarket(address(usdc), address(vault2), "Market C");

        vm.prank(admin);
        vault2.grantRole(SENTINEL_ROLE, address(sentinel));

        vm.prank(curator);
        vault2.submitAddMarket(address(marketC), 30_000 * 1e6);
        vm.warp(block.timestamp + 3601);
        vault2.executeAddMarket(address(marketC), 30_000 * 1e6);

        vm.prank(admin);
        sentinel.registerVault(address(vault2), false);

        usdc.approve(address(vault), 5_000 * 1e6);
        vault.deposit(5_000 * 1e6, address(this));
        vm.prank(allocator);
        vault.allocate(address(marketA), 1_000 * 1e6);
        marketA.setUtilization(10);

        usdc.approve(address(vault2), 5_000 * 1e6);
        vault2.deposit(5_000 * 1e6, address(this));
        vm.prank(allocator);
        vault2.allocate(address(marketC), 4_500 * 1e6);
        marketC.setUtilization(96);

        sentinel.checkVault{value: CHECK_VALUE}(address(vault));
        platform.simulateCallback(_latestRequestId(), "SAFE");

        (VaultSentinel.RiskLevel l1,,) = sentinel.getLatestRisk(address(vault));
        assertEq(uint256(l1), uint256(VaultSentinel.RiskLevel.Safe));
        assertFalse(vault.depositsPaused());

        vm.warp(block.timestamp + CHECK_COOLDOWN + 1);
        sentinel.checkVault{value: CHECK_VALUE}(address(vault2));
        platform.simulateCallback(_latestRequestId(), "CRITICAL");

        (VaultSentinel.RiskLevel l2,,) = sentinel.getLatestRisk(address(vault2));
        assertEq(uint256(l2), uint256(VaultSentinel.RiskLevel.Critical));
        assertFalse(vault2.depositsPaused(), "autoPause=false must not auto-pause");

        vm.prank(admin);
        vault2.grantRole(SENTINEL_ROLE, address(this));
        vault2.pauseDeposits();
        assertTrue(vault2.depositsPaused());
        vm.prank(admin);
        vault2.revokeRole(SENTINEL_ROLE, address(this));
    }

    /**
     * @notice Depositors cannot be denied their principal via share rounding.
     * Redeem immediately after deposit returns >= deposited amount - 1 wei.
     */
    function testIntegration_depositRedeemRoundTrip() public {
        uint256 depositAmount = 10_000 * 1e6;
        usdc.approve(address(vault), depositAmount);
        uint256 shares = vault.deposit(depositAmount, address(this));

        uint256 usdcBefore = usdc.balanceOf(address(this));
        vault.redeem(shares, address(this), address(this));
        uint256 returned = usdc.balanceOf(address(this)) - usdcBefore;

        assertGe(returned + 1, depositAmount, "round-trip principal preserved");
    }
}
