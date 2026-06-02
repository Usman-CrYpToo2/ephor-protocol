# Ephor Protocol — Specification-Driven Development Document (v2.0)

> **Autonomous AI Risk + Allocation Layer for ERC-4626 Vaults on the Somnia Agentic L1**
>
> **Document type:** Specification-Driven Development (SDD) / Technical Design Document (TDD)
> **Status:** Draft for implementation
> **Audience:** Claude Code (implementer) + human reviewers
> **Authoring lens:** Lead software engineer · blockchain protocol engineer · smart-contract security auditor
> **Scope:** Theory, architecture, invariants, prompt strategy, mocks, threat model, test plan. **No production Solidity in this file** — the implementing agent writes all code from this spec.

---

## 0. How To Use This Document

This is a **specification**, not an implementation. It is written to be handed to an autonomous coding agent (Claude Code) that will:

1. Read this entire document top to bottom **before writing any code**.
2. Produce a short implementation plan that maps each numbered requirement (`R-*`), invariant (`I-*`), and acceptance criterion (`AC-*`) to concrete files, functions, and tests.
3. Implement contracts, mocks, scripts, and tests that satisfy every `MUST` and document every deviation from a `SHOULD`.
4. Verify against the **live Somnia primitives** described in §4 and §Appendix B — and **re-generate the exact agent interfaces from `https://agents.somnia.network`** rather than trusting any signature reproduced here from memory.

**Normative language.** "MUST", "MUST NOT", "SHOULD", "SHOULD NOT", "MAY" follow RFC-2119 meaning. A `MUST` is a hard requirement; violating it is a defect. A `SHOULD` is a strong default; deviating requires a written justification in the PR.

**Golden rule of this redesign (read this twice):**

> **The EVM is the constitution. The AI is an advisor with no signing authority.**
> Every number the AI emits is a *request*, never a *command*. The vault re-derives, re-validates, and re-bounds everything at the custody boundary before a single wei moves. If the AI is wrong, malicious, slow, or absent, depositor funds remain safe by construction — not by trust.

---

## 1. Executive Summary

Ephor Protocol is an ERC-4626 USDC yield vault on Somnia that uses Somnia's native, validator-consensus LLM inference to (a) **defend** the vault (autonomous risk circuit-breaker) and, new in v2, (b) **grow** the vault (autonomous capital allocation across lending markets).

The v1 system works but has three classes of problem this SDD resolves:

1. **The prompt strategy is ill-defined and asks the LLM to do the EVM's job.** The current design hands the model raw numbers and asks it to apply fixed arithmetic thresholds (`allocation > 40%`, `utilization > 95%`). Arithmetic thresholds are deterministic and belong on-chain. Pushing them into a probabilistic model adds latency, cost, consensus fragility, and precision loss — for zero benefit. (See §2.3, §7, §9.)
2. **Structural correctness and precision defects** (an off-by-logic "worst market" selection bug, a fragile hand-rolled integer-to-string formatter, integer-percent metrics that destroy the exact boundary the rules depend on, and an under-sized agent deposit that will silently time out on mainnet). (See §2.4.)
3. **No allocation brain.** Capital movement is manual, single-market, and unoptimized. v2 introduces an **AI Allocation Strategist** that proposes target allocations which the vault validates against hard invariants and executes — *autonomous execution behind EVM guardrails*. (See §8, §10, §11.)

The redesign cleanly separates two AI agents with least-privilege, replaceable roles:

| Agent | Posture | Role held | Can do | Can never do |
|---|---|---|---|---|
| **RiskSentinel** | Defensive (circuit-breaker) | `SENTINEL_ROLE` | Pause deposits, emergency-deallocate, lower caps | Add markets, raise caps, move funds *into* markets |
| **AllocationStrategist** | Offensive (yield optimizer) | `ALLOCATOR_ROLE` | Propose a target allocation vector; trigger a validated rebalance | Exceed any cap, breach the idle floor, exceed turnover/concentration limits, touch a non-whitelisted market |

Both agents are **smart contracts** that talk to the Somnia Agent Platform. Both are bounded by EVM invariants enforced **inside the vault's `reallocate` entrypoint** — so even a fully compromised AI cannot violate a cap, drain liquidity, or route to an unapproved market.

---

## 2. Background & Analysis of the Current System

### 2.1 What exists today (v1)

- `CuratedVault` — ERC-4626 USDC vault, inline ERC-20 share token, inline `AccessControl`/`ReentrancyGuard`, virtual-shares/assets inflation protection (`VSHARES=VASSETS=1`), timelocked market additions and cap increases, immediate cap decreases / action revocations, performance fee accrual, `_ensureLiquidity` withdrawal pull-down.
- `VaultSentinel` — reads five metrics, builds a plain-English prompt, calls `inferString` with `allowedValues=[SAFE,CAUTION,CRITICAL]`, and on `CRITICAL` pauses deposits and deallocates 50% of the "worst" market (only if utilization > 90%).
- `ISomnia.sol` — accurate transcription of the real platform interface (`IAgentRequester`, callback signature, `Response`/`Request` structs, `ConsensusType`, `ResponseStatus`, agent method interfaces).
- Mocks — `MockUSDC` (6-dec, open mint), `MockLendingMarket` (per-second 5% APY compounding, `setUtilization`, `fastForwardDays`), `MockSomniaPlatform` (`createRequest`, `simulateCallback`, `simulateTimeout`).

### 2.2 What is genuinely good and MUST be preserved

- **ERC-4626 inflation-attack protection** via virtual offsets — keep.
- **Role separation with risk-reducing-only sentinel** — keep and extend; this mirrors the production Morpho V2 model (Curator/Allocator/Sentinel).
- **Timelocked risk-increasing actions** (market adds, cap raises) with immediate risk-reducing actions (cap cuts, revokes) — keep; this is the correct asymmetry.
- **`onlyPlatform` + `pendingRequests` callback gating** and the **fail-safe (timeout → CAUTION, never silent SAFE)** philosophy — keep and generalize.
- **CEI + `nonReentrant`** discipline — keep.
- **Exact callback name/selector discipline** (`handleResponse.selector`) and **`pendingRequests` being `public`** for mock lookup — keep.

### 2.3 The core problem: the prompt strategy (root-cause analysis)

The current system prompt instructs the model:

> *"CRITICAL if ANY: (1) any market allocation > 40%; (2) idle buffer < 5%; (3) any market utilization > 95% …"*

This is the central design error. **These are deterministic numeric predicates.** A `uint256` comparison on-chain is exact, free of consensus risk, costs almost nothing, and can never hallucinate. Routing it through an LLM introduces every one of the following failure modes:

- **F1 — Boundary ambiguity.** Is `40%` critical or the start of caution? Is the comparison inclusive? LLMs are unreliable exactly at thresholds, and the v1 user prompt *truncates* `utilBps/100`, so `9499 bps` and `9450 bps` both render as `"94%"`, erasing the very boundary (`95%`) the rule hinges on. The model is asked to be precise about data that has already lost precision.
- **F2 — Consensus fragility.** Somnia reaches consensus on AI output by requiring **byte-identical results across validators** (fixed seed, `temperature=0`). The more reasoning the model must do over free-form text, the larger the surface for one validator to diverge — risking `Failed`/`TimedOut` instead of a verdict.
- **F3 — Wasted capability.** The LLM is a pattern-recognition engine. Spending it on `if (x > 40)` is like hiring a strategist to run a calculator. The genuinely AI-suitable judgment (regime detection, relative ranking under multiple weak signals) is *not* being used.
- **F4 — No structured, auditable output.** A single bare word is the entire verdict. There is no per-market breakdown, no severity score, no machine-readable reasoning for the audit trail.

**Resolution (preview):** move all hard numeric thresholds **on-chain as deterministic circuit-breakers**, and narrow the AI to the judgment it is actually good at, fed by a **lossless, canonical, integer-only** prompt with **constrained outputs** (§7, §9).

### 2.4 Concrete defects found in v1 (audit findings)

These are recorded so the implementer fixes them, not merely re-ports them.

