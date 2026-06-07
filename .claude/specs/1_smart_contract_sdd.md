# Ephor Protocol — Specification-Driven Development Document (v2.2)

> **Autonomous AI Risk + Allocation Layer for ERC-4626 Vaults on the Somnia Agentic L1**
>
> **Document type:** Specification-Driven Development (SDD) / Technical Design Document (TDD)
> **Status:** Draft for implementation
> **Version:** 2.2 — corrects USDC-specific assumptions; vault is asset-agnostic; adds market lifecycle; fixes decimal handling
> **Changelog from v2.1:** Removed all USDC-specific language throughout; vault accepts any ERC-20 asset configured at deployment; fixed §6.1 decimal assumption; fixed §9.3 feature block label; clarified market addition lifecycle (§5.4); updated §13, §14, §19, §21, Appendix A
> **Changelog from v2.0→v2.1:** Added D-8, G-8, P-9, I-11, §7.7 (UtilizationOracle + dual-track TWAP)
> **Audience:** Claude Code (implementer) + human reviewers
> **Authoring lens:** Lead software engineer · blockchain protocol engineer · smart-contract security auditor
> **Scope:** Theory, architecture, invariants, prompt strategy, mocks, threat model, test plan. **No production Solidity in this file.**

---

## 0. How To Use This Document

This is a **specification**, not an implementation. It is written to be handed to an autonomous coding agent (Claude Code) that will:

1. Read this entire document top to bottom **before writing any code**.
2. Produce a short implementation plan mapping each `R-*`, `I-*`, `AC-*`, and `D-*` to concrete files, functions, and tests.
3. Implement contracts, mocks, scripts, and tests satisfying every `MUST`; document every deviation from a `SHOULD`.
4. Verify against live Somnia primitives (§4, Appendix B) — re-generate exact agent interfaces from `https://agents.somnia.network`.

**Normative language.** MUST / MUST NOT / SHOULD / SHOULD NOT / MAY follow RFC-2119.

**Golden rule (read twice):**
> **The EVM is the constitution. The AI is an advisor with no signing authority.**
> Every number the AI emits is a *request*, never a *command*. The vault re-derives, re-validates, and re-bounds everything at the custody boundary before a single wei moves.

**Second golden rule (v2.1):**
> **Every metric fed to a risk decision MUST be manipulation-resistant.**
> A spot read from any external contract is a weapon. The sentinel MUST NEVER use raw spot utilization as the sole input to any threshold comparison or AI feature. All utilization inputs go through the UtilizationOracle dual-track filter first.

**Third golden rule (v2.2):**
> **The vault is asset-agnostic. Never hardcode USDC, 6 decimals, or any specific token.**
> The vault's ERC-20 asset is configured at deployment and is immutable thereafter. Every lending market added by the curator must lend and return that same asset. The AI, the oracle, the mocks, and all arithmetic must work correctly regardless of the asset's decimal count or token type.

---

## 1. Executive Summary

Ephor Protocol is an **ERC-4626 yield vault for any configured ERC-20 asset** on Somnia. It uses Somnia's native, validator-consensus LLM inference to (a) **defend** the vault (autonomous risk circuit-breaker) and (b) **grow** the vault (autonomous capital allocation across lending markets). The vault's asset — which token it holds, lends, and distributes yield in — is set once at deployment by the owner and never changes.

**What the owner can configure after deployment:**
- Add new lending markets (timelocked, requires curator role)
- Set and adjust per-market supply caps
- Set and adjust risk parameters (idle floor, concentration limits, thresholds)
- Replace the AI arms (RiskSentinel, AllocationStrategist) without touching the vault
- Add market adapters in the oracle for each new market

The v1 system works but has four classes of problem this SDD resolves:

1. **The prompt strategy asks the LLM to do the EVM's job.** Fixed arithmetic thresholds belong on-chain. The AI should judge patterns, not run calculators. (§2.3, §7, §9.)
2. **Structural correctness and precision defects.** Seven bugs including wrong worst-market selection, broken number formatter, integer-percent precision loss, under-funded agent deposit. (§2.4, D-1..D-7.)
3. **No allocation brain.** Capital movement is manual. v2 adds an AI Allocation Strategist that proposes target allocations the vault validates and executes. (§8, §10, §11.)
4. **Flash-loan manipulation of spot utilization.** Any spot read from an external market is manipulable. A TWAP oracle is required. (§2.4 D-8, §7.7.)

The redesign separates two AI agents with least-privilege, replaceable roles:

| Agent | Posture | Role held | Can do | Can never do |
|---|---|---|---|---|
| **RiskSentinel** | Defensive (circuit-breaker) | `SENTINEL_ROLE` | Pause deposits, emergency-deallocate, lower caps | Add markets, raise caps, move funds *into* markets |
| **AllocationStrategist** | Offensive (yield optimizer) | `ALLOCATOR_ROLE` | Propose a target allocation vector; trigger a validated rebalance | Exceed any cap, breach the idle floor, exceed turnover/concentration limits, touch a non-whitelisted market |

Both agents are smart contracts bounded by EVM invariants enforced inside the vault's `reallocate` entrypoint. All utilization data passes through the UtilizationOracle before any risk decision is made.

---

## 2. Background & Analysis of the Current System

### 2.1 What exists today (v1)

- `CuratedVault` — ERC-4626 vault with a **configurable ERC-20 asset** (currently deployed with USDC for testnet, but the contract accepts any ERC-20 at construction). Inline ERC-20 share token, inline AccessControl/ReentrancyGuard, virtual-shares/assets inflation protection (VSHARES=VASSETS=1), timelocked market additions and cap increases, immediate cap decreases and revocations, performance fee accrual, `_ensureLiquidity` withdrawal pull-down.
- `VaultSentinel` — reads five metrics, builds a plain-English prompt, calls `inferString` with `allowedValues=[SAFE,CAUTION,CRITICAL]`, and on CRITICAL pauses deposits and deallocates 50% of the "worst" market.
- `ISomnia.sol` — accurate transcription of the real platform interface.
- Mocks — `MockERC20` (configurable decimals, open mint; deployed as 6-decimal USDC for testnet), `MockLendingMarket`, `MockSomniaPlatform`.

### 2.2 What is genuinely good and MUST be preserved

- **ERC-4626 inflation-attack protection** via virtual offsets — keep.
- **Asset-agnostic vault design** — the vault accepts any ERC-20 at construction. This MUST remain. No USDC-specific logic anywhere in the core vault.
- **Role separation with risk-reducing-only sentinel** — keep; mirrors production Morpho V2.
- **Timelocked risk-increasing actions** with immediate risk-reducing actions — keep.
- **`onlyPlatform` + `pendingRequests` callback gating** and fail-safe philosophy — keep.
- **CEI + `nonReentrant`** discipline — keep.
- **Exact callback name/selector discipline** — keep.

### 2.3 The core problem: the prompt strategy (root-cause analysis)

The current system prompt instructs the model:

> *"CRITICAL if ANY: (1) any market allocation > 40%; (2) idle buffer < 5%; (3) any market utilization > 95%"*

This is the central design error. These are deterministic numeric predicates that belong on-chain, not in an LLM. The four resulting failure modes:

- **F1 — Boundary ambiguity + precision loss.** The prompt truncates `utilBps/100`, so 9499 and 9450 both render as "94%", erasing the 95% boundary the rule depends on.
- **F2 — Consensus fragility.** Somnia requires byte-identical output across validators. Complex free-form reasoning over text creates divergence risk.
- **F3 — Wasted capability.** Using an LLM to evaluate `if (x > 40)` wastes the tool built for pattern recognition.
- **F4 — No auditable output.** A single bare word has no per-market breakdown, no severity score, no reasoning trail.

**Resolution:** move all hard numeric thresholds on-chain as deterministic circuit-breakers; narrow the AI to judgment only (§7, §9).

### 2.4 Concrete defects found in v1 (audit findings)

| ID | Severity | Location | Finding | Required fix |
|---|---|---|---|---|
| **D-1** | High (correctness) | `VaultSentinel._deallocateWorstMarket` | `worst = m` is unconditional in the loop — always picks the last market in the list, never the highest-utilization one. | Track `worst` only inside the `if (u > worstUtil)` block. |
| **D-2** | High (liveness) | `VaultSentinel._u` formatter | Digit-count and digit-emit loops do not advance their counters — risks infinite loop / gas exhaustion. | Delete `_u`. Use canonical integer feature encoding (§9.3). |
| **D-3** | Medium (precision) | `CuratedVault.marketAllocationPct`, `idleBufferPct` | Integer percent (`*100/t`) discards sub-percent precision. Thresholds at 40% cannot distinguish 40.0% from 40.9%. | Express all ratios in **basis points (bps, /10000)**. |
| **D-4** | Medium (liveness/cost) | `README` deposit guidance (0.15 STT) | LLM costs 0.07/validator × 3 = 0.21 reward + floor ≈ 0.25 STT. 0.15 under-funds → runners skip → TimedOut. | Compute at call time: `getRequestDeposit() + LLM_COST_PER_AGENT * subcommitteeSize`. |
| **D-5** | Medium (logic redundancy) | `VaultSentinel._respondToCritical` | After AI says CRITICAL, contract re-gates on `util > 9000` before acting — AI verdict silently ignored. No clear authority. | On-chain hard guards are authoritative; AI is an escalation modifier layered on top (§7.4). |
| **D-6** | Low (consensus handling) | `VaultSentinel.handleResponse` | Reads `responses[0]`, trusts `status==Success` without verifying the agreeing set met `details.threshold`. | Verify status AND assert responseCount >= threshold. |
| **D-7** | Low (liveness) | Idle buffer | No invariant maintains a minimum idle buffer after allocation — `_ensureLiquidity` only reacts at redeem time. | Introduce curator-set `minIdleBufferBps` enforced on every allocation (I-3). |
| **D-8** | **Critical (security)** | `VaultSentinel._readMetrics` | Sentinel reads **spot utilization** from an external market in the same transaction as `checkVault`. An attacker can flash-loan to spike utilization, trigger a false emergency, then repay. Two-block defense also fails — attacker can manipulate both blocks. Real precedent: Mango Markets ($117M), Beanstalk ($182M). | Deploy `UtilizationOracle` with TWAP accumulator. Sentinel reads `effectiveUtil` from the dual-track filter, never raw spot. (§7.7) |
| **D-9** | **Critical (assumption)** | Entire codebase, documentation, mocks | **USDC-specific hardcoding throughout.** Asset decimal count (6) hardcoded; "USDC" named in prompts, docs, variable names, mock names; feature block labels USDC. The vault contract itself is asset-agnostic, but all surrounding code treats it as USDC-only. | Remove all asset-specific references. Vault asset is set at deployment. Decimal count is read from the asset contract at runtime. All references to "USDC" become "vault asset." (§2.2, §5.4, §6.1) |

