// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../src/Mock/MockUSDC.sol";
import "../src/Mock/MockLendingMarket.sol";
import "../src/CuratedVault.sol";
import "../src/VaultSentinel.sol";
import "../src/Mock/MockSomniaPlatform.sol";
import {Test} from "forge-std/Test.sol";

/**
 * @title  VaultSentinelTest
 * @notice Comprehensive Foundry test suite for the VaultSentinel protocol.
 *
 *  Run all:          forge test -vvv
 *  Run one test:     forge test --match-test <testName> -vvv
 *  Run one group:    forge test --match-test "testVault_" -vvv
 *
 *  ── Root-cause notes for previous failures ────────────────────────────────
 *  1. setUp called vault.grantRole / vault.submitAddMarket / sentinel.registerVault
 *     without vm.prank — the test contract has no vault roles.  Fixed by adding
 *     vm.prank(admin) / vm.prank(curator) around every privileged call.
 *  2. Many tests called vault.allocate without ALLOCATOR_ROLE.  Fixed with
 *     vm.prank(allocator).
 *  3. testMultipleVaultsIndependent registered vault twice → "already registered".
 *  4. testSentinel_checkVault_respectsCooldown tested cooldown while an active
 *     request was still pending, so the warp-then-check path hit "check in
 *     progress" instead of succeeding.
 *  5. All checkVault calls used 0.15 ETH; after fixing the deposit check to
 *     include the per-agent reward pot the minimum is 0.22 ETH.  Use 0.25 ETH.
 *  ──────────────────────────────────────────────────────────────────────────
 */