| ID | Severity | Location | Finding | Required fix |
|---|---|---|---|---|
| **D-1** | High (correctness) | `VaultSentinel._deallocateWorstMarket` | The loop assigns `worst = m` **unconditionally** on every iteration; it is outside the `if (u > worstUtil)` block. The "worst" market is therefore always the **last** market in the list, not the highest-utilization one. The `> 9000 bps` guard then applies to the wrong market. | Track `worst` only when a strictly higher utilization is found; select the true argmax. (Superseded by the redesigned, on-chain risk engine in §7.) |
| **D-2** | High (liveness) | `VaultSentinel._u` integer formatter | Hand-rolled `uint→string` is fragile and, as written, the digit-count and digit-emit loops do not advance their counters inside the loop body, risking non-termination / gas exhaustion, and the logic is incorrect for multi-digit values. Building prompts via manual decimal rendering is an anti-pattern. | Eliminate hand-rolled formatting. Use a vetted library routine (e.g., OpenZeppelin `Strings.toString`) **only if** human-readable prompts are retained; preferably switch to a canonical integer feature encoding (§9.3) that is unit-test-pinned. |
| **D-3** | Medium (precision) | `CuratedVault.marketAllocationPct`, `idleBufferPct`; sentinel prompt | Metrics are integer **percent** (`*100/t`), discarding sub-percent precision. Risk rules expressed at 25%/40% cannot distinguish 40.0% from 40.9%. | Express all ratios in **basis points (bps, /10000)**. All thresholds, caps, and AI features use bps. |
| **D-4** | Medium (liveness/cost) | `README` deposit guidance ("0.15 STT") | LLM inference is **0.07 per validator**; with the default subcommittee of 3 the reward pot alone is `0.21`, plus the operations-reserve floor from `getRequestDeposit()`. 0.15 STT under-funds the request → `perAgentBudget` too low → runners skip → `TimedOut`. `CLAUDE.md`'s 0.25 STT figure is the correct one. | Compute deposit at call time as `getRequestDeposit() + LLM_COST_PER_AGENT * subcommitteeSize`. Never hardcode a guess. Reconcile README/CLAUDE.md/code to one source of truth. |
| **D-5** | Medium (logic redundancy) | `VaultSentinel._respondToCritical` / `_deallocateWorstMarket` | When the AI returns `CRITICAL`, the contract still **re-gates** on `utilization > 9000 bps` before acting. If the AI's notion of "critical" diverges from that single on-chain predicate, the AI verdict is silently ignored. The system can't decide whether the AI or the on-chain check is authoritative. | Make the **on-chain hard guards authoritative for action**; treat the AI verdict as an *escalation/severity signal* layered on top (§7.4). Document one clear precedence rule. |
| **D-6** | Low (consensus handling) | `VaultSentinel.handleResponse` | Reads `responses[0]` only and trusts `status==Success`. For `Majority` consensus this is acceptable (the threshold guarantees identical bytes), but there is no defense-in-depth check that the agreeing set actually met `details.threshold`. | Verify `status==Success` **and** optionally assert `details.responseCount >= details.threshold` before acting; document the assumption. |
| **D-7** | Low (liveness) | Idle buffer | No invariant guarantees a minimum idle buffer is *maintained* after allocation; `_ensureLiquidity` only reacts at redeem time and can force costly unwinds / fail under market illiquidity. | Introduce a curator-set `minIdleBufferBps` enforced on every allocation/rebalance (I-3). |

---

## 3. Goals, Non-Goals, Success Criteria

### 3.1 Goals (G)

- **G-1** Re-architect so that **all deterministic risk arithmetic is on-chain** and the AI is used only for genuine judgment.
- **G-2** Redesign the **prompt strategy** for losslessness, determinism (consensus-safety), constrained outputs, and auditability.
- **G-3** Add an **autonomous Allocation Strategist**: the AI proposes target allocations; the EVM validates against hard invariants and executes — *autonomous execution behind guardrails*.
- **G-4** Guarantee, by construction, that **no AI output can violate a depositor-protecting invariant** (caps, idle floor, concentration, turnover, whitelist, conservation).
- **G-5** Preserve a **fail-safe** posture: AI absence/failure/timeout never harms depositors and never silently increases risk.
- **G-6** Keep the system **live-deployable on Somnia today** using only documented primitives; isolate any speculative feature behind a clearly-labeled future tier.
- **G-7** Provide **complete mocks** enabling deterministic, fast, local testing of every path including adversarial AI behavior and validator disagreement.

### 3.2 Non-Goals (NG)

- **NG-1** No cross-chain, no bridging, no external price oracles for v2 core (a yield signal is sourced from the markets themselves / an optional JSON-API agent — see §8.5).
- **NG-2** No change to the ERC-4626 share-accounting math (virtual offsets retained).
- **NG-3** No raw-calldata agent execution (`inferToolsChat`) in v2 production path; documented as Tier-3 future work with explicit guardrails (§8.6, §20).
- **NG-4** No mainnet deployment with real funds without a formal third-party audit (carried over from v1 README).

### 3.3 Success criteria (high level; see §18 for full `AC-*`)

- The vault behaves identically to v1 for deposit/redeem/share-price.
- The RiskSentinel fires hard circuit-breakers **on-chain** with the AI as a layered second opinion; the `_deallocateWorstMarket` defect is gone.
- The AllocationStrategist can take any AI proposal — including a deliberately malicious one in tests — and the vault **never** ends in a state that violates any `I-*`.
- All agent deposits are computed from `getRequestDeposit()` + reward, never hardcoded.
- 100% of invariants have at least one positive test and one adversarial (rejection) test.

---

## 4. Research Foundations (grounding the design in reality)

This section records the external facts the design depends on. The implementer MUST re-verify the live signatures from the Somnia agent explorer before coding.

### 4.1 Somnia Agent Platform — the execution substrate

- A Somnia Agent is a sandboxed, validator-executed compute container addressable by `agentId`. Contracts invoke it with ABI-encoded calldata; execution happens **off the EVM** on a subcommittee of validators; the result returns **asynchronously** via a callback. (`docs.somnia.network/agents/invoking-agents/from-solidity`.)
- **Two-phase async model:** `createRequest{value}(agentId, callbackAddress, callbackSelector, payload)` returns a `requestId` synchronously; later the platform invokes `handleResponse(requestId, Response[] responses, ResponseStatus status, Request details)`.
- **Consensus:** `ConsensusType.Majority` (validators must agree on the **same result bytes**) or `ConsensusType.Threshold` (results counted individually). **LLM/JSON agents use Majority.** Majority is *only* reachable because LLM agents run with **fixed seed and temperature = 0**, making validator outputs byte-identical. **This is the single most important constraint on prompt design.**
- **Deposit sizing:** `msg.value MUST be ≥ getRequestDeposit() + pricePerAgent × subcommitteeSize`. The floor alone sets `perAgentBudget = 0`, runners skip the job, and the request times out. Implement `receive()` to accept the automatic rebate of unused budget.
- **Status handling:** a request finalizes as `Success(2)`, `Failed(3)`, or `TimedOut(4)`. Decoding `responses[0].result` on a non-success status is a panic; always branch on status first.
- **Platform addresses:** Testnet (chain `50312`) `0x037Bb9C718F3f7fe5eCBDB0b600D607b52706776`; Mainnet (chain `5031`) `0x5E5205CF39E766118C01636bED000A54D93163E6`.

### 4.2 The LLM Inference base agent (Qwen3-30B), four methods

The platform's LLM Inference agent (price **0.07 per validator**) exposes four methods of increasing power. Choosing the right one is the heart of this redesign:

| Method | Output shape | Consensus safety | Use in Ephor |
|---|---|---|---|
| `inferString(prompt, system, chainOfThought, allowedValues[])` | One string, constrainable to an enum | **Highest** (output ∈ small fixed set) | Risk verdict; Tier-1 allocation **strategy label** |
| `inferNumber(...)` | One integer, **clamped to a range** | **High** (single integer) | Tier-2 per-market **attractiveness score** |
| `inferChat(...)` | Multi-turn free text | Lower (free-form) | Not used in v2 core |
| `inferToolsChat(...)` | Tool calls / **calldata yielded back to the contract** | Lowest (free-form calldata) | **Tier-3 future only**, behind full re-validation |

The official developer guide explicitly frames `inferToolsChat` for "agentic DeFi bots" where "the model decides which DEX to call and yields the calldata back to your contract." We deliberately **do not** use that in v2 production because raw model-authored calldata is the largest possible attack surface and inverts the "EVM is the constitution" principle. We use the **most constrained primitive that can express the decision** (§8).

> **Implementer action (Appendix B):** the exact parameter lists for `inferNumber`/`inferChat`/`inferToolsChat` MUST be regenerated from `agents.somnia.network` ("Solidity" tab). Do not assume the order/types reproduced anywhere in this document; treat §4.2 as semantic, not syntactic.

### 4.3 Per-agent prices (for deposit sizing)

| Agent | Price / validator | Default subcommittee | Reward pot (size 3) |
|---|---|---|---|
| JSON API Request | 0.03 | 3 | 0.09 |
| **LLM Inference** | **0.07** | 3 | **0.21** |
| LLM Parse Website | 0.10 | 3 | 0.30 |