---

## 3. Goals, Non-Goals, Success Criteria

### 3.1 Goals (G)

- **G-1** Re-architect so all deterministic risk arithmetic is on-chain; AI used only for genuine judgment.
- **G-2** Redesign the prompt strategy for losslessness, determinism, constrained outputs, and auditability.
- **G-3** Add an autonomous Allocation Strategist: AI proposes target allocations; EVM validates and executes.
- **G-4** Guarantee by construction that no AI output can violate a depositor-protecting invariant.
- **G-5** Preserve a fail-safe posture: AI absence/failure/timeout never harms depositors.
- **G-6** Keep the system live-deployable on Somnia today using only documented primitives.
- **G-7** Provide complete mocks enabling deterministic local testing including adversarial AI behavior.
- **G-8** Flash-loan manipulation resistance: all utilization inputs MUST be time-weighted.
- **G-9** *(New v2.2)* **Asset-agnosticism**: the vault, its AI arms, oracle, mocks, and all documentation MUST work correctly for any ERC-20 asset regardless of decimal count. No USDC-specific logic in any contract.

### 3.2 Non-Goals (NG)

- **NG-1** No cross-chain or bridging. No mandatory external price oracles for v2 core.
- **NG-2** No change to the ERC-4626 share-accounting math (virtual offsets retained).
- **NG-3** No raw-calldata agent execution (`inferToolsChat`) in v2 production path.
- **NG-4** No mainnet deployment with real funds without a formal third-party audit.
- **NG-5** *(New v2.2)* No multi-asset vault (one vault = one asset). Multiple asset types require multiple vault deployments. This is the correct ERC-4626 pattern.

### 3.3 Success criteria (high level; see §18 for full AC-*)

- Vault behaves identically to v1 for deposit/redeem/share-price for any configured ERC-20 asset.
- RiskSentinel fires hard circuit-breakers on-chain with AI as layered second opinion.
- AllocationStrategist cannot produce a state that violates any I-*.
- All agent deposits computed from `getRequestDeposit()` + reward, never hardcoded.
- A flash-loan spike of 2000+ bps in one block moves the TWAP by less than 50 bps (proven by test).
- System works correctly with WETH (18 decimals), WBTC (8 decimals), and USDC (6 decimals) in tests.
- 100% of invariants have at least one positive and one adversarial test.

---

## 4. Research Foundations

### 4.1 Somnia Agent Platform — the execution substrate

- A Somnia Agent is a sandboxed, validator-executed compute container addressable by `agentId`. Contracts invoke it with ABI-encoded calldata; result returns **asynchronously** via a callback.
- **Two-phase async model:** `createRequest{value}(agentId, callbackAddress, callbackSelector, payload)` returns a `requestId` synchronously; later the platform invokes `handleResponse(requestId, Response[] responses, ResponseStatus status, Request details)`.
- **Consensus:** `ConsensusType.Majority` requires byte-identical results across validators. LLM agents use Majority — only reachable because they run with fixed seed and temperature=0.
- **Deposit sizing:** `msg.value MUST be ≥ getRequestDeposit() + pricePerAgent × subcommitteeSize`. Implement `receive()` for unused budget rebate.
- **Status handling:** Success(2), Failed(3), TimedOut(4). Never decode `responses[0].result` on a non-success status.
- **Platform addresses:** Testnet (50312): `0x037Bb9C718F3f7fe5eCBDB0b600D607b52706776`; Mainnet (5031): `0x5E5205CF39E766118C01636bED000A54D93163E6`.

### 4.2 The LLM Inference base agent (Qwen3-30B), four methods

| Method | Output shape | Consensus safety | Use in Ephor |
|---|---|---|---|
| `inferString(prompt, system, chainOfThought, allowedValues[])` | One string, constrainable to an enum | **Highest** | Risk verdict; Tier-1 allocation strategy label |
| `inferNumber(...)` | One integer, clamped to a range | **High** | Tier-2 per-market attractiveness score |
| `inferChat(...)` | Multi-turn free text | Lower | Not used in v2 core |
| `inferToolsChat(...)` | Tool calls / calldata yielded back to contract | Lowest | Tier-3 future only |

> **Implementer action (Appendix B):** Exact parameter lists MUST be regenerated from `agents.somnia.network`.

### 4.3 Per-agent prices (for deposit sizing)

| Agent | Price / validator | Default subcommittee | Reward pot (size 3) |
|---|---|---|---|
| JSON API Request | 0.03 | 3 | 0.09 |
| **LLM Inference** | **0.07** | 3 | **0.21** |
| LLM Parse Website | 0.10 | 3 | 0.30 |

Add `getRequestDeposit()` floor. Practical LLM deposit ≈ **0.25 STT**. Never hardcode.

### 4.4 Production curated-vault patterns

- **MetaMorpho / Morpho Vaults** — ERC-4626 vaults with Curator (caps/fees, timelocked), Allocator (active allocation within caps), Sentinel (reactively reduce risk). Ephor's roles mirror this exactly; v2 makes the Allocator an AI.
- **Key MetaMorpho invariant:** supply caps guarantee allocators cannot put more than the cap amount into any single market. This is the primary protection even if the AI behaves adversarially.

### 4.5 Flash-loan manipulation — real-world precedent

- **Mango Markets (Oct 2022) — $117M:** Spot price manipulated in one transaction; borrowed against inflated collateral.
- **Beanstalk (Apr 2022) — $182M:** Flash loan used to gain temporary governance supermajority atomically.
- **Common pattern:** read an external value → attacker controls it in-block → protocol acts on the fake value. **Defense:** time-weighted averages that flash loans cannot meaningfully shift.

---

## 5. Redesigned Architecture

### 5.1 Component overview

```
                          ┌────────────────────────────────────────────────────────┐
                          │                  Somnia Agent Platform                  │
                          │  IAgentRequester · LLM Inference (Qwen3-30B)            │
                          │  Majority consensus · fixed seed · temp=0 · async cb    │
                          └──────▲──────────────────────────────────────▲───────────┘
                                 │ createRequest / handleResponse        │
           (defensive path)      │                                       │  (offensive path)
                         ┌───────┴───────┐                      ┌────────┴────────────┐
                         │  RiskSentinel │                      │ AllocationStrategist │
                         │ SENTINEL_ROLE │                      │   ALLOCATOR_ROLE     │
                         │ reads         │                      │ reads effectiveUtil  │
                         │ effectiveUtil │                      │ from oracle → AI →   │
                         │ → hard guards │                      │ projection →         │
                         │ + AI 2nd-opin │                      │ reallocate()         │
                         └───────┬───────┘                      └────────┬─────────────┘
                                 │                                        │
                         ┌───────▼────────────────────────────────────────▼───────────┐
                         │           CuratedVault (ERC-4626, any ERC-20 asset)         │
                         │  ── THE CONSTITUTION: invariant enforcement at custody ──   │
                         │  asset set at deployment · immutable                        │
                         │  deposit/redeem · share math · timelocked market mgmt       │
                         │  reallocate(targets) re-validates I-1..I-11 before moving   │
                         └───────┬────────────────────────────────────────┬────────────┘
                                 │ supply / withdraw (vault asset)         │ view metrics
                         ┌───────▼────────────────────────────────────────▼───────────┐
                         │                  UtilizationOracle                          │
                         │  TWAP accumulator per market · ring buffer checkpoints      │
                         │  effectiveUtil = dual-track(spot, twap, spikeToleranceBps)  │
                         │  permissionless update() · isValid() · SuspiciousSpike evt  │
                         └───────┬────────────────────────────────────────┬────────────┘
                                 │ IMarketAdapter.utilizationBps()         │
                         ┌───────▼──────┐  ┌─────────────────┐  ┌────────▼──────────┐
                         │ AaveAdapter  │  │ CompoundAdapter  │  │  GenericAdapter   │
                         └──────┬───────┘  └────────┬─────────┘  └────────┬──────────┘
                                │                   │                      │
                         ┌──────▼──────────┐  ┌────▼──────────┐  ┌────────▼──────────┐
                         │ Aave Pool (any  │  │ Compound cToken│  │MockLendingMarket  │
                         │ asset reserve)  │  │(any asset)     │  │(any asset, mock)  │
                         └─────────────────┘  └───────────────┘  └───────────────────┘
```

### 5.2 Module responsibilities

