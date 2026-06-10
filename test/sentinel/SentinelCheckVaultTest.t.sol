// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {TestBase} from "../TestBase.sol";
import {CuratedVault} from "../../src/CuratedVault.sol";
import {MockLendingMarket} from "../../src/Mock/MockLendingMarket.sol";
import {VaultSentinel} from "../../src/VaultSentinel.sol";

/// @notice Tests for checkVault request flow, cooldown, and the 5-market coverage fix.
contract SentinelCheckVaultTest is TestBase {
    // ══════════════════════════════════════════════════════════════════════════
    //  GROUP 11 — checkVault and request flow
    // ══════════════════════════════════════════════════════════════════════════

    function testSentinel_checkVault_setsUpRequest() public {
        usdc.approve(address(vault), 5_000 * 1e6);
        vault.deposit(5_000 * 1e6, address(this));

        sentinel.checkVault{value: CHECK_VALUE}(address(vault));

        uint256 reqId = _latestRequestId();
        assertTrue(sentinel.isCheckPending(address(vault)));
        assertEq(sentinel.activeRequest(address(vault)), reqId);
        assertEq(sentinel.pendingRequests(reqId), address(vault));
    }

    function testSentinel_insufficientDepositReverts() public {
        usdc.approve(address(vault), 5_000 * 1e6);
        vault.deposit(5_000 * 1e6, address(this));

        vm.expectRevert();
        sentinel.checkVault{value: 0.15 ether}(address(vault));
    }

    function testSentinel_exactMinimumDepositAccepted() public {
        usdc.approve(address(vault), 5_000 * 1e6);
        vault.deposit(5_000 * 1e6, address(this));

        uint256 minRequired = platform.getRequestDeposit() + LLM_COST_PER_AGENT * SUBCOMMITTEE_SIZE;
        sentinel.checkVault{value: minRequired}(address(vault));
        assertTrue(sentinel.isCheckPending(address(vault)));
    }

    /**
     * @notice Tests true cooldown enforcement (not "check in progress").
     * The first request is resolved before testing the cooldown window.
     */
    function testSentinel_checkVault_respectsCooldown() public {
        usdc.approve(address(vault), 5_000 * 1e6);
        vault.deposit(5_000 * 1e6, address(this));

        sentinel.checkVault{value: CHECK_VALUE}(address(vault));
        platform.simulateCallback(_latestRequestId(), "SAFE");

        bool reverted;
        try sentinel.checkVault{value: CHECK_VALUE}(address(vault)) {
            reverted = false;
        } catch {
            reverted = true;
        }
        assertTrue(reverted, "cooldown should block immediate re-check");

        vm.warp(block.timestamp + CHECK_COOLDOWN + 1);
        sentinel.checkVault{value: CHECK_VALUE}(address(vault));
        assertTrue(sentinel.isCheckPending(address(vault)));
    }

    /**
     * @notice Duplicate request blocked by "check in progress", not cooldown.
     */
    function testSentinel_noDuplicateActiveRequests() public {
        usdc.approve(address(vault), 5_000 * 1e6);
        vault.deposit(5_000 * 1e6, address(this));

        sentinel.checkVault{value: CHECK_VALUE}(address(vault));
        vm.warp(block.timestamp + CHECK_COOLDOWN + 1);

        bool reverted;
        try sentinel.checkVault{value: CHECK_VALUE}(address(vault)) {
            reverted = false;
        } catch {
            reverted = true;
        }
        assertTrue(reverted, "check in progress should block duplicate");
    }

    function testSentinel_unregisteredVaultReverts() public {
        address fake = address(0xDEAF);
        vm.expectRevert();
        sentinel.checkVault{value: CHECK_VALUE}(fake);
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  GROUP 14 — All markets assessed (no 4-market cap bug)
    // ══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Proves the 4-market hard-cap bug is fixed.
     *
     * Before the fix: _readMetrics only iterated markets 0-3, silently missing
     * the 5th.  After the fix: dynamic arrays cover all markets.
     */
    function testSentinel_allMarketsIncludedBeyondFour() public {
        CuratedVault vault5 =
            new CuratedVault(address(usdc), "5-Market Vault", "V5", admin, curator, allocator, address(this));
        vm.prank(admin);
        vault5.grantRole(SENTINEL_ROLE, address(sentinel));

        MockLendingMarket[5] memory mkts;
        mkts[0] = new MockLendingMarket(address(usdc), address(vault5), "M1");
        mkts[1] = new MockLendingMarket(address(usdc), address(vault5), "M2");
        mkts[2] = new MockLendingMarket(address(usdc), address(vault5), "M3");
        mkts[3] = new MockLendingMarket(address(usdc), address(vault5), "M4");
        mkts[4] = new MockLendingMarket(address(usdc), address(vault5), "M5");

        vm.startPrank(curator);
        for (uint256 i; i < 5; i++) {
            vault5.addMarket(address(mkts[i]), 20_000 * 1e6);
        }
        vm.stopPrank();

        vm.prank(admin);
        sentinel.registerVault(address(vault5), true);

        usdc.mint(address(this), 100_000 * 1e6);
        usdc.approve(address(vault5), 100_000 * 1e6);
        vault5.deposit(100_000 * 1e6, address(this));

        vm.startPrank(allocator);
        for (uint256 i; i < 5; i++) {
            vault5.allocate(address(mkts[i]), 18_000 * 1e6);
        }
        vm.stopPrank();

        for (uint256 i; i < 4; i++) {
            mkts[i].setUtilization(10);
        }
        mkts[4].setUtilization(96); // index 4 — previously invisible

        sentinel.checkVault{value: CHECK_VALUE}(address(vault5));
        platform.simulateCallback(_latestRequestId(), "CRITICAL");

        assertTrue(vault5.depositsPaused(), "vault must be paused when 5th market is at critical utilization");
        (VaultSentinel.RiskLevel level,,) = sentinel.getLatestRisk(address(vault5));
        assertEq(uint256(level), uint256(VaultSentinel.RiskLevel.Critical));
    }
}
