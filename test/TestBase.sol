// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {MockUSDC} from "../src/Mock/MockUSDC.sol";
import {MockERC20} from "../src/Mock/MockERC20.sol";
import {MockLendingMarket} from "../src/Mock/MockLendingMarket.sol";
import {CuratedVault} from "../src/CuratedVault.sol";
import {VaultSentinel} from "../src/VaultSentinel.sol";
import {MockSomniaPlatform} from "../src/Mock/MockSomniaPlatform.sol";
import {UtilizationOracle} from "../src/UtilizationOracle.sol";
import {GenericAdapter} from "../src/Mock/GenericAdapter.sol";

/// @dev ISomnia types used in callback tests
import "../src/Interface/ISomnia.sol";

/**
 * @title  TestBase
 * @notice Shared state, setUp, and helpers for all Ephor Protocol test contracts.
 *
 *  Every category-specific test contract inherits this.  setUp() deploys a complete
 *  protocol environment: USDC → CuratedVault → two markets → VaultSentinel → registered.
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
abstract contract TestBase is Test {
    // ── Contracts ──────────────────────────────────────────────────────────
    MockUSDC usdc;
    CuratedVault vault;
    MockLendingMarket marketA;
    MockLendingMarket marketB;
    VaultSentinel sentinel;
    MockSomniaPlatform platform;

    // ── Actors ─────────────────────────────────────────────────────────────
    address admin     = address(0x1111); // DEFAULT_ADMIN_ROLE on vault + sentinel owner
    address curator   = address(0x2222); // CURATOR_ROLE on vault
    address allocator = address(0x3333); // ALLOCATOR_ROLE on vault
    address user1     = address(0x4444);
    address user2     = address(0x5555);
    address attacker  = address(0x6666);

    // ── Role constants ─────────────────────────────────────────────────────
    bytes32 constant CURATOR_ROLE   = keccak256("CURATOR_ROLE");
    bytes32 constant ALLOCATOR_ROLE = keccak256("ALLOCATOR_ROLE");
    bytes32 constant SENTINEL_ROLE  = keccak256("SENTINEL_ROLE");
    bytes32 constant ADMIN_ROLE     = bytes32(0);

    // ── Sentinel constants mirrored for tests ──────────────────────────────
    uint256 constant CHECK_COOLDOWN     = 5 minutes;
    uint256 constant LLM_COST_PER_AGENT = 0.07 ether;
    uint256 constant SUBCOMMITTEE_SIZE  = 3;

    // Minimum msg.value for checkVault.
    // = getRequestDeposit() + LLM_COST_PER_AGENT × SUBCOMMITTEE_SIZE
    // = 0.01 (mock floor) + 0.07×3 = 0.22 ETH. Use 0.25 for headroom.
    uint256 constant CHECK_VALUE = 0.25 ether;

    // ── Helpers ────────────────────────────────────────────────────────────

    function _latestRequestId() internal view returns (uint256) {
        return platform.nextRequestId() - 1;
    }

    /// @dev Deposit `amount` USDC into `vault` as `user`. Shares go to `user`.
    function _deposit(address user, uint256 amount) internal returns (uint256 shares) {
        vm.startPrank(user);
        usdc.approve(address(vault), amount);
        shares = vault.deposit(amount, user);
        vm.stopPrank();
    }

    /// @dev Deploy a fresh UtilizationOracle with GenericAdapter registered for marketA and marketB.
    function _deployOracle() internal returns (UtilizationOracle orc, GenericAdapter adapter) {
        // 30-min window, 10% spike tolerance, 80% caution, 95% critical
        orc = new UtilizationOracle(30 minutes, 1_000, 8_000, 9_500, address(this));
        adapter = new GenericAdapter();
        orc.setAdapter(address(marketA), address(adapter));
        orc.setAdapter(address(marketB), address(adapter));
    }

    // ── setUp ──────────────────────────────────────────────────────────────

    function setUp() public virtual {
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

        // 4. VaultSentinel (sentinel owner = 0x1111)
        sentinel = new VaultSentinel(address(platform), 1, admin);

        // 5. Grant SENTINEL_ROLE to VaultSentinel contract
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

        // 8. Register vault in sentinel (autoPause enabled)
        vm.prank(admin);
        sentinel.registerVault(address(vault), true);

        // 9. Fund users
        usdc.mint(user1, 10_000 * 1e6);
        usdc.mint(user2, 10_000 * 1e6);
        usdc.mint(address(this), 500_000 * 1e6);
    }

    receive() external payable {}
}