Add `getRequestDeposit()` (operations-reserve floor) on top. Practical LLM deposit ≈ **0.25 STT** (matches `CLAUDE.md`). **Never hardcode**; always `getRequestDeposit() + price × size` at call time.

### 4.4 Production curated-vault patterns (the allocation model to imitate)

Anchoring the new allocator in battle-tested DeFi:

- **MetaMorpho / Morpho Vaults** are ERC-4626 vaults whose allocators move capital across enabled markets to optimize yield while respecting **per-market supply caps** that "guarantee that allocators cannot reallocate more than that limit to that market." Max 30 markets per vault. Risk-altering actions are timelocked.
- **Morpho Vault V2 role model** is exactly our target: **Curator** (caps/fees, timelocked), **Allocator** (active allocation to enabled markets), **Sentinel** (reactively reduce risk — deallocate, decrease caps, revoke pending actions). Ephor's roles already mirror this; v2 makes the Allocator an AI.
- **Gauntlet's curation methodology** frames allocation as continuously optimizing **risk-adjusted yield** under caps, treating market caps as exposure limits and reallocating as conditions change. This is the objective function our Strategist approximates: *maximize expected yield subject to risk/exposure constraints*.

**Design takeaway:** the canonical safe interface is a **batch `reallocate(targets[])`** that the custody contract validates against caps and executes atomically. The AI's job is to *propose the targets*; the vault's job is to *enforce the constraints*. This is precisely the "untrusted allocator + EVM guardrails" architecture requested.

---

## 5. Redesigned Architecture

### 5.1 Component overview

```
                          ┌─────────────────────────────────────────────────────────┐
                          │                      Somnia Agent Platform                │
                          │   IAgentRequester  ·  LLM Inference Agent (Qwen3-30B)     │
                          │   Majority consensus · fixed seed · temp=0 · async cb     │
                          └───────▲───────────────────────────────────────▲──────────┘
                                  │ createRequest / handleResponse         │
            (defensive path)      │                                        │   (offensive path)
                          ┌───────┴────────┐                       ┌───────┴─────────────┐
                          │  RiskSentinel  │                       │ AllocationStrategist │
                          │  SENTINEL_ROLE │                       │   ALLOCATOR_ROLE      │
                          │                │                       │                       │
                          │ on-chain hard  │                       │ snapshot features →   │
                          │ guards (auth.) │                       │ AI proposal →         │
                          │ + AI 2nd-opinion│                      │ deterministic project │
                          └───────┬────────┘                       └───────┬──────────────┘
                                  │ pauseDeposits / emergencyDeallocate     │ reallocate(targets, guard)
                                  │ lowerCap                                │
                          ┌───────▼─────────────────────────────────────────▼──────────┐
                          │                       CuratedVault (ERC-4626)               │
                          │  ── THE CONSTITUTION: invariant enforcement at custody ──    │
                          │  deposit/redeem · share math · timelocked market mgmt        │
                          │  reallocate(targets) re-validates I-1..I-10 before moving    │
                          │  risk params (caps, idle floor, concentration, turnover)     │
                          └───────┬──────────────────────────────────────────┬──────────┘
                                  │ supply / withdraw                          │ view metrics (bps)
                          ┌───────▼─────────┐   ┌─────────────────┐   ┌───────▼─────────┐
                          │ LendingMarket A │   │ LendingMarket B │   │ LendingMarket … │
                          └─────────────────┘   └─────────────────┘   └─────────────────┘
```

### 5.2 Module responsibilities (single-responsibility split)

| Module | Responsibility | Holds | Trust level |
|---|---|---|---|
| `CuratedVault` | Custody, ERC-4626 math, **invariant enforcement**, market registry, risk parameters, atomic `reallocate` | — | Trusted core |
| `RiskSentinel` | Defensive monitoring; **on-chain hard guards**; AI regime second-opinion; emergency actions | `SENTINEL_ROLE` | Semi-trusted (risk-reducing only, replaceable) |
| `AllocationStrategist` | Offensive optimization; AI proposal lifecycle; deterministic projection; trigger validated rebalances | `ALLOCATOR_ROLE` | **Untrusted-by-design** (bounded by vault invariants, replaceable) |
| `ISomnia` | Exact platform + agent interfaces | — | External truth |
| Mocks | Deterministic test doubles incl. adversarial behavior | — | Test only |

**Why invariants live in the vault, not the Strategist:** if the Strategist enforced its own limits, a bug or compromise in the Strategist would defeat them. By enforcing every `I-*` inside `CuratedVault.reallocate`, the protection is **independent of the proposer**. The Strategist is then free to be "clever" (and even wrong) without ever being "dangerous."

### 5.3 Design principles (the spine of the redesign)

- **P-1 Deterministic/Probabilistic separation.** If a rule can be written as exact integer arithmetic, it lives on-chain. The AI is reserved for ranking/judgment under multiple weak signals.
- **P-2 Constitution at the custody boundary.** All depositor-protecting invariants are enforced where funds move (`reallocate`, `allocate`, `deallocate`), not in the proposer.
- **P-3 Most-constrained primitive.** Use the narrowest AI output that can express the decision (`allowedValues` enum > clamped `inferNumber` > free text > calldata). Narrower = more consensus-safe + smaller attack surface.
- **P-4 Lossless canonical inputs.** Feed the model integer, fixed-unit (bps), fixed-order, locale-free features. Never truncate the data the decision depends on.
- **P-5 Fail-closed / fail-safe.** Absence, failure, timeout, or invalidity of an AI response leaves the vault in its last safe state and (for risk) escalates caution, never silently relaxing protection.
- **P-6 Least privilege + replaceability.** Each AI arm holds the minimum role; each is hot-swappable by admin without redeploying the vault.
- **P-7 Bounded blast radius.** Even a maximally adversarial, fully-trusted-by-mistake AI proposal can at most reshuffle already-whitelisted, capped funds, within a per-epoch turnover limit, once per epoch.
- **P-8 Auditability.** Every decision emits a structured, on-chain record: inputs (feature snapshot hash), AI raw output, the projected target, the executed deltas, and the outcome.

---

## 6. Domain Model & Canonical Units

### 6.1 Units (eliminates D-3)

- **All ratios in basis points (bps), 1e4 = 100%.** `utilizationBps`, `allocationBps`, `idleBufferBps`, `minIdleBufferBps`, `maxMarketBps`, `maxTurnoverBps`, `driftToleranceBps`.
- **All asset amounts in USDC base units (6 decimals).**
- **All share amounts in 18 decimals** (unchanged).
- **AI scores in a fixed clamp range** `[0, SCORE_MAX]` with `SCORE_MAX = 10_000` (so a score reads naturally as "weight in bps" before projection).

### 6.2 Core entities

- **Vault** — `totalAssets` (idle + sum of market balances), `totalSupply`, `sharePrice`, `depositsPaused`, risk parameters, market registry, current epoch.
- **Market** — `enabled`, `supplyCap`, current `balanceOf(vault)`, `utilizationBps`, **`supplyRateBps`** (new yield signal; see §8.5).
- **RiskParameters** (curator-set; risk-increasing changes timelocked) — `minIdleBufferBps`, `maxMarketBps`, `maxTurnoverBps`, `driftToleranceBps`, `rebalanceEpoch`, plus the **hard risk thresholds** now living on-chain: `criticalUtilBps`, `cautionUtilBps`, `criticalAllocBps`, `cautionAllocBps`, `minHealthyIdleBps`.
- **Proposal** — `{requestId, vault, epoch, snapshotHash, rawAiOutput, projectedTargets[], status}` for audit.

---

## 7. The RiskSentinel Redesign (defensive path)

### 7.1 Objective

Detect dangerous vault states and *reduce* risk autonomously, with **on-chain determinism as the authority** and **AI as a layered escalator** — resolving D-1, D-5, and the §2.3 prompt critique.

### 7.2 What moves on-chain (deterministic hard guards)

`RiskSentinel.assessOnChain(vault)` (pure view over vault metrics) computes, in bps, with **no truncation**:

- `maxUtilBps` = max over enabled markets of `utilizationBps`.
- `maxAllocBps` = max over enabled markets of `balanceOf(vault) * 1e4 / totalAssets`.
- `idleBps` = `idleAssets * 1e4 / totalAssets`.
- A deterministic **HardLevel ∈ {Safe, Caution, Critical}** from curator-set thresholds:
  - **Critical** if `maxUtilBps > criticalUtilBps` **or** `maxAllocBps > criticalAllocBps` **or** `idleBps < minHealthyIdleBps`.
  - **Caution** if any value sits in the caution band.
  - **Safe** otherwise.
- The **true worst market** = argmax utilization (fixes **D-1**), returned alongside.

