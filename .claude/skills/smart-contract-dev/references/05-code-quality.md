# 05 — Code Quality, Style, and Review Standards

Code quality is not aesthetics — it is the prevention of bugs through clarity, and the enablement
of effective review. In smart contracts, unclear code kills money. This module covers professional
Solidity style, documentation, error handling, and the complete code review checklist.

---

## Solidity Style Standards

### File & Contract Organization
```
Layout within a contract (in this order):
  1. Type declarations (enums, structs)
  2. State variables
  3. Events
  4. Custom errors
  5. Modifiers
  6. Constructor / initialize
  7. External functions
  8. Public functions
  9. Internal functions
  10. Private functions
  11. View / pure functions (each tier: external, public, internal, private)

File header:
  // SPDX-License-Identifier: MIT
  pragma solidity ^0.8.20;
  
  import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
  import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
  // Named imports always — never `import * from "..."`
```

### Naming Conventions
```solidity
// Contracts: PascalCase
contract LiquidityPool { }

// Functions: camelCase
function addLiquidity(uint256 amount) external { }

// Internal/private: prefixed with underscore
function _calculateShares(uint256 assets) internal view returns (uint256) { }

// Constants: SCREAMING_SNAKE_CASE
uint256 public constant MAX_FEE = 1000;  // basis points
bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

// Immutables: camelCase (they're like special variables)
address public immutable asset;

// Storage variables: camelCase
uint256 public totalSupply;
mapping(address => uint256) private _balances;

// Events: PascalCase (noun-verb form)
event LiquidityAdded(address indexed provider, uint256 amount, uint256 shares);
event FeeCollected(address indexed recipient, uint256 amount);

// Custom errors: PascalCase, descriptive
error InsufficientBalance(uint256 requested, uint256 available);
error UnauthorizedCaller(address caller);
error DeadlineExpired(uint256 deadline, uint256 currentTime);
```

---

## NatSpec Documentation (Mandatory for All Public Interfaces)

NatSpec is not optional — it is how auditors, integrators, and future engineers understand your
protocol without reading every line of implementation.

```solidity
/// @title Minimal ERC-4626 Vault
/// @author ProtocolTeam
/// @notice A tokenized vault that earns yield on deposited assets
/// @dev Implements ERC-4626 with virtual shares to prevent inflation attacks.
///      All share accounting rounds DOWN to protect vault solvency.
contract Vault is ERC4626, Ownable, ReentrancyGuard {

    /// @notice Maximum fee the protocol can charge, in basis points
    /// @dev 1000 = 10%. Hardcoded as a security boundary.
    uint256 public constant MAX_FEE = 1000;

    /// @notice Deposit assets and receive vault shares in return
    /// @param assets The amount of underlying tokens to deposit
    /// @param receiver The address that receives the minted shares
    /// @return shares The number of shares minted to receiver
    /// @dev Follows CEI pattern. Shares are minted before transfer to prevent
    ///      reentrancy from exploiting stale share price.
    ///      Reverts if receiver is address(0) or assets is 0.
    function deposit(
        uint256 assets,
        address receiver
    ) public override nonReentrant returns (uint256 shares) {
        ...
    }

    /// @notice Emergency pause — stops all deposits and withdrawals
    /// @dev Only callable by PAUSER_ROLE. Does not affect accrued yield.
    ///      State: ACTIVE → PAUSED
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
        emit EmergencyPause(msg.sender, block.timestamp);
    }
}
```

---

## Custom Errors (Always Prefer Over Require Strings)

```solidity
// BAD: string errors
require(amount > 0, "Amount must be positive");                // 3x more gas; no params
require(msg.sender == owner, "Not authorized");               // No context in error

// GOOD: custom errors with context
error InvalidAmount(uint256 provided);
error Unauthorized(address caller, bytes32 requiredRole);
error SlippageExceeded(uint256 expected, uint256 actual, uint256 maxSlippage);

// Usage:
if (amount == 0) revert InvalidAmount(amount);
if (!hasRole(role, msg.sender)) revert Unauthorized(msg.sender, role);
```

Custom errors: ~3x cheaper to deploy and revert with; more informative for debugging.

---

## Event Design

Events are the permanent, queryable history of your protocol. Design them thoughtfully.

### What Must Always Be Logged
```solidity
// Log ALL state changes:
event Transfer(address indexed from, address indexed to, uint256 value);
event Approval(address indexed owner, address indexed spender, uint256 value);
event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);
event Withdraw(address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares);
event ParameterUpdated(bytes32 indexed paramName, uint256 oldValue, uint256 newValue);
event RoleGranted(bytes32 indexed role, address indexed account, address indexed sender);
event EmergencyPause(address indexed caller, uint256 timestamp);
```

