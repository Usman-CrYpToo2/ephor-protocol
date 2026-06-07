// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {TestBase} from "../TestBase.sol";

/// @notice Tests for sentinel query helpers: marketAllocationBps, idleBufferBps, utilizationBps.
contract VaultMetricsTest is TestBase {

    // ══════════════════════════════════════════════════════════════════════════
    //  GROUP 9 — Vault query helpers (consumed by sentinel)
    // ══════════════════════════════════════════════════════════════════════════

    // Proves AC-4: all ratio metrics are bps (10_000 = 100%). Fixes D-3.
    function testVault_marketAllocationBps() public {
        usdc.approve(address(vault), 10_000 * 1e6);
        vault.deposit(10_000 * 1e6, address(this));
        vm.prank(allocator);
        vault.allocate(address(marketA), 6_000 * 1e6);

        uint256 bps = vault.marketAllocationBps(address(marketA));
        assertApproxEqAbs(bps, 6_000, 1); // Proves AC-4
    }

    // Proves AC-4: idle buffer uses bps precision. Fixes D-3.
    function testVault_idleBufferBps() public {
        usdc.approve(address(vault), 10_000 * 1e6);
        vault.deposit(10_000 * 1e6, address(this));
        vm.prank(allocator);
        vault.allocate(address(marketA), 9_000 * 1e6);

        uint256 idle = vault.idleBufferBps();
        assertApproxEqAbs(idle, 1_000, 1); // Proves AC-4
    }

    function testVault_marketAllocationBpsZeroWhenEmpty() public view {
        assertEq(vault.marketAllocationBps(address(marketA)), 0);
    }

    function testVault_idleBufferBpsZeroWhenEmpty() public view {
        assertEq(vault.idleBufferBps(), 0);
    }

    function testMarket_utilizationReflectsSetValue() public {
        usdc.approve(address(vault), 10_000 * 1e6);
        vault.deposit(10_000 * 1e6, address(this));
        vm.prank(allocator);
        vault.allocate(address(marketA), 8_000 * 1e6);

        marketA.setUtilization(97);
        assertApproxEqAbs(marketA.utilizationBps(), 9700, 100);
    }

    function testMarket_zeroUtilizationWhenNoSupply() public view {
        assertEq(marketA.utilizationBps(), 0);
    }
}
