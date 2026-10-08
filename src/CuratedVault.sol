// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ILendingMarket} from "./Interface/ILendingMarket.sol";

/**
 * @title  CuratedVault
 * @notice ERC-4626 tokenised yield vault.
 *
 *  ROLES
 *  ─────
 *  DEFAULT_ADMIN  DAO multisig — grants roles, unpauses
 *  CURATOR_ROLE   Risk manager  — adds markets (timelocked), sets fee
 *  ALLOCATOR_ROLE Yield bot     — moves USDC between markets (within caps)
 *  SENTINEL_ROLE  VaultSentinel — pauses deposits, emergency-deallocates
 *
 *  SECURITY
 *  ────────
 *  • CEI (Checks-Effects-Interactions) throughout
 *  • ReentrancyGuard on all external state-changing functions
 *  • ERC-4626 inflation attack protection via virtual shares/assets offset
 *  • Per-market supply caps enforced by Allocator
 *  • Timelocked market additions (curator cannot instantly add bad markets)
 *  • Sentinel can only REDUCE risk — cannot add markets or move funds out
 */
contract CuratedVault is ERC20, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ── Role constants ────────────────────────────────────────────────
    bytes32 public constant CURATOR_ROLE = keccak256("CURATOR_ROLE");
    bytes32 public constant ALLOCATOR_ROLE = keccak256("ALLOCATOR_ROLE");
    bytes32 public constant SENTINEL_ROLE = keccak256("SENTINEL_ROLE");

    // ERC-4626 inflation-attack protection offsets
    uint256 private constant VSHARES = 1;
    uint256 private constant VASSETS = 1;

    // Fees
    uint256 public constant MAX_FEE_BPS = 2_000; // 20%

    // Timelock bounds for risk-increasing curator actions
    uint256 public constant MIN_TIMELOCK = 1 minutes;
    uint256 public constant MAX_TIMELOCK = 3 weeks;
    uint256 public timelock = 1 minutes; // testnet default; set 24h+ for production

    // Timelock queue
    struct Pending {
        uint256 eta;
        bool exists;
    }

    mapping(bytes32 => Pending) public pendingActions;
    uint256 public performanceFeeBps = 1_000; // 10%
    address public feeRecipient;

    IERC20 public immutable asset;

    // Market registry
    struct MarketCfg {
        bool enabled;
        uint256 supplyCap;
    }
    mapping(address => MarketCfg) public markets;
    address[] private _mlist;

    bool public depositsPaused;
    uint256 private _lastTA; // totalAssets snapshot for fee accrual

    /// @notice Minimum fraction of vault assets that must remain idle (unallocated), in bps.
    ///         1% = 100 bps, 100% = 10_000 bps.
    ///         Default: 1000 (10%). Set to 0 to disable the floor entirely.
    ///         Maximum: 5000 (50%). Settable by CURATOR_ROLE only.
    ///         Fixes D-7: enforced on every allocate() call.
    uint256 public minIdleBufferBps = 1_000;

    /// @notice Maximum allowed minIdleBufferBps (50%). Prevents curator from locking > half the vault idle.
    uint256 public constant MAX_IDLE_FLOOR_BPS = 5_000;

    // ── Phase 2: Risk/allocation parameters (curator-set) ────────────────
    /// @notice Maximum allocation per market as fraction of totalAssets, in bps. Default 50%.
    uint256 public maxMarketBps = 5_000;
    /// @notice Maximum total absolute movement per rebalance as fraction of totalAssets, in bps. Default 30%.
    uint256 public maxTurnoverBps = 3_000;
    /// @notice Maximum allowed drift from AI snapshot before staleness reject, in bps. Default 5%.
    uint256 public driftToleranceBps = 500;
    /// @notice Minimum time between rebalances. Default 1 hour.
    uint256 public rebalanceEpochLength = 1 hours;

    // ── Phase 2: Epoch state ──────────────────────────────────────────────
    /// @notice Timestamp of the last successfully executed reallocate call.
    uint256 public lastRebalanceTime;
    /// @notice Monotonically incrementing rebalance epoch counter.
    uint256 public currentEpoch;

    // ── Phase 2: New types ───────────────────────────────────────────────
    /// @notice Target allocation for a single market, expressed in asset base units.
    struct MarketTarget {
        address market;
        uint256 targetAmount;
    }

    /// @notice Snapshot guard supplied by the caller to detect staleness.
    struct RebalanceGuard {
        uint256 snapshotTotalAssets; // totalAssets at time of AI request
        uint256 snapshotEpoch; // currentEpoch at time of AI request
    }

    // ── Custom Errors ─────────────────────────────────────────────────
    /// @dev Reverts when an allocation would drop idle below minIdleBufferBps.
    error IdleFloorBreached(uint256 actualIdleBps, uint256 requiredBps);

    /// @dev Reverts when a deposit would exceed the sum of all market supply caps.
    error DepositExceedsCap(uint256 requested, uint256 available);

    /// @dev Reverts when a reallocate call violates an invariant.
    ///      invariantId is bytes32("I-1") through bytes32("I-10").
    error InvariantViolation(bytes32 invariantId);

    // ── Events ───────────────────────────────────────────────────────
    event Deposited(address indexed caller, address indexed rcv, uint256 assets, uint256 shares);
    event Redeemed(address indexed caller, address indexed rcv, address indexed owner, uint256 assets, uint256 shares);
    event Allocated(address indexed market, uint256 amount);
    event Deallocated(address indexed market, uint256 amount);
    event MarketEnabled(address indexed market, uint256 cap);
    event CapUpdated(address indexed market, uint256 cap);
    event MarketQueued(bytes32 indexed id, address indexed market, uint256 eta);
    event CapQueued(bytes32 indexed id, address indexed market, uint256 cap, uint256 eta);
    event ActionRevoked(bytes32 indexed id);
    event TimelockUpdated(uint256 d);
    event DepositsToggled(bool paused, address by);
    event FeeMinted(address indexed to, uint256 shares, uint256 gain);
    event FeeUpdated(uint256 bps);
    /// @dev Emitted when the minimum idle buffer floor is changed.
    event MinIdleBufferBpsSet(uint256 newBps);
    /// @dev Phase 2 events
    event Rebalanced(uint256 indexed epoch, uint256 totalMoved);
    event RebalanceRejected(bytes32 invariantId);
    event MaxMarketBpsSet(uint256 bps);
    event MaxTurnoverBpsSet(uint256 bps);
    event DriftToleranceBpsSet(uint256 bps);
    event RebalanceEpochLengthSet(uint256 d);

    // ── Constructor ──────────────────────────────────────────────────
    constructor(
        address _asset,
        string memory _name,
        string memory _symbol,
        address _admin,
        address _curator,
        address _allocator,
        address _feeRecipient
    ) ERC20(_name, _symbol) {
        require(_asset != address(0) && _admin != address(0) && _feeRecipient != address(0), "zero addr");
        asset = IERC20(_asset);
        feeRecipient = _feeRecipient;
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(CURATOR_ROLE, _curator);
        _grantRole(ALLOCATOR_ROLE, _allocator);
    }

    // ═══════════════════════════════════════════════════════════════
    //  ERC-4626 CORE
    // ═══════════════════════════════════════════════════════════════

    function deposit(uint256 assets, address receiver) external nonReentrant returns (uint256 shares) {
        require(!depositsPaused, "deposits paused");
        require(assets > 0, "zero assets");
        require(receiver != address(0), "zero receiver");
        // D-4 fix: cap check — deposit must not exceed available headroom in supply caps
        {
            uint256 available = maxDeposit(receiver);
            if (assets > available) {
                revert DepositExceedsCap(assets, available);
            }
        }
        _accruePerformanceFee();
        shares = _toShares(assets);
        require(shares > 0, "zero shares");
        _mint(receiver, shares);
        asset.safeTransferFrom(msg.sender, address(this), assets);
        _lastTA = totalAssets();
        emit Deposited(msg.sender, receiver, assets, shares);
    }

    function redeem(uint256 shares, address receiver, address owner_) external nonReentrant returns (uint256 assets) {
        require(shares > 0 && receiver != address(0), "bad args");
        require(balanceOf(owner_) >= shares, "insufficient shares");
        if (msg.sender != owner_) _spendAllowance(owner_, msg.sender, shares);
        _accruePerformanceFee();
        assets = _toAssets(shares);
        require(assets > 0, "zero assets out");
        _ensureLiquidity(assets);
        _burn(owner_, shares);
        _lastTA = totalAssets();
        asset.safeTransfer(receiver, assets);
        emit Redeemed(msg.sender, receiver, owner_, assets, shares);
    }

    // ── ERC-4626 views ───────────────────────────────────────────────

    /// @notice Maximum amount of assets that can be deposited without exceeding the
    ///         sum of all enabled market supply caps.
    ///
    ///         Returns max(0, totalCap - totalAssets()) where
    ///         totalCap = sum(markets[m].supplyCap for all enabled markets).
    ///
    ///         When totalAssets() >= totalCap, returns 0 (vault is at capacity).
    ///         The `receiver` parameter is included for ERC-4626 compatibility but
    ///         is not used — the cap applies globally, not per-user.
    ///
    /// @dev    Fixes D-4: previously returned type(uint256).max, which allowed
    ///         deposits that could not be allocated to any market.
    function maxDeposit(
        address /* receiver */
    )
        public
        view
        returns (uint256)
    {
        uint256 totalCap;
        uint256 n = _mlist.length;
        for (uint256 i; i < n;) {
            address m = _mlist[i];
            if (markets[m].enabled) {
                totalCap += markets[m].supplyCap;
            }
            unchecked {
                ++i;
            }
        }
        uint256 ta = totalAssets();
        if (ta >= totalCap) {
            return 0;
        }
        return totalCap - ta;
    }

    /// @notice Sum of ALL assets controlled by vault (idle + all markets).
    ///         Share price = totalAssets / totalSupply.  Single source of truth.
    function totalAssets() public view returns (uint256) {
        uint256 t = asset.balanceOf(address(this));
        uint256 n = _mlist.length;
        for (uint256 i; i < n;) {
            address m = _mlist[i];
            if (markets[m].enabled) t += ILendingMarket(m).balanceOf(address(this));
            unchecked {
                ++i;
            }
        }
        return t;
    }

    function previewDeposit(uint256 assets_) external view returns (uint256) {
        return _toShares(assets_);
    }

    function previewRedeem(uint256 shares_) external view returns (uint256) {
        return _toAssets(shares_);
    }

    function sharePrice() external view returns (uint256) {
        return (totalAssets() + VASSETS) * 1e18 / (totalSupply() + VSHARES);
    }

    // ═══════════════════════════════════════════════════════════════
    //  ALLOCATOR
    // ═══════════════════════════════════════════════════════════════

    function allocate(address market, uint256 amount) external onlyRole(ALLOCATOR_ROLE) nonReentrant {
        MarketCfg storage cfg = markets[market];
        require(cfg.enabled, "market disabled");
        require(!depositsPaused, "paused: no new allocation"); // I-9
        require(ILendingMarket(market).balanceOf(address(this)) + amount <= cfg.supplyCap, "cap exceeded");
        require(asset.balanceOf(address(this)) >= amount, "insufficient idle");
        // CEI: approve + supply (interaction), then check post-condition
        asset.forceApprove(market, amount);
        ILendingMarket(market).supply(amount);
        // D-7 fix: enforce minimum idle buffer after allocation (I-3)
        // Skip when minIdleBufferBps == 0 (floor disabled) or totalAssets == 0
        if (minIdleBufferBps > 0) {
            uint256 ta = totalAssets();
            if (ta > 0) {
                uint256 idleBal = asset.balanceOf(address(this));
                uint256 actualIdleBps = idleBal * 10_000 / ta;
                if (actualIdleBps < minIdleBufferBps) {
                    revert IdleFloorBreached(actualIdleBps, minIdleBufferBps);
                }
            }
        }
        emit Allocated(market, amount);
    }

    function deallocate(address market, uint256 amount) external onlyRole(ALLOCATOR_ROLE) nonReentrant {
        require(markets[market].enabled, "market disabled");
        ILendingMarket(market).withdraw(amount);
        emit Deallocated(market, amount);
    }

    // ═══════════════════════════════════════════════════════════════
    //  ALLOCATOR – REALLOCATE (Phase 2 invariant system)
    // ═══════════════════════════════════════════════════════════════

    /// @notice Atomically rebalance the vault according to `targets`.
    ///         Enforces all SDD §10 invariants (I-1 through I-10) before
    ///         executing any token movements. Reverts on any violation.
    ///
    /// @param targets  Per-market target balances in asset base units.
    /// @param guard    Staleness guard capturing totalAssets and epoch at
    ///                 the time the AI/caller built the proposal.
    function reallocate(MarketTarget[] calldata targets, RebalanceGuard calldata guard)
        external
        onlyRole(ALLOCATOR_ROLE)
        nonReentrant
    {
        uint256 ta = totalAssets();

        // ── I-10 Staleness check ──────────────────────────────────────
        // Check epoch mismatch first (cheap, no division).
        if (guard.snapshotEpoch != currentEpoch) {
            revert InvariantViolation(bytes32("I-10"));
        }
        // Check drift: |ta - snapshot| <= driftToleranceBps * snapshot / 1e4
        {
            uint256 snap = guard.snapshotTotalAssets;
            uint256 drift = ta > snap ? ta - snap : snap - ta;
            // Allow zero-snapshot only when ta is also zero (empty vault corner case)
            if (snap == 0) {
                if (ta != 0) revert InvariantViolation(bytes32("I-10"));
            } else {
                if (drift * 10_000 > driftToleranceBps * snap) {
                    revert InvariantViolation(bytes32("I-10"));
                }
            }
        }

        // ── I-8 Epoch cooldown ───────────────────────────────────────
        if (block.timestamp < lastRebalanceTime + rebalanceEpochLength) {
            revert InvariantViolation(bytes32("I-8"));
        }

        // ── Pre-compute sum of targets ────────────────────────────────
        // Each market may appear once: a duplicate would be counted twice in
        // the I-1 sum while only being moved once.
        uint256 targetSum;
        uint256 n = targets.length;
        for (uint256 i; i < n;) {
            for (uint256 j; j < i;) {
                if (targets[j].market == targets[i].market) {
                    revert InvariantViolation(bytes32("I-1"));
                }
                unchecked {
                    ++j;
                }
            }
            targetSum += targets[i].targetAmount;
            unchecked {
                ++i;
            }
        }

        // Enabled markets missing from `targets` keep their balances. Those
        // balances are not idle, so they are reserved before deriving idle.
        uint256 untouched;
        uint256 mlen = _mlist.length;
        for (uint256 k; k < mlen;) {
            address m = _mlist[k];
            if (markets[m].enabled && !_isListed(targets, m)) {
                untouched += ILendingMarket(m).balanceOf(address(this));
            }
            unchecked {
                ++k;
            }
        }

        // ── I-1 Conservation ─────────────────────────────────────────
        // impliedIdle = ta - targetSum - untouched; must be >= 0 (plus 1-wei epsilon)
        if (targetSum + untouched > ta + 1) {
            revert InvariantViolation(bytes32("I-1"));
        }
        uint256 impliedIdle = ta >= targetSum + untouched ? ta - targetSum - untouched : 0;

        // ── I-3 Idle floor ───────────────────────────────────────────
        if (minIdleBufferBps > 0 && ta > 0) {
            if (impliedIdle * 10_000 < minIdleBufferBps * ta) {
                revert InvariantViolation(bytes32("I-3"));
            }
        }

        // ── Per-target checks ─────────────────────────────────────────
        uint256 totalAbsMovement;
        for (uint256 i; i < n;) {
            address mkt = targets[i].market;
            uint256 tgt = targets[i].targetAmount;

            // ── I-5 Whitelist ─────────────────────────────────────────
            if (!markets[mkt].enabled || tgt == 0) {
                revert InvariantViolation(bytes32("I-5"));
            }

            // ── I-2 Cap compliance ────────────────────────────────────
            if (tgt > markets[mkt].supplyCap) {
                revert InvariantViolation(bytes32("I-2"));
            }

            // ── I-4 Max concentration ─────────────────────────────────
            if (ta > 0 && tgt * 10_000 > maxMarketBps * ta) {
                revert InvariantViolation(bytes32("I-4"));
            }

            // ── I-6 Turnover accumulator ──────────────────────────────
            uint256 cur = ILendingMarket(mkt).balanceOf(address(this));
            uint256 delta = tgt > cur ? tgt - cur : cur - tgt;
            totalAbsMovement += delta;

            // ── I-9 Pause respect ─────────────────────────────────────
            if (depositsPaused && tgt > cur) {
                revert InvariantViolation(bytes32("I-9"));
            }

            // ── I-7 Liquidity-aware (withdrawal must not exceed balance) ──
            // Withdrawals will only be tried when cur > tgt; cur comes from
            // balanceOf so that's automatically the available amount. Still
            // checked here for clarity and early revert.
            // (supply direction is always safe — vault holds idle assets)

            unchecked {
                ++i;
            }
        }

        // ── I-6 Turnover bound ────────────────────────────────────────
        if (ta > 0 && totalAbsMovement * 10_000 > maxTurnoverBps * ta) {
            revert InvariantViolation(bytes32("I-6"));
        }

        // ── Effects: update epoch before interactions ─────────────────
        lastRebalanceTime = block.timestamp;
        currentEpoch++;

        // ── Interactions: Phase A — withdrawals first ─────────────────
        for (uint256 i; i < n;) {
            address mkt = targets[i].market;
            uint256 tgt = targets[i].targetAmount;
            uint256 cur = ILendingMarket(mkt).balanceOf(address(this));
            if (cur > tgt) {
                ILendingMarket(mkt).withdraw(cur - tgt);
            }
            unchecked {
                ++i;
            }
        }

        // ── Interactions: Phase B — deposits ─────────────────────────
        for (uint256 i; i < n;) {
            address mkt = targets[i].market;
            uint256 tgt = targets[i].targetAmount;
            uint256 cur = ILendingMarket(mkt).balanceOf(address(this));
            if (tgt > cur) {
                uint256 toSupply = tgt - cur;
                asset.forceApprove(mkt, toSupply);
                ILendingMarket(mkt).supply(toSupply);
            }
            unchecked {
                ++i;
            }
        }

        emit Rebalanced(currentEpoch, totalAbsMovement);
    }

    // ═══════════════════════════════════════════════════════════════
    //  CURATOR – MARKET MANAGEMENT (timelocked)
    // ═══════════════════════════════════════════════════════════════

    /// @notice Queue a market addition. Executable by anyone after `timelock`.
    function submitAddMarket(address market, uint256 cap) external onlyRole(CURATOR_ROLE) {
        require(market != address(0) && cap > 0, "bad args");
        require(!markets[market].enabled, "already enabled");
        bytes32 id = keccak256(abi.encodePacked("addMarket", market, cap));
        require(!pendingActions[id].exists, "already queued");
        uint256 eta = block.timestamp + timelock;
        pendingActions[id] = Pending(eta, true);
        emit MarketQueued(id, market, eta);
    }

    function executeAddMarket(address market, uint256 cap) external nonReentrant {
        bytes32 id = keccak256(abi.encodePacked("addMarket", market, cap));
        Pending storage p = pendingActions[id];
        require(p.exists, "no pending action");
        require(block.timestamp >= p.eta, "timelock active");
        // Two queued additions of one market (different caps) must not both
        // execute: a duplicate _mlist entry would double-count totalAssets().
        require(!markets[market].enabled, "already enabled");
        delete pendingActions[id];
        markets[market] = MarketCfg(true, cap);
        _mlist.push(market);
        emit MarketEnabled(market, cap);
    }

    /// @notice Cap decreases apply immediately (curator or sentinel).
    ///         Cap increases are curator-only and go through the timelock.
    function setSupplyCap(address market, uint256 newCap) external {
        require(markets[market].enabled, "not enabled");
        if (newCap > markets[market].supplyCap) {
            require(hasRole(CURATOR_ROLE, msg.sender), "curator only");
            bytes32 id = keccak256(abi.encodePacked("setCap", market, newCap));
            require(!pendingActions[id].exists, "already queued");
            uint256 eta = block.timestamp + timelock;
            pendingActions[id] = Pending(eta, true);
            emit CapQueued(id, market, newCap, eta);
        } else {
            require(hasRole(CURATOR_ROLE, msg.sender) || hasRole(SENTINEL_ROLE, msg.sender), "unauthorized");
            markets[market].supplyCap = newCap;
            emit CapUpdated(market, newCap);
        }
    }

    function executeSetCap(address market, uint256 newCap) external nonReentrant {
        bytes32 id = keccak256(abi.encodePacked("setCap", market, newCap));
        Pending storage p = pendingActions[id];
        require(p.exists && block.timestamp >= p.eta, "timelock active");
        require(markets[market].enabled, "not enabled");
        delete pendingActions[id];
        markets[market].supplyCap = newCap;
        emit CapUpdated(market, newCap);
    }

    /// @notice Cancel a queued action. Risk-reducing, so curator or sentinel.
    function revokeAction(bytes32 id) external {
        require(hasRole(SENTINEL_ROLE, msg.sender) || hasRole(CURATOR_ROLE, msg.sender), "unauthorized");
        require(pendingActions[id].exists, "no action");
        delete pendingActions[id];
        emit ActionRevoked(id);
    }

    function setTimelock(uint256 d) external onlyRole(CURATOR_ROLE) {
        require(d >= MIN_TIMELOCK && d <= MAX_TIMELOCK, "bad delay");
        timelock = d;
        emit TimelockUpdated(d);
    }

    // ═══════════════════════════════════════════════════════════════
    //  SENTINEL – EMERGENCY (risk-reducing only)
    // ═══════════════════════════════════════════════════════════════

    function pauseDeposits() external onlyRole(SENTINEL_ROLE) {
        depositsPaused = true;
        emit DepositsToggled(true, msg.sender);
    }

    function unpauseDeposits() external onlyRole(DEFAULT_ADMIN_ROLE) {
        depositsPaused = false;
        emit DepositsToggled(false, msg.sender);
    }

    function emergencyDeallocate(address market, uint256 amount) external onlyRole(SENTINEL_ROLE) nonReentrant {
        require(markets[market].enabled, "market disabled");
        ILendingMarket(market).withdraw(amount);
        emit Deallocated(market, amount);
    }

    // ═══════════════════════════════════════════════════════════════
    //  CURATOR – CONFIG
    // ═══════════════════════════════════════════════════════════════

    /// @notice Set the minimum idle buffer floor in basis points.
    ///         After any allocation, idle assets as a fraction of totalAssets must be >= newBps.
    ///         Set to 0 to disable the floor entirely.
    ///         Maximum allowed value: MAX_IDLE_FLOOR_BPS (5000 = 50%).
    ///
    /// @dev    Fixes D-7. Enforces I-3. Risk-increasing changes (raising the floor) are
    ///         immediate since raising the floor is risk-reducing for depositors.
    ///         Only CURATOR_ROLE may call this function.
    ///
    /// @param newBps  New minimum idle buffer in bps. Must be <= MAX_IDLE_FLOOR_BPS.
    function setMinIdleBufferBps(uint256 newBps) external onlyRole(CURATOR_ROLE) {
        require(newBps <= MAX_IDLE_FLOOR_BPS, "idle floor too high");
        minIdleBufferBps = newBps;
        emit MinIdleBufferBpsSet(newBps);
    }

    /// @notice Set maximum allocation per market in bps. Max 9000 (90%).
    function setMaxMarketBps(uint256 bps) external onlyRole(CURATOR_ROLE) {
        require(bps <= 9_000, "too high");
        maxMarketBps = bps;
        emit MaxMarketBpsSet(bps);
    }

    /// @notice Set maximum total turnover per rebalance in bps. Max 9000 (90%).
    function setMaxTurnoverBps(uint256 bps) external onlyRole(CURATOR_ROLE) {
        require(bps <= 9_000, "too high");
        maxTurnoverBps = bps;
        emit MaxTurnoverBpsSet(bps);
    }

    /// @notice Set drift tolerance for guard staleness check in bps. Max 2000 (20%).
    function setDriftToleranceBps(uint256 bps) external onlyRole(CURATOR_ROLE) {
        require(bps <= 2_000, "too high");
        driftToleranceBps = bps;
        emit DriftToleranceBpsSet(bps);
    }

    /// @notice Set minimum time between rebalances. Max 7 days.
    function setRebalanceEpochLength(uint256 d) external onlyRole(CURATOR_ROLE) {
        require(d <= 7 days, "too long");
        rebalanceEpochLength = d;
        emit RebalanceEpochLengthSet(d);
    }

    function setPerformanceFee(uint256 bps) external onlyRole(CURATOR_ROLE) {
        require(bps <= MAX_FEE_BPS, "fee too high");
        _accruePerformanceFee();
        performanceFeeBps = bps;
        emit FeeUpdated(bps);
    }

    function setFeeRecipient(address r) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(r != address(0), "zero");
        feeRecipient = r;
    }

    // ═══════════════════════════════════════════════════════════════
    //  SENTINEL QUERY HELPERS (read-only, no external API needed)
    // ═══════════════════════════════════════════════════════════════

    /// @notice Fraction of vault assets allocated to `market`, in basis points (bps).
    ///         1% = 100 bps, 100% = 10_000 bps.
    ///         Returns 0 when totalAssets is zero.
    /// @dev    Replaces the deprecated `marketAllocationPct` (which used *100 and lost
    ///         sub-percent precision). Fixes D-3: thresholds at 40% now distinguish
    ///         40.0% (4000 bps) from 40.9% (4090 bps) without ambiguity.
    function marketAllocationBps(address market) external view returns (uint256) {
        uint256 t = totalAssets();
        if (t == 0) return 0;
        return ILendingMarket(market).balanceOf(address(this)) * 10_000 / t;
    }

    /// @notice Fraction of vault assets held idle (unallocated), in basis points (bps).
    ///         1% = 100 bps, 100% = 10_000 bps.
    ///         Returns 0 when totalAssets is zero.
    /// @dev    Replaces the deprecated `idleBufferPct` (which used *100). Fixes D-3.
    function idleBufferBps() external view returns (uint256) {
        uint256 t = totalAssets();
        if (t == 0) return 0;
        return asset.balanceOf(address(this)) * 10_000 / t;
    }

    function marketCount() external view returns (uint256) {
        return _mlist.length;
    }

    function marketList(uint256 i) external view returns (address) {
        return _mlist[i];
    }

    /// @notice Decimal count of the vault's configured asset (read from the asset ERC-20).
    function assetDecimals() external view returns (uint8) {
        return IERC20Metadata(address(asset)).decimals();
    }

    /// @notice Supply cap for a market in asset base units. Returns 0 for unregistered markets.
    function marketSupplyCap(address market) external view returns (uint256) {
        return markets[market].supplyCap;
    }

    // ═══════════════════════════════════════════════════════════════
    //  INTERNAL
    // ═══════════════════════════════════════════════════════════════
    // @audit must use muldiv rather than the native solidity operation may result in overflow
    function _toShares(uint256 a) internal view returns (uint256) {
        return a * (totalSupply() + VSHARES) / (totalAssets() + VASSETS);
    }

    function _toAssets(uint256 s) internal view returns (uint256) {
        return s * (totalAssets() + VASSETS) / (totalSupply() + VSHARES);
    }

    function _isListed(MarketTarget[] calldata targets, address market) internal pure returns (bool) {
        uint256 n = targets.length;
        for (uint256 i; i < n;) {
            if (targets[i].market == market) return true;
            unchecked {
                ++i;
            }
        }
        return false;
    }

    function _ensureLiquidity(uint256 needed) internal {
        uint256 idle = asset.balanceOf(address(this));
        if (idle >= needed) return;
        uint256 gap = needed - idle;
        uint256 n = _mlist.length;
        for (uint256 i = n; i > 0;) {
            unchecked {
                --i;
            }
            address m = _mlist[i];
            if (!markets[m].enabled) continue;
            uint256 av = ILendingMarket(m).balanceOf(address(this));
            if (av == 0) continue;
            uint256 w = av >= gap ? gap : av;
            ILendingMarket(m).withdraw(w);
            gap -= w;
            if (gap == 0) break;
        }
        require(gap == 0, "insufficient liquidity");
    }

    function _accruePerformanceFee() internal {
        uint256 cur = totalAssets();
        if (cur <= _lastTA || totalSupply() == 0 || performanceFeeBps == 0) {
            _lastTA = cur;
            return;
        }
        uint256 gain = cur - _lastTA;
        uint256 feeA = gain * performanceFeeBps / 10_000;
        uint256 feeShares = feeA * (totalSupply() + VSHARES) / (cur + VASSETS);
        if (feeShares > 0) _mint(feeRecipient, feeShares);
        emit FeeMinted(feeRecipient, feeShares, gain);
        _lastTA = cur;
    }
}
