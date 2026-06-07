// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
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
    // ── Role constants ────────────────────────────────────────────────
    bytes32 public constant CURATOR_ROLE = keccak256("CURATOR_ROLE");
    bytes32 public constant ALLOCATOR_ROLE = keccak256("ALLOCATOR_ROLE");
    bytes32 public constant SENTINEL_ROLE = keccak256("SENTINEL_ROLE");

    // ERC-4626 inflation-attack protection offsets
    uint256 private constant VSHARES = 1;
    uint256 private constant VASSETS = 1;

    // Timelock bounds
    uint256 public constant MIN_TIMELOCK = 1 minutes;
    uint256 public constant MAX_TIMELOCK = 3 weeks;
    uint256 public timelock = 1 minutes; // 1 min for testnet demo; 24h+ on mainnet

    // Fees
    uint256 public constant MAX_FEE_BPS = 2_000; // 20%
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

    // Timelock queue
    struct Pending {
        uint256 eta;
        bool exists;
    }
    mapping(bytes32 => Pending) public pendingActions;

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

    // ── Custom Errors ─────────────────────────────────────────────────
    /// @dev Reverts when an allocation would drop idle below minIdleBufferBps.
    error IdleFloorBreached(uint256 actualIdleBps, uint256 requiredBps);

    /// @dev Reverts when a deposit would exceed the sum of all market supply caps.
    error DepositExceedsCap(uint256 requested, uint256 available);

    // ── Events ───────────────────────────────────────────────────────
    event Deposited(address indexed caller, address indexed rcv, uint256 assets, uint256 shares);
    event Redeemed(address indexed caller, address indexed rcv, address indexed owner, uint256 assets, uint256 shares);
    event Allocated(address indexed market, uint256 amount);
    event Deallocated(address indexed market, uint256 amount);
    event MarketQueued(bytes32 indexed id, address indexed market, uint256 eta);
    event MarketEnabled(address indexed market, uint256 cap);
    event CapUpdated(address indexed market, uint256 cap);
    event CapQueued(bytes32 indexed id, address indexed market, uint256 cap, uint256 eta);
    event ActionRevoked(bytes32 indexed id);
    event DepositsToggled(bool paused, address by);
    event FeeMinted(address indexed to, uint256 shares, uint256 gain);
    event TimelockUpdated(uint256 d);
    event FeeUpdated(uint256 bps);
    /// @dev Emitted when the minimum idle buffer floor is changed.
    event MinIdleBufferBpsSet(uint256 newBps);

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
        require(asset.transferFrom(msg.sender, address(this), assets), "transferFrom");
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
        require(asset.transfer(receiver, assets), "transfer");
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
        require(ILendingMarket(market).balanceOf(address(this)) + amount <= cfg.supplyCap, "cap exceeded");
        require(asset.balanceOf(address(this)) >= amount, "insufficient idle");
        // CEI: approve + supply (interaction), then check post-condition
        asset.approve(market, amount);
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
    //  CURATOR – MARKET MANAGEMENT (timelocked)
    // ═══════════════════════════════════════════════════════════════

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
        markets[market] = MarketCfg(true, cap);
        _mlist.push(market);
        delete pendingActions[id];
        emit MarketEnabled(market, cap);
    }

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
        markets[market].supplyCap = newCap;
        delete pendingActions[id];
        emit CapUpdated(market, newCap);
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

    function revokeAction(bytes32 id) external {
        require(hasRole(SENTINEL_ROLE, msg.sender) || hasRole(CURATOR_ROLE, msg.sender), "unauthorized");
        require(pendingActions[id].exists, "no action");
        delete pendingActions[id];
        emit ActionRevoked(id);
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

    function setTimelock(uint256 d) external onlyRole(CURATOR_ROLE) {
        require(d >= MIN_TIMELOCK && d <= MAX_TIMELOCK, "bad delay");
        timelock = d;
        emit TimelockUpdated(d);
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

    // ═══════════════════════════════════════════════════════════════
    //  INTERNAL
    // ═══════════════════════════════════════════════════════════════

    function _toShares(uint256 a) internal view returns (uint256) {
        return a * (totalSupply() + VSHARES) / (totalAssets() + VASSETS);
    }

    function _toAssets(uint256 s) internal view returns (uint256) {
        return s * (totalAssets() + VASSETS) / (totalSupply() + VSHARES);
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
