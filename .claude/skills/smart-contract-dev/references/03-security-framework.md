# 03 — Security Framework & Audit Methodology

Security in smart contracts is not a feature — it is the foundation. This module provides a
systematic framework for both building secure contracts and conducting rigorous security reviews.

---

## Vulnerability Taxonomy (Deep Reference)

### 1. Reentrancy

**Classic (Single-Function)**
```solidity
// VULNERABLE:
function withdraw(uint256 amount) external {
    require(balances[msg.sender] >= amount);
    (bool success,) = msg.sender.call{value: amount}("");  // External call BEFORE state update
    require(success);
    balances[msg.sender] -= amount;  // State update AFTER — attacker re-enters before this
}

// FIXED: Checks-Effects-Interactions
function withdraw(uint256 amount) external nonReentrant {
    require(balances[msg.sender] >= amount);
    balances[msg.sender] -= amount;  // Effect FIRST
    (bool success,) = msg.sender.call{value: amount}("");  // Interaction LAST
    require(success);
}
```

**Cross-Function Reentrancy**: State is valid in function A but function B reads stale state during A's execution.
**Read-Only Reentrancy**: Attacker reenters a view function to read inconsistent state (used by oracle-dependent contracts).
**Cross-Contract Reentrancy**: Contract A → External → Contract B reads from Contract A while it's mid-execution.

**Defense**: CEI strictly + `nonReentrant` modifier on all external-call-containing functions.
Consider transient storage locks for gas efficiency (EIP-1153).

---

### 2. Integer Arithmetic Issues

**Overflow/Underflow** (pre-0.8 Solidity):
```solidity
// Use Solidity 0.8+ or OpenZeppelin SafeMath for older versions
uint256 x = type(uint256).max;
x + 1;  // OVERFLOW → 0 (pre-0.8)
```

**Precision Loss / Rounding**:
```solidity
// DANGEROUS: Division before multiplication
uint256 fee = (amount / 1000) * 3;  // Truncation compounds

// CORRECT: Multiply first, divide last
uint256 fee = (amount * 3) / 1000;

// ROUNDING DIRECTION matters in DeFi:
// Round in FAVOR of protocol (not user) for security:
// - When minting shares: round DOWN shares given to user
// - When redeeming assets: round DOWN assets given to user
// This prevents share inflation attacks and precision drain
```

**Casting Truncation**:
```solidity
uint256 bigNumber = type(uint256).max;
uint128 truncated = uint128(bigNumber);  // SILENT TRUNCATION — use SafeCast

// CORRECT:
import "@openzeppelin/contracts/utils/math/SafeCast.sol";
uint128 safe = SafeCast.toUint128(bigNumber);  // Reverts if overflow
```

**Phantom Overflow** (mulDiv):
```solidity
// DANGEROUS: intermediate overflow
uint256 result = (a * b) / c;  // a*b might overflow uint256

// CORRECT: Use mulDiv with overflow protection
result = Math.mulDiv(a, b, c);  // 512-bit intermediate, safe
```

---

### 3. Access Control Failures

**Unprotected Initializer** (critical in proxy patterns):
```solidity
// VULNERABLE: Attacker deploys proxy pointing to this, calls initialize
function initialize(address admin) public {
    require(!initialized);
    _admin = admin;
    initialized = true;
}

// FIXED: Use OpenZeppelin Initializable with onlyInitializing
function initialize(address admin) public initializer {
    __Ownable_init(admin);
}
// Also: disable initializers in implementation constructor
constructor() { _disableInitializers(); }
```

**Function Visibility Errors**:
```solidity
// DANGEROUS: internal function marked public
function _mintTokens(address to, uint256 amount) public { ... }  // anyone can call!

// RULE: Always explicitly state visibility; default to private/internal
```

**Missing Zero Address Checks**:
```solidity
// DANGEROUS:
function setAdmin(address newAdmin) external onlyAdmin {
    admin = newAdmin;  // Can be set to zero — permanently bricked
}

// FIXED:
function setAdmin(address newAdmin) external onlyAdmin {
    require(newAdmin != address(0), "Zero address");
    admin = newAdmin;
}
```

---

### 4. Oracle Manipulation

**Spot Price Manipulation**:
```
Attack:
  1. Flash loan → large swap in AMM pool (manipulate spot price)
  2. Protocol reads spot price → grants over-collateralized borrow or large liquidation
  3. Repay flash loan

Defense:
  - TWAP (Time-Weighted Average Price) with sufficient period (1 hour minimum)
  - Chainlink with staleness check + heartbeat monitoring
  - Multi-oracle median with deviation check
  - Circuit breaker: reject price updates deviating > X% from last
```

