---
name: smart-contract-dev
description: >
  A comprehensive elite-level skill framework for smart contract development, blockchain engineering,
  and security auditing. Use this skill whenever the user asks about smart contract design, architecture,
  Solidity or Rust/Anchor development, EVM internals, DeFi protocol engineering, access control patterns,
  upgradeability, testing strategies (fuzzing, invariant testing, formal verification), gas optimization,
  security reviews, audit methodology, invariant definition, threat modeling, vulnerability analysis,
  protocol lifecycle management, or anything related to building production-grade on-chain systems.
  Trigger even when the user frames it as a general question — e.g., "how do I design a lending protocol",
  "what are the best practices for a DEX", "how should I structure my contracts", "what could go wrong here",
  or "review my smart contract". This skill applies universally across EVM chains, Solana, CosmWasm, and
  any other smart contract platform.
---

# Smart Contract Development — Elite Engineering Framework

This skill equips Claude to reason, design, implement, review, and audit smart contracts with the rigor
of a senior blockchain engineer and security researcher. It covers the full lifecycle: requirements → 
architecture → implementation → testing → auditing → deployment → evolution.

---

## Core Philosophy: The Five Pillars

Every decision in smart contract engineering must be evaluated through five lenses, always in this order:

1. **Correctness** — Does it do what it says? Are invariants preserved under all conditions?
2. **Security** — Can an adversary exploit this? What is the worst-case outcome?
3. **Maintainability** — Can the next engineer understand, modify, and extend this safely?
4. **Efficiency** — Is resource usage acceptable given the correctness and security constraints?
5. **Sustainability** — Can this protocol evolve, be governed, and survive incidents?

> ⚠️ **Critical Rule**: Never sacrifice Correctness or Security for Efficiency. Gas is cheap relative to exploits. Optimization is a last step, never a first one.

---

## Universal Mental Model: Smart Contracts as State Machines

Think of every smart contract as a **deterministic state machine** with:

- **State**: All storage variables, balances, and their relationships
- **Invariants**: Properties that MUST hold true at all times, regardless of call order
- **Transitions**: Functions that move state from one valid configuration to another
- **Guards**: Access controls, input validations, and preconditions on transitions
- **Outputs**: Events, return values, and side effects (external calls, token transfers)

Before writing a single line of code, define:
```
INVARIANTS:    What can never be violated?
PRECONDITIONS: What must be true before a function runs?
POSTCONDITIONS: What must be true after a function runs?
STATE SPACE:   What are all reachable states, and are unsafe states unreachable?
```

This is the foundation of both correct implementation and systematic security review.

---

## The Engineering Decision Framework

When making any design or implementation decision, ask:

```
1. WHAT is the goal? (Functional requirement)
2. WHO can call this? (Access control surface)
3. WHEN can this go wrong? (Failure modes)
4. WHAT can an adversary do? (Threat model)
5. HOW does this interact with everything else? (Composability risks)
6. WHAT happens if the external world lies? (Oracle / input trust)
7. WHAT happens over time? (Economic equilibrium, parameter drift)
8. HOW do we recover if something breaks? (Incident response)
```

No feature should be implemented without consciously answering all eight.

---

## Reference Files — Navigation Guide

This framework is organized into seven deep-reference modules. Load the relevant one(s) based on the current task:

| Module | File | When to Load |
|--------|------|-------------|
| **Engineering Mindset** | `references/01-engineering-mindset.md` | Requirements analysis, invariant design, threat modeling, architectural decisions |
| **Architecture Patterns** | `references/02-architecture-patterns.md` | Protocol design, proxy patterns, access control, composability, DeFi primitives |
| **Security Framework** | `references/03-security-framework.md` | Vulnerability analysis, attack vectors, audit methodology, security review |
| **Testing Strategies** | `references/04-testing-strategies.md` | Unit/fuzz/invariant/formal testing, coverage, CI, mutation testing |
| **Code Quality** | `references/05-code-quality.md` | Solidity style, NatSpec, error handling, events, struct packing, review checklists |
| **Gas & Performance** | `references/06-gas-and-performance.md` | Storage optimization, calldata, assembly, when (not) to optimize |
| **Protocol Lifecycle** | `references/07-protocol-lifecycle.md` | Upgradeability, governance, timelocks, incident response, post-mortems |

---

## Interaction Protocol

When helping with smart contract work, always:

### 1. Establish Context First
Before designing or reviewing:
- What chain/VM? (EVM, SVM, CosmWasm, MoveVM)
- Is this new protocol or iteration on existing?
- What is the trust model? (Who are admins, users, external actors?)
- What assets are at risk and what is the value of the protocol?

