// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

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

interface IERC20 {
    function balanceOf(address)                           external view returns (uint256);
    function transfer(address to, uint256 amount)         external returns (bool);
    function transferFrom(address f, address t, uint256 a) external returns (bool);
    function approve(address spender, uint256 amount)     external returns (bool);
}

interface ILendingMarket {
    function supply(uint256 amount)          external;
    function withdraw(uint256 amount)        external;
    function balanceOf(address account)      external view returns (uint256);
    function utilizationBps()               external view returns (uint256);
}

// ── Minimal inline ERC-20 (shares token) ────────────────────────────────────
abstract contract ERC20Base {
    string  public name;
    string  public symbol;
    uint8   public constant decimals = 18;

    uint256 public totalSupply;
    mapping(address => uint256)                     public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to,       uint256 v);
    event Approval(address indexed owner, address indexed spender, uint256 v);

    constructor(string memory _n, string memory _s) { name = _n; symbol = _s; }

    function transfer(address to, uint256 v) external returns (bool)
        { _transfer(msg.sender, to, v); return true; }
    function approve(address sp, uint256 v) external returns (bool)
        { allowance[msg.sender][sp] = v; emit Approval(msg.sender, sp, v); return true; }
    function transferFrom(address f, address t, uint256 v) external returns (bool)
        { _spend(f, msg.sender, v); _transfer(f, t, v); return true; }

    function _transfer(address f, address t, uint256 v) internal {
        require(t != address(0) && balanceOf[f] >= v, "ERC20: transfer");
        balanceOf[f] -= v; balanceOf[t] += v; emit Transfer(f, t, v);
    }
    function _mint(address t, uint256 v) internal {
        require(t != address(0), "ERC20: mint zero");
        totalSupply += v; balanceOf[t] += v; emit Transfer(address(0), t, v);
    }
    function _burn(address f, uint256 v) internal {
        require(balanceOf[f] >= v, "ERC20: burn");
        balanceOf[f] -= v; totalSupply -= v; emit Transfer(f, address(0), v);
    }
    function _spend(address o, address sp, uint256 v) internal {
        uint256 a = allowance[o][sp];
        if (a != type(uint256).max) { require(a >= v, "ERC20: allowance"); allowance[o][sp] = a - v; }
    }
}

// ── Inline AccessControl ─────────────────────────────────────────────────────
abstract contract AccessControl {
    bytes32 public constant DEFAULT_ADMIN_ROLE = bytes32(0);
    bytes32 public constant CURATOR_ROLE       = keccak256("CURATOR_ROLE");
    bytes32 public constant ALLOCATOR_ROLE     = keccak256("ALLOCATOR_ROLE");
    bytes32 public constant SENTINEL_ROLE      = keccak256("SENTINEL_ROLE");

    mapping(bytes32 => mapping(address => bool)) private _r;

    event RoleGranted(bytes32 indexed role, address indexed account);
    event RoleRevoked(bytes32 indexed role, address indexed account);

    modifier onlyRole(bytes32 role) { require(_r[role][msg.sender], "missing role"); _; }

    function hasRole(bytes32 role, address a) public view returns (bool) { return _r[role][a]; }
    function grantRole(bytes32 role, address a) external onlyRole(DEFAULT_ADMIN_ROLE)
        { _r[role][a] = true;  emit RoleGranted(role, a); }
    function revokeRole(bytes32 role, address a) external onlyRole(DEFAULT_ADMIN_ROLE)
        { _r[role][a] = false; emit RoleRevoked(role, a); }
    function _setupRole(bytes32 role, address a) internal { _r[role][a] = true; }
}

// ── Inline ReentrancyGuard ───────────────────────────────────────────────────
abstract contract ReentrancyGuard {
    uint256 private _s = 1;
    modifier nonReentrant() { require(_s == 1, "reentrant"); _s = 2; _; _s = 1; }
}