**Chainlink Integration Checklist**:
```solidity
(
    uint80 roundId,
    int256 price,
    uint256 startedAt,
    uint256 updatedAt,
    uint80 answeredInRound
) = priceFeed.latestRoundData();

require(price > 0, "Invalid price");
require(updatedAt >= block.timestamp - MAX_STALENESS, "Stale price");  // e.g. 1 hours
require(answeredInRound >= roundId, "Incomplete round");

// Sequencer uptime check for L2 deployments:
// Chainlink L2 Sequencer Feed must show uptime > GRACE_PERIOD after restart
```

---

### 5. Front-Running & MEV

**Transaction Ordering Exploitation**:
```
Sandwich Attack:
  1. Searcher sees large swap in mempool
  2. Searcher front-runs with buy (price increases)
  3. Victim's swap executes at worse price
  4. Searcher back-runs with sell

Defenses:
  - Slippage tolerance: revert if price moves > N% (user-controlled)
  - Deadline: revert if tx not mined by block N
  - Private mempool (Flashbots Protect, MEV Blocker)
  - Commit-reveal scheme for sensitive operations
```

**Approve Front-Run** (ERC-20 allowance race):
```solidity
// DANGEROUS: User approves 100, attacker sees it, spends old 50 + new 100
approve(spender, 100);  // If previous allowance is non-zero

// FIXED: Use increaseAllowance/decreaseAllowance OR
// always set allowance to 0 first, then to new value
// OR use permit() (EIP-2612) for off-chain approvals
```

---

### 6. Signature Security

**Replay Attacks**:
```solidity
// DANGEROUS: No nonce, no chain ID, no expiry
function execute(bytes32 hash, bytes memory sig) external {
    address signer = hash.recover(sig);
    require(signer == authorized, "Bad sig");
    // Attackable: same signature replayable on any chain, any time
}

// CORRECT: EIP-712 structured data with nonce + chainId + expiry
struct PermitData {
    address owner;
    address spender;
    uint256 value;
    uint256 nonce;
    uint256 deadline;
}
// Include: DOMAIN_SEPARATOR with chainId, contract address, version
// Nonces: per-user, strictly increasing (or unordered with EIP-3009)
// Deadline: always enforce block.timestamp <= deadline
```

**Signature Malleability**:
```solidity
// DANGEROUS: Raw ecrecover — malleable signatures (s-value)
address signer = ecrecover(hash, v, r, s);

// FIXED: Use OpenZeppelin ECDSA library
address signer = ECDSA.recover(hash, signature);  // Validates s in lower half
```

---

### 7. Denial of Service (DoS)

**Unbounded Loops**:
```solidity
// DANGEROUS: Loops over user-controlled arrays
function distributeDividends() external {
    for (uint256 i = 0; i < users.length; i++) {  // Gas bomb if users.length grows
        token.transfer(users[i], dividends[users[i]]);
    }
}

// FIXED: Pagination + pull pattern
mapping(address => uint256) public pendingDividends;
function claimDividend() external {  // User pulls their own dividend
    uint256 amount = pendingDividends[msg.sender];
    pendingDividends[msg.sender] = 0;
    token.transfer(msg.sender, amount);
}
```

**ETH Receiver Griefing** (push pattern):
```solidity
// DANGEROUS: If one recipient reverts, entire distribution fails
function distributeETH(address[] calldata recipients) external {
    for (address r : recipients) {
        r.transfer(share);  // Any reverting recipient bricks the loop
    }
}
// FIXED: Pull pattern; record balances, let users withdraw
```

**Block Gas Limit Attacks**: Any O(n) operation where n is user-controlled is a griefing vector.
Always design O(1) per-user operations.

---

### 8. Economic & Flash Loan Attacks

**Price Oracle Manipulation** (covered above)

**Governance Flash Loan**:
```
Attack: Borrow voting tokens → create proposal → vote → execute → repay
Defense: Vote power snapshots taken at proposal creation block (not current)
         Delegation with lock periods
         Minimum voting delay (so you can't create + pass in one block)
```

