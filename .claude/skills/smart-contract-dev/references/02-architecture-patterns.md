# 02 — Architecture Patterns & Protocol Design

Architecture is the highest-leverage decision in smart contract engineering. Mistakes here compound
throughout the entire lifecycle. This module covers proven patterns for protocol design, upgradeability,
access control, storage, and composability.

---

## Upgradeability Patterns

### Pattern 1: Transparent Proxy (OpenZeppelin)
```
[User] → [TransparentUpgradeableProxy] → [Implementation]
                    ↑ admin-only
              [ProxyAdmin]
```
- Admin calls go to proxy (upgrade)
- Non-admin calls are delegated to implementation
- **Risk**: Admin key exposure; seldom-called admin functions add complexity
- **Use when**: Simple upgradeability with clear admin separation

### Pattern 2: UUPS (EIP-1822)
```
[User] → [ERC1967Proxy] → [Implementation (contains upgrade logic)]
```
- Upgrade function lives in the implementation
- Lower deploy cost; leaner proxy
- **Risk**: If implementation upgrade function is broken, proxy is stuck forever
- **Use when**: Need minimal proxy overhead; team understands the risk
- **Critical**: Always include `_authorizeUpgrade` override with access control

### Pattern 3: Diamond / EIP-2535
```
[User] → [Diamond Proxy] → [Facet A]
                         → [Facet B]
                         → [Facet C]
         [DiamondLoupe] (inspection)
```
- Multiple implementation contracts (facets) with shared storage
- Bypasses 24KB contract size limit
- **Risk**: Storage collision between facets; high complexity
- **Use when**: Protocol exceeds size limit; intentionally modular architecture
- **Critical**: Use DiamondStorage or named storage structs to prevent collision

### Pattern 4: Immutable Core + Upgradeable Periphery
```
[Immutable Vault Core] ← no upgrade risk
         ↑
[Upgradeable Strategy] ← can be swapped via governance
[Upgradeable Fee Model] ← adjustable parameters
```
- Core invariants (asset custody) are immutable
- Periphery (yield strategies, fee distribution) can evolve
- **Best practice for DeFi**: Maximum security on what matters most
- **Use when**: High-value vaults, lending pools, core settlement logic

### Storage Upgrade Safety
Always use ERC-1967 storage slots for proxy variables. Never use slot 0-9 in implementations.
When adding storage in upgrades:

```solidity
// CORRECT: append only, never reorder
contract V1 {
    uint256 public totalSupply;  // slot 0
    mapping(address => uint256) public balances;  // slot 1
}

contract V2 is V1 {
    uint256 public newField;  // slot 2 — SAFE, appended
    // uint256 public totalSupply;  // NEVER move existing fields
}

// CORRECT: Named storage pattern for Diamond
bytes32 constant VAULT_STORAGE = keccak256("vault.storage.v1");
struct VaultStorage {
    uint256 totalAssets;
    mapping(address => uint256) shares;
}
function _vaultStorage() internal pure returns (VaultStorage storage vs) {
    bytes32 slot = VAULT_STORAGE;
    assembly { vs.slot := slot }
}
```

---

## Access Control Architecture

### Levels of Access Control

**Level 1: Ownable** (simple, high-risk)
- Single owner address; single point of failure
- Acceptable only for non-critical admin functions in small protocols
- Never use for protocols with > $1M TVL without a multi-sig

**Level 2: Ownable + Timelock**
- All admin actions queued for N days before execution
- Users can exit before malicious or mistaken changes take effect
- Minimum: 24h for parameter changes; 48-72h for upgrades

**Level 3: Role-Based Access Control (RBAC)**
```solidity
bytes32 constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
bytes32 constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
bytes32 constant HARVESTER_ROLE = keccak256("HARVESTER_ROLE");

// Separate roles for separate capabilities — principle of least privilege
// UPGRADER should be a multi-sig with timelock
// PAUSER should be able to act quickly (circuit breaker)
// HARVESTER can be an automated keeper
```

**Level 4: RBAC + Governance + Timelock (production standard)**
```
[Governance Token Holders]
          ↓
    [Governor Contract] — 4 day proposal period
          ↓
    [Timelock Controller] — 2 day delay
          ↓
    [Protocol Contracts]
```

### Access Control Anti-Patterns (Never Do This)
```solidity
// BAD: tx.origin check
require(tx.origin == owner);  // bypassed by contract calls, phishing

// BAD: msg.sender in constructor not captured correctly
constructor() { owner = msg.sender; }  // OK if not upgradeable, BAD in proxy (owner = proxy deployer)

// BAD: Unprotected initializer
function initialize() public { ... }  // can be front-run; ALWAYS use initializer modifier

// BAD: Implicit access (no modifier, forgot require)
function setFee(uint256 fee) external {  // missing access control
    _fee = fee;
}

// BAD: Default admin role too broadly distributed
_grantRole(DEFAULT_ADMIN_ROLE, msg.sender);  // creates unlimited role granter
```

---

## Storage Design Patterns

### Struct Packing
```solidity
// INEFFICIENT: 3 storage slots
struct Position {
    uint256 collateral;   // slot 0 (32 bytes)
    uint128 debt;         // slot 1 (16 bytes, new slot due to uint256 above)
    uint128 lastUpdate;   // slot 1 (shares with debt — packed correctly)
    address owner;        // slot 2 (20 bytes)
    bool isActive;        // slot 2 (packed with owner)
}

// EFFICIENT: pack small types together
struct Position {
    uint256 collateral;   // slot 0
    uint128 debt;         // slot 1: 16 bytes
    uint64 lastUpdate;    // slot 1: 8 bytes (fits with debt)
    bool isActive;        // slot 1: 1 byte (fits)
    address owner;        // slot 2: 20 bytes
    // 12 bytes remaining in slot 2 — available for future fields
}
```

