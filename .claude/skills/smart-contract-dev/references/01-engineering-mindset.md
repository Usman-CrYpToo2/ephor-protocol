# 01 — Engineering Mindset & Analytical Framework

The single biggest differentiator between a junior and elite smart contract engineer is not syntax
knowledge — it is the quality of thought before any code is written. This module covers the mental
models, analytical processes, and decision frameworks used by top blockchain engineers.

---

## Phase 0: Requirements Analysis

### The Specification Contract
Before code, write a specification. A specification is not a readme — it is a formal (or semi-formal)
contract between the engineer and the system. It must answer:

```
ACTORS:       Who interacts with this system? What are their incentives?
ASSETS:       What value does the system hold or move?
OPERATIONS:   What can each actor do? Under what conditions?
INVARIANTS:   What is always true, regardless of operation order?
CONSTRAINTS:  What is explicitly forbidden?
LIFECYCLE:    How does this system change over time?
```

**Red flag**: Engineers who start coding before they can write two pages of spec are building on
sand. Require — and write — the spec first.

### Functional vs Security Requirements
Distinguish these explicitly:

| Functional | Security |
|-----------|----------|
| Users can deposit ERC-20 tokens | Users cannot withdraw more than they deposited |
| Governance can set fees | Governance cannot set fees higher than 50% in one tx |
| Protocol earns yield on idle assets | Yield strategy cannot drain principal |

Security requirements are often **implicit negations** of functional requirements. Making them
explicit is the foundation of invariant design.

---

## Phase 1: Invariant-First Design

Invariants are the **immutable laws of your protocol**. They must hold:
- After every state-changing function
- Under any ordering of transactions
- With any combination of inputs (including malicious ones)
- Including reentrancy scenarios

### Categories of Invariants

**1. Conservation Invariants** (most critical for financial protocols)
```
sum(all_user_shares) == total_shares_outstanding
sum(all_deposits) - sum(all_withdrawals) == current_balance (+ yield)
totalBorrow + available_liquidity == total_supplied
```

**2. Monotonicity Invariants**
```
sharePrice never decreases (ERC-4626 vault with no losses)
totalDebt never increases without a borrow event
nonce[user] is strictly increasing
```

**3. Access Invariants**
```
Only role OPERATOR can call harvest()
Only depositor can initiate their own withdrawal
Paused contracts reject all state-changing calls
```

**4. Relationship Invariants**
```
collateral_value(position) >= required_collateral(position.debt) OR position is liquidatable
position.healthFactor < 1.0 iff isLiquidatable(position) == true
```

**5. Boundary Invariants**
```
No function can bring totalLiquidity to zero unless all users have withdrawn
Fee cannot exceed MAX_FEE constant
```

### The Invariant Test: Can You Break It?
For every invariant, play adversary:
- What sequence of calls might violate it?
- What flash loan scenario challenges it?
- What governance action could cause it to fail?
- What does it look like at extreme values (first user, last user, max position)?

If you can't break it with reasonable effort, you have a solid invariant. If you can break it, you
have found a design flaw *before writing code*.

---

## Phase 2: State & Data Flow Modeling

### The State Space Map
Enumerate all states your system can be in, and which transitions are valid:

```
UNINITIALIZED → ACTIVE (only via initialize())
ACTIVE → PAUSED (admin only)
PAUSED → ACTIVE (admin only)
ACTIVE → DEPRECATED (governance only, after time delay)
DEPRECATED → [terminal, no transitions out]
```

For protocols with positions:
```
Position State: {OPEN, UNDERWATER, LIQUIDATABLE, CLOSED}
Transition Rules:
  OPEN → UNDERWATER: when healthFactor drops below threshold
  UNDERWATER → LIQUIDATABLE: when healthFactor drops below 1.0
  LIQUIDATABLE → CLOSED: when liquidated
  OPEN/UNDERWATER → CLOSED: when user closes position manually
```

**Never allow a contract to reach an undefined state.** Every reachable state must be intentional.

### Data Flow Analysis
Trace the path of every asset through the system:

```
User calls deposit(100 USDC):
  1. USDC transferred FROM user TO vault (safeTransferFrom)
  2. Shares minted TO user (mint)
  3. totalAssets() increases by 100
  4. sharePrice unchanged (proportional)
  5. Event emitted: Deposit(user, 100, shares)

Adversary calls deposit(100 USDC) then triggers reentrancy:
  → At what point in the flow are shares minted?
  → If minted AFTER transfer, is state consistent during the external call?
  → CEI: shares must be minted BEFORE the external transfer in most cases
```

Draw this on paper. The moments between an external call and state update are your attack surface.

---

## Phase 3: Threat Modeling

### STRIDE for Smart Contracts
Adapt the STRIDE model:

| Category | Smart Contract Expression |
|----------|--------------------------|
| **Spoofing** | Signature replay, front-running identity |
| **Tampering** | Storage collision, delegatecall shadowing |
| **Repudiation** | Missing events, off-chain oracle dependencies |
| **Information Disclosure** | Private variables readable via slot probing |
| **Denial of Service** | Gas griefing, unbounded loops, push payment DoS |
| **Elevation of Privilege** | Incorrect access control, unprotected initializers |