| Module | Responsibility | Holds | Trust level |
|---|---|---|---|
| `CuratedVault` | Custody of **vault asset**, ERC-4626 math, invariant enforcement, market registry, risk parameters, atomic `reallocate` | — | Trusted core |
| `RiskSentinel` | Defensive monitoring; on-chain hard guards via effectiveUtil; AI regime second-opinion; emergency actions | `SENTINEL_ROLE` | Semi-trusted (risk-reducing only, replaceable) |
| `AllocationStrategist` | Offensive optimization; AI proposal lifecycle; deterministic projection; trigger validated rebalances | `ALLOCATOR_ROLE` | Untrusted-by-design (bounded by vault invariants, replaceable) |
| `UtilizationOracle` | TWAP accumulator per market; dual-track filter; IMarketAdapter routing; SuspiciousSpike events | — | Trusted data layer (no custody, no roles) |
| `IMarketAdapter` | Protocol-specific translation of external market data to standard `utilizationBps` (asset-agnostic) | — | External truth adapter |
| `ISomnia` | Exact platform + agent interfaces | — | External truth |
| Mocks | Deterministic test doubles; configurable asset decimals; flash-spike simulation | — | Test only |

### 5.3 Design principles

- **P-1 Deterministic/Probabilistic separation.** Arithmetic on-chain. AI reserved for judgment.
- **P-2 Constitution at the custody boundary.** Invariants enforced where funds move.
- **P-3 Most-constrained primitive.** Narrowest AI output that expresses the decision.
- **P-4 Lossless canonical inputs.** Integer bps, fixed order, no truncation.
- **P-5 Fail-closed / fail-safe.** AI failure leaves vault in last safe state.
- **P-6 Least privilege + replaceability.** Each arm holds minimum role; hot-swappable.
- **P-7 Bounded blast radius.** Maximally adversarial AI can only reshuffle within invariants, once/epoch.
- **P-8 Auditability.** Every decision emits a structured on-chain record.
- **P-9 Manipulation-resistant inputs.** No raw spot read as sole threshold input. TWAP required.
- **P-10 Asset-agnosticism.** *(New v2.2)* No asset-specific logic in any contract. Decimal counts are read from the asset ERC-20 at runtime. All arithmetic is correct for any valid decimal count (0–18).

---

### 5.4 Asset-Agnostic Architecture & Market Lifecycle (New v2.2)

This section resolves D-9 and establishes the definitive model for how the vault handles assets and how markets are added.

#### 5.4.1 One vault = one asset

A single `CuratedVault` deployment accepts exactly one ERC-20 asset, set immutably at construction. All lending markets added to that vault must lend and return **that same asset**. The vault is never aware of a second asset type. This is the correct ERC-4626 pattern.

Examples of valid vault deployments:
- A vault configured with WETH — markets lend WETH, yield paid in WETH
- A vault configured with USDC — markets lend USDC, yield paid in USDC
- A vault configured with DAI — markets lend DAI, yield paid in DAI

The current testnet deployment uses USDC for demonstration purposes. The protocol design is not USDC-specific.

#### 5.4.2 Decimal handling

The vault reads `asset.decimals()` once at construction and stores it. All internal arithmetic that involves amounts uses this stored decimal count. The AI feature block always expresses amounts in the asset's own base units (not normalized), with the decimal count included in the portfolio header line so the AI and any observer knows the scale.

The feature block grammar must include the asset's decimal count so the AI does not confuse a WETH amount (18 decimals) with a USDC amount (6 decimals):

```
PORTFOLIO|ta=<totalAssets>|decimals=<assetDecimals>|idle=<idleBps>|mkts=<count>|...
```

**Critically:** all *ratios* (utilization, allocation, idle buffer) are in basis points regardless of asset — they are dimensionless and scale-independent. Only absolute amounts (totalAssets) are asset-decimal-dependent. This means the risk thresholds (bps) and AI scoring are completely asset-agnostic.

#### 5.4.3 Market addition lifecycle (the curator process)

Adding a market is a four-stage process controlled by the curator:

```
Stage 1 — Curator submits (timelocked):
  curator calls submitAddMarket(market, supplyCap, adapterAddress)
  → Creates a pending timelock action
  → Registers the adapter in UtilizationOracle for this market
  → Emits MarketQueued(id, market, eta)
  → Wait period: MIN_TIMELOCK to MAX_TIMELOCK (curator-set)

Stage 2 — Timelock expires → execute:
  Anyone calls executeAddMarket(market, supplyCap, adapterAddress)
  → Block.timestamp >= eta required
  → Market enabled in vault registry
  → Emits MarketEnabled(market, supplyCap)

Stage 3 — Oracle seeding (before first risk check or rebalance):
  Anyone calls oracle.update(market) repeatedly over TWAP_WINDOW
  → oracle.isValid(market) returns false until age >= TWAP_WINDOW
  → During this period: effectiveUtil returns cautionUtilBps (conservative)
  → Minimum seeding period: TWAP_WINDOW (default 30 minutes)

Stage 4 — Market fully active:
  oracle.isValid(market) returns true
  → Market can receive allocations from AllocationStrategist
  → Market's utilization is fully TWAP-protected
  → Sentinel monitors it on every checkVault call
```

**Why the adapter is submitted with the market:** When a curator adds Market X (say, an Aave WETH lending pool), they must also specify which adapter translates that market's data into the standard `utilizationBps()` format. This ties the oracle integration to the market registration atomically — a market cannot be added without its oracle adapter, preventing silent spot-read vulnerabilities on new markets.

**Curator can also:**
- **Lower a supply cap** (immediate — risk-reducing)
- **Raise a supply cap** (timelocked — risk-increasing)
- **Revoke a pending timelock action** (immediate — Sentinel can also do this)
- **Disable a market** (immediate — stop new allocations; existing funds can still be withdrawn)

---

## 6. Domain Model & Canonical Units

### 6.1 Units (corrected in v2.2 — eliminates D-3 and D-9)

- **All ratios in basis points (bps), 1e4 = 100%.** `utilizationBps`, `allocationBps`, `idleBufferBps`, `minIdleBufferBps`, `maxMarketBps`, `maxTurnoverBps`, `driftToleranceBps`, `spikeToleranceBps`. Bps are dimensionless — independent of the vault asset.
- **All asset amounts in the vault asset's native base units.** The base unit size depends on the asset's decimal count. USDC: 1 unit = 1e-6 USDC. WETH: 1 unit = 1e-18 WETH. WBTC: 1 unit = 1e-8 WBTC. **Never assume 6 decimals.** Always read `asset.decimals()`.
- **All share amounts in 18 decimals** (ERC-4626 standard, unchanged).
- **AI scores in a fixed clamp range** `[0, SCORE_MAX]` with `SCORE_MAX = 10_000` — dimensionless, asset-agnostic.

### 6.2 Core entities

- **Vault** — `asset` (immutable ERC-20 address set at construction), `assetDecimals` (read from asset, stored at construction), `totalAssets`, `totalSupply`, `sharePrice`, `depositsPaused`, risk parameters, market registry, current epoch.
- **Market** — `enabled`, `supplyCap` (in asset base units), `adapterAddress` (for oracle), current `balanceOf(vault)` (in asset base units), raw `utilizationBps` (spot, from adapter), `supplyRateBps` (yield signal).
- **MarketObservation** — per-market TWAP state inside UtilizationOracle: `lastSpotUtil`, `lastObservationTime`, `accumulator`, `firstObservationTime`, ring buffer of checkpoint pairs.
- **RiskParameters** (curator-set; risk-increasing changes timelocked) — `minIdleBufferBps`, `maxMarketBps`, `maxTurnoverBps`, `driftToleranceBps`, `rebalanceEpoch`, `criticalUtilBps`, `cautionUtilBps`, `criticalAllocBps`, `cautionAllocBps`, `minHealthyIdleBps`, `spikeToleranceBps`, `TWAP_MIN_WINDOW`.
- **Proposal** — `{requestId, vault, epoch, snapshotHash, rawAiOutput, projectedTargets[], status}` for audit.

---

## 7. The RiskSentinel Redesign (defensive path)

### 7.1 Objective

Detect dangerous vault states and reduce risk autonomously. On-chain determinism is the authority; AI is a layered escalator. Resolves D-1, D-5, D-8, D-9, and the §2.3 prompt critique. All utilization readings go through the UtilizationOracle (§7.7).

### 7.2 What moves on-chain (deterministic hard guards)

`RiskSentinel.assessOnChain(vault)` computes, in bps, with no truncation:

- For each enabled market: call `oracle.update(market)` then read `effectiveUtil = oracle.effectiveUtil(market)`.
- `maxEffectiveUtilBps` = max over enabled markets of `effectiveUtil`.
- `maxAllocBps` = max over enabled markets of `balanceOf(vault) * 1e4 / totalAssets`. *(Vault-internal — not flash-loan manipulable.)*
- `idleBps` = `idleAssets * 1e4 / totalAssets`. *(Vault-internal — not flash-loan manipulable.)*
- A deterministic **HardLevel ∈ {Safe, Caution, Critical}** from curator-set thresholds.

These guards fire **regardless of the AI** and are the **authoritative trigger for emergency action**.

### 7.3 What the AI actually decides

The AI is asked: **"Is this a deteriorating risk regime beyond what any single threshold shows?"**

- Primitive: `inferString` with `allowedValues = ["STABLE","WATCH","DETERIORATING"]`.
- Input: canonical feature block (§9.3) including twap, spike, and trend signals.
- The AI's answer is an **escalation modifier only**.

### 7.4 Precedence rule (resolves D-5)

```
EffectiveLevel = max(HardLevel_onchain, AiAdjustedLevel)

where AiAdjustedLevel =
   Critical  if AI == DETERIORATING and HardLevel >= Caution
   Caution   if AI == WATCH        and HardLevel == Safe
   HardLevel otherwise

AI failure/timeout/unknown → EffectiveLevel = HardLevel (AI_UNAVAILABLE recorded)
AI can NEVER lower the effective level — only raise it.
```