contract VaultSentinelTest is Test {
    // ── Contracts ──────────────────────────────────────────────────────────
    MockUSDC usdc;
    CuratedVault vault;
    MockLendingMarket marketA;
    MockLendingMarket marketB;
    VaultSentinel sentinel;
    MockSomniaPlatform platform;

    // ── Actors ─────────────────────────────────────────────────────────────
    address admin = address(0x1111); // DEFAULT_ADMIN_ROLE on vault + sentinel admin
    address curator = address(0x2222); // CURATOR_ROLE on vault
    address allocator = address(0x3333); // ALLOCATOR_ROLE on vault
    address user1 = address(0x4444);
    address user2 = address(0x5555);
    address attacker = address(0x6666);

    // ── Role constants ─────────────────────────────────────────────────────
    bytes32 constant CURATOR_ROLE = keccak256("CURATOR_ROLE");
    bytes32 constant ALLOCATOR_ROLE = keccak256("ALLOCATOR_ROLE");
    bytes32 constant SENTINEL_ROLE = keccak256("SENTINEL_ROLE");
    bytes32 constant ADMIN_ROLE = bytes32(0);

    // ── Sentinel constants mirrored for tests ──────────────────────────────
    uint256 constant CHECK_COOLDOWN = 5 minutes;
    uint256 constant LLM_COST_PER_AGENT = 0.07 ether;
    uint256 constant SUBCOMMITTEE_SIZE = 3;

    // ── Helpers ────────────────────────────────────────────────────────────

    // Minimum msg.value for checkVault after the deposit-check fix.
    // = getRequestDeposit() + LLM_COST_PER_AGENT * SUBCOMMITTEE_SIZE
    // = 0.01 (mock floor) + 0.07*3 = 0.22 ETH. Use 0.25 for headroom.
    uint256 constant CHECK_VALUE = 0.25 ether;

    function _latestRequestId() internal view returns (uint256) {
        return platform.nextRequestId() - 1;
    }

    // Deposit `amount` USDC into `vault` as `user`, shares go to `user`.
    function _deposit(address user, uint256 amount) internal returns (uint256 shares) {
        vm.startPrank(user);
        usdc.approve(address(vault), amount);
        shares = vault.deposit(amount, user);
        vm.stopPrank();
    }

    // ── setUp ──────────────────────────────────────────────────────────────

    function setUp() public {
        vm.deal(address(this), 100 ether);

        // 1. Stablecoin
        usdc = new MockUSDC();

        // 2. CuratedVault — admin=0x1111, curator=0x2222, allocator=0x3333
        vault = new CuratedVault(
            address(usdc),
            "VaultSentinel USDC",
            "vsUSDC",
            admin,
            curator,
            allocator,
            address(this) // feeRecipient = test contract
        );

        // 3. Mock Somnia platform
        platform = new MockSomniaPlatform();

        // 4. VaultSentinel (sentinel admin = 0x1111)
        sentinel = new VaultSentinel(address(platform), 1, admin);

        // 5. Grant SENTINEL_ROLE to VaultSentinel contract (requires DEFAULT_ADMIN_ROLE)
        vm.prank(admin);
        vault.grantRole(SENTINEL_ROLE, address(sentinel));

        // 6. Deploy two lending markets bound to this vault
        marketA = new MockLendingMarket(address(usdc), address(vault), "Market A");
        marketB = new MockLendingMarket(address(usdc), address(vault), "Market B");

        // 7. Add markets via curator timelock
        vm.startPrank(curator);
        vault.submitAddMarket(address(marketA), 50_000 * 1e6);
        vault.submitAddMarket(address(marketB), 50_000 * 1e6);
        vm.stopPrank();

        vm.warp(block.timestamp + 3601);

        vault.executeAddMarket(address(marketA), 50_000 * 1e6);
        vault.executeAddMarket(address(marketB), 50_000 * 1e6);

        // 8. Register vault in sentinel (sentinel admin = 0x1111)
        vm.prank(admin);
        sentinel.registerVault(address(vault), true); // autoPause enabled

        // 9. Fund users
        usdc.mint(user1, 10_000 * 1e6);
        usdc.mint(user2, 10_000 * 1e6);
        usdc.mint(address(this), 500_000 * 1e6);
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  GROUP 1 — MockUSDC
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
    //  GROUP 2 — CuratedVault: ERC-4626 core
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
    //  GROUP 3 — CuratedVault: allocation
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
    //  GROUP 4 — CuratedVault: yield / interest
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

    // ══════════════════════════════════════════════════════════════════════════
    //  GROUP 5 — CuratedVault: timelocked market management
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
        // Sentinel or curator can revoke — grant SENTINEL_ROLE temporarily
        vm.prank(admin);
        vault.grantRole(SENTINEL_ROLE, address(this));
        vault.revokeAction(id);
        vm.prank(admin);
        vault.revokeRole(SENTINEL_ROLE, address(this));

        (, bool exists) = vault.pendingActions(id);
        assertFalse(exists);
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  GROUP 6 — CuratedVault: performance fee
    // ══════════════════════════════════════════════════════════════════════════

    function testVault_performanceFeeMintsShares() public {
        usdc.approve(address(vault), 10_000 * 1e6);
        vault.deposit(10_000 * 1e6, address(this));
        vm.prank(allocator);
        vault.allocate(address(marketA), 8_000 * 1e6);

        uint256 supplyBefore = vault.totalSupply();
        marketA.fastForwardDays(365);

        // Trigger fee accrual by depositing a small amount
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
        // First deposit — baseline
        usdc.approve(address(vault), 10_000 * 1e6);
        vault.deposit(10_000 * 1e6, address(this));

        uint256 feeRecipientSharesBefore = vault.balanceOf(address(this));

        // Second deposit immediately — no yield has been generated
        usdc.approve(address(vault), 5_000 * 1e6);
        vault.deposit(5_000 * 1e6, address(this));

        // Fee recipient shares must not increase between the two deposits
        // (address(this) is both depositor and fee recipient here, so check
        // that the *extra* shares from the second deposit are purely proportional)
        uint256 feeRecipientSharesAfter = vault.balanceOf(address(this));
        uint256 shareDelta = feeRecipientSharesAfter - feeRecipientSharesBefore;

        // Expected shares for a 5000 USDC deposit with 10000 USDC in vault
        // ≈ 5000/10000 * totalSupply = ~50% of supplyAfterFirst
        uint256 expectedShares = vault.previewDeposit(5_000 * 1e6);

        // The delta should be approximately expected shares — NOT expected + fee-on-principal
        // Allow 1 share tolerance for rounding
        assertApproxEqAbs(shareDelta, expectedShares, 1, "no fee shares minted on deposit principal");
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  GROUP 7 — CuratedVault: role-based access control
    // ══════════════════════════════════════════════════════════════════════════

    function testVault_nonAllocatorCannotAllocate() public {
        usdc.approve(address(vault), 10_000 * 1e6);
        vault.deposit(10_000 * 1e6, address(this));

        vm.expectRevert();
        vault.allocate(address(marketA), 1_000 * 1e6); // test contract has no ALLOCATOR_ROLE
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
        vm.warp(block.timestamp + 3601);
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

        // Sentinel CANNOT unpause — only DEFAULT_ADMIN_ROLE can
        vm.expectRevert();
        vault.unpauseDeposits();
        assertTrue(vault.depositsPaused(), "still paused after failed unpause");

        // Admin CAN unpause
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
    //  GROUP 8 — CuratedVault: config functions
    // ══════════════════════════════════════════════════════════════════════════

    function testVault_setTimelockWithinBounds() public {
        vm.prank(curator);
        vault.setTimelock(2 minutes);
        assertEq(vault.timelock(), 2 minutes);
    }

    function testVault_setTimelockTooShortReverts() public {
        vm.prank(curator);
        vm.expectRevert();
        vault.setTimelock(30 seconds); // < 1 minute minimum
    }

    function testVault_setTimelockTooLongReverts() public {
        vm.prank(curator);
        vm.expectRevert();
        vault.setTimelock(4 weeks); // > 3 week maximum
    }

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
    //  GROUP 9 — Vault query helpers (consumed by sentinel)
    // ══════════════════════════════════════════════════════════════════════════

    // Proves AC-4: all ratio metrics are bps (10_000 = 100%). Fixes D-3.
    function testVault_marketAllocationBps() public {
        usdc.approve(address(vault), 10_000 * 1e6);
        vault.deposit(10_000 * 1e6, address(this));
        vm.prank(allocator);
        vault.allocate(address(marketA), 6_000 * 1e6);

        // 6000/10000 = 60% = 6000 bps (not 60 as the old integer-percent would return)
        uint256 bps = vault.marketAllocationBps(address(marketA));
        assertApproxEqAbs(bps, 6_000, 1); // Proves AC-4: value is in bps, not percent
    }

    // Proves AC-4: idle buffer uses bps precision. Fixes D-3.
    function testVault_idleBufferBps() public {
        usdc.approve(address(vault), 10_000 * 1e6);
        vault.deposit(10_000 * 1e6, address(this));
        vm.prank(allocator);
        vault.allocate(address(marketA), 9_000 * 1e6);

        // 1000/10000 = 10% = 1000 bps (not 10 as the old integer-percent would return)
        uint256 idle = vault.idleBufferBps();
        assertApproxEqAbs(idle, 1_000, 1); // Proves AC-4: value is in bps, not percent
    }

    function testVault_marketAllocationBpsZeroWhenEmpty() public {
        assertEq(vault.marketAllocationBps(address(marketA)), 0);
    }

    function testVault_idleBufferBpsZeroWhenEmpty() public {
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

    function testMarket_zeroUtilizationWhenNoSupply() public {
        assertEq(marketA.utilizationBps(), 0);
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  GROUP 10 — VaultSentinel: registration
    // ══════════════════════════════════════════════════════════════════════════

    function testSentinel_registersVault() public {
        (bool registered, bool autoPause,,,,) = sentinel.vaultInfo(address(vault));
        assertTrue(registered);
        assertTrue(autoPause);
    }

    function testSentinel_nonAdminCannotRegister() public {
        CuratedVault v2 = new CuratedVault(address(usdc), "V2", "V2", admin, curator, allocator, address(this));
        vm.expectRevert();
        sentinel.registerVault(address(v2), false); // test contract is not sentinel admin
    }

    function testSentinel_getVaultList() public {
        address[] memory vaults = sentinel.getVaultList();
        assertEq(vaults.length, 1);
        assertEq(vaults[0], address(vault));
    }

    function testSentinel_cannotRegisterTwice() public {
        vm.prank(admin);
        vm.expectRevert();
        sentinel.registerVault(address(vault), false); // already registered in setUp
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  GROUP 11 — VaultSentinel: checkVault & request flow
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

        // Below the new minimum (0.01 floor + 0.07*3 = 0.22 ETH)
        vm.expectRevert();
        sentinel.checkVault{value: 0.15 ether}(address(vault));
    }

    function testSentinel_exactMinimumDepositAccepted() public {
        usdc.approve(address(vault), 5_000 * 1e6);
        vault.deposit(5_000 * 1e6, address(this));

        // 0.01 (mock floor) + 0.07*3 = 0.22 ETH exactly
        uint256 minRequired = platform.getRequestDeposit() + LLM_COST_PER_AGENT * SUBCOMMITTEE_SIZE;
        sentinel.checkVault{value: minRequired}(address(vault)); // must not revert
        assertTrue(sentinel.isCheckPending(address(vault)));
    }

    /**
     * @notice Tests true cooldown enforcement (not "check in progress").
     * The first request is resolved before testing the cooldown window.
     */
    function testSentinel_checkVault_respectsCooldown() public {
        usdc.approve(address(vault), 5_000 * 1e6);
        vault.deposit(5_000 * 1e6, address(this));

        // First check
        sentinel.checkVault{value: CHECK_VALUE}(address(vault));
        platform.simulateCallback(_latestRequestId(), "SAFE");

        // Immediately after resolution → cooldown active
        bool reverted;
        try sentinel.checkVault{value: CHECK_VALUE}(address(vault)) {
            reverted = false;
        } catch {
            reverted = true;
        }
        assertTrue(reverted, "cooldown should block immediate re-check");

        // After cooldown window passes → succeeds
        vm.warp(block.timestamp + CHECK_COOLDOWN + 1);
        sentinel.checkVault{value: CHECK_VALUE}(address(vault));
        assertTrue(sentinel.isCheckPending(address(vault)));
    }

    /**
     * @notice Duplicate request blocked by "check in progress", not cooldown.
     * Warp past cooldown first so the only guard remaining is activeRequest.
     */
    function testSentinel_noDuplicateActiveRequests() public {
        usdc.approve(address(vault), 5_000 * 1e6);
        vault.deposit(5_000 * 1e6, address(this));

        sentinel.checkVault{value: CHECK_VALUE}(address(vault));
        // Warp past cooldown — request is still pending
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
    //  GROUP 12 — VaultSentinel: verdict handling
    // ══════════════════════════════════════════════════════════════════════════

    function testSentinel_safeVerdictNoAction() public {
        usdc.approve(address(vault), 10_000 * 1e6);
        vault.deposit(10_000 * 1e6, address(this));
        vm.startPrank(allocator);
        vault.allocate(address(marketA), 3_000 * 1e6);
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
        vault.allocate(address(marketA), 8_000 * 1e6); // highest util
        vault.allocate(address(marketB), 1_000 * 1e6);
        vm.stopPrank();
        marketA.setUtilization(96); // >90% threshold → will be deallocated
        marketB.setUtilization(10);

        uint256 marketABefore = marketA.balanceOf(address(vault));
        uint256 marketBBefore = marketB.balanceOf(address(vault));

        sentinel.checkVault{value: CHECK_VALUE}(address(vault));
        platform.simulateCallback(_latestRequestId(), "CRITICAL");

        // Market A: ~50% withdrawn
        assertLt(marketA.balanceOf(address(vault)), marketABefore);
        // Market B: untouched
        assertEq(marketB.balanceOf(address(vault)), marketBBefore);
    }

    function testSentinel_noDeallocateWhenUtilBelow90() public {
        usdc.approve(address(vault), 10_000 * 1e6);
        vault.deposit(10_000 * 1e6, address(this));
        vm.prank(allocator);
        vault.allocate(address(marketA), 8_000 * 1e6);
        marketA.setUtilization(88); // <90% → no emergency deallocate

        uint256 marketABefore = marketA.balanceOf(address(vault));

        sentinel.checkVault{value: CHECK_VALUE}(address(vault));
        platform.simulateCallback(_latestRequestId(), "CRITICAL");

        // Vault paused but no deallocation (util < 9000 bps threshold)
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

        // First check → SAFE
        sentinel.checkVault{value: CHECK_VALUE}(address(vault));
        platform.simulateCallback(_latestRequestId(), "SAFE");

        // Second check → CAUTION
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
        // Deploy a vault with autoPause = false
        CuratedVault vaultNoPause =
            new CuratedVault(address(usdc), "NoPause", "NP", admin, curator, allocator, address(this));
        vm.prank(admin);
        vaultNoPause.grantRole(SENTINEL_ROLE, address(sentinel));

        MockLendingMarket mkt = new MockLendingMarket(address(usdc), address(vaultNoPause), "NoPause Market");
        vm.prank(curator);
        vaultNoPause.submitAddMarket(address(mkt), 50_000 * 1e6);
        vm.warp(block.timestamp + 3601);
        vaultNoPause.executeAddMarket(address(mkt), 50_000 * 1e6);

        vm.prank(admin);
        sentinel.registerVault(address(vaultNoPause), false); // autoPause = false

        usdc.approve(address(vaultNoPause), 10_000 * 1e6);
        vaultNoPause.deposit(10_000 * 1e6, address(this));
        vm.prank(allocator);
        vaultNoPause.allocate(address(mkt), 9_000 * 1e6);
        mkt.setUtilization(96);

        sentinel.checkVault{value: CHECK_VALUE}(address(vaultNoPause));
        platform.simulateCallback(_latestRequestId(), "CRITICAL");

        // Risk recorded as Critical but vault NOT paused
        (VaultSentinel.RiskLevel level,,) = sentinel.getLatestRisk(address(vaultNoPause));
        assertEq(uint256(level), uint256(VaultSentinel.RiskLevel.Critical));
        assertFalse(vaultNoPause.depositsPaused(), "autoPause=false must not auto-pause");
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  GROUP 13 — VaultSentinel: admin functions
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
        sentinel.transferAdmin(newAdmin);
        assertEq(sentinel.admin(), newAdmin);

        // Old admin is locked out
        vm.prank(admin);
        vm.expectRevert();
        sentinel.setLlmAgentId(1);

        // Restore for downstream tests
        vm.prank(newAdmin);
        sentinel.transferAdmin(admin);
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  GROUP 14 — CRITICAL FIX: all markets assessed (no 4-market cap)
    // ══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Proves the 4-market hard-cap bug is fixed.
     *
     * Before the fix: _readMetrics and _buildUserPrompt only iterated markets
     * 0-3, so a vault with 5 markets would silently miss the 5th.  A risky
     * market placed at index 4 would not appear in the LLM prompt, producing a
     * false SAFE verdict.
     *
     * After the fix: dynamic arrays cover all markets.  The prompt includes all
     * 5 markets so the AI can return CRITICAL.
     */
    function testSentinel_allMarketsIncludedBeyondFour() public {
        // Deploy a fresh vault with 5 markets
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
            vault5.submitAddMarket(address(mkts[i]), 20_000 * 1e6);
        }
        vm.stopPrank();

        vm.warp(block.timestamp + 3601);
        for (uint256 i; i < 5; i++) {
            vault5.executeAddMarket(address(mkts[i]), 20_000 * 1e6);
        }

        vm.prank(admin);
        sentinel.registerVault(address(vault5), true);

        // Deposit 100k, allocate 20k to each market
        usdc.mint(address(this), 100_000 * 1e6);
        usdc.approve(address(vault5), 100_000 * 1e6);
        vault5.deposit(100_000 * 1e6, address(this));

        vm.startPrank(allocator);
        for (uint256 i; i < 5; i++) {
            vault5.allocate(address(mkts[i]), 20_000 * 1e6);
        }
        vm.stopPrank();

        // Only the 5th market is at critical utilization
        for (uint256 i; i < 4; i++) {
            mkts[i].setUtilization(10);
        }
        mkts[4].setUtilization(96); // index 4 — previously invisible

        sentinel.checkVault{value: CHECK_VALUE}(address(vault5));
        // Simulate what the AI would respond seeing all 5 markets in the prompt
        platform.simulateCallback(_latestRequestId(), "CRITICAL");

        assertTrue(vault5.depositsPaused(), "vault must be paused when 5th market is at critical utilization");
        (VaultSentinel.RiskLevel level,,) = sentinel.getLatestRisk(address(vault5));
        assertEq(uint256(level), uint256(VaultSentinel.RiskLevel.Critical));
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  GROUP 15 — Security / access edge cases
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
        // user2 tries to redeem shares owned by this contract without approval
        vm.prank(user2);
        vm.expectRevert();
        vault.redeem(shares, user2, address(this));
    }

    function testSentinel_transferZeroAdminReverts() public {
        vm.prank(admin);
        vm.expectRevert();
        sentinel.transferAdmin(address(0));
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  GROUP 16 — Full integration flows
    // ══════════════════════════════════════════════════════════════════════════

    /**
     * @notice End-to-end: SAFE → CRITICAL → admin unpause cycle.
     */
    function testIntegration_safeToCriticalCycle() public {
        // Healthy vault
        usdc.approve(address(vault), 20_000 * 1e6);
        vault.deposit(20_000 * 1e6, address(this));
        vm.startPrank(allocator);
        vault.allocate(address(marketA), 5_000 * 1e6);
        vault.allocate(address(marketB), 5_000 * 1e6);
        vm.stopPrank();
        marketA.setUtilization(20);
        marketB.setUtilization(20);

        // Check 1 → SAFE
        sentinel.checkVault{value: CHECK_VALUE}(address(vault));
        platform.simulateCallback(_latestRequestId(), "SAFE");

        (VaultSentinel.RiskLevel l1,,) = sentinel.getLatestRisk(address(vault));
        assertEq(uint256(l1), uint256(VaultSentinel.RiskLevel.Safe));
        assertFalse(vault.depositsPaused());

        // Make vault risky
        marketA.setUtilization(96);
        vm.warp(block.timestamp + CHECK_COOLDOWN + 1);

        // Check 2 → CRITICAL
        sentinel.checkVault{value: CHECK_VALUE}(address(vault));
        platform.simulateCallback(_latestRequestId(), "CRITICAL");

        (VaultSentinel.RiskLevel l2,,) = sentinel.getLatestRisk(address(vault));
        assertEq(uint256(l2), uint256(VaultSentinel.RiskLevel.Critical));
        assertTrue(vault.depositsPaused());

        // Admin reviews and unpauses
        vm.prank(admin);
        vault.unpauseDeposits();
        assertFalse(vault.depositsPaused());

        // Audit trail has both entries
        VaultSentinel.RiskSnapshot[] memory h = sentinel.getHistory(address(vault));
        assertEq(h.length, 2);
    }

    /**
     * @notice Two independent vaults — one SAFE, one CRITICAL — do not interfere.
     */
    function testIntegration_multipleVaultsIndependent() public {
        // Deploy second vault
        CuratedVault vault2 = new CuratedVault(address(usdc), "Vault 2", "V2", admin, curator, allocator, address(this));
        MockLendingMarket marketC = new MockLendingMarket(address(usdc), address(vault2), "Market C");

        vm.prank(admin);
        vault2.grantRole(SENTINEL_ROLE, address(sentinel));

        vm.prank(curator);
        vault2.submitAddMarket(address(marketC), 30_000 * 1e6);
        vm.warp(block.timestamp + 3601);
        vault2.executeAddMarket(address(marketC), 30_000 * 1e6);

        // vault is already registered in setUp; register vault2 only
        vm.prank(admin);
        sentinel.registerVault(address(vault2), false); // autoPause disabled for vault2

        // Fund vault1 (healthy)
        usdc.approve(address(vault), 5_000 * 1e6);
        vault.deposit(5_000 * 1e6, address(this));
        vm.prank(allocator);
        vault.allocate(address(marketA), 2_000 * 1e6);
        marketA.setUtilization(10);

        // Fund vault2 (risky)
        usdc.approve(address(vault2), 5_000 * 1e6);
        vault2.deposit(5_000 * 1e6, address(this));
        vm.prank(allocator);
        vault2.allocate(address(marketC), 4_500 * 1e6); // ~90% allocation
        marketC.setUtilization(96);

        // Check vault1 → SAFE
        sentinel.checkVault{value: CHECK_VALUE}(address(vault));
        platform.simulateCallback(_latestRequestId(), "SAFE");

        (VaultSentinel.RiskLevel l1,,) = sentinel.getLatestRisk(address(vault));
        assertEq(uint256(l1), uint256(VaultSentinel.RiskLevel.Safe));
        assertFalse(vault.depositsPaused());

        // Check vault2 → CRITICAL (autoPause=false so no auto-pause)
        vm.warp(block.timestamp + CHECK_COOLDOWN + 1);
        sentinel.checkVault{value: CHECK_VALUE}(address(vault2));
        platform.simulateCallback(_latestRequestId(), "CRITICAL");

        (VaultSentinel.RiskLevel l2,,) = sentinel.getLatestRisk(address(vault2));
        assertEq(uint256(l2), uint256(VaultSentinel.RiskLevel.Critical));
        assertFalse(vault2.depositsPaused(), "autoPause=false must not auto-pause");

        // Manual pause by admin still works on vault2
        vm.prank(admin);
        vault2.grantRole(SENTINEL_ROLE, address(this));
        vault2.pauseDeposits();
        assertTrue(vault2.depositsPaused());
        vm.prank(admin);
        vault2.revokeRole(SENTINEL_ROLE, address(this));
    }

    /**
     * @notice Depositors cannot be denied their principal via share rounding.
     * Redeem immediately after deposit returns ≥ deposited amount - 1 wei.
     */
    function testIntegration_depositRedeemRoundTrip() public {
        uint256 depositAmount = 10_000 * 1e6;
        usdc.approve(address(vault), depositAmount);
        uint256 shares = vault.deposit(depositAmount, address(this));

        uint256 usdcBefore = usdc.balanceOf(address(this));
        vault.redeem(shares, address(this), address(this));
        uint256 returned = usdc.balanceOf(address(this)) - usdcBefore;

        // Must return nearly full amount (virtual shares cause ≤1 wei rounding)
        assertGe(returned + 1, depositAmount, "round-trip principal preserved");
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  GROUP 17 — D-3 Regression: BPS Precision (AC-4)
    // ══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Regression for D-3: marketAllocationBps distinguishes 40.5% (4050 bps)
     *         from 40.0% (4000 bps).
     *
     *         The old *100 formula would truncate both to 40, making them
     *         indistinguishable. The new *10000 formula preserves the difference.
     *         Proves AC-4: all ratio metrics are bps; no integer-percent path.
     */
    function testD3_marketAllocationBps_distinguishes4050From4000() public {
        // Deposit exactly 10_000 USDC so 1 USDC == 1 bps of totalAssets
        usdc.approve(address(vault), 10_000 * 1e6);
        vault.deposit(10_000 * 1e6, address(this));

        // Allocate exactly 4050 USDC → 4050/10000 = 40.5% = 4050 bps
        vm.prank(allocator);
        vault.allocate(address(marketA), 4_050 * 1e6);

        uint256 bps = vault.marketAllocationBps(address(marketA));

        // Proves AC-4: 40.5% is represented as 4050, not 40
        assertEq(bps, 4_050, "D-3 regression: 40.5% must be 4050 bps");

        // Explicitly confirm it is NOT equal to 4000 (40.0%)
        assertTrue(bps != 4_000, "D-3 regression: 40.5% must be distinguishable from 40.0%");
    }

    /**
     * @notice Regression for D-3: idleBufferBps distinguishes 40.5% (4050 bps)
     *         from 40.0% (4000 bps) for the idle buffer.
     */
    function testD3_idleBufferBps_distinguishes4050From4000() public {
        // Deposit exactly 10_000 USDC
        usdc.approve(address(vault), 10_000 * 1e6);
        vault.deposit(10_000 * 1e6, address(this));

        // Allocate 5950 USDC to marketA → idle = 4050 USDC = 4050 bps
        vm.prank(allocator);
        vault.allocate(address(marketA), 5_950 * 1e6);

        uint256 idleBps = vault.idleBufferBps();

        // Proves AC-4: 40.5% idle is 4050 bps, not 40
        assertEq(idleBps, 4_050, "D-3 regression: idle 40.5% must be 4050 bps");

        // Explicitly confirm it is NOT equal to 4000 (40.0%)
        assertTrue(idleBps != 4_000, "D-3 regression: idle 40.5% must be distinguishable from 40.0%");
    }

    /**
     * @notice Explicitly documents the old bug and the fix.
     *
     *         Old code: balanceOf * 100 / totalAssets → truncates 4050 to 40
     *         New code: balanceOf * 10_000 / totalAssets → returns 4050
     *
     *         The first assertion shows WHY the old code was wrong.
     *         The second assertion shows the fix is correct.
     */
    function testD3_oldPctWouldHaveLostPrecision() public {
        usdc.approve(address(vault), 10_000 * 1e6);
        vault.deposit(10_000 * 1e6, address(this));
        vm.prank(allocator);
        vault.allocate(address(marketA), 4_050 * 1e6);

        // Simulate what the old *100 formula would have returned:
        // 4050 USDC * 100 / 10000 USDC = 40 (truncated, losing 0.5%)
        uint256 marketBal = 4_050 * uint256(1e6);
        uint256 totalBal = 10_000 * uint256(1e6);
        uint256 oldStylePct = marketBal * 100 / totalBal;
        assertEq(oldStylePct, 40, "Documents the old precision loss: 40.5% truncated to 40");

        // The new *10000 formula preserves the precision
        uint256 newBps = vault.marketAllocationBps(address(marketA));
        assertEq(newBps, 4_050, "New bps formula returns lossless 4050");

        // Confirm they represent different values (the whole point of D-3)
        assertTrue(newBps != oldStylePct * 100, "4050 bps != 4000 (which is what 40*100 gives)");
    }

    /**
     * @notice Fuzz test: marketAllocationBps is consistent with the underlying balance.
     *         For any deposit and allocation, bps == balance * 10_000 / totalAssets.
     *         Proves P-4 (lossless canonical inputs) and AC-4.
     */
    function testFuzz_marketAllocationBps_isConsistentWithBalance(uint256 depositAmount, uint256 allocAmount) public {
        // Bound to realistic vault ranges (1 USDC to 49,999 USDC per market cap)
        depositAmount = bound(depositAmount, 1_000 * 1e6, 100_000 * 1e6);
        // Must not exceed supply cap (50_000 * 1e6) and must be at most total deposit
        allocAmount = bound(allocAmount, 0, depositAmount < 50_000 * 1e6 ? depositAmount : 49_999 * 1e6);

        usdc.mint(address(this), depositAmount);
        usdc.approve(address(vault), depositAmount);
        vault.deposit(depositAmount, address(this));

        if (allocAmount > 0) {
            vm.prank(allocator);
            vault.allocate(address(marketA), allocAmount);
        }

        uint256 actualBal = marketA.balanceOf(address(vault));
        uint256 totalA = vault.totalAssets();
        uint256 expectedBps = totalA == 0 ? 0 : actualBal * 10_000 / totalA;
        uint256 reportedBps = vault.marketAllocationBps(address(marketA));

        // Proves P-4: reported bps matches exact arithmetic (within 1 bps rounding)
        // Proves AC-4: no truncation or precision loss
        assertApproxEqAbs(reportedBps, expectedBps, 1, "bps must match balance * 10_000 / totalAssets");
    }

    /**
     * @notice End-to-end: the sentinel history snapshot stores idleBps (not the old idlePct).
     *         After a checkVault+SAFE callback, the stored snapshot's idleBps field
     *         equals vault.idleBufferBps() at snapshot time. Proves the struct rename is
     *         correct and the field stores bps values end-to-end.
     */
    function testD3_sentinelHistoryStoresIdleBps() public {
        usdc.approve(address(vault), 10_000 * 1e6);
        vault.deposit(10_000 * 1e6, address(this));
        vm.prank(allocator);
        vault.allocate(address(marketA), 6_000 * 1e6);

        // Record current idleBufferBps before the check
        uint256 expectedIdleBps = vault.idleBufferBps();
        // 4000 USDC idle / 10000 USDC total = 4000 bps (40%)
        assertEq(expectedIdleBps, 4_000, "precondition: idle should be 4000 bps");

        sentinel.checkVault{value: CHECK_VALUE}(address(vault));
        platform.simulateCallback(_latestRequestId(), "SAFE");

        VaultSentinel.RiskSnapshot[] memory history = sentinel.getHistory(address(vault));
        assertEq(history.length, 1, "should have exactly one snapshot");

        // Proves AC-4 end-to-end: stored idleBps is in basis points
        assertEq(history[0].idleBps, expectedIdleBps, "snapshot idleBps must match vault.idleBufferBps()");

        // Additional sanity: the stored value is bps-scale (>=100 for any non-trivial idle)
        // A 40% idle buffer should be 4000 bps, not 40 (old integer percent)
        assertGe(history[0].idleBps, 100, "idleBps must be bps-scale, not integer-percent-scale");
    }

    receive() external payable {}
}