### 2. State the Invariants Explicitly
Every protocol review or design begins with explicit invariant enumeration. Example:
```
Token vault invariants:
  I1: sum(userBalances) <= totalAssets()
  I2: sharePrice is monotonically non-decreasing (no loss)
  I3: Only depositor can initiate withdrawal of their own funds
  I4: Contract is not re-entered during accounting
```

### 3. Identify the Threat Actors
Classify adversary capabilities:
- **Passive user**: Can only call public functions normally
- **Flashloan attacker**: Has access to arbitrary capital within one tx
- **Governance attacker**: Has acquired voting power
- **Admin / privileged role**: Can call restricted functions
- **MEV searcher**: Can observe mempool and reorder/insert transactions
- **Compromised oracle**: Can supply manipulated external data

### 4. Apply Structured Analysis
Use the reference modules to build a rigorous response: architecture, security, testing, and code quality together — not in isolation.

---

## Universal Security Principles (Always Active)

These apply to every contract, always. They are non-negotiable defaults:

```solidity
// 1. CHECKS-EFFECTS-INTERACTIONS (CEI) — always
function withdraw(uint256 amount) external {
    require(balances[msg.sender] >= amount);   // CHECK
    balances[msg.sender] -= amount;             // EFFECT
    token.transfer(msg.sender, amount);         // INTERACTION
}

// 2. PULL OVER PUSH — prefer pull payment patterns
// 3. REENTRANCY GUARDS — on all state-changing external interactions
// 4. NO MAGIC NUMBERS — all constants named and documented
// 5. EXPLICIT VISIBILITY — every function and variable
// 6. SAFE MATH — Solidity 0.8+ or explicit checks
// 7. INPUT VALIDATION — validate all external inputs at entry points
// 8. FAIL LOUDLY — revert with informative custom errors, never silent failure
// 9. EMIT EVENTS — for all state transitions
// 10. MINIMAL PRIVILEGE — least authority for all roles
```

---

## Audit Mindset (Always Active)

When reviewing any code, internal monologue should include:

```
"What happens if msg.sender is a contract?"
"What happens if this external call reverts? Returns false? Reenters?"
"What happens if this value is zero? Max uint? Negative (if applicable)?"
"What happens if the two transactions run in reverse order?"
"What happens if someone reads and then front-runs this?"
"What happens at the very first deposit/action (initialization edge cases)?"
"What happens at the last withdrawal (dust, rounding)?"
"What happens if the oracle returns a stale/manipulated value?"
"What happens if governance passes a malicious parameter?"
"Is there any path that bypasses this check?"
```

---

## Quick Reference: Vulnerability Taxonomy

| Class | Example Attack | Primary Defense |
|-------|---------------|-----------------|
| Reentrancy | DAO Hack | CEI + ReentrancyGuard |
| Integer Issues | Overflow exploits | Solidity 0.8+, checked math |
| Access Control | Parity Multisig | Role-based access control |
| Oracle Manipulation | Flash loan price attack | TWAP, multi-oracle, circuit breakers |
| Front-Running | DEX sandwich | Slippage limits, commit-reveal |
| Logic Errors | Compound governance bug | Formal invariants, extensive testing |
| Precision Loss | Division rounding | Scale factors, rounding direction analysis |
| Denial of Service | Unbounded loops | Gas-aware design, pull patterns |
| Signature Issues | Replay attacks | EIP-712, nonces, domain separators |
| Economic Attacks | Governance takeover | Time-locks, voting delays, quorum |

For each class, see `references/03-security-framework.md` for full analysis and mitigations.

---

## Protocol Classification Guide

Use these categories to select appropriate reference modules:

**Token Contracts**: Mindset + Architecture + Security + Code Quality  
**DeFi Primitives (AMM, Lending, Vault)**: All modules  
**NFT / Digital Asset Systems**: Mindset + Architecture + Security  
**Governance / DAO**: Architecture + Security + Lifecycle  
**Bridges / Cross-Chain**: Security (highest priority) + Architecture  
**Infrastructure (Oracles, Relayers)**: Mindset + Security + Lifecycle  
**Account Abstraction / Wallets**: Security + Architecture  
**Security Review / Audit**: Security + Testing + Code Quality  

---

## Getting Started Checklist (New Protocol)

Before any code is written, the following must exist:

- [ ] Specification document with precise functional requirements
- [ ] Explicit invariant list (at least 5-10 for non-trivial protocols)
- [ ] Threat model with adversary capabilities enumerated
- [ ] Architecture diagram with trust boundaries marked
- [ ] Data flow diagram showing all asset movements
- [ ] Access control matrix (who can call what, under what conditions)
- [ ] Upgrade strategy decision (immutable / proxy / modular)
- [ ] Emergency response plan (pause, migration, circuit breakers)
- [ ] Testing strategy (unit, integration, fuzz, invariant, fork)
- [ ] Audit scope and timeline (built into the development plan)

---

*Load the relevant reference module(s) for deep guidance on each topic.*