### Indexing Strategy
```solidity
// Index: addresses you'll filter by (up to 3 indexed per event)
event Trade(
    address indexed maker,      // indexed: query "all trades by maker"
    address indexed taker,      // indexed: query "all trades with taker"
    address indexed tokenIn,    // indexed: query "all trades involving token"
    uint256 amountIn,           // not indexed: just data
    uint256 amountOut           // not indexed: just data
);

// Indexed = keccak256'd in topic — only useful for equality filter
// Don't index: amounts (range queries on-chain are impossible anyway)
// Do index: addresses, enums, IDs
```

### Old vs New Values
For parameter updates, always emit both old and new:
```solidity
function setFee(uint256 newFee) external onlyOwner {
    require(newFee <= MAX_FEE, "Fee too high");
    uint256 oldFee = fee;
    fee = newFee;
    emit FeeUpdated(oldFee, newFee);  // Not just FeeUpdated(newFee)
}
```

---

## Modifier Design

```solidity
// GOOD: simple guard modifiers
modifier onlyOwner() {
    if (msg.sender != owner) revert Unauthorized(msg.sender);
    _;
}

modifier whenNotPaused() {
    if (paused) revert ContractPaused();
    _;
}

modifier validAmount(uint256 amount) {
    if (amount == 0) revert InvalidAmount(0);
    _;
}

// BAD: logic-heavy modifiers — hard to audit, hide bugs
modifier complexModifier() {
    // Lots of state reads and complex logic here
    // Nobody reviews this carefully
    _;
    // Side effects after execution — confusing
}
// RULE: Modifiers should be guards only (checks). 
// Put logic in functions, not modifiers.
```

---

## Dangerous Patterns to Always Avoid

### Silent Failure
```solidity
// NEVER: ignore return values
token.transfer(recipient, amount);          // Returns bool; failure is silent
token.approve(spender, amount);             // Same

// ALWAYS: use SafeERC20 or check
token.safeTransfer(recipient, amount);      // Reverts on failure
bool ok = token.transfer(recipient, amount);
require(ok, "Transfer failed");             // Manual check
```

### Comparing Floating-Point-Like Values
```solidity
// DANGEROUS: exact equality for token balances
require(token.balanceOf(vault) == expectedBalance);  // Dust amounts will break this
// CORRECT: use >= or tolerate dust
require(token.balanceOf(vault) >= expectedBalance);
```

### Boolean Return Values on Transfer
```solidity
// Some tokens return false instead of reverting (USDT on some chains)
// SafeERC20 handles this — always use it for unknown tokens
```

### Magic Numbers
```solidity
// BAD: meaningless numbers in code
uint256 fee = (amount * 30) / 10000;   // What is 30? What is 10000?

// GOOD: named constants with documentation
uint256 constant FEE_BPS = 30;         // 0.30% base fee
uint256 constant BPS_DENOMINATOR = 10_000;
uint256 fee = (amount * FEE_BPS) / BPS_DENOMINATOR;
```

### Timestamp Dependence
```solidity
// DANGEROUS: block.timestamp for randomness or fine-grained timing
require(block.timestamp % 2 == 0);  // Miner-influenceable

// ACCEPTABLE: block.timestamp for deadlines (miner influence is bounded to ~15s)
require(block.timestamp <= deadline, "Expired");

// FOR RANDOMNESS: use Chainlink VRF or commit-reveal scheme
```

---

## Code Review Checklist (Complete)

**Before submitting any PR for review, the author must verify:**

**Correctness**
- [ ] All functions implement spec behavior, not just "close enough"
- [ ] Edge cases (zero, max, empty array, first/last user) explicitly handled
- [ ] Return values are correct and documented
- [ ] State is consistent before and after every external call

**Security**
- [ ] CEI pattern followed in every function with external calls
- [ ] `nonReentrant` on all external-call-containing state-changing functions
- [ ] All external call return values checked
- [ ] Access control on every function (explicit, not assumed)
- [ ] No address(0) can become owner/admin/recipient without check
- [ ] SafeERC20 used for all token transfers
- [ ] No tx.origin for authorization

**Documentation**
- [ ] NatSpec on all public/external functions
- [ ] Inline comments on non-obvious logic
- [ ] Storage layout comment on upgradeable contracts
- [ ] All invariants documented with `@dev Invariant:` comments

**Code Quality**
- [ ] No magic numbers — all constants named
- [ ] No dead code (commented-out blocks, unused variables)
- [ ] Function names accurately describe behavior
- [ ] No silent failures — all operations revert loudly on error
- [ ] Custom errors used (not require strings)

**Testing**
- [ ] New code has corresponding unit tests
- [ ] Revert conditions tested
- [ ] Fuzz tests for functions with numeric inputs
- [ ] Invariants still hold (invariant tests pass)
- [ ] Gas snapshot updated if significant changes
