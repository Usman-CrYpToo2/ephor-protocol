// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {TestBase} from "../TestBase.sol";
import {CuratedVault} from "../../src/CuratedVault.sol";
import {MockLendingMarket} from "../../src/Mock/MockLendingMarket.sol";
import {VaultSentinel} from "../../src/VaultSentinel.sol";
import "../../src/Interface/ISomnia.sol";

/// @notice Tests for verdict handling: SAFE/CAUTION/CRITICAL responses, timeouts, and auto-pause.
contract SentinelVerdictTest is TestBase {
    // ══════════════════════════════════════════════════════════════════════════
    //  GROUP 12 — Verdict handling
    // ══════════════════════════════════════════════════════════════════════════

    function testSentinel_safeVerdictNoAction() public {
        usdc.approve(address(vault), 10_000 * 1e6);
        vault.deposit(10_000 * 1e6, address(this));
        // Use 20% allocation per market (2000 bps < CAUTION_ALLOC_BPS=2500) → HardLevel=Safe
        vm.startPrank(allocator);
        vault.allocate(address(marketA), 2_000 * 1e6);
        vault.allocate(address(marketB), 2_000 * 1e6);
        vm.stopPrank();
        marketA.setUtilization(10);
        marketB.setUtilization(10);

        sentinel.checkVault{value: CHECK_VALUE}(address(vault));
        platform.simulateCallback(_latestRequestId(), "SAFE");

        (VaultSentinel.RiskLevel level,, string memory verdict) = sentinel.getLatestRisk(address(vault));
        assertEq(uint256(level), uint256(VaultSentinel.RiskLevel.Safe));
        assertEq(verdict, "SAFE");
        assertFalse(vault.depositsPaused());
    }

    function testSentinel_cautionVerdictNoAutomaticAction() public {
        usdc.approve(address(vault), 10_000 * 1e6);
        vault.deposit(10_000 * 1e6, address(this));
        vm.prank(allocator);
        vault.allocate(address(marketA), 3_000 * 1e6);
        marketA.setUtilization(85);

        sentinel.checkVault{value: CHECK_VALUE}(address(vault));
        platform.simulateCallback(_latestRequestId(), "CAUTION");

        (VaultSentinel.RiskLevel level,,) = sentinel.getLatestRisk(address(vault));
        assertEq(uint256(level), uint256(VaultSentinel.RiskLevel.Caution));
        assertFalse(vault.depositsPaused(), "CAUTION must not auto-pause");
    }

    function testSentinel_criticalVerdictPausesVault() public {
        usdc.approve(address(vault), 10_000 * 1e6);
        vault.deposit(10_000 * 1e6, address(this));
        vm.prank(allocator);
        vault.allocate(address(marketA), 9_000 * 1e6);
        marketA.setUtilization(96);

        sentinel.checkVault{value: CHECK_VALUE}(address(vault));
        platform.simulateCallback(_latestRequestId(), "CRITICAL");

        assertTrue(vault.depositsPaused(), "CRITICAL must pause vault");
        (VaultSentinel.RiskLevel level,,) = sentinel.getLatestRisk(address(vault));
        assertEq(uint256(level), uint256(VaultSentinel.RiskLevel.Critical));
    }

    function testSentinel_criticalVerdictDeallocatesWorstMarket() public {
        usdc.approve(address(vault), 10_000 * 1e6);
        vault.deposit(10_000 * 1e6, address(this));
        vm.startPrank(allocator);
        vault.allocate(address(marketA), 8_000 * 1e6);
        vault.allocate(address(marketB), 1_000 * 1e6);
        vm.stopPrank();
        marketA.setUtilization(96);
        marketB.setUtilization(10);

        uint256 marketABefore = marketA.balanceOf(address(vault));
        uint256 marketBBefore = marketB.balanceOf(address(vault));

        sentinel.checkVault{value: CHECK_VALUE}(address(vault));
        platform.simulateCallback(_latestRequestId(), "CRITICAL");

        assertLt(marketA.balanceOf(address(vault)), marketABefore);
        assertEq(marketB.balanceOf(address(vault)), marketBBefore);
    }

    function testSentinel_noDeallocateWhenUtilBelow90() public {
        usdc.approve(address(vault), 10_000 * 1e6);
        vault.deposit(10_000 * 1e6, address(this));
        vm.prank(allocator);
        vault.allocate(address(marketA), 8_000 * 1e6);
        marketA.setUtilization(88);

        uint256 marketABefore = marketA.balanceOf(address(vault));

        sentinel.checkVault{value: CHECK_VALUE}(address(vault));
        platform.simulateCallback(_latestRequestId(), "CRITICAL");

        assertTrue(vault.depositsPaused());
        assertEq(marketA.balanceOf(address(vault)), marketABefore, "no deallocation when util < 90%");
    }

    function testSentinel_timeoutTriggersFailSafeCAUTION() public {
        usdc.approve(address(vault), 5_000 * 1e6);
        vault.deposit(5_000 * 1e6, address(this));

        sentinel.checkVault{value: CHECK_VALUE}(address(vault));
        platform.simulateTimeout(_latestRequestId());

        (VaultSentinel.RiskLevel level,, string memory verdict) = sentinel.getLatestRisk(address(vault));
        assertEq(uint256(level), uint256(VaultSentinel.RiskLevel.Caution), "timeout must default to CAUTION not SAFE");
        assertEq(verdict, "AI_UNAVAILABLE");
    }

    function testSentinel_unknownVerdictDefaultsToCAUTION() public {
        usdc.approve(address(vault), 5_000 * 1e6);
        vault.deposit(5_000 * 1e6, address(this));

        sentinel.checkVault{value: CHECK_VALUE}(address(vault));
        platform.simulateCallback(_latestRequestId(), "GARBAGE_VERDICT");

        (VaultSentinel.RiskLevel level,,) = sentinel.getLatestRisk(address(vault));
        assertEq(
            uint256(level), uint256(VaultSentinel.RiskLevel.Caution), "unrecognised verdict must default to CAUTION"
        );
    }

    function testSentinel_auditTrailPersists() public {
        usdc.approve(address(vault), 5_000 * 1e6);
        vault.deposit(5_000 * 1e6, address(this));

        sentinel.checkVault{value: CHECK_VALUE}(address(vault));
        platform.simulateCallback(_latestRequestId(), "SAFE");

        vm.warp(block.timestamp + CHECK_COOLDOWN + 1);
        sentinel.checkVault{value: CHECK_VALUE}(address(vault));
        platform.simulateCallback(_latestRequestId(), "CAUTION");

        VaultSentinel.RiskSnapshot[] memory history = sentinel.getHistory(address(vault));
        assertEq(history.length, 2);
        assertEq(uint256(history[0].level), uint256(VaultSentinel.RiskLevel.Safe));
        assertEq(uint256(history[1].level), uint256(VaultSentinel.RiskLevel.Caution));
    }

    function testSentinel_onlyPlatformCanCallback() public {
        Response[] memory responses = new Response[](1);
        responses[0] = Response({
            validator: address(this),
            result: abi.encode("CRITICAL"),
            status: ResponseStatus.Success,
            receipt: 0,
            timestamp: block.timestamp,
            executionCost: 0
        });

        address[] memory sub = new address[](0);
        Response[] memory empty = new Response[](0);
        Request memory req = Request({
            id: 999,
            requester: address(this),
            callbackAddress: address(sentinel),
            callbackSelector: sentinel.handleResponse.selector,
            subcommittee: sub,
            responses: empty,
            responseCount: 1,
            failureCount: 0,
            threshold: 1,
            createdAt: block.timestamp,
            deadline: block.timestamp + 60,
            status: ResponseStatus.Success,
            consensusType: ConsensusType.Majority,
            remainingBudget: 0,
            perAgentBudget: 0
        });

        vm.expectRevert();
        sentinel.handleResponse(999, responses, ResponseStatus.Success, req);
    }

    function testSentinel_autoPauseDisabledDoesNotPause() public {
        CuratedVault vaultNoPause =
            new CuratedVault(address(usdc), "NoPause", "NP", admin, curator, allocator, address(this));
        vm.prank(admin);
        vaultNoPause.grantRole(SENTINEL_ROLE, address(sentinel));

        MockLendingMarket mkt = new MockLendingMarket(address(usdc), address(vaultNoPause), "NoPause Market");
        _addMarket(vaultNoPause, address(mkt), 50_000 * 1e6);

        vm.prank(admin);
        sentinel.registerVault(address(vaultNoPause), false);

        usdc.approve(address(vaultNoPause), 10_000 * 1e6);
        vaultNoPause.deposit(10_000 * 1e6, address(this));
        vm.prank(allocator);
        vaultNoPause.allocate(address(mkt), 9_000 * 1e6);
        mkt.setUtilization(96);

        sentinel.checkVault{value: CHECK_VALUE}(address(vaultNoPause));
        platform.simulateCallback(_latestRequestId(), "CRITICAL");

        (VaultSentinel.RiskLevel level,,) = sentinel.getLatestRisk(address(vaultNoPause));
        assertEq(uint256(level), uint256(VaultSentinel.RiskLevel.Critical));
        assertFalse(vaultNoPause.depositsPaused(), "autoPause=false must not auto-pause");
    }
}