### 7.5 Action mapping

| EffectiveLevel | On-chain action |
|---|---|
| Safe | Store snapshot; no action. |
| Caution | Store snapshot; emit `RiskAlert`. Optionally lower worst-market cap. |
| Critical | `pauseDeposits()` (if autoPauseEnabled); `emergencyDeallocate(worstMarket, pullBps × balance / 1e4)` on true worst market (argmax effectiveUtil); emit events. |

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

Keep from v1: `CHECK_COOLDOWN` (5 min), one in-flight per vault, `onlyPlatform`, `pendingRequests` public, immutable history snapshots, view functions.

---

### 7.7 UtilizationOracle — Manipulation-Resistant Utilization

#### 7.7.1 Purpose

Solves D-8. External lending markets expose only spot utilization — manipulable in one block via flash loans. The oracle wraps any external market and maintains a TWAP using the Uniswap V2 accumulator pattern applied to utilization instead of price. Works for any asset type.

**Why TWAP defeats flash loans:** A 2-second spike contributes `2/1800 = 0.1%` of a 30-minute window's weight. A 2000 bps spike moves the TWAP by ≤ 2 bps. **Why two-block defense fails:** Attacker can manipulate both blocks independently with flash loans. TWAP contains history across many blocks — attacker cannot rewrite that history.

#### 7.7.2 IMarketAdapter — asset-agnostic external protocol abstraction

```
interface IMarketAdapter {
    function utilizationBps(address market) external view returns (uint256);
}
```

Adapter implementations (spec, not code — asset-agnostic in all cases):

- **AaveAdapter** — reads `getReserveData(asset)`, computes `(variableDebt + stableDebt) × 10000 / (totalDebt + availableLiquidity)`. Works for any Aave reserve asset.
- **CompoundAdapter** — reads `totalBorrows()`, `getCash()`, `totalReserves()`, computes `borrows × 10000 / (cash + borrows - reserves)`. Works for any cToken asset.
- **GenericAdapter** — for markets that directly expose `utilizationBps()` (mocks, simple implementations).

The curator registers an adapter per market during `submitAddMarket`. The oracle uses the registered adapter for that market regardless of what asset it holds.

#### 7.7.3 Oracle data structure per market

```
struct MarketObservation {
    uint256 lastSpotUtil
    uint256 lastObservationTime
    uint256 accumulator            // cumulative sum of (util × elapsed seconds)
    uint256 firstObservationTime
    bool    initialized
    uint256[7] checkpointAccumulator  // ring buffer for sliding-window TWAP
    uint256[7] checkpointTimestamp
    uint8   checkpointHead
}
```

#### 7.7.4 Oracle update() logic

```
function update(address market) external {
    MarketObservation storage obs = _observations[market];
    uint256 spotNow = IMarketAdapter(adapters[market]).utilizationBps(market);
    uint256 timeNow = block.timestamp;

    if (!obs.initialized) {
        obs.lastSpotUtil         = spotNow;
        obs.lastObservationTime  = timeNow;
        obs.firstObservationTime = timeNow;
        obs.initialized          = true;
        _writeCheckpoint(obs, 0, timeNow);
        return;
    }

    uint256 elapsed = timeNow - obs.lastObservationTime;
    if (elapsed == 0) return; // same block, no-op

    obs.accumulator          += obs.lastSpotUtil * elapsed;
    obs.lastSpotUtil         = spotNow;
    obs.lastObservationTime  = timeNow;

    uint256 lastCpTime = obs.checkpointTimestamp[(obs.checkpointHead + 6) % 7];
    if (timeNow - lastCpTime >= 5 minutes) {
        _writeCheckpoint(obs, obs.accumulator, timeNow);
    }
}
```

`update` is **permissionless** — any address, no role required.

#### 7.7.5 Oracle twap() logic

```
function twap(address market, uint256 window) external view returns (uint256) {
    MarketObservation storage obs = _observations[market];
    if (!obs.initialized) return cautionUtilBps;
    if (block.timestamp - obs.firstObservationTime < window) return cautionUtilBps;

    uint256 targetTime = block.timestamp - window;
    (uint256 cpAcc, uint256 cpTime) = _findCheckpointAt(obs, targetTime);

    uint256 elapsed    = block.timestamp - obs.lastObservationTime;
    uint256 currentAcc = obs.accumulator + (obs.lastSpotUtil * elapsed);
    uint256 accDelta   = currentAcc - cpAcc;
    uint256 timeDelta  = block.timestamp - cpTime;
    if (timeDelta == 0) return obs.lastSpotUtil;

    return accDelta / timeDelta;
}
```

#### 7.7.6 The dual-track filter — effectiveUtil()

```
function effectiveUtil(address market)
    external returns (uint256 util, bool spikeDetected)
{
    this.update(market);
    uint256 spot    = IMarketAdapter(adapters[market]).utilizationBps(market);
    uint256 twapVal = this.twap(market, TWAP_WINDOW);
    uint256 delta   = spot > twapVal ? spot - twapVal : 0;

    if (delta > spikeToleranceBps) {
        emit SuspiciousSpike(market, spot, twapVal, delta, block.timestamp);
        return (twapVal, true);
    }
    if (spot > criticalUtilBps && twapVal > cautionUtilBps) {
        return (spot, false); // real sustained emergency — secondary rule
    }
    return (spot, false); // spot and twap agree
}
```

| Condition | effectiveUtil | spikeDetected | Rationale |
|---|---|---|---|
| `spot - twap > spikeToleranceBps` | TWAP | true | Manipulation detected. Use trusted average. |
| `spot > criticalUtil AND twap > cautionUtil` | spot | false | Real sustained emergency. Both elevated. Act fast. |
| Otherwise | spot | false | Readings agree. Use current value. |

#### 7.7.7 Oracle parameters (curator-set)

| Parameter | Default | Change type |
|---|---|---|
| `TWAP_WINDOW` | 30 minutes | Risk-reducing (reduce) = immediate; risk-increasing (increase) = timelocked |
| `spikeToleranceBps` | 1000 (10%) | Tightening (reduce) = immediate; loosening (increase) = timelocked |
| `cautionUtilBps` | 8000 (80%) | Timelocked |
| `criticalUtilBps` | 9500 (95%) | Timelocked |

#### 7.7.8 Oracle liveness

If `update` is not called for extended periods, the TWAP reflects the last known spot held constant — conservative if healthy, cautious if already in caution band. The sentinel calls `update` on every `checkVault`, so oracle is refreshed at minimum every 5 minutes during active monitoring.

#### 7.7.9 isValid()

```
function isValid(address market) external view returns (bool) {
    MarketObservation storage obs = _observations[market];
    if (!obs.initialized) return false;
    return (block.timestamp - obs.firstObservationTime) >= TWAP_WINDOW;
}
```

Until `isValid` is true, `twap()` returns `cautionUtilBps`. New markets are treated conservatively until enough real history accumulates (§5.4.3 Stage 3).

---

## 8. The AllocationStrategist (offensive path)

### 8.1 Objective

Autonomously improve risk-adjusted yield across the vault's configured asset by proposing target allocations, then executing only through the vault's invariant-checked `reallocate`. The strategist reads utilization from `UtilizationOracle.effectiveUtil()` — manipulation-resistant, asset-agnostic. Works identically regardless of whether the vault holds USDC, WETH, or any other asset.

### 8.2 Trust architecture

```
AI proposes ──► Strategist projects onto feasible set ──► Vault re-validates ALL invariants ──► executes
(untrusted)     (deterministic math, asset-agnostic)      (the constitution, at custody)         (atomic, CEI)

All util inputs: UtilizationOracle.effectiveUtil() — manipulation-resistant
All amount math: uses vault.assetDecimals — correct for any asset
```

### 8.3 Tiered allocation modes

**Tier-1 — Strategy Selection (default; cheapest; maximal consensus safety).**
One `inferString` call. `allowedValues = ["DEFENSIVE","BALANCED","YIELD_TILT","DERISK"]`. EVM maps label to deterministic weights. One word, fully determined outcome. Bulletproof consensus.

**Tier-2 — Per-Market Scoring (higher fidelity).**
One `inferNumber` call per market. Score clamped `[0, SCORE_MAX]`. EVM normalizes to weights and projects onto feasible set (§11). N × cost vs Tier-1.

**Tier-3 — Tool-Calling Allocator (future, NG-3).** `inferToolsChat`. Deferred — see §20.

> Make tier a curator-set mode (`AllocationMode` enum), defaulting to Tier-1.

### 8.4 Rebalance lifecycle (sequence)

```
Keeper/anyone             Strategist                     Platform (LLM)               CuratedVault
     │ requestRebalance(){STT}  │                              │                           │
     │─────────────────────────►│ oracle.update(all markets)   │                           │
     │                          │ read effectiveUtil per mkt   │                           │
     │                          │ snapshot features (bps)      │                           │
     │                          │ epochGuard, snapshotHash     │                           │
     │                          │ createRequest{value}(...)    │                           │
     │                          │─────────────────────────────►│                           │
     │         requestId        │                              │ validators run Qwen3-30B  │
     │◄─────────────────────────│                              │ (seed fixed, temp=0)      │
     │                          │  handleResponse(reqId,...)   │                           │
     │                          │◄─────────────────────────────│ Majority consensus        │
     │                          │ decode label/scores          │                           │
     │                          │ staleness check (I-10)       │                           │
     │                          │ project → targets[]          │                           │
     │                          │  reallocate(targets, guard)  │                           │
     │                          │────────────────────────────────────────────────────────►│
     │                          │                              │ re-validate I-1..I-11     │
     │                          │                              │ execute minimal deltas    │
     │                          │     Rebalanced / Rejected    │ (CEI, nonReentrant)       │
     │                          │◄────────────────────────────────────────────────────────│
```

