# 06 — Gas & Performance Optimization

**First rule of gas optimization: Don't optimize prematurely.**
Profile first. Optimize only after correctness and security are verified.
A gas-optimized but insecure contract is worse than a secure but slightly expensive one.

---

## The Optimization Hierarchy

```
1. Architecture-level (highest impact, must be decided early)
   - Use calldata instead of memory for read-only params
   - Batch operations to amortize fixed costs
   - Off-chain computation where possible

2. Storage-level (second highest impact)
   - Struct packing to reduce slots
   - Avoid unnecessary SSTORE
   - Use events instead of storage for historical data

3. Computation-level (moderate impact)
   - Unchecked arithmetic in safe contexts
   - Short-circuit evaluation
   - Cache storage reads in local variables

4. Assembly-level (marginal, high risk)
   - Inline assembly for hot paths only
   - Only if team can audit assembly safely
```

---

## Storage Optimization (Highest Impact)

### The Gas Cost of Storage
```
SSTORE (cold, new value):    20,000 gas
SSTORE (warm, update):        2,900 gas
SSTORE (clear to zero):      -4,800 gas refund (max 1/5 of tx gas)
SLOAD (cold):                 2,100 gas
SLOAD (warm):                   100 gas
```

### Slot Packing
```solidity
// 3 slots (INEFFICIENT):
uint256 a;     // slot 0: 32 bytes
uint128 b;     // slot 1: 16 bytes (can't pack with uint256)
uint128 c;     // slot 2: 16 bytes (new slot)

// 2 slots (EFFICIENT):
uint256 a;     // slot 0: 32 bytes
uint128 b;     // slot 1: 16 bytes
uint128 c;     // slot 1: packed with b (16 bytes)

// 1 slot (OPTIMAL for small structs):
struct Config {
    uint64 lastUpdate;   // 8 bytes
    uint64 fee;          // 8 bytes  ← packed
    uint64 cooldown;     // 8 bytes  ← packed
    bool paused;         // 1 byte   ← packed
    // Total: 25 bytes → 1 slot
}
```

### Caching Storage Variables
```solidity
// BAD: multiple SLOADs in a loop
function totalRewards() public view returns (uint256 total) {
    for (uint256 i; i < stakers.length; i++) {
        total += (block.timestamp - lastClaim[stakers[i]]) * rewardRate;  // SLOAD rewardRate every iteration
    }
}

// GOOD: cache once
function totalRewards() public view returns (uint256 total) {
    uint256 _rewardRate = rewardRate;  // Single SLOAD, then stack reads
    uint256 _timestamp = block.timestamp;
    for (uint256 i; i < stakers.length; i++) {
        total += (_timestamp - lastClaim[stakers[i]]) * _rewardRate;
    }
}
```

### Events vs Storage for History
```solidity
// BAD: storing historical data on-chain
struct TransferRecord {
    address from;
    address to;
    uint256 amount;
    uint256 timestamp;
}
TransferRecord[] public history;  // Expensive; nobody needs this on-chain

// GOOD: emit events; index off-chain
event Transfer(address indexed from, address indexed to, uint256 amount);
// Indexers (The Graph, Dune) handle historical queries
```

---

## Calldata Optimization

```solidity
// BAD: memory for read-only array param
function processItems(uint256[] memory items) external { ... }
// memory: copies to new memory area (extra gas)

// GOOD: calldata for read-only
function processItems(uint256[] calldata items) external { ... }
// calldata: reads directly from call data area, no copy
// Rule: always use calldata for external function array/struct params you don't modify
```

---

## Unchecked Arithmetic

```solidity
// Solidity 0.8+ adds overflow checks — gas cost is non-trivial in loops
// When PROVABLY SAFE (e.g., loop counter that can't overflow):
for (uint256 i; i < arr.length;) {
    // ...
    unchecked { ++i; }  // i < arr.length proves no overflow; saves ~40 gas/iter
}

// Subtraction when PROVABLY non-underflowing:
unchecked {
    uint256 remaining = total - used;  // Only safe if you've already checked total >= used
}

// NEVER use unchecked without a proof of safety
// NEVER use unchecked on user-supplied arithmetic
```

---

## Common Gas Patterns

### Mapping vs Array
```solidity
// For balances/state: mapping (O(1) access)
mapping(address => uint256) balances;  // 1 SLOAD per access

// For enumeration: EnumerableSet (but pays gas for iteration capability)
// Only add iteration if you actually need to iterate on-chain
```

### Short-Circuit Evaluation
```solidity
// Put cheapest checks first
require(amount > 0 && token.balanceOf(msg.sender) >= amount);
// If amount == 0, skip the SLOAD for balanceOf

// For modifier order: cheapest modifiers first
function sensitive() external onlyNotPaused onlyWhitelisted onlyRole(OPERATOR_ROLE) {
    // onlyNotPaused (1 SLOAD) before onlyRole (1-2 SLOADs + keccak)
}
```

### Custom Errors Save Gas
```solidity
revert InsufficientBalance(available, requested);  // ~200 gas less than require string
// At scale across many reverts: meaningful savings in complex protocols
```

### Immutables vs Constants vs Storage
```solidity
// Gas cost: constants ≈ immutables (inlined at compile time) << storage variables

uint256 public constant MAX_FEE = 1000;     // FREE — inlined at compile
address public immutable asset;              // FREE after constructor — inlined
address public mutableAdmin;                 // 2,100 gas cold SLOAD each read

// Rule: if a value doesn't change, make it constant or immutable
```

---

## When NOT to Optimize

**Do not micro-optimize if:**
- The contract handles security-critical logic (clarity > gas)
- The optimization makes code harder to audit
- The savings are < 1% of total transaction cost
- The optimization pattern is unfamiliar to your team

**Always prioritize:**
```
Correctness > Security > Readability > Gas efficiency
```

Gas is a recurring operating cost. An exploit is a catastrophic one-time cost.
Every optimization that makes an audit harder should be questioned.

---

## Gas Profiling with Foundry

```bash
# Snapshot gas costs
forge snapshot

# Compare against previous snapshot
forge snapshot --diff .gas-snapshot

# Profile specific test
forge test --match-test testDeposit -vv --gas-report
```

Use gas reports before and after optimization to validate actual savings.
Document every optimization with a comment explaining why it's safe.