These guards fire **regardless of the AI** and are the **authoritative trigger for emergency action** (resolves **D-5**: on-chain is authoritative; AI is additive).

### 7.3 What the AI actually decides (the judgment worth buying)

The AI is asked a question arithmetic cannot answer well: **"Across the whole portfolio and its recent trajectory, is this a deteriorating risk regime that warrants caution beyond what any single threshold shows?"**

- Primitive: `inferString` with `allowedValues = ["STABLE","WATCH","DETERIORATING"]`.
- Input: the **canonical feature block** (§9.3) including *cross-market* and *trend* features (e.g., number of markets in the caution band, dispersion of utilization, change since last snapshot) — signals that are genuinely pattern-like rather than single-threshold.
- The AI's answer is an **escalation modifier**, not a trigger:

### 7.4 Precedence rule (one clear rule — resolves D-5)

```
EffectiveLevel = max(HardLevel_onchain, AiAdjustedLevel)

where AiAdjustedLevel =
   Critical  if AI == DETERIORATING and HardLevel >= Caution     (AI can escalate Caution→Critical)
   Caution   if AI == WATCH        and HardLevel == Safe          (AI can nudge Safe→Caution)
   HardLevel otherwise                                            (AI can never DE-escalate)
```

**The AI can only raise caution, never lower it.** If the AI is unavailable/timeout/failed → `EffectiveLevel = HardLevel` (and we still record `AI_UNAVAILABLE` for the trail). This preserves P-5.

### 7.5 Action mapping

| EffectiveLevel | On-chain action |
|---|---|
| Safe | Store snapshot; no action. |
| Caution | Store snapshot; emit `RiskAlert`. *(Optionally: lower the cap of the worst market by a curator-set step — risk-reducing, allowed for Sentinel.)* |
| Critical | `pauseDeposits()` (if `autoPauseEnabled`); `emergencyDeallocate(worstMarket, pullBps × balance / 1e4)` on the **true** worst market; emit events. Pull fraction `pullBps` is a curator parameter (default 50%), and the action is gated on **on-chain** util/alloc, not on the AI word. |

### 7.6 Sentinel state machine

```
            checkVault() + STT
   Idle ───────────────────────────► Pending (activeRequest set, cooldown started)
    ▲                                   │
    │ store snapshot                    │ handleResponse(status)
    │                                   ▼
    │             ┌──────────── Success ────────────┐
    │             │                                 │
    │      decode label                       Failed/TimedOut/empty
    │             │                                 │
    │   EffectiveLevel = max(Hard, AI)        EffectiveLevel = Hard
    │             │                                 │  (+ record AI_UNAVAILABLE)
    │             └──────────────┬──────────────────┘
    │                            ▼
    │                  apply Action mapping (§7.5)
    └────────────────────────────┘
```

Keep from v1: `CHECK_COOLDOWN` (5 min), one in-flight per vault (`activeRequest`), `onlyPlatform`, `pendingRequests` public, immutable history snapshots, `getLatestRisk`/`getHistory`/`getVaultList`/`isCheckPending` views.

---

## 8. The AllocationStrategist (offensive path — the new brain)

### 8.1 Objective

Autonomously improve **risk-adjusted yield** by proposing how the vault's assets should be distributed across enabled markets and idle, then executing the proposal **only through the vault's invariant-checked `reallocate`**.

### 8.2 The trust architecture (this is the crux of the whole request)

```
   AI proposes  ──►  Strategist projects onto feasible set  ──►  Vault re-validates EVERY invariant  ──►  executes
   (untrusted)       (deterministic, off-the-money math)        (the constitution, at custody)            (atomic, CEI)
        │                       │                                        │
   weights/scores         caps + idle + concentration             rejects if ANY I-* fails
   (bounded ints)         + turnover applied here too              (fail-closed, funds stay put)
```

The AI never names an amount of money. It emits **dimensionless preferences** (a strategy label or per-market scores). The Strategist turns preferences into a **candidate target vector**. The vault turns the candidate into **money movement only if it satisfies the constitution**. Three independent layers; each strictly narrows the previous.

### 8.3 Tiered allocation modes (ship safe, design for better)

The implementer MUST build **Tier-1** and **Tier-2**; **Tier-3** is documented future work (§20).

**Tier-1 — Strategy Selection (default; cheapest; maximal consensus safety).**
- One `inferString` call. `allowedValues` is a curated, fixed enum of **named allocation policies**, e.g.:
  - `DEFENSIVE` — maximize idle/liquidity; allocate minimally, prefer lowest-utilization market.
  - `BALANCED` — even risk-weighted spread across healthy markets.
  - `YIELD_TILT` — overweight highest `supplyRateBps` markets that remain under caution thresholds.
  - `DERISK` — pull toward idle floor + lowest-utilization market only.
- The EVM maps the chosen label to **target weights via a deterministic, pure function** over the *current* market set and features. One word in, a fully determined feasible target out. Bulletproof: same primitive that already works for the risk verdict.

**Tier-2 — Per-Market Scoring (higher fidelity).**
- For each enabled market `i`, an `inferNumber` call returns an **attractiveness score** in `[0, SCORE_MAX]`, clamped, given that market's canonical features + the portfolio context. Single integer per call → consensus-safe.
- The EVM normalizes scores to weights and **projects onto the feasible set** (§11). The AI expresses *relative* preference; the EVM owns *all* the money math.
- Cost scales with market count (N × 0.07 × subSize). Acceptable for the 2–5 markets typical on testnet; documented as the precision/cost trade vs Tier-1.

**Tier-3 — Tool-Calling Allocator (future, NG-3).**
- `inferToolsChat` yields candidate moves/calldata; the vault would still re-validate every move against `I-*`. Deferred because free-form calldata is the weakest consensus case and the largest attack surface. See §20.

> **Selection guidance for the implementer:** make the tier a **curator-set mode** on the Strategist (`AllocationMode` enum), defaulting to Tier-1. Tests MUST cover both Tier-1 and Tier-2 end-to-end, including adversarial AI outputs.

### 8.4 Rebalance lifecycle (sequence)

```
Keeper/anyone                Strategist                    Platform (LLM)                 CuratedVault
     │  requestRebalance(vault){STT}  │                            │                            │
     │───────────────────────────────►│  snapshot features (bps)   │                            │
     │                                │  epochGuard, snapshotHash   │                            │
     │                                │  createRequest{value}(...)  │                            │
     │                                │───────────────────────────►│                            │
     │           requestId            │                            │  validators run Qwen3-30B  │
     │◄───────────────────────────────│                            │  (seed fixed, temp=0)      │
     │                                │   handleResponse(reqId,...) │                            │
     │                                │◄───────────────────────────│  Majority consensus        │
     │                                │ decode label/scores         │                            │
     │                                │ staleness check (I-10)      │                            │
     │                                │ project → targets[]         │                            │
     │                                │  reallocate(targets, guard) │                            │
     │                                │────────────────────────────────────────────────────────►│
     │                                │                            │  re-validate I-1..I-10      │
     │                                │                            │  execute minimal deltas     │
     │                                │      Rebalanced / Rejected  │  (CEI, nonReentrant)        │
     │                                │◄────────────────────────────────────────────────────────│
```

**Fail-safe branches:** `Failed`/`TimedOut`/empty → emit `RebalanceSkipped(reason)`, no movement. Invariant rejection inside `reallocate` → revert with reason or emit `RebalanceRejected(invariantId)` and leave funds untouched. Either way the vault stays in its last safe allocation (P-5).

### 8.5 The yield signal (objective-function input without external oracles)

The Strategist needs a per-market "attractiveness" signal beyond utilization. To honor NG-1 (no mandatory external oracle) while staying realistic:

- **Primary:** add `supplyRateBps()` to the market interface — the market's *current supply APY in bps*. Real lending markets expose this; the mock computes it from its interest model (§14.3). This is an on-chain view, consensus-trivial.
- **Optional augmentation (documented, not required):** a Somnia **JSON API agent** (`fetchUint`, 0.03/validator) could pull an external benchmark rate; if used, it MUST be treated as just another *feature*, never as a constraint, and the design must tolerate its absence. Keep this behind a flag; v2 core uses only on-chain `supplyRateBps`.

### 8.6 Why not just let the AI move funds directly?

Because that would make the AI a treasurer, not an advisor (violates the Golden Rule, P-2, P-7). The requested architecture — and the correct one — is: **AI as untrusted ALLOCATOR proposing arrays; EVM validates against hard invariants before any physical routing.** §10 specifies those invariants formally; §11 specifies the deterministic projection that makes any AI output *feasible by construction or rejected*.

---

## 9. Prompt Engineering Strategy (the explicit fix for the stated problem)