### Transient Storage (EIP-1153, Solidity 0.8.24+)
For reentrancy locks and per-transaction state — much cheaper than SSTORE:
```solidity
// TSTORE/TLOAD — cleared at end of transaction, gas ~100 vs 20,000
uint256 private transient _locked;
modifier nonReentrant() {
    require(_locked == 0, "Reentrant");
    _locked = 1;
    _;
    _locked = 0;
}
```

### Mappings vs Arrays
- **Mappings**: O(1) access, no length, no iteration — prefer for balances, allowances, positions
- **Arrays**: Iterable, but O(n) operations are gas traps — use only with bounded length
- **Enumerable sets** (OpenZeppelin): Pay the gas cost consciously; document the bound

### Storage Layout Documentation
Every contract should have an explicit storage layout comment:
```solidity
/**
 * @dev Storage layout (DO NOT REORDER for upgradeable contracts):
 * Slot 0: totalSupply (uint256)
 * Slot 1: balances mapping (mapping(address=>uint256))
 * Slot 2: allowances mapping (mapping(address=>mapping(address=>uint256)))
 * Slot 3: _paused (bool, 1 byte), _initialized (uint8, 1 byte) — packed
 * Slots 4-50: __gap reserved for future use
 */
uint256[47] private __gap;  // Always include gap in upgradeable contracts
```

---

## DeFi Protocol Architecture Patterns

### Vault (ERC-4626 Standard)
```
Core Invariants:
  totalAssets() == sum(all deposits) + yield accrued - fees taken
  convertToAssets(convertToShares(x)) == x (within rounding)
  
Attack Surfaces:
  - Inflation attack (first depositor): use virtual shares/assets offset
  - Sandwich on harvest: use internal price updates or access-controlled harvest
  - Rebasing token: validate totalAssets() after external yield calls
  
Key Design:
  - Separate yield accounting from user accounting
  - Define rounding direction (round down for users, up for protocol — ERC-4626)
  - Test edge case: single-wei deposit, max uint deposit
```

### AMM (Constant Product / Curve / Concentrated Liquidity)
```
Core Invariants:
  k = reserve0 * reserve1 must increase or hold after swaps (with fee)
  LP shares proportional to pool contribution at time of deposit
  
Attack Surfaces:
  - Price manipulation via large swap before oracle read (TWAP mitigates)
  - LP sandwich (JIT liquidity, MEV)
  - Fee rounding exploitation
  - Imbalanced pool drain with exotic tokens (fee-on-transfer)
  
Key Design:
  - Minimum liquidity (lock MINIMUM_LIQUIDITY on first deposit)
  - TWAP oracle with cardinality tuning
  - Separate fee accumulation from price calculation
  - Flash swap callbacks must validate k invariant at end
```

### Lending Protocol
```
Core Invariants:
  collateral_value * LTV >= debt_value for all non-liquidatable positions
  total_borrows <= total_liquidity_supplied
  Interest rate model produces rates that disincentivize 100% utilization
  
Attack Surfaces:
  - Oracle manipulation for liquidation or borrow size
  - Interest accrual manipulation (time skipping in tests)
  - Collateral whitelisting and correlation risks
  - Liquidation incentive that's too low (undercollateralized) or too high (bad debt)
  
Key Design:
  - Isolation mode for new/risky collateral types
  - Circuit breakers on utilization rate
  - Bad debt socialization mechanism
  - Health factor buffer above liquidation threshold
```

### Governance / DAO
```
Core Invariants:
  Proposal must meet quorum to be executable
  Time-lock delay enforced between pass and execution
  Voting power snapshot at proposal creation block (anti-flash-loan)
  
Attack Surfaces:
  - Governance flash loan (borrow voting power, pass proposal, repay)
  - Low quorum + low participation = whale takeover
  - Malicious calldata in proposal execution
  - Proposal spam (front-running, griefing)
  
Key Design:
  - Voting snapshot at proposal start (not current block)
  - Proposal threshold (cost to create proposal)
  - Timelock as final safety layer
  - Guardian role for emergency veto (with sunset clause)
```

---

## Cross-Contract Interaction Patterns

### Safe External Call Patterns
```solidity
// PREFER: Return value checking with SafeERC20
using SafeERC20 for IERC20;
token.safeTransfer(recipient, amount);  // reverts on false/no-return

// PREFER: Low-level call with return value validation
(bool success, bytes memory returnData) = target.call(calldata);
require(success, "Call failed");
// Validate returnData if expecting specific output

// AVOID: Blind transfer()
payable(recipient).transfer(amount);  // 2300 gas limit; breaks with smart contract recipients

// PREFER for ETH: call with gas forwarding
(bool success,) = recipient.call{value: amount}("");
require(success, "ETH transfer failed");
```

### Interface Trust Levels
Define and document the trust level of every external contract:
```
TRUSTED (same team, audited):     Can receive callbacks without full reentrancy guard
SEMI-TRUSTED (audited external):  Validate return values; guard against interface changes
UNTRUSTED (user-supplied):        Assume adversarial; full reentrancy guard; validate all outputs
```

### Token Integration Checklist
Before integrating any ERC-20 token:
- [ ] Does it have transfer hooks? (ERC-777, ERC-1363)
- [ ] Does it have fee-on-transfer? (measure balance delta, not return value)
- [ ] Is it rebasing? (balances change without transfer events)
- [ ] Can it be paused? (transfers might revert mid-protocol)
- [ ] Does it return false instead of reverting? (use SafeERC20)
- [ ] Is the decimals value what you expect? (USDC is 6, WETH is 18)
- [ ] Can the deployer blacklist addresses? (USDC, USDT compliance)