**Liquidity Drain via Invariant Rounding**:
```
Scenario: ERC-4626 inflation attack
  1. First depositor deposits 1 wei → gets 1 share
  2. Attacker donates 1e18 assets to vault
  3. Second depositor deposits 1.9e18 assets → gets 1 share (rounds down)
  4. Attacker redeems their 1 share → receives half of all assets

Defense:
  - Virtual shares/assets: add offset to prevent first-depositor manipulation
  - OpenZeppelin ERC-4626 _decimalsOffset() for virtual amount
  - Alternatively: transfer initial liquidity into "dead" address
```

**Profitable Liquidation at Bad Debt**:
```
Ensure liquidation incentive < liquidation penalty gap
If protocol allows liquidation at 105% bonus with 102% collateral, bad debt is created
Circuit breaker: cap liquidation size to maintain protocol solvency
```

---

## Audit Methodology (Systematic Process)

### Phase 1: Reconnaissance (2-4 hours)
```
□ Read all documentation (whitepaper, README, NatSpec)
□ Understand the protocol's purpose and value proposition
□ Identify all actors and their incentives
□ Map contract architecture (inheritance, composition)
□ Identify all assets held and entry/exit points
□ Enumerate all external dependencies (oracles, tokens, protocols)
□ Note: deployment scripts, admin configuration, initial state
```

### Phase 2: Invariant Extraction (2-4 hours)
```
□ Write down every invariant you can derive from documentation
□ Verify invariants are actually enforced in code
□ Identify invariants that are ASSUMED but NOT enforced
□ For each invariant: write a test that would fail if violated
□ Flag every place where invariants could theoretically be broken
```

### Phase 3: Systematic Line-by-Line Review
For every function, evaluate:
```
□ Access control: who can call this? Under what conditions?
□ Input validation: what inputs are accepted? What are rejected?
□ State transitions: what state changes? Is it always safe?
□ External calls: what is called? What are the trust assumptions?
□ Return values: are all return values checked?
□ Arithmetic: can any operation overflow? Underflow? Lose precision?
□ Events: are all state changes logged?
□ Edge cases: zero, max, first user, last user
```

### Phase 4: Attack Scenario Construction
For each vulnerability category, construct concrete attack scenarios:
```
For each finding:
  1. Write a proof-of-concept (PoC) that reproduces it
  2. Calculate maximum extractable value (MEV/damage)
  3. Determine preconditions (capital required, permissions needed)
  4. Classify: Critical / High / Medium / Low / Info
  5. Propose fix and verify fix actually addresses root cause
```

### Phase 5: Systemic & Economic Analysis
```
□ Are there economic incentive misalignments?
□ Can the protocol be drained profitably by a rational actor?
□ Under what market conditions does the protocol become insolvent?
□ Is the governance system resistant to capture?
□ What are the centralization risks?
□ Are there any trust-but-verify assumptions that are actually unverified?
```

### Finding Classification
| Severity | Criteria |
|----------|----------|
| **Critical** | Direct loss of user funds; protocol compromise with no prerequisite |
| **High** | Significant loss of funds under realistic conditions; invariant violation |
| **Medium** | Partial loss / temporary DoS / invariant violation under specific conditions |
| **Low** | Best practice violations; non-exploitable but indicative of poor hygiene |
| **Info** | Code quality; documentation; gas efficiency; design suggestions |

---

## Security Checklist (Pre-Deployment)

**Access Control**
- [ ] All privileged functions protected with correct access control
- [ ] No unprotected initializers
- [ ] Multi-sig for all admin/upgrade roles
- [ ] Timelock on parameter changes and upgrades

**Arithmetic & Data**
- [ ] Solidity 0.8+ or explicit overflow protection
- [ ] All type casts use SafeCast or validated explicitly
- [ ] Division and multiplication order checked (multiply first)
- [ ] Rounding direction explicitly chosen and documented

**External Interactions**
- [ ] All external calls follow CEI or use reentrancy guard
- [ ] All external call return values checked
- [ ] Token integrations handle fee-on-transfer and rebasing
- [ ] Oracle staleness checked; sequencer uptime checked for L2

**Signatures**
- [ ] EIP-712 domain separator with chainId + contract address
- [ ] Nonces implemented and checked
- [ ] Deadlines enforced
- [ ] ECDSA.recover used (not raw ecrecover)

**Protocol Logic**
- [ ] All invariants have corresponding tests
- [ ] Flash loan attack scenarios tested
- [ ] Front-running scenarios analyzed
- [ ] DoS via gas limits analyzed
- [ ] Economic incentive alignment verified