This section is the heart of "the prompt strategy is not well-defined." It applies to **both** AI arms.

### 9.1 The five prompt-design laws

- **L-1 Decide what the AI is for.** Only ask the model questions arithmetic can't answer (regime judgment, relative ranking). Never ask it to evaluate a fixed numeric threshold — that's on-chain (P-1).
- **L-2 Lossless canonical input.** Integers only, basis points, fixed field order, fixed units, no locale formatting, no truncation, markets always serialized in **canonical order** (e.g., ascending market index). Determinism of the *input string* across validators is as important as the model's determinism.
- **L-3 Constrained output.** `inferString` with `allowedValues` (enum) or `inferNumber` with a clamp range. Never free-form for a decision that drives money. `chainOfThought=false` for single-shot decisions (a visible thought stream is extra tokens that can diverge across validators and break Majority consensus).
- **L-4 Unambiguous rubric.** The system prompt specifies the mapping from features to the allowed outputs with explicit, closed definitions and explicit boundary handling — but only over the *judgment* dimension, since thresholds are on-chain.
- **L-5 Pin and test the prompt.** The exact system prompt and the feature-encoding grammar are **constants with unit tests** (golden-string tests). A prompt change is a reviewed, versioned event (`PROMPT_VERSION` recorded in the audit trail).

### 9.2 Determinism checklist (consensus-safety; MUST pass before mainnet)

- [ ] Output is enum-constrained or clamped-integer (never free text driving funds).
- [ ] `chainOfThought=false` on consensus-critical calls (or justified + tested if on).
- [ ] Feature string is byte-identical for identical chain state (no addresses unless lowercased/checksum-fixed, no timestamps inside the prompt, canonical market ordering).
- [ ] No floating point anywhere; bps integers only.
- [ ] Prompt + system are compile-time constants except for the feature block.
- [ ] `allowedValues` enumerated exactly and matched on-chain by `keccak256` comparison.

### 9.3 Canonical feature-block grammar (lossless, fixed)

Define a single, pinned grammar used by both arms. Conceptually (the implementer renders this deterministically; exact rendering is unit-pinned):

```
PORTFOLIO|ta=<totalAssetsUSDC>|idle=<idleBps>|mkts=<count>|epoch=<n>
M<i>|util=<utilBps>|alloc=<allocBps>|cap=<capHeadroomBps>|rate=<supplyRateBps>
M<i+1>|...
```

- `capHeadroomBps` = remaining room under the supply cap, in bps of totalAssets, so the model sees how much *can* be added without the EVM clipping it.
- Markets emitted in ascending index order, every time.
- All values integers, bps where ratios, USDC base units where amounts.

This replaces the v1 human-sentence prompt and the buggy `_u` formatter (fixes **D-2**) and never truncates (fixes **D-3**).

### 9.4 System prompts (semantic specification — implementer pins exact text)

**RiskSentinel regime classifier** (`allowedValues=["STABLE","WATCH","DETERIORATING"]`):
- Role: "You are a portfolio-risk regime classifier for a lending vault. You are given canonical integer features in basis points. The contract already enforces all hard numeric limits; your job is to judge the *overall trajectory and concentration* of risk that no single limit captures."
- Output exactly one of the allowed words. Define each word qualitatively (e.g., DETERIORATING = multiple markets crowding their caution bands and/or rising utilization dispersion). No numbers in the output, no punctuation, no explanation.

**AllocationStrategist Tier-1 selector** (`allowedValues=["DEFENSIVE","BALANCED","YIELD_TILT","DERISK"]`):
- Role: "You are a capital-allocation policy selector for a lending vault. Choose the single policy best matching current conditions. The contract converts your choice into a concrete, cap-respecting allocation; you only choose the policy."
- Define each policy's intent precisely and the conditions favoring it (e.g., DERISK when any market is near its caution utilization; YIELD_TILT only when all markets are comfortably below caution and rate dispersion is meaningful).

**AllocationStrategist Tier-2 scorer** (`inferNumber`, clamp `[0, 10000]`):
- Role: "Given this market's features in the portfolio context, output a single integer attractiveness score in [0,10000], higher = more capital deserved, penalizing high utilization and rewarding higher supply rate, but never exceeding what the cap allows."
- The clamp + single-integer output is the consensus guarantee.

### 9.5 Output parsing

- `inferString`: compare `keccak256(bytes(result))` against the pinned enum hashes; **unknown → fail-safe** (RiskSentinel: treat as `WATCH`/no-deescalation; Strategist: treat as `DEFENSIVE`/abort rebalance). Never trust an unrecognized word.
- `inferNumber`: decode to `uint256`, **re-clamp on-chain** to `[0, SCORE_MAX]` defensively (do not assume the agent clamped).

---

## 10. The Invariant System (the constitution — formal)

These are enforced **inside `CuratedVault.reallocate(targets, guard)`** and the existing allocate/deallocate paths. If **any** fails, the whole reallocation reverts/rejects atomically (fail-closed). This is what makes the AI safe to be untrusted.

| ID | Invariant | Formal statement | Rationale |
|---|---|---|---|
| **I-1** | **Conservation** | `Σ target_i + targetIdle == totalAssets` (within a defined rounding epsilon; rounding favors idle) | No funds created/destroyed; reallocation is a permutation of existing assets. |
| **I-2** | **Cap compliance** | `∀i: target_i ≤ supplyCap_i` | MetaMorpho's core guarantee; AI can never over-expose a market. |
| **I-3** | **Idle floor** | `targetIdle ≥ minIdleBufferBps × totalAssets / 1e4` | Guarantees withdrawal liquidity; prevents redeem failures/forced unwinds (fixes D-7). |
| **I-4** | **Max concentration** | `∀i: target_i ≤ maxMarketBps × totalAssets / 1e4` | Diversification limit independent of (possibly generous) caps. |
| **I-5** | **Whitelist** | `∀i ∉ enabledMarkets: target_i == 0` | Funds only ever sit in curator-approved markets. |
| **I-6** | **Turnover bound** | `Σ |target_i − current_i| ≤ maxTurnoverBps × totalAssets / 1e4` | Bounds churn, gas, MEV, and the blast radius of a single bad proposal (P-7). |
| **I-7** | **Liquidity-aware moves** | Every withdrawal ≤ market's redeemable balance; partial-fill or revert, never silent shortfall | Markets may be illiquid; never assume full withdrawability. |
| **I-8** | **Epoch / cooldown** | One executed rebalance per `rebalanceEpoch` per vault | Anti-thrash, anti-DoS, predictable cadence. |
| **I-9** | **Pause respect** | If `depositsPaused`, allocation *into* markets is forbidden; deallocation still allowed | Don't add risk while the circuit-breaker is tripped. |
| **I-10** | **Staleness guard** | `|totalAssets_now − totalAssets_atRequest| ≤ driftToleranceBps × totalAssets_atRequest / 1e4`, and `epoch_now == epoch_atRequest` | The AI judged a snapshot; reject if reality drifted materially (sandwich/large flow between request and callback). |

Supporting non-AI invariants (retained from v1, restated): ERC-4626 share math via virtual offsets; CEI ordering; `nonReentrant` on all external state-changing entrypoints; role gating; timelock for risk-increasing curator actions.

**Rounding policy:** floor when allocating to markets, ceil when computing the required idle floor — always round in the depositor's favor so I-1/I-3 can't be gamed by dust.

---

## 11. The Deterministic Allocation Projection (the math)

This pure function converts *any* AI output into a **feasible** target or proves none exists (→ stay defensive). It runs in the Strategist (off-the-money) and its result is **re-checked** by the vault (I-1..I-10).

**Inputs:** `A = totalAssets`; per enabled market `i`: current balance `b_i`, cap `c_i`; risk params `minIdleBufferBps (fIdle)`, `maxMarketBps (mMax)`, `maxTurnoverBps (tMax)`; AI weights `w_i ≥ 0` (Tier-2 scores, or Tier-1 policy-derived weights).

**Step 1 — Budget.** Allocatable budget `B = A − ceil(fIdle × A / 1e4)`. (Reserve the idle floor first; I-3 holds by construction.)

**Step 2 — Per-market ceiling.** `u_i = min(c_i, floor(mMax × A / 1e4))`. (Encodes I-2 and I-4 together.)

**Step 3 — Desired split.** If `Σ w_j == 0` → all weights zero → `target_i = 0 ∀i`, everything idle (fully defensive; valid). Else desired `d_i = floor(w_i × B / Σ w_j)`.