Fail-safe: `Failed`/`TimedOut`/empty → `RebalanceSkipped(reason)`, no movement. Invariant rejection → `RebalanceRejected(invariantId)`, funds untouched.

### 8.5 The yield signal

Primary: `supplyRateBps()` on each market — current supply APY in bps. On-chain view, not flash-loan manipulable (derives from the market's interest rate model). Asset-agnostic: a bps rate means the same thing whether the market holds WETH or USDC. The mock computes it from a settable interest model (§14.3).

### 8.6 Why not let the AI move funds directly?

That makes the AI a treasurer, not an advisor (violates the Golden Rule, P-2, P-7). §10 specifies invariants; §11 specifies the deterministic projection.

---

## 9. Prompt Engineering Strategy

### 9.1 The five prompt-design laws

- **L-1** Only ask what arithmetic cannot answer.
- **L-2** Lossless canonical input. Integers only, bps, fixed field order, canonical market ordering.
- **L-3** Constrained output. Never free-form for a decision that drives money.
- **L-4** Unambiguous rubric. Defines each output qualitatively — thresholds are on-chain.
- **L-5** Pin and test the prompt. Exact text is a versioned constant with unit tests.

### 9.2 Determinism checklist (MUST pass before mainnet)

- [ ] Output is enum-constrained or clamped-integer.
- [ ] `chainOfThought=false` on consensus-critical calls.
- [ ] Feature string is byte-identical for identical chain state.
- [ ] No floating point; bps integers only.
- [ ] Prompt + system are compile-time constants except for the feature block.
- [ ] `allowedValues` matched on-chain by `keccak256`.

### 9.3 Canonical feature-block grammar (corrected in v2.2 — eliminates D-9)

```
PORTFOLIO|ta=<totalAssets>|decimals=<assetDecimals>|idle=<idleBps>|mkts=<count>|epoch=<n>|prev_idle=<idleBps_lastSnapshot>
AGGREGATE|mkts_near_caution=<count>|util_dispersion=<maxUtil-minUtil>|alloc_dispersion=<maxAlloc-minAlloc>
M<i>|util=<effectiveUtilBps>|twap=<twapUtilBps>|spike=<0|1>|alloc=<allocBps>|headroom=<capHeadroomBps>|rate=<supplyRateBps>
M<i+1>|...
```

**Changes from v2.1:**
- `ta` field: was `ta=<totalAssetsUSDC>` — now `ta=<totalAssets>` (asset-agnostic label)
- `decimals` field: **new** — tells the AI the scale of the `ta` amount. Critical for correct AI reasoning when vaults hold assets of different decimal counts.
- All ratio fields remain bps — scale-independent, unchanged.

Markets emitted in ascending index order, every time. All values integers.

### 9.4 System prompts (semantic specification — implementer pins exact text)

**RiskSentinel regime classifier** (`allowedValues=["STABLE","WATCH","DETERIORATING"]`):

> "You are a portfolio-risk regime classifier for a yield vault. Inputs are canonical integer features in basis points; amounts are in the vault's native asset units with decimal count provided. The smart contract already enforces every hard numeric limit. Judge only the overall trajectory and concentration of risk no single limit captures. A spike=1 means a flash-loan manipulation was detected — factor this as an additional risk signal. Output exactly one of: STABLE, WATCH, DETERIORATING. No other text."

**AllocationStrategist Tier-1 selector** (`allowedValues=["DEFENSIVE","BALANCED","YIELD_TILT","DERISK"]`):

> "You are a capital-allocation policy selector for a yield vault. The contract converts your choice into a concrete, cap-respecting allocation in the vault's native asset. The util field is manipulation-resistant (time-weighted). Prefer DERISK or DEFENSIVE when any market nears caution utilization, has spike=1, or the idle buffer is thin. Prefer YIELD_TILT only when all markets are comfortably healthy and rate differences are meaningful. Output exactly one policy word. No other text."

**AllocationStrategist Tier-2 scorer** (`inferNumber`, clamp `[0,10000]`):

> "Given one market's features in the portfolio context, output a single integer attractiveness score in [0,10000]. Reward higher supply rate, penalize higher effective utilization and thin cap headroom. If spike=1, penalize more severely. Output only the integer."

### 9.5 Output parsing

- `inferString`: compare `keccak256(bytes(result))` against pinned enum hashes. Unknown → fail-safe.
- `inferNumber`: decode to `uint256`, re-clamp on-chain to `[0, SCORE_MAX]` defensively.

---

## 10. The Invariant System (the constitution — formal)

Enforced **inside `CuratedVault.reallocate(targets, guard)`**. If any fails, the whole reallocation reverts atomically. All amount comparisons use `assetDecimals`-consistent arithmetic — invariants hold for any asset.

| ID | Invariant | Formal statement | Rationale |
|---|---|---|---|
| **I-1** | **Conservation** | `Σ target_i + targetIdle == totalAssets` (within rounding epsilon; rounding favors idle) | No funds created/destroyed in the vault asset. |
| **I-2** | **Cap compliance** | `∀i: target_i ≤ supplyCap_i` | Curator-set cap in asset base units. AI cannot exceed it. |
| **I-3** | **Idle floor** | `targetIdle ≥ minIdleBufferBps × totalAssets / 1e4` | Withdrawal liquidity in vault asset. Fixes D-7. |
| **I-4** | **Max concentration** | `∀i: target_i ≤ maxMarketBps × totalAssets / 1e4` | Diversification independent of caps. |
| **I-5** | **Whitelist** | `∀i ∉ enabledMarkets: target_i == 0` | Funds only in curator-approved markets. |
| **I-6** | **Turnover bound** | `Σ |target_i − current_i| ≤ maxTurnoverBps × totalAssets / 1e4` | Bounds churn, gas, MEV, blast radius. |
| **I-7** | **Liquidity-aware moves** | Every withdrawal ≤ market's redeemable balance | Markets may be illiquid. |
| **I-8** | **Epoch / cooldown** | One executed rebalance per `rebalanceEpoch` per vault | Anti-thrash, anti-DoS. |
| **I-9** | **Pause respect** | If `depositsPaused`, allocation into markets forbidden; deallocation allowed | No new risk during circuit-breaker. |
| **I-10** | **Staleness guard** | `|totalAssets_now − totalAssets_atRequest| ≤ driftToleranceBps × totalAssets_atRequest / 1e4` AND `epoch_now == epoch_atRequest` | Reject proposals built on stale snapshots. |
| **I-11** | **Manipulation resistance** | Sentinel and strategist MUST read `oracle.effectiveUtil(market)`, never raw spot. `effectiveUtil` MUST use TWAP when `spot - twap > spikeToleranceBps`. For a ≤2-second flash-loan spike in a 30-minute window, `effectiveUtil` MUST differ from baseline by ≤ `spikeToleranceBps / 2`. | Defeats flash-loan manipulation (D-8). |
| **I-12** | **Asset conservation** *(New v2.2)* | The only ERC-20 that ever enters or leaves the vault's `asset` balance is `vault.asset()`. No other token is ever approved, transferred, or tracked by the vault. Lending markets enabled in the vault MUST accept and return the same asset as `vault.asset()`. | Ensures single-asset integrity. A market that returns a different token is not a valid Ephor market. |

**Rounding policy:** floor when allocating to markets, ceil for idle floor — round in depositor's favor.

---

## 11. The Deterministic Allocation Projection (the math)

Asset-agnostic — all amounts in asset base units, all ratios in bps. Correct for any decimal count.

**Inputs:** `A = totalAssets` (in asset base units); per market `i`: `b_i` (current balance), `c_i` (supply cap); risk params `fIdle, mMax, tMax`; AI weights `w_i ≥ 0`.

**Step 1 — Budget.** `B = A − ceil(fIdle × A / 1e4)`. I-3 holds by construction.

**Step 2 — Per-market ceiling.** `u_i = min(c_i, floor(mMax × A / 1e4))`. Encodes I-2 and I-4 together.

**Step 3 — Desired split.** If `Σ w_j == 0` → everything idle. Else `d_i = floor(w_i × B / Σ w_j)`.

**Step 4 — Capped water-filling.** Clip `t_i = min(d_i, u_i)`. Redistribute overflow to uncapped markets. Residue → idle.

**Step 5 — Turnover scale.** If `T = Σ|t_i − b_i| > tMax × A / 1e4`, scale: `λ = (tMax×A/1e4) / T`, `final_i = b_i + floor(λ(t_i − b_i))`.

**Step 6 — Execute deltas.** Phase A: withdraw from over-weight markets (raises idle). Phase B: supply to under-weight markets (funded from idle). Re-assert I-1..I-12 on resulting state.

```
   AI weights w_i (dimensionless, asset-agnostic)
        │
        ▼
 [Reserve idle floor] ──► B (in asset base units)       (I-3)
        │
        ▼
 [Box ceilings u_i = min(cap, maxMkt) in asset units]   (I-2, I-4)
        │
        ▼
 [Proportional split d_i]
        │
        ▼
 [Capped water-fill → t_i] ──► residue to idle
        │
        ▼
 [Turnover scale λ → final_i]                           (I-6)
        │
        ▼
 [Vault executes deltas, re-checks I-1..I-12]  ──► Rebalanced | Rejected
```

---

## 12. Roles & Permissions

### 12.1 Matrix

| Capability | DEFAULT_ADMIN | CURATOR | ALLOCATOR (Strategist) | SENTINEL (RiskSentinel) | Anyone |
|---|---|---|---|---|---|
| Grant/revoke roles | ✅ | — | — | — | — |
| Submit market addition (timelocked) | — | ✅ | — | — | — |
| Execute market addition (after timelock) | open | open | open | open | ✅ |
| Raise supply cap (timelocked) | — | ✅ | — | — | — |
| Lower supply cap (immediate) | — | ✅ | — | ✅ | — |
| Register market adapter in oracle | — | ✅ (with submitAddMarket) | — | — | — |
| Set risk params (risk-increasing → timelocked) | — | ✅ | — | — | — |
| Set risk params (risk-reducing → immediate) | — | ✅ | — | ✅ (subset) | — |
| `reallocate(targets)` | — | — | ✅ | — | — |
| `pauseDeposits` | — | — | — | ✅ | — |
| `unpauseDeposits` | ✅ | — | — | — | — |
| `emergencyDeallocate` | — | — | — | ✅ | — |
| Revoke pending timelock action | — | ✅ | — | ✅ | — |
| `oracle.update(market)` | open | open | open | open | ✅ |
| Trigger AI risk check | open | open | open | open | ✅ |
| Trigger AI rebalance | open | open | open | open | ✅ |
| Replace Strategist / Sentinel | ✅ | — | — | — | — |

### 12.2 Replaceability

Both AI arms are external contracts holding roles. Admin can `revokeRole` the old and `grantRole` the new without touching the vault or migrating funds. Oracle reads are permissionless — replacing the sentinel or strategist requires no oracle migration.

---

## 13. Storage & Interface Design (theory, not code)

### 13.1 CuratedVault additions (v2.2 corrections)

- `asset` — immutable `IERC20` address, set in constructor, never changes. **This is the only asset the vault ever holds, lends, or yields.** (I-12)
- `assetDecimals` — read from `asset.decimals()` at construction, stored once.
- `RiskParameters` struct (all bps + epoch length) with curator setters (risk-increasing timelocked).
- `reallocate(MarketTarget[] targets, RebalanceGuard guard)` — single invariant-checked entrypoint for the Strategist. All amounts in asset base units.
- bps-precision view metrics: `allocationBps(market)`, `idleBufferBps()` (replace integer-percent versions; fixes D-3).
- Events: `Rebalanced`, `RebalanceRejected(invariantId)`, `RiskParamUpdated`, `MarketQueued(id, market, eta)`, `MarketEnabled(market, supplyCap)`.

### 13.2 RiskSentinel

- `assessOnChain(vault) view → (HardLevel, worstMarket, maxEffectiveUtilBps, maxAllocBps, idleBps)`.
- Calls `oracle.update(m)` for each market inside `checkVault` before reading any utilization.
- AI request/response plumbing, EffectiveLevel computation (§7.4), immutable history with `PROMPT_VERSION`.

### 13.3 AllocationStrategist

- `AllocationMode` curator-set (Tier-1 / Tier-2).
- `requestRebalance(vault)` payable — snapshots oracle-filtered features including `assetDecimals` for the prompt.
- Callbacks decode AI output, check staleness (I-10), project, call `vault.reallocate`.
- Audit: `Proposal` records with raw AI output, projected targets, executed deltas, outcome.

### 13.4 UtilizationOracle

- `registerAdapter(market, adapter)` — curator only; called as part of `submitAddMarket`.
- `update(market)` — permissionless.
- `twap(market, window) view` — returns TWAP in bps, `cautionUtilBps` if insufficient history.
- `effectiveUtil(market) returns (uint256 util, bool spikeDetected)`.
- `isValid(market) view` — true if age ≥ TWAP_WINDOW.
- Events: `SuspiciousSpike(market, spot, twap, delta, timestamp)`, `AdapterRegistered(market, adapter)`.

### 13.5 ISomnia extensions

Keep existing interfaces. Add `ILLMInferenceAgent.inferNumber(...)` — signatures from `agents.somnia.network` (Appendix B).

---

## 14. Mock Specifications (complete, deterministic test doubles)

### 14.1 MockERC20 (replaces MockUSDC — corrected in v2.2)

**The mock is no longer called MockUSDC.** It is `MockERC20` with a **configurable decimal count** passed to the constructor. This allows tests to verify the protocol works correctly for any asset.

```
MockERC20(string name, string symbol, uint8 decimals)
```

Standard test deployments:
- `MockERC20("USDC", "USDC", 6)` — 6-decimal stablecoin (testnet demo)
- `MockERC20("WETH", "WETH", 18)` — 18-decimal wrapped ETH
- `MockERC20("WBTC", "WBTC", 8)` — 8-decimal wrapped BTC

All three MUST be used in the test suite to verify asset-agnosticism (AC-19, AC-20).

Open `mint(address to, uint256 amount)` — no role required. Amounts in the token's own decimals.

### 14.2 MockSomniaPlatform (unchanged from v2.1)

- `simulateInferString(requestId, word)` — happy path string.
- `simulateInferNumber(requestId, value)` — integer response.
- `simulateMajority(requestId, result, n, threshold)` — N identical responses, status=Success.
- `simulateDisagreement(requestId, results[])` — divergent → status=Failed.
- `simulateTimeout(requestId)` — status=TimedOut.
- `simulateMalicious(requestId, value)` — out-of-range hostile value.

### 14.3 MockLendingMarket (extended, fully asset-agnostic)

Accepts any ERC-20 token at construction — no USDC assumption. All supply/withdraw operations work on whatever token it is configured with.

```
MockLendingMarket(address asset)
```

- Keep: per-second compounding, `balanceOf`, `utilizationBps`, `setUtilization`, `fastForwardDays`, `onlyVault` supply/withdraw.
- **`supplyRateBps()`** — settable yield signal.
- **`setAvailableLiquidity(amount)`** — test I-7 (illiquid withdrawal). Amount in asset base units.
- **`simulateFlashSpike(spikeBps, durationBlocks)`** — temporarily overrides `utilizationBps()` for N blocks.
- **`simulateGradualRise(targetBps, durationSeconds)`** — steady utilization climb for testing real emergencies.

### 14.4 MockUtilizationOracle

- `setEffectiveUtil(market, util, spikeDetected)` — directly control returned value.
- `setTwap(market, twap)` — control TWAP independently.
- `simulateSpike(market, spotBps, twapBps)` — emits SuspiciousSpike.
- `setInvalid(market)` — makes `isValid()` return false.

### 14.5 MockMaliciousMarket (asset-agnostic)

A market that reverts on `withdraw`, lies about `balanceOf`, or attempts reentrancy. Configured with the vault asset. Proves I-7, CEI, and `nonReentrant` hold for any asset.

### 14.6 Test scenario fixtures

World fixtures: `world_safe`, `world_caution`, `world_critical`, `world_flash_spike`, `world_real_emergency`, `world_gradual_rise`, `world_yield_dispersion`, `world_illiquid`, `world_at_caps`.

**New v2.2 fixtures:**
- `world_18dec_asset` — vault configured with WETH (18 decimals), tests that all arithmetic and prompt generation is correct.
- `world_8dec_asset` — vault configured with WBTC (8 decimals), tests boundary decimal cases.

---

## 15. Threat Model & Security Analysis

### 15.1 Trust boundaries

```
 Untrusted ─────────────────────────────────────────────────────────────► Trusted
 ┌──────────────┐  ┌──────────────────┐  ┌──────────────────┐  ┌───────────────────────┐
 │ AI model     │  │ Strategist proj. │  │ UtilizationOracle│  │ CuratedVault           │
 │ output       │  │ (deterministic,  │  │ (TWAP filter,    │  │ custody + I-1..I-12    │
 │ (untrusted)  │─►│ asset-agnostic)  │─►│ asset-agnostic)  │─►│ (authoritative;        │
 │              │  │                  │  │                  │  │ any configured asset)  │
 └──────────────┘  └──────────────────┘  └──────────────────┘  └───────────────────────┘
```

### 15.2 Threats & mitigations

| ID | Threat | Mitigation |
|---|---|---|
| **T-1** | Malicious AI proposes draining allocation | I-2/I-4/I-5/I-6 in vault. Bounded reshuffle among whitelisted, capped markets, ≤ turnover, once/epoch. |
| **T-2** | Forged callback | `onlyPlatform` + `pendingRequests`/`activeRequest` gating. |
| **T-3** | Sandwich / large deposit between request and callback | I-10 staleness + epoch binding. |
| **T-4** | Validator disagreement / non-deterministic prompt | Constrained outputs + canonical inputs + `chainOfThought=false`. `Failed`/`TimedOut` → fail-safe. |
| **T-5** | Idle-buffer starvation | I-3 on every rebalance; `_ensureLiquidity` at redeem; rounding favors idle. |
| **T-6** | Reentrancy via market | CEI + `nonReentrant` on all state-changing entrypoints. |
| **T-7** | DoS via spamming triggers | Per-vault cooldown + per-epoch + payment required. |
| **T-8** | AI platform down | On-chain hard guards independent of AI. Allocation stays at last safe state. |
| **T-9** | Dust / rounding attack | bps math + round-in-depositor's-favor + epsilon-bounded conservation (I-1). |
| **T-10** | Sentinel/Strategist compromise | Least-privilege roles; Sentinel risk-reducing only; Strategist bounded by I-*; both replaceable. |
| **T-11** | Curator malicious | Timelock on risk-increasing actions + immediate sentinel revoke gives depositors a reaction window. |
| **T-12** | Prompt injection | Only canonical numeric features in prompt. No attacker-controlled strings. |
| **T-13** | Flash-loan spot manipulation | TWAP oracle: 2-second spike moves 30-min TWAP by ≤ 2 bps. False emergency cannot be triggered. |
| **T-14** | Two-block flash-loan attack | TWAP contains history across many blocks. Two manipulated blocks contribute ≤ 0.2% of total weight. |
| **T-15** | Oracle griefing via update() | Same-block updates are no-ops (elapsed=0). Cross-block manipulation requires sustained real capital. |
| **T-16** | New market bypasses TWAP | `isValid()` false until TWAP_WINDOW of history. Conservative `cautionUtilBps` returned until then. |
| **T-17** | Wrong-asset market added | I-12: any market that does not return `vault.asset()` on withdraw reverts during supply/withdraw. The curator is responsible for only adding markets that lend the vault's configured asset. Tests MUST verify a wrong-asset market causes a revert, not a silent loss. |

### 15.3 Privileged-action checklist

- Every AI-driven action has a "AI is hostile" test.
- Every emergency action has a "AI is silent" test.
- Every market has a "flash-spike" test.
- Every market has a "gradual real rise" test.
- Tests run for 6-decimal, 8-decimal, and 18-decimal assets.

---

## 16. Failure Modes & Fail-Safe Matrix

| Event | RiskSentinel behavior | AllocationStrategist behavior |
|---|---|---|
| AI `Success`, recognized output | Apply EffectiveLevel (§7.4) | Project + reallocate (within I-*) |
| AI `Success`, unrecognized output | Treat as no-escalation (≥ Hard) | Abort rebalance (DEFENSIVE/skip) |
| AI `Failed` | EffectiveLevel = Hard; record `AI_UNAVAILABLE` | `RebalanceSkipped(FAILED)`, no move |
| AI `TimedOut` | EffectiveLevel = Hard; record `AI_UNAVAILABLE` | `RebalanceSkipped(TIMEOUT)`, no move |
| Empty responses | As `Failed` | As `Failed` |
| Invariant rejection at execute | n/a | `RebalanceRejected(I-x)`, funds untouched |
| Staleness drift exceeded | n/a | `RebalanceRejected(STALE)`, re-request next epoch |
| Market illiquid on withdraw | Partial emergency-deallocate, emit shortfall | Partial-fill per I-7 or reject |
| Vault paused | Emergency actions still allowed | Allocation-in forbidden (I-9); deallocation allowed |
| Flash-loan spike detected | `SuspiciousSpike` emitted; effectiveUtil = TWAP; hard guard uses TWAP | Feature block shows spike=1; AI penalizes the market; TWAP-based score used |
| Oracle invalid (new market) | Market treated as cautionUtilBps | Market scored conservatively |
| Wrong-asset market behavior | withdraw reverts; emergency-deallocate catches it | reallocate target for that market rejected (I-12) |

**Restated principle:** worst-case behavior under any failure is "do nothing or act conservatively" — for any configured asset.

---

## 17. Economics, Gas & Cost Analysis

- **Per AI call:** `getRequestDeposit() + 0.07 × subSize` STT. Tier-1 = 1 call/rebalance. Tier-2 = N calls/rebalance. Risk check = 1 call.
- **Oracle update cost:** one SSTORE per update. Cheap; no STT required.
- **Deposit handling:** compute at call time from on-chain getter; implement `receive()` for rebates.
- **Somnia gas multiplier:** keep `--gas-estimate-multiplier 3000` from v1.
- **TWAP_WINDOW trade-off:** longer = more manipulation-resistant, slower real-emergency response. 30 min recommended. For testnet demo: 5 min is acceptable.
- **Asset-agnostic cost note:** the vault's gas costs are independent of the asset's decimal count. All ratio math is bps; all amount math is integer arithmetic in native units.

---

## 18. Testing Strategy & Acceptance Criteria

### 18.1 Test layers

1. **Unit:** projection math; bps metrics; feature encoding golden strings; enum hash matching; TWAP accumulator arithmetic; dual-track logic truth table; decimal-agnostic amount math.
2. **Component:** RiskSentinel assessOnChain truth table; EffectiveLevel precedence; Strategist tier flows with mocked callbacks; oracle effectiveUtil outputs.
3. **Integration:** full request→consensus→callback→reallocate; risk check→critical→pause+deallocate; flash-spike→oracle filters→no false emergency.
4. **Adversarial:** hostile AI outputs; validator disagreement; timeout; malicious market; staleness; cap edges; illiquidity; flash spikes; two-block attacks; wrong-asset market.
5. **Property/fuzz (256 runs):** post-rebalance state satisfies all I-1..I-12 for random weights and states.
6. **Invariant mode:** across random sequences of actions, conservation, idle floor, cap compliance, and no-false-emergency always hold.
7. **Multi-asset (new v2.2):** run core integration tests for 6-decimal, 8-decimal, and 18-decimal assets.

### 18.2 Acceptance criteria

- **AC-1** Deposit/redeem/share-price match v1 semantics for the configured asset (regression).
- **AC-2** `assessOnChain` returns true worst market (argmax effectiveUtil) — D-1 regression.
- **AC-3** No hardcoded agent deposit — D-4 regression.
- **AC-4** All ratio metrics are bps; no integer-percent path — D-3 regression.
- **AC-5** Malicious Tier-2 score on capped market: balance ≤ min(cap, maxMarketBps) — I-2/I-4.
- **AC-6** Any AI weights: targetIdle ≥ minIdleBufferBps — I-3 (fuzzed).
- **AC-7** Any rebalance turnover ≤ maxTurnoverBps — I-6 (fuzzed).
- **AC-8** AI TimedOut/Failed/unknown → no fund movement; no de-escalation — P-5.
- **AC-9** Forged handleResponse from non-platform caller reverts — T-2.
- **AC-10** Staleness beyond driftToleranceBps rejects rebalance — I-10.
- **AC-11** Reentrant market cannot break accounting — T-6.
- **AC-12** EffectiveLevel never below HardLevel for any AI input — §7.4.
- **AC-13** Flash-loan spike of 2000 bps for 2 seconds moves TWAP by ≤ 10 bps — I-11/T-13.
- **AC-14** Two-block flash-loan attack: effectiveUtil returns TWAP; no false emergency fires — T-14.
- **AC-15** Real gradual rise: TWAP and spot both exceed threshold → secondary rule → critical fires — T-13.
- **AC-16** New market with oracle not yet valid: returns cautionUtilBps; no allocation until isValid() — T-16.
- **AC-17** `oracle.update(market)` callable by any address with no role check.
- **AC-18** `SuspiciousSpike` event emitted with correct fields when dual-track engages.
- **AC-19** *(New v2.2)* Vault configured with 18-decimal WETH: deposit, rebalance, and risk check all produce correct results. Feature block `decimals=18` field is present and correct.
- **AC-20** *(New v2.2)* Vault configured with 8-decimal WBTC: same as AC-19 with `decimals=8`.
- **AC-21** *(New v2.2)* Wrong-asset market (configured to return a different token): `supply` or `withdraw` reverts; I-12 is enforced; no silent loss of vault asset.
- **AC-22** *(New v2.2)* No reference to "USDC" appears anywhere in contract code or mock names — confirmed by grep test.

### 18.3 Tooling

Foundry: `forge test -vvv`, fuzz 256 runs, invariant mode, `forge snapshot`, `forge fmt`. Solidity 0.8.20 / EVM paris / optimizer 200 from v1.

---

## 19. Deployment & Migration Plan

1. **Configure asset.** Decide which ERC-20 asset this vault deployment serves. This decision is permanent.
2. **Deploy oracle infrastructure.** AaveAdapter / CompoundAdapter / GenericAdapter as needed for each planned market.
3. **Deploy core.** `MockERC20` (for testnet with configured decimals), `CuratedVault(assetAddress, ...)`.
4. **Deploy arms.** `RiskSentinel(oracleAddress, ...)`, `AllocationStrategist(oracleAddress, ..., Tier-1)`.
5. **Wire roles.** Grant `SENTINEL_ROLE` → RiskSentinel; `ALLOCATOR_ROLE` → Strategist.
6. **Submit market additions.** Curator calls `submitAddMarket(market, supplyCap, adapterAddress)` for each market. This simultaneously registers the adapter in the oracle.
7. **Wait for timelocks.** Minimum timelock period per market addition.
8. **Execute market additions.** `executeAddMarket(market, supplyCap, adapterAddress)` for each market.
9. **Seed oracle.** Call `oracle.update(market)` at least every 5 minutes for TWAP_WINDOW (30 min). `oracle.isValid(market)` must return true for all markets before AI arms are activated.
10. **Trigger flows.** `cast send` for risk check and rebalance (forge-script simulation fails on Somnia `NotActivated`). Value computed from `getRequestDeposit()`.
11. **Replace-arm scripts.** `ReplaceSentinel.s.sol` and `ReplaceStrategist.s.sol` — revoke old role, grant to new contract. Oracle requires no migration.
12. **Verify-response scripts.** Read back latest risk verdict, latest rebalance proposal, and latest oracle TWAP values.

Reconcile all docs (README, CLAUDE.md) to: asset-agnostic language, bps metrics, computed deposits, two-arm architecture, oracle infrastructure, correct cost figures.

---

## 20. Phased Roadmap

| Phase | Deliverable | Risk |
|---|---|---|
| **0** | Audit-fix pass: D-1..D-9; bps migration; asset-agnostic refactor; deploy UtilizationOracle with adapters; rename MockUSDC → MockERC20 | Low |
| **1** | RiskSentinel redesign (on-chain hard guards via effectiveUtil + narrowed AI second-opinion + precedence rule) | Low |
| **2** | Invariant system I-1..I-12 in CuratedVault.reallocate + projection math — no AI yet, stub allocator | Medium |
| **3** | AllocationStrategist Tier-1 end-to-end | Medium |
| **4** | AllocationStrategist Tier-2 end-to-end | Medium |
| **5 (future)** | Tier-3 inferToolsChat — only after audit; vault re-validates every move | High |
| **6 (future)** | Reactive/scheduled triggers if native Somnia scheduler confirmed. Permissionless keeper model is the live anchor. | Low |

**Order rationale:** asset-agnostic refactor (Phase 0) → oracle + cage (Phases 0-2) → brain (Phases 3-4). The AI arm is born into a pre-existing, fuzz-proven, asset-agnostic safety system.

---

## 21. Open Decisions for the Implementer

- **OD-1** Tier-2 batching: verify on `agents.somnia.network` whether vector return in one call is consensus-safe vs N separate inferNumber calls. Default to N calls.
- **OD-2** Idle floor vs supply queue: pure floor (simpler) or managed reserve band. Spec assumes pure floor.
- **OD-3** Risk param change asymmetry: confirm which changes are risk-increasing (timelocked) vs risk-reducing (immediate) per the list in §12.1.
- **OD-4** Worst-market emergency fraction: 50% default pullBps, or scale with over-threshold distance. Spec keeps curator-set constant for v2.
- **OD-5** Multi-vault: confirm whether v2 targets one vault (simpler) or many.
- **OD-6** Prompt versioning: confirm PROMPT_VERSION recorded in every audit record, bumped on any change.
- **OD-7** TWAP_WINDOW for testnet: 30 min for mainnet, 5 min for testnet demo. Make deploy-time parameter.
- **OD-8** Oracle update keeper: recommend off-chain keeper calling `update` every 5 min between sentinel triggers. Document in CLAUDE.md.
- **OD-9** Secondary rule thresholds: reuse curator-set `criticalUtilBps` and `cautionUtilBps` from risk params. No separate parameters.
- **OD-10** *(New v2.2)* Decimal normalization in feature block: the `ta` (totalAssets) field is in native asset base units. The `decimals` field tells the AI the scale. Decision: do NOT normalize all amounts to a fixed decimal count inside the contract — this would require multiplication/division and introduces rounding. The AI receives native amounts plus the decimal count and handles interpretation. This is simpler and lossless.
- **OD-11** *(New v2.2)* Multi-vault deployment: for protocols wanting vaults for multiple assets (USDC vault + WETH vault + WBTC vault), each is a completely independent deployment of the full protocol stack. They share no storage. The oracle can optionally be shared if the same markets are used — the oracle is market-specific, not asset-specific.

---

## 22. Requirements Traceability (condensed)

| Requirement | Addressed by |
|---|---|
| R-1 Move risk arithmetic on-chain | §7.2, P-1 |
| R-2 Redesign prompt strategy | §9 (L-1..L-5, grammar, system prompts) |
| R-3 Autonomous allocation w/ EVM guardrails | §8, §10, §11 |
| R-4 No AI output can break invariants | §10, §11, §15 |
| R-5 Fail-safe under AI failure | §7.4, §8.4, §16, P-5 |
| R-6 Live-deployable on Somnia | §4, §8.3 Tier-1/2, §19 |
| R-7 Complete mocks incl. adversarial | §14 |
| R-8 Fix D-1..D-7 | §2.4, §18.2 AC-2..AC-4 |
| R-9 Diagrams & theory, no code | This document |
| R-10 Flash-loan manipulation resistance | §2.4 D-8, §5.1, §7.7, I-11, T-13..T-16, AC-13..AC-18 |
| R-11 Asset-agnosticism | §2.4 D-9, §5.4, §6.1, §6.2, I-12, T-17, AC-19..AC-22, G-9, P-10 |

---

## Appendix A — Glossary

- **bps** — basis points; 1% = 100 bps; 100% = 10,000 bps. Dimensionless — independent of vault asset.
- **vault asset** — the ERC-20 token configured at vault deployment. Immutable. All lending markets in the vault accept and return this token. Examples: USDC (6 dec), WETH (18 dec), WBTC (8 dec).
- **assetDecimals** — `asset.decimals()`, stored at vault construction. Used for all amount arithmetic. Never assumed to be 6.
- **Subcommittee** — the set of validators elected to execute an agent request.
- **Majority consensus** — finalization requires ≥ threshold validators returning byte-identical result bytes.
- **Idle floor** — minimum fraction of vault assets (in vault asset base units) kept unallocated for withdrawal liquidity.
- **Turnover** — total absolute asset movement in one rebalance, in vault asset base units.
- **Projection** — deterministic mapping of AI weights onto the feasible set. Asset-agnostic.
- **Epoch** — minimum interval between executed rebalances.
- **TWAP** — Time-Weighted Average Utilization. Maintained by UtilizationOracle. Resistant to flash-loan manipulation. A 2-second spike in a 30-minute window moves the TWAP by ≤ 2 bps.
- **effectiveUtil** — manipulation-resistant utilization from `UtilizationOracle.effectiveUtil(market)`. Either TWAP (spike detected) or spot (readings agree or real emergency).
- **spikeToleranceBps** — max acceptable delta between spot and TWAP before spike classification. Default 1000 bps (10%).
- **SuspiciousSpike** — event emitted when `spot - twap > spikeToleranceBps`.
- **IMarketAdapter** — protocol-specific adapter translating any external market's data to standard `utilizationBps(market)`. Asset-agnostic.
- **Secondary rule** — dual-track override using spot when `spot > criticalUtilBps AND twap > cautionUtilBps`. Catches real sustained emergencies.
- **isValid** — oracle state: true when observation age ≥ TWAP_WINDOW. False → conservative `cautionUtilBps` returned.
- **Market lifecycle** — the four stages a new market passes through: submitted (timelocked) → executed (enabled) → seeding (oracle accumulates TWAP history) → active (isValid=true, fully operational).
- **I-12** — Asset conservation invariant: only `vault.asset()` ever enters or leaves the vault's balance.

---

## Appendix B — Interface Verification Checklist

1. Visit `https://agents.somnia.network`, open LLM Inference agent, copy exact Solidity signatures for `inferString`, `inferNumber`, `inferChat`, `inferToolsChat`. Treat §4.2 as semantics only.
2. Copy real LLM Inference `agentId` — never hardcode a placeholder.
3. Confirm `getRequestDeposit()` and `getAdvancedRequestDeposit(size)` return values on target network.
4. Confirm callback signature and selector.
5. Confirm platform address for target chain.
6. Confirm per-agent LLM price and default subcommittee size.

---

## Appendix C — Prompt Templates (semantic; pin exact text in code, version it)

**Risk regime — system (allowedValues = STABLE | WATCH | DETERIORATING):**
> "You are a portfolio-risk regime classifier for a yield vault holding a single configured asset. Inputs are canonical integer features: ratios in basis points (dimensionless, asset-agnostic), amounts in the vault asset's native units with decimal count given in the PORTFOLIO header. The smart contract enforces all hard numeric limits. Your job: judge the overall trajectory and concentration of risk no single limit captures. A spike=1 means a flash-loan manipulation was detected — treat this as an additional risk signal. Output exactly one of: STABLE, WATCH, DETERIORATING. No other text."

**Allocation policy — system (allowedValues = DEFENSIVE | BALANCED | YIELD_TILT | DERISK):**
> "You are a capital-allocation policy selector for a yield vault. The contract converts your choice into a concrete, cap-respecting allocation in the vault's native asset. The util field is manipulation-resistant (time-weighted). Prefer DERISK or DEFENSIVE when any market nears caution utilization, has spike=1, or the idle buffer is thin. Prefer YIELD_TILT only when all markets are healthy and rate differences are meaningful. Output exactly one policy word. No other text."

**Allocation score — system (inferNumber, clamp [0,10000]):**
> "Given one market's features in the portfolio context, output a single integer attractiveness score in [0,10000]. Reward higher supply rate, penalize higher effective utilization and thin cap headroom. If spike=1, penalize more severely. Output only the integer."

**Feature block (user prompt) — pinned grammar (§9.3).** Covered by golden-string unit tests. `PROMPT_VERSION` bumped on any grammar or system-prompt change.

---

## Appendix D — Flash-Loan Attack Analysis

**Why spot reads are manipulable:** Any value read from an external contract inside the same transaction as a privileged action is manipulable if the attacker controls that external state atomically via flash loans.

**Why two-block defense fails:** Attacker executes two separate flash-loan transactions — one in block N (initiateCheck) and one in block N+1 (checkVault). Both readings are consistent with each other but inconsistent with reality. Two-block consistency checks are insufficient.

**Why TWAP defeats both attacks:** The accumulator `Σ(util_i × elapsed_i)` contains history across all prior blocks. A single malicious block contributes `blockTime / windowLength ≈ 0.1%`. Two malicious blocks contribute ≈ 0.2%. Moving the TWAP by 1000 bps requires holding the manipulated state for 3 real minutes — requiring capital, not a flash loan.

**Why real emergencies are still caught:** A genuine market-run scenario where utilization rises organically over 30 minutes moves both spot and TWAP upward together. When spot > criticalUtilBps AND twap > cautionUtilBps, the secondary rule fires and `effectiveUtil = spot`. The sentinel catches the real emergency approximately 10–15 minutes into the crisis.

**Asset-agnostic note:** the TWAP mechanism is in utilization bps — dimensionless. It works identically regardless of whether the vault holds USDC, WETH, or any other asset.

---

*End of SDD v2.2. The implementing agent should map every R-*, I-*, AC-*, and D-* (including new D-9, I-12, AC-19..AC-22, R-11) to files, functions, and tests. Build in order: Phase 0 (asset-agnostic refactor + oracle + bug fixes) → Phase 1 (sentinel) → Phase 2 (constitution) → Phase 3 (Tier-1 brain) → Phase 4 (Tier-2 brain). The oracle MUST be seeded and valid, and the vault MUST be asset-agnostic, before the AI arms are activated on any network.*
