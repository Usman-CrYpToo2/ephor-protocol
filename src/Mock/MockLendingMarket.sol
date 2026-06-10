// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title  MockLendingMarket
/// @notice Simulates an Aave/Morpho-style single-asset lending market.
///         Compounds interest per-second at 5% APY using binary-exp math.
///         Only the registered vault can supply/withdraw.
///
///         DEMO HELPERS (testnet only):
///         - setUtilization(pct)  – set borrow utilization 0-100 for AI demo
///         - fastForwardDays(n)   – advance interest index as if n days passed

contract MockLendingMarket {
    // 5 % APY as per-second compound rate in 1e18 fixed-point
    // (1.05)^(1/31536000) ≈ 1 + 1.5471e-9  → 1_000_000_001_547_100_000
    uint256 private constant RATE = 1_000_000_001_547_100_000;
    uint256 private constant ONE = 1e18;

    IERC20 public immutable asset;
    address public immutable vault;
    string public name;

    // Interest index: starts at 1e18, grows each second
    uint256 public globalIndex = ONE;
    uint256 public lastAccrualTimestamp;

    struct Position {
        uint256 principal;
        uint256 entryIndex;
    }
    mapping(address => Position) public positions;
    uint256 public totalPrincipal;

    // Demo: simulated borrows for utilization display
    uint256 public totalBorrowed;

    // Reentrancy
    uint256 private _lock = 1;
    modifier nonReentrant() {
        require(_lock == 1, "reentrant");
        _lock = 2;
        _;
        _lock = 1;
    }
    modifier onlyVault() {
        require(msg.sender == vault, "only vault");
        _;
    }

    event Supplied(address indexed by, uint256 amount);
    event Withdrawn(address indexed by, uint256 amount);
    event UtilizationSet(uint256 borrowed, uint256 supplied);

    constructor(address _asset, address _vault, string memory _name) {
        require(_asset != address(0) && _vault != address(0), "zero addr");
        asset = IERC20(_asset);
        vault = _vault;
        name = _name;
        lastAccrualTimestamp = block.timestamp;
    }

    // ── Vault-facing ─────────────────────────────────────────────────

    function supply(uint256 amount) external onlyVault nonReentrant {
        require(amount > 0, "zero amount");
        _accrue();
        require(asset.transferFrom(msg.sender, address(this), amount), "transferFrom");
        Position storage p = positions[msg.sender];
        if (p.principal > 0) {
            // Settle existing accrued interest into principal before adding
            p.principal = p.principal * globalIndex / p.entryIndex;
        }
        p.principal += amount;
        p.entryIndex = globalIndex;
        totalPrincipal += amount;
        emit Supplied(msg.sender, amount);
    }

    function withdraw(uint256 amount) external onlyVault nonReentrant {
        require(amount > 0, "zero amount");
        _accrue();
        uint256 avail = balanceOf(msg.sender);
        require(avail >= amount, "insufficient balance");
        require(asset.balanceOf(address(this)) >= amount, "no liquidity");

        Position storage p = positions[msg.sender];
        uint256 settled = p.principal * globalIndex / p.entryIndex;
        uint256 remaining = settled - amount;
        // Convert remaining back to index-adjusted principal
        p.principal = remaining * ONE / globalIndex;
        p.entryIndex = globalIndex;
        if (totalPrincipal >= amount) totalPrincipal -= amount;
        else totalPrincipal = 0;

        require(asset.transfer(msg.sender, amount), "transfer");
        emit Withdrawn(msg.sender, amount);
    }

    // ── View ─────────────────────────────────────────────────────────

    function balanceOf(address account) public view returns (uint256) {
        Position storage p = positions[account];
        if (p.principal == 0) return 0;
        return p.principal * _currentIndex() / p.entryIndex;
    }

    /// @notice Utilization in basis points (0-10000). Used by VaultSentinel.
    function utilizationBps() external view returns (uint256) {
        uint256 supplied = asset.balanceOf(address(this));
        if (supplied == 0) return 0;
        uint256 borrowed = totalBorrowed > supplied ? supplied : totalBorrowed;
        return borrowed * 10_000 / supplied;
    }

    function totalAssets() external view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    // ── Demo helpers ─────────────────────────────────────────────────

    /// @notice Set borrow utilization 0-100 for AI risk demo.
    function setUtilization(uint256 pct) external {
        require(pct <= 100, "pct > 100");
        uint256 supplied = asset.balanceOf(address(this));
        totalBorrowed = supplied * pct / 100;
        emit UtilizationSet(totalBorrowed, supplied);
    }

    /// @notice Current supply APY in basis points. Settable; auto-computes from utilization if not set.
    uint256 private _supplyRateBps;

    function setSupplyRate(uint256 rateBps) external {
        _supplyRateBps = rateBps;
    }

    function supplyRateBps() external view returns (uint256) {
        if (_supplyRateBps > 0) return _supplyRateBps;
        uint256 supplied = asset.balanceOf(address(this));
        if (supplied == 0) return 0;
        uint256 borrowed = totalBorrowed > supplied ? supplied : totalBorrowed;
        uint256 util = borrowed * 10_000 / supplied;
        return util * 20 / 100; // rough proxy: rate = 20% of utilization bps
    }

    /// @notice Fast-forward interest without waiting real time.
    function fastForwardDays(uint256 d) external {
        uint256 factor = _rpow(RATE, d * 86_400);
        globalIndex = globalIndex * factor / ONE;
        // lastAccrualTimestamp intentionally not updated so real-time accrual continues
    }

    // ── Internal ─────────────────────────────────────────────────────

    function _accrue() internal {
        uint256 elapsed = block.timestamp - lastAccrualTimestamp;
        if (elapsed == 0) return;
        globalIndex = globalIndex * _rpow(RATE, elapsed) / ONE;
        lastAccrualTimestamp = block.timestamp;
    }

    function _currentIndex() internal view returns (uint256) {
        uint256 elapsed = block.timestamp - lastAccrualTimestamp;
        if (elapsed == 0) return globalIndex;
        return globalIndex * _rpow(RATE, elapsed) / ONE;
    }

    function _rpow(uint256 base, uint256 exp) internal pure returns (uint256 z) {
        z = ONE;
        while (exp > 0) {
            if (exp & 1 == 1) z = z * base / ONE;
            base = base * base / ONE;
            exp >>= 1;
        }
    }
}