### Adversary Capability Matrix
Before finalizing design, enumerate all adversary types and their realistic capabilities:

```
ADVERSARY: Passive User
  Capital: Any ERC-20 balance
  Powers: Call any public/external function
  Goal: Extract more value than deposited

ADVERSARY: Flash Loan Attacker
  Capital: Effectively unlimited within one transaction
  Powers: Manipulate price, borrow arbitrary amounts, influence governance
  Goal: Drain protocol or manipulate oracle/governance

ADVERSARY: MEV Searcher
  Capital: Gas advantage + mempool visibility
  Powers: Front-run, back-run, sandwich transactions
  Goal: Extract user slippage, arbitrage state transitions

ADVERSARY: Governance Attacker
  Capital: Voting power (bought or borrowed)
  Powers: Pass parameter changes, upgrade contracts, drain treasury
  Goal: Drain treasury or introduce malicious upgrade

ADVERSARY: Compromised Admin
  Capital: Private key + privileged role
  Powers: Pause, upgrade, change parameters
  Goal: Rug pull or protocol manipulation

ADVERSARY: Malicious Token
  Capital: ERC-20 token with hooks (ERC-777, fee-on-transfer, rebasing)
  Powers: Reenter on transfer, report false balances, deflate via fees
  Goal: Corrupt accounting or drain balances
```

For each adversary: design explicitly to limit or eliminate their attack surface.

---

## Phase 4: Architectural Decision-Making

### The Immutability Spectrum
Every protocol must decide where it sits:

```
FULLY IMMUTABLE ←————————————————→ FULLY UPGRADEABLE

Pros: Maximum trustlessness      Pros: Bug fixes, feature evolution
      No governance attack             Protocol can adapt
      Simpler mental model

Cons: Can't fix critical bugs    Cons: Admin key risk
      Can't evolve                     Complexity
      Locked in design flaws           User trust requires governance

BEST PRACTICE: Immutable core invariants + upgradeable parameters
               Use timelocks + multi-sig for all admin actions
               Make upgrade paths transparent and time-delayed
```

### The Composition Decision
Before composing with external protocols:

```
DEPENDENCY ANALYSIS for each external contract:
  1. What permissions do we grant it?
  2. What callbacks does it make into us?
  3. What happens if it's compromised, paused, or upgraded?
  4. Does our protocol remain solvent if it returns unexpected values?
  5. Do we take on its governance risk?
  6. Does it introduce oracle dependencies we don't control?
```

Rule of thumb: **Every external dependency is an attack surface.** Minimize dependencies,
validate their outputs, and design for their failure.

### The Minimal Footprint Principle
Contracts should do one thing well. Ask:
- Can this logic be moved off-chain safely?
- Can this state be computed rather than stored?
- Does this contract need to hold assets, or can it just route them?
- Is this admin function needed on-chain, or can it be off-chain governance?

Fewer on-chain operations = fewer attack vectors.

---

## Phase 5: Pre-Implementation Review

Before writing implementation code, validate:

**Spec completeness check:**
- [ ] All actors enumerated with their capabilities
- [ ] All assets tracked with flow diagrams
- [ ] All invariants written down (minimum 5-10 for financial protocols)
- [ ] State transitions mapped and verified finite
- [ ] Threat model covers all adversary types
- [ ] Edge cases documented: zero values, max values, first/last user

**Architecture validation:**
- [ ] Access control matrix is complete (every function mapped to authorized callers)
- [ ] External dependencies assessed and failure modes designed for
- [ ] Upgradeability strategy decided and justified
- [ ] Emergency mechanisms designed (pause, migrate, circuit breaker)

**Economic validation (for DeFi):**
- [ ] Fee model analyzed for edge cases (zero fee, max fee, rounding)
- [ ] Liquidation mechanics validated at boundary conditions
- [ ] Reserve ratios / collateralization ratios stress-tested conceptually
- [ ] Flash loan attack scenarios analyzed
- [ ] MEV exposure assessed

Only when all items are checked should implementation begin.

---

## The "Break Your Own Protocol" Discipline

Adopt this as a mandatory personal practice:

**Before submitting any code for review**, spend 30 minutes trying to break it:

```
Checklist:
□ Reentrancy: What if every external call reenters?
□ Order dependency: What if Alice and Bob swap transaction order?
□ Scale: What happens at 1 user? 1,000,000 users? Max supply?
□ Rounding: What happens with 1 wei deposits? Fractional shares?
□ Time: What happens at block 0? After 10 years? After overflow of uint32 timestamps?
□ Initialization: What happens before initialize() is called?
□ Griefing: How can a malicious user make others' experience worse?
□ Economic: Can an attacker profit from normal-looking activity?
□ Governance: What malicious parameter changes are possible?
```

Writing down the results of this exercise — even for "no issues found" — is a discipline that
distinguishes elite engineers from average ones.
