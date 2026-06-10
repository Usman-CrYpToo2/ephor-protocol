// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {TestBase} from "../TestBase.sol";
import {CuratedVault} from "../../src/CuratedVault.sol";

/// @notice Tests for vault registration and sentinel admin (owner) functions.
contract SentinelSetupTest is TestBase {
    // ══════════════════════════════════════════════════════════════════════════
    //  GROUP 10 — Vault registration
    // ══════════════════════════════════════════════════════════════════════════

    function testSentinel_registersVault() public view {
        (bool registered, bool autoPause,,,,) = sentinel.vaultInfo(address(vault));
        assertTrue(registered);
        assertTrue(autoPause);
    }

    function testSentinel_nonAdminCannotRegister() public {
        CuratedVault v2 = new CuratedVault(address(usdc), "V2", "V2", admin, curator, allocator, address(this));
        vm.expectRevert();
        sentinel.registerVault(address(v2), false);
    }

    function testSentinel_getVaultList() public view {
        address[] memory vaults = sentinel.getVaultList();
        assertEq(vaults.length, 1);
        assertEq(vaults[0], address(vault));
    }

    function testSentinel_cannotRegisterTwice() public {
        vm.prank(admin);
        vm.expectRevert();
        sentinel.registerVault(address(vault), false);
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  GROUP 13 — Sentinel admin (owner) functions
    // ══════════════════════════════════════════════════════════════════════════

    function testSentinel_setLlmAgentId() public {
        vm.prank(admin);
        sentinel.setLlmAgentId(42);
        assertEq(sentinel.llmAgentId(), 42);
    }

    function testSentinel_nonAdminCannotSetLlmAgentId() public {
        vm.prank(attacker);
        vm.expectRevert();
        sentinel.setLlmAgentId(99);
    }

    function testSentinel_transferAdmin() public {
        address newAdmin = address(0x9999);
        vm.prank(admin);
        sentinel.transferOwnership(newAdmin);
        assertEq(sentinel.owner(), newAdmin);

        vm.prank(admin);
        vm.expectRevert();
        sentinel.setLlmAgentId(1);

        vm.prank(newAdmin);
        sentinel.transferOwnership(admin);
    }
}