**Step 4 — Capped water-filling (projection onto the box).**
- Clip `t_i = min(d_i, u_i)`.
- Compute overflow `O = Σ(d_i − t_i)` (mass that hit ceilings) and the set `U` of markets still below their ceiling.
- Redistribute `O` across `U` proportionally to their remaining headroom `(u_i − t_i)`, iterate until `O == 0` or no headroom remains.
- Any residue that can't be placed (all ceilings reached) **stays idle** (≥ floor — strengthens I-3, never weakens it).

**Step 5 — Turnover cap (I-6).** Let `T = Σ|t_i − b_i|`. If `T > tMax × A / 1e4`, **scale the move toward target**: choose `λ ∈ [0,1]` maximal such that `Σ|b_i + λ(t_i − b_i) − b_i| ≤ tMax×A/1e4`, i.e. `λ = (tMax×A/1e4) / T`; set `final_i = b_i + floor(λ(t_i − b_i))`. This moves *partway* to the AI's target, never more than the turnover budget. (Bounds blast radius; the next epoch can continue converging.)

**Step 6 — Execute minimal deltas (in the vault).**
- Phase A: for markets where `final_i < b_i`, **withdraw** `b_i − final_i` (raises idle first — guarantees liquidity for Phase B).
- Phase B: for markets where `final_i > b_i`, **supply** `final_i − b_i` (now funded from idle).
- Re-assert I-1..I-10 on the resulting state; revert if any fails.

**Properties (state these as test assertions):**
- *Feasibility:* the output of Steps 1–5 satisfies I-1..I-6 for any non-negative `w`.
- *Monotone safety:* increasing any `w_i` can never push `final_i` above `u_i`.
- *Idle dominance:* `final` always leaves `targetIdle ≥ floor`.
- *Bounded move:* total turnover ≤ `tMax`.
- *Determinism:* identical inputs → identical outputs (no ordering ambiguity; iterate markets in canonical index order).

```
   AI weights w_i
        │
        ▼
 [Reserve idle floor]──► B               (I-3)
        │
        ▼
 [Box ceilings u_i=min(cap,maxMkt)]      (I-2,I-4)
        │
        ▼
 [Proportional split d_i]
        │
        ▼
 [Capped water-fill → t_i]  ──► residue to idle
        │
        ▼
 [Turnover scale λ → final_i]            (I-6)
        │
        ▼
 [Vault executes deltas, re-checks I-1..I-10]  ──► Rebalanced | Rejected(fail-closed)
```

---

## 12. Roles & Permissions

### 12.1 Matrix

| Capability | DEFAULT_ADMIN | CURATOR | ALLOCATOR (Strategist) | SENTINEL (RiskSentinel) | Anyone |
|---|---|---|---|---|---|
| Grant/revoke roles | ✅ | — | — | — | — |
| Add market (timelocked) | — | ✅ | — | — | — |
| Raise supply cap (timelocked) | — | ✅ | — | — | — |
| Lower supply cap (immediate) | — | ✅ | — | ✅ | — |
| Set risk params (risk-increasing → timelocked) | — | ✅ | — | — | — |
| Set risk params (risk-reducing → immediate) | — | ✅ | — | ✅ (subset) | — |
| `reallocate(targets)` | — | — | ✅ | — | — |
| `pauseDeposits` | — | — | — | ✅ | — |
| `unpauseDeposits` | ✅ | — | — | — | — |
| `emergencyDeallocate` | — | — | — | ✅ | — |
| Revoke pending timelock action | — | ✅ | — | ✅ | — |
| Trigger AI risk check (pays STT) | open | open | open | open | ✅ |
| Trigger AI rebalance (pays STT) | open | open | open | open | ✅ |
| Replace Strategist / Sentinel (regrant role) | ✅ | — | — | — | — |

**Note:** triggering is permissionless (anyone can pay STT to request a check/rebalance), but *acting* is constrained: the Strategist can only `reallocate` within invariants; the Sentinel can only reduce risk. This mirrors v1's "anyone can call `checkVault`."

### 12.2 Replaceability (generalize v1's ReplaceSentinel)

- `AllocationStrategist` and `RiskSentinel` are external contracts holding roles. Admin can `revokeRole` the old and `grantRole` the new without touching the vault — enabling prompt upgrades, model-id changes, and bug fixes without migrating funds.

---

## 13. Storage & Interface Design (theory, not code)

### 13.1 CuratedVault additions

- `RiskParameters` struct (all bps + epoch length) with curator setters (risk-increasing timelocked).
- `reallocate(MarketTarget[] targets, RebalanceGuard guard)` — the single invariant-checked entrypoint for the Strategist; `MarketTarget = {market, targetAssets}`, `RebalanceGuard = {epoch, totalAssetsAtRequest, snapshotHash}`.
- `lastRebalanceEpoch` per-vault counter; `currentEpoch()` derived from `block.timestamp / rebalanceEpoch`.
- bps-precision view metrics: `utilizationBps` (per market, already exists on market), `allocationBps(market)`, `idleBufferBps()` (replace integer-percent versions; fixes D-3).
- Events: `Rebalanced(epoch, deltas…, turnover)`, `RebalanceRejected(invariantId)`, `RiskParamUpdated(...)`.

### 13.2 RiskSentinel

- On-chain `assessOnChain(vault) view → (HardLevel, worstMarket, maxUtilBps, maxAllocBps, idleBps)`.
- AI request/response plumbing (kept from v1 but generalized), `EffectiveLevel` computation (§7.4), immutable history with `PROMPT_VERSION`.

### 13.3 AllocationStrategist

- `AllocationMode` (Tier-1/Tier-2) curator-set.
- `requestRebalance(vault)` payable; snapshots features + computes `snapshotHash`; binds `requestId → {vault, epoch, snapshotHash}`.
- Tier-1 callback: decode label → policy → deterministic weights → project → `vault.reallocate`.
- Tier-2: orchestrate N `inferNumber` calls (or one advanced batched request if the live agent supports a vector return — verify in Appendix B); collect scores; project; reallocate. Track partial responses; require all-N (or a quorum) before projecting; timeout → skip.
- Audit: `Proposal` records with raw AI output, projected targets, executed deltas, outcome.

### 13.4 ISomnia extensions

- Keep `IAgentRequester`, callback, structs, `ConsensusType`, `ResponseStatus`.
- Add `ILLMInferenceAgent.inferNumber(...)` and (commented, future) `inferToolsChat(...)` — **with exact signatures regenerated from the agent explorer** (Appendix B).

---

## 14. Mock Specifications (complete, deterministic test doubles)

Mocks MUST let tests reproduce every real behavior — including adversarial AI and validator disagreement — without network access.

### 14.1 MockUSDC

- Keep as-is (6-dec, open `mint`). Sufficient.

### 14.2 MockSomniaPlatform (significantly extended)

Must faithfully model the two-phase async flow and consensus, and enable adversarial tests:

- **`createRequest` / `createAdvancedRequest`** — store `{callbackAddress, callbackSelector, payload, agentId, subSize, threshold, consensusType}`; assign incrementing `requestId`; require `msg.value ≥ minimumDeposit`; emit `RequestCreated`. Expose `getRequestDeposit()` / `getAdvancedRequestDeposit(size)`.
- **`simulateInferString(requestId, word)`** — deliver a single-word LLM result (existing `simulateCallback`, renamed/clarified).
- **`simulateInferNumber(requestId, value)`** — deliver an integer result (for Tier-2 scoring).
- **`simulateMajority(requestId, result, n, threshold)`** — deliver `n` validator `Response`s with identical bytes and `status=Success`, `responseCount=n`, `threshold` set — exercises D-6 defense-in-depth.
- **`simulateDisagreement(requestId, results[])`** — deliver divergent validator results; finalize as `Failed` (Majority not reached) — proves fail-safe.
- **`simulateTimeout(requestId)`** — keep; finalize `TimedOut`.
- **`simulateMalicious(requestId, value)`** — deliver an out-of-range / hostile score (e.g., 99999, or a label not in the enum) to prove the Strategist/vault reject or clamp it (P-3/P-7 tests).
- **Rebate behavior** — optionally transfer a configurable rebate to the requester's `receive()` to test rebate handling.
- Must call back via low-level `call` with the stored selector (so it works for both arms' callbacks), bubbling revert reasons (as v1 does).

### 14.3 MockLendingMarket (extended)

- Keep per-second compounding, `balanceOf`, `utilizationBps`, `setUtilization`, `fastForwardDays`, `onlyVault` supply/withdraw.
- **Add `supplyRateBps()`** — current supply APY in bps (the yield signal for §8.5). Derive deterministically from a settable model (e.g., base rate + slope × utilization), exposing **`setSupplyRateBps(bps)`** and/or computing from `utilizationBps` so tests can craft yield landscapes.
- **Add a settable liquidity ceiling** (`setAvailableLiquidity`) so I-7 (partial-fill / illiquid withdraw) can be tested: `withdraw` must respect available liquidity and the vault must handle a partial/blocked withdrawal gracefully.
- **Add `maxDepositable()` / behavior at cap** so cap-edge allocation can be exercised.

### 14.4 MockMaliciousMarket (new, optional but recommended)

- A market that reverts on `withdraw`, lies about `balanceOf`, or tries to reenter — to prove I-7, CEI, and `nonReentrant` hold. Even though only whitelisted markets are used, defense-in-depth testing is cheap and valuable.

### 14.5 Test scenario fixtures (deterministic worlds)

Provide helper setups: `world_safe` (all markets healthy, room under caps), `world_caution` (one market in caution band), `world_critical` (a market over critical util), `world_yield_dispersion` (rates differ widely), `world_illiquid` (a market can't fully honor withdrawals), `world_at_caps` (markets near caps so projection residue → idle).

---

## 15. Threat Model & Security Analysis (auditor lens)

### 15.1 Trust boundaries

```
 Untrusted ───────────────────────────────────────────────► Trusted
 ┌───────────────┐   ┌──────────────────┐   ┌────────────────────────────┐
 │ AI model output│   │ Strategist proj. │   │ CuratedVault custody + I-*  │
 │ (could be wrong│──►│ (deterministic,  │──►│ (authoritative; rejects any │
 │  or malicious) │   │  no money power) │   │  invariant violation)       │
 └───────────────┘   └──────────────────┘   └────────────────────────────┘
        ▲                                              ▲
        │ Somnia platform (semi-trusted: consensus)    │ Curator/Admin (governance-trusted, timelocked)
        └──────────────────────────────────────────────┘
```

### 15.2 Threats & mitigations

| ID | Threat | Mitigation |
|---|---|---|
| **T-1** | Malicious/compromised AI proposes a draining or over-concentrated allocation | I-2/I-4/I-5/I-6 in the vault: worst case is a bounded reshuffle among whitelisted, capped markets, ≤ turnover, once/epoch (P-7). The AI literally cannot exceed the box; the projection clips and the vault re-checks. |
| **T-2** | Forged callback (anyone calls `handleResponse`) | `onlyPlatform` + `pendingRequests`/`activeRequest` gating; unknown `requestId` rejected. |
| **T-3** | Sandwich / large deposit-redeem between request and callback (stale AI view) | I-10 staleness + epoch binding; reject and re-request if drift exceeds tolerance. |
| **T-4** | Validator disagreement / non-deterministic prompt → no consensus | Constrained outputs (P-3) + canonical lossless inputs (P-4) + `chainOfThought=false`; on `Failed`/`TimedOut` → fail-safe skip / caution (P-5). Tested via `simulateDisagreement`. |
| **T-5** | Idle-buffer starvation → failed user withdrawals | I-3 enforced on every rebalance; `_ensureLiquidity` retained at redeem; rounding favors idle. |
| **T-6** | Reentrancy via a market during withdraw/supply | CEI + `nonReentrant` on `reallocate`/`allocate`/`deallocate`/`deposit`/`redeem`; `MockMaliciousMarket` test. |
| **T-7** | DoS via spamming triggers | Per-vault cooldown (risk) + per-epoch (allocation) + payment requirement; one in-flight per arm. |
| **T-8** | AI never responds (platform down) | Allocation is opportunistic — no rebalance, funds stay safe. Risk circuit-breaker has on-chain hard guards independent of AI (§7.2). |
| **T-9** | Cap/rounding gaming with dust | bps math + round-in-vault's-favor policy (§10) + epsilon-bounded conservation (I-1). |
| **T-10** | Sentinel/Strategist over-reach if compromised | Least-privilege roles: Sentinel risk-reducing only; Strategist bounded by I-*; both replaceable; neither can raise caps or add markets (those are curator + timelock). |
| **T-11** | Curator turns malicious | Out of scope for AI safety, but timelock on risk-increasing actions + immediate sentinel/curator revoke gives depositors a reaction window (carried from v1; document clearly). |
| **T-12** | Prompt-injection via on-chain data the model reads | The model only reads our **own canonical numeric features**, never attacker-controlled free text/URLs in the core path (the optional JSON-API yield feature is the only external read and is treated as a non-authoritative feature). No external strings enter the prompt in v2 core. |

### 15.3 Privileged-action checklist (must be in tests)

- Every AI-driven action has a corresponding "AI is hostile" test proving funds remain within all invariants.
- Every emergency action has a "AI is silent" test proving on-chain guards still protect.

---

## 16. Failure Modes & Fail-Safe Matrix

| Event | RiskSentinel behavior | AllocationStrategist behavior |
|---|---|---|
| AI `Success`, recognized output | Apply EffectiveLevel (§7.4) | Project + reallocate (within I-*) |
| AI `Success`, unrecognized output | Treat as no-deescalation (≥ Hard) | Abort rebalance (treat as DEFENSIVE/skip) |
| AI `Failed` | EffectiveLevel = Hard; record `AI_UNAVAILABLE` | `RebalanceSkipped(FAILED)`, no move |
| AI `TimedOut` | EffectiveLevel = Hard; record `AI_UNAVAILABLE` | `RebalanceSkipped(TIMEOUT)`, no move |
| Empty responses | As `Failed` | As `Failed` |
| Invariant rejection at execute | n/a | `RebalanceRejected(I-x)`, funds untouched |
| Staleness drift exceeded | n/a | `RebalanceRejected(STALE)`, re-request next epoch |
| Market illiquid on withdraw | Partial emergency-deallocate, emit shortfall | Partial-fill per I-7 or reject |
| Vault paused | Emergency actions still allowed | Allocation-in forbidden (I-9); deallocation allowed |

Principle restated: **the system's worst-case behavior under any AI failure is "do nothing / stay safe," never "do something unsafe."**

---

## 17. Economics, Gas & Cost Analysis

- **Per AI call:** `getRequestDeposit() + 0.07 × subSize` STT. Tier-1 = 1 call/rebalance. Tier-2 = N calls/rebalance (N = enabled markets). Risk check = 1 call.
- **Deposit handling:** always compute at call time; implement `receive()` for rebates (D-4 fix). Document expected per-action cost in README and reconcile the 0.15 vs 0.25 discrepancy to a single computed value.
- **Somnia gas multiplier:** keep the `--gas-estimate-multiplier 3000` deployment guidance (~27× EVM estimates) from v1.
- **Epoch sizing trade-off:** shorter `rebalanceEpoch` = more responsive but more STT spend and more churn; longer = cheaper, calmer. Make it curator-tunable; default conservative.
- **Tier choice trade-off:** Tier-1 (cheap, coarse) vs Tier-2 (N× cost, fine-grained). Document so curators choose deliberately.

---

## 18. Testing Strategy & Acceptance Criteria

### 18.1 Test layers

1. **Unit (pure math):** projection (§11) feasibility/monotonicity/idle-dominance/turnover/determinism; bps metric calculations; prompt feature-encoding golden strings (§9.3); enum hash matching.
2. **Component:** RiskSentinel `assessOnChain` truth table; EffectiveLevel precedence table (§7.4); Strategist tier flows with mocked callbacks.
3. **Integration (end-to-end via mocks):** full request→consensus→callback→reallocate for Tier-1 and Tier-2; risk check→critical→pause+deallocate.
4. **Adversarial:** hostile AI outputs; validator disagreement; timeout; malicious market; staleness; cap edges; illiquidity.
5. **Property/fuzz (Foundry, 256 runs):** for random non-negative weights and random feasible chain states, the post-rebalance state satisfies **all** I-* (this is the headline safety proof).
6. **Invariant tests (Foundry invariant mode):** across random sequences of deposit/redeem/rebalance/risk-check, `totalAssets` conservation, idle floor, cap compliance, and no-unauthorized-cap-increase always hold.

### 18.2 Acceptance criteria (sample — implementer expands to cover every R/I)

- **AC-1** Deposit/redeem/share-price match v1 semantics (regression).
- **AC-2** `assessOnChain` returns the **true** worst market (argmax util) — D-1 regression test.
- **AC-3** No hardcoded agent deposit anywhere; all use `getRequestDeposit()+reward` — D-4 regression.
- **AC-4** All ratio metrics are bps; no integer-percent path remains — D-3 regression.
- **AC-5** Given a malicious Tier-2 score vector `[10000, 0]` on a market whose cap is 30% of assets, post-rebalance that market's balance ≤ `min(cap, maxMarketBps)` — I-2/I-4.
- **AC-6** Given any AI weights, `targetIdle ≥ minIdleBufferBps` — I-3 (fuzzed).
- **AC-7** Turnover of any single rebalance ≤ `maxTurnoverBps` — I-6 (fuzzed).
- **AC-8** AI `TimedOut`/`Failed`/unknown-word → no fund movement (allocation) / no de-escalation (risk) — P-5.
- **AC-9** Forged `handleResponse` from a non-platform caller reverts — T-2.
- **AC-10** Staleness beyond `driftToleranceBps` rejects the rebalance — I-10.
- **AC-11** Reentrant market cannot break accounting — T-6.
- **AC-12** EffectiveLevel never below HardLevel for any AI input — §7.4.

### 18.3 Tooling

- Foundry: `forge test -vvv`, `forge test --match-contract`, fuzz 256, invariant mode, `forge snapshot` for gas, `forge fmt`. Keep Solidity 0.8.20 / EVM paris / optimizer 200 from v1.

---

## 19. Deployment & Migration Plan

1. **Deploy core:** `MockUSDC`, two `MockLendingMarket`s (with `supplyRateBps`), `CuratedVault` (with risk params).
2. **Deploy arms:** `RiskSentinel`, `AllocationStrategist` (mode = Tier-1).
3. **Wire roles:** grant `SENTINEL_ROLE` → RiskSentinel; `ALLOCATOR_ROLE` → Strategist; keep curator/admin.
4. **Timelock market adds** (submit → wait → execute), seed caps and risk params.
5. **Trigger flows:** `cast send` for risk check and rebalance (forge-script simulation fails on Somnia `NotActivated` — keep v1's `cast send` guidance), value computed from on-chain deposit helper.
6. **Replace-arm scripts:** generalize `ReplaceSentinel.s.sol` to also replace the Strategist.
7. **Verify-response scripts:** read back latest risk verdict and latest rebalance proposal.

Reconcile all docs (README, CLAUDE.md) to: bps metrics, computed deposits, the two-arm architecture, and the corrected cost figure.

---

## 20. Phased Roadmap

| Phase | Deliverable | Risk |
|---|---|---|
| **0** | Audit-fix pass: D-1..D-7 on the existing system; bps migration | Low |
| **1** | RiskSentinel redesign (on-chain hard guards + narrowed AI second-opinion + precedence rule) | Low |
| **2** | Invariant system in `CuratedVault.reallocate` + projection math (§11) — *no AI yet*, exercised by a stub allocator | Medium |
| **3** | AllocationStrategist **Tier-1** (strategy-label) end-to-end | Medium |
| **4** | AllocationStrategist **Tier-2** (per-market scoring) | Medium |
| **5 (future, NG-3)** | **Tier-3** `inferToolsChat` allocator — model yields candidate moves, vault re-validates every move against I-*; only after consensus behavior on structured output is proven and an audit is done | High |
| **6 (future)** | Reactive/scheduled triggers if a native Somnia scheduler is confirmed; otherwise keeper/cron off-chain. Treat as optional; the permissionless `requestRebalance` keeper model is the live anchor. | Low |

**Order rationale:** build the constitution (Phase 2) *before* the brain (Phases 3–4), so the brain is born into a cage. Never ship an AI arm before its invariants exist and are fuzz-proven.

---

## 21. Open Decisions for the Implementer

- **OD-1 Tier-2 batching:** verify on `agents.somnia.network` whether the LLM agent can return a numeric **vector** in one call (cheaper, but check consensus behavior) vs N single `inferNumber` calls. Default to N calls if a consensus-safe vector return isn't confirmed.
- **OD-2 Idle floor vs supplyQueue:** decide whether idle is a pure floor (simpler) or a managed reserve with a target band. Spec assumes a floor.
- **OD-3 Risk param change asymmetry:** confirm exactly which risk-param changes are risk-increasing (timelocked) vs risk-reducing (immediate). Spec proposes: lowering caps / raising idle floor / lowering maxMarket / lowering turnover = immediate; the inverses = timelocked.
- **OD-4 Worst-market emergency fraction:** keep 50% default `pullBps`, or make it scale with how far over the critical threshold the market is. Spec keeps a curator-set constant for v2.
- **OD-5 Multi-vault:** the arms are written per-vault-registry; confirm whether v2 targets one vault (simpler) or many.
- **OD-6 Prompt versioning:** confirm `PROMPT_VERSION` is recorded in every audit record and bumped on any system-prompt/grammar change.

---

## 22. Requirements Traceability (condensed)

| Requirement | Addressed by |
|---|---|
| R-1 Move risk arithmetic on-chain | §7.2, P-1 |
| R-2 Redesign prompt strategy | §9 (L-1..L-5, grammar, system prompts) |
| R-3 Autonomous allocation w/ EVM guardrails | §8, §10, §11 |
| R-4 No AI output can break invariants | §10 (enforced in vault), §11 (projection), §15 |
| R-5 Fail-safe under AI failure | §7.4, §8.4, §16, P-5 |
| R-6 Live-deployable on Somnia | §4, §8.3 Tier-1/2, §19 |
| R-7 Complete mocks incl. adversarial | §14 |
| R-8 Fix D-1..D-7 | §2.4, §18.2 AC-2/3/4 |
| R-9 Diagrams & theory, no code | This document |

---

## Appendix A — Glossary

- **bps** — basis points; 1% = 100 bps; 100% = 10,000 bps.
- **Subcommittee** — the set of validators elected to execute an agent request.
- **Majority consensus** — finalization requires ≥ threshold validators returning byte-identical result bytes; only reachable for LLM agents because of fixed seed + temp=0.
- **Operations reserve / reward pot** — the two parts of the agent deposit: gas-refund floor (`getRequestDeposit()`) and per-agent reward (`price × size`).
- **Idle floor** — minimum fraction of assets kept un-allocated for withdrawal liquidity.
- **Turnover** — total absolute asset movement in a single rebalance.
- **Projection** — deterministic mapping of AI weights onto the feasible (cap/idle/concentration/turnover-respecting) set.
- **Epoch** — the minimum interval between executed rebalances.

## Appendix B — Interface Verification Checklist (MUST do before coding)

1. Visit `https://agents.somnia.network` (testnet: `agents.testnet.somnia.network`), open the **LLM Inference** agent, and copy the **exact** Solidity signatures for `inferString`, `inferNumber`, `inferChat`, `inferToolsChat`. Treat §4.2 as semantics only.
2. Copy the real **LLM Inference `agentId`** (same on testnet/mainnet per docs) into config; never hardcode a placeholder.
3. Confirm `getRequestDeposit()` and `getAdvancedRequestDeposit(size)` return values on the target network; size deposits from them at runtime.
4. Confirm callback signature `handleResponse(uint256, Response[], ResponseStatus, Request)` and that the selector passed to `createRequest` matches your function exactly.
5. Confirm platform address for the target chain (testnet `0x037Bb9C718F3f7fe5eCBDB0b600D607b52706776`, mainnet `0x5E5205CF39E766118C01636bED000A54D93163E6`).
6. Re-confirm per-agent LLM price (0.07) and default subcommittee (3) on the **Gas Fees** doc; update constants if changed.

## Appendix C — Prompt Templates (semantic; pin exact text in code, version it)

**Risk regime — system (allowedValues = STABLE | WATCH | DETERIORATING):**
> "You are a portfolio-risk regime classifier for a lending vault. Inputs are canonical integer features in basis points, markets in fixed order. The smart contract already enforces every hard numeric limit; judge only the overall trajectory and concentration of risk that no single limit captures. Reply with exactly one of: STABLE, WATCH, DETERIORATING. No other text."

**Allocation policy — system (allowedValues = DEFENSIVE | BALANCED | YIELD_TILT | DERISK):**
> "You are a capital-allocation policy selector for a lending vault. Choose the single policy that best fits current conditions; the contract converts your choice into a concrete, cap-respecting allocation. Prefer DERISK or DEFENSIVE when any market nears its caution utilization or the idle buffer is thin; prefer YIELD_TILT only when all markets are comfortably healthy and supply-rate dispersion is meaningful; otherwise BALANCED. Reply with exactly one policy word. No other text."

**Allocation score — system (inferNumber, clamp [0,10000]):**
> "Given one market's features within the portfolio context, output a single integer in [0,10000] for how much capital it deserves: reward higher supply rate, penalize higher utilization and thin cap headroom. Output only the integer."

**Feature block (user prompt) — pinned grammar (§9.3).** Rendered deterministically; covered by golden-string unit tests; `PROMPT_VERSION` bumped on any change.

---

*End of SDD v2.0. The implementing agent should now produce an implementation plan mapping every R-*, I-*, AC-*, and D-* to files, functions, and tests, then build Phase 0 → Phase 4, with Phase 2 (the constitution) preceding any AI allocation arm.*