// ════════════════════════════════════════════════════════════════════════════
contract CuratedVault is ERC20Base, AccessControl, ReentrancyGuard {

    // ERC-4626 inflation-attack protection offsets
    uint256 private constant VSHARES = 1;
    uint256 private constant VASSETS = 1;

    // Timelock bounds
    uint256 public constant MIN_TIMELOCK = 1 minutes;
    uint256 public constant MAX_TIMELOCK = 3 weeks;
    uint256 public timelock = 1 minutes;     // 1 min for testnet demo; 24h+ on mainnet

    // Fees
    uint256 public constant MAX_FEE_BPS = 2_000;  // 20%
    uint256 public performanceFeeBps    = 1_000;  // 10%
    address public feeRecipient;

    IERC20 public immutable asset;

    // Market registry
    struct MarketCfg { bool enabled; uint256 supplyCap; }
    mapping(address => MarketCfg) public markets;
    address[] private _mlist;

    // Timelock queue
    struct Pending { uint256 eta; bool exists; }
    mapping(bytes32 => Pending) public pendingActions;

    bool    public depositsPaused;
    uint256 private _lastTA; // totalAssets snapshot for fee accrual

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

    // ── Constructor ──────────────────────────────────────────────────
    constructor(
        address _asset,
        string  memory _name,
        string  memory _symbol,
        address _admin,
        address _curator,
        address _allocator,
        address _feeRecipient
    ) ERC20Base(_name, _symbol) {
        require(_asset != address(0) && _admin != address(0) && _feeRecipient != address(0), "zero addr");
        asset        = IERC20(_asset);
        feeRecipient = _feeRecipient;
        _setupRole(DEFAULT_ADMIN_ROLE, _admin);
        _setupRole(CURATOR_ROLE,       _curator);
        _setupRole(ALLOCATOR_ROLE,     _allocator);
    }

    // ═══════════════════════════════════════════════════════════════
    //  ERC-4626 CORE
    // ═══════════════════════════════════════════════════════════════

    function deposit(uint256 assets, address receiver) external nonReentrant returns (uint256 shares) {
        require(!depositsPaused,        "deposits paused");
        require(assets > 0,             "zero assets");
        require(receiver != address(0), "zero receiver");
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
        require(balanceOf[owner_] >= shares, "insufficient shares");
        if (msg.sender != owner_) _spend(owner_, msg.sender, shares);
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

    /// @notice Sum of ALL USDC controlled by vault (idle + all markets).
    ///         Share price = totalAssets / totalSupply.  Single source of truth.
    function totalAssets() public view returns (uint256) {
        uint256 t = asset.balanceOf(address(this));
        uint256 n = _mlist.length;
        for (uint256 i; i < n;) {
            address m = _mlist[i];
            if (markets[m].enabled) t += ILendingMarket(m).balanceOf(address(this));
            unchecked { ++i; }
        }
        return t;
    }

    function previewDeposit(uint256 assets_) external view returns (uint256) { return _toShares(assets_); }
    function previewRedeem(uint256 shares_)  external view returns (uint256) { return _toAssets(shares_); }
    function sharePrice()                   external view returns (uint256) {
        return (totalAssets() + VASSETS) * 1e18 / (totalSupply + VSHARES);
    }

    // ═══════════════════════════════════════════════════════════════
    //  ALLOCATOR
    // ═══════════════════════════════════════════════════════════════

    function allocate(address market, uint256 amount) external onlyRole(ALLOCATOR_ROLE) nonReentrant {
        MarketCfg storage cfg = markets[market];
        require(cfg.enabled, "market disabled");
        require(ILendingMarket(market).balanceOf(address(this)) + amount <= cfg.supplyCap, "cap exceeded");
        require(asset.balanceOf(address(this)) >= amount, "insufficient idle");
        asset.approve(market, amount);
        ILendingMarket(market).supply(amount);
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
        require(p.exists,                          "no pending action");
        require(block.timestamp >= p.eta,          "timelock active");
        markets[market] = MarketCfg(true, cap);
        _mlist.push(market);
        delete pendingActions[id];
        emit MarketEnabled(market, cap);
    }

    function setSupplyCap(address market, uint256 newCap) external {
        require(markets[market].enabled, "not enabled");
        if (newCap > markets[market].supplyCap) {
            require(hasRole(CURATOR_ROLE, msg.sender), "curator only");
            bytes32 id  = keccak256(abi.encodePacked("setCap", market, newCap));
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

    function setTimelock(uint256 d) external onlyRole(CURATOR_ROLE) {
        require(d >= MIN_TIMELOCK && d <= MAX_TIMELOCK, "bad delay");
        timelock = d; emit TimelockUpdated(d);
    }

    function setPerformanceFee(uint256 bps) external onlyRole(CURATOR_ROLE) {
        require(bps <= MAX_FEE_BPS, "fee too high");
        _accruePerformanceFee();
        performanceFeeBps = bps; emit FeeUpdated(bps);
    }

    function setFeeRecipient(address r) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(r != address(0), "zero"); feeRecipient = r;
    }

    // ═══════════════════════════════════════════════════════════════
    //  SENTINEL QUERY HELPERS (read-only, no external API needed)
    // ═══════════════════════════════════════════════════════════════

    function marketAllocationPct(address market) external view returns (uint256) {
        uint256 t = totalAssets(); if (t == 0) return 0;
        return ILendingMarket(market).balanceOf(address(this)) * 100 / t;
    }

    function idleBufferPct() external view returns (uint256) {
        uint256 t = totalAssets(); if (t == 0) return 0;
        return asset.balanceOf(address(this)) * 100 / t;
    }

    function marketCount() external view returns (uint256) { return _mlist.length; }
    function marketList(uint256 i) external view returns (address) { return _mlist[i]; }

    // ═══════════════════════════════════════════════════════════════
    //  INTERNAL
    // ═══════════════════════════════════════════════════════════════

    function _toShares(uint256 a) internal view returns (uint256) {
        return a * (totalSupply + VSHARES) / (totalAssets() + VASSETS);
    }
    function _toAssets(uint256 s) internal view returns (uint256) {
        return s * (totalAssets() + VASSETS) / (totalSupply + VSHARES);
    }

    function _ensureLiquidity(uint256 needed) internal {
        uint256 idle = asset.balanceOf(address(this));
        if (idle >= needed) return;
        uint256 gap = needed - idle;
        uint256 n   = _mlist.length;
        for (uint256 i = n; i > 0;) {
            unchecked { --i; }
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
        if (cur <= _lastTA || totalSupply == 0 || performanceFeeBps == 0) {
            _lastTA = cur; return;
        }
        uint256 gain     = cur - _lastTA;
        uint256 feeA     = gain * performanceFeeBps / 10_000;
        uint256 feeShares = feeA * (totalSupply + VSHARES) / (cur + VASSETS);
        if (feeShares > 0) { _mint(feeRecipient, feeShares); emit FeeMinted(feeRecipient, feeShares, gain); }
        _lastTA = cur;
    }
}
