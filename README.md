<div align="center">
  <img src="frontend/public/logoAndName.svg" alt="Ephor Protocol" width="420" />
</div>

# Ephor Protocol

[![CI](https://github.com/Usman-CrYpToo2/ephor-protocol/actions/workflows/test.yml/badge.svg)](https://github.com/Usman-CrYpToo2/ephor-protocol/actions/workflows/test.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

A curated yield vault on [Somnia](https://somnia.network) whose risk management
and capital allocation are driven by Somnia's on-chain, validator-consensus LLM
inference. Two AI agents, a defensive sentinel and an allocation strategist,
advise the vault. Every number they produce is re-validated by on-chain
invariants before any funds move.

> The EVM is the constitution. The AI is an advisor with no signing authority.

[Live demo](https://ephor-protocol.netlify.app) · [Design specification](docs/design-spec.md) · [Security review](audits/2026-10-self-review.md)

## Architecture

| Contract | Role | Privilege |
|---|---|---|
| [`CuratedVault`](src/CuratedVault.sol) | Asset-agnostic ERC-4626-style vault. Holds funds, allocates to whitelisted lending markets, enforces invariants I-1 to I-10 in `reallocate` | Custody |
| [`VaultSentinel`](src/VaultSentinel.sol) | Defensive agent. Combines deterministic on-chain risk levels with an AI regime classification; can pause deposits and emergency-deallocate | `SENTINEL_ROLE`: risk-reducing only |
| [`AllocationStrategist`](src/AllocationStrategist.sol) | Offensive agent. Asks the AI for a strategy label, turns it into target allocations, submits them to `reallocate` | `ALLOCATOR_ROLE`: bounded by invariants |
| [`AllocationProjection`](src/AllocationProjection.sol) | Library. Deterministic projection from AI weights to targets: idle budget, caps, capped water-fill, turnover scaling | None |
| [`UtilizationOracle`](src/UtilizationOracle.sol) | Manipulation-resistant market utilization: TWAP accumulator with a dual-track spike filter | None |

```
                     Somnia LLM agent (Qwen3-30B, 3 validators, temperature 0)
                          ▲ prompt   │ label            ▲ prompt   │ label
                          │          ▼                  │          ▼
UtilizationOracle ──► VaultSentinel                AllocationStrategist
  (TWAP, spike filter)    │                             │
                          │ pause, emergency            │ targets via AllocationProjection
                          │ deallocate                  │
                          ▼                             ▼
                      CuratedVault  ◄── reallocate enforces invariants I-1 to I-10
```

## Trust model

| Agent | AI decides | The contract decides |
|---|---|---|
| Sentinel | A regime label: `STABLE`, `WATCH` or `DETERIORATING` | The hard risk level from oracle data. The effective level is `max(hard, ai_adjusted)`, so the AI can escalate but never lower risk. |
| Strategist | A strategy label: `BALANCED`, `YIELD_TILT`, `DEFENSIVE` or `DERISK` | The weights for each label, the projection into amounts, and every invariant check in `reallocate`. |

Both agents treat timeouts, failures, unknown labels and responses below the
consensus threshold as no-ops. AI absence never moves funds.

## Invariants

Enforced in [`CuratedVault.reallocate`](src/CuratedVault.sol). Any violation
reverts the whole rebalance with `InvariantViolation(id)`.

| ID | Invariant |
|---|---|
| I-1 | Conservation: targets plus untouched market balances plus idle equal `totalAssets`; each market listed once |
| I-2 | Every target is within its market's supply cap |
| I-3 | Idle balance stays at or above `minIdleBufferBps` |
| I-4 | No market exceeds `maxMarketBps` of `totalAssets` |
| I-5 | Only whitelisted markets receive funds |
| I-6 | Total movement stays within `maxTurnoverBps` |
| I-7 | Withdrawals never exceed a market's balance |
| I-8 | At most one rebalance per `rebalanceEpochLength` |
| I-9 | No new allocation while deposits are paused |
| I-10 | The proposal's snapshot epoch matches and `totalAssets` drift is within `driftToleranceBps` |
| I-11 | Risk decisions read `UtilizationOracle.effectiveUtil`, never raw spot utilization |
| I-12 | The vault only ever holds and moves its configured asset |

## Roles

| Role | Holder | Permissions |
|---|---|---|
| `DEFAULT_ADMIN_ROLE` | Governance | Grant and revoke roles, unpause deposits, fee recipient |
| `CURATOR_ROLE` | Risk manager | Queue market additions and cap increases (timelocked), lower caps, set risk parameters and fee |
| `ALLOCATOR_ROLE` | `AllocationStrategist` or operator | `allocate`, `deallocate`, `reallocate` within invariants |
| `SENTINEL_ROLE` | `VaultSentinel` | `pauseDeposits`, `emergencyDeallocate`, lower caps, revoke queued actions |

Risk-increasing curator actions wait out a `timelock` (1 minute on testnet,
bounded to 3 weeks). Risk-reducing actions apply immediately.

## Deployments

Somnia testnet (chain ID 50312). These contracts predate the fixes in the
[security review](audits/2026-10-self-review.md); redeploy from `main` for the
reviewed code.

| Vault | Vault address | Strategist |
|---|---|---|
| USDC | [`0x9c85...C346`](https://shannon-explorer.somnia.network/address/0x9c8512238532b37C0d01CA2d82dbB180eB11C346) | [`0x0091...Af3c`](https://shannon-explorer.somnia.network/address/0x00913D41650F9eFEC0FD916c956b83915049Af3c) |
| WETH | [`0x9A0d...7f70`](https://shannon-explorer.somnia.network/address/0x9A0d394822c5d569883d704724547c7fF7Fe7f70) | [`0x9623...28e3`](https://shannon-explorer.somnia.network/address/0x96237866CF8BD829C7f06ebDCf71625A969428e3) |
| WBTC | [`0xf7EC...498D`](https://shannon-explorer.somnia.network/address/0xf7ECFFc39c9EA02CC60B6f990DDd1039e6cd498D) | [`0x4d8D...B55D`](https://shannon-explorer.somnia.network/address/0x4d8De4926DE963836D597680aA3c910D16a5B55D) |

Shared `VaultSentinel`: [`0xFd87...74fD`](https://shannon-explorer.somnia.network/address/0xFd87296402b958ba822F529d9ffc9Fe7751574fD).
Markets and tokens are mocks; full addresses are in [`frontend/src/config.js`](frontend/src/config.js).

## Usage

Requires [Foundry](https://book.getfoundry.sh/getting-started/installation).

```bash
git clone --recurse-submodules https://github.com/Usman-CrYpToo2/ephor-protocol.git
cd ephor-protocol
forge test
```

### Deploy

```bash
cp .env.example .env   # PRIVATE_KEY, DEPLOYER_ADDRESS, SOMNIA_TESTNET_RPC, LLM_AGENT_ID
source .env

# 1. Deploy vaults, agents, oracle and mocks; queue market additions
forge script script/DeployAndSubmit.s.sol --rpc-url somnia_testnet \
  --private-key $PRIVATE_KEY --broadcast --gas-estimate-multiplier 3000

# 2. After the timelock: execute market additions and seed state
forge script script/ExecuteAndSeed.s.sol --rpc-url somnia_testnet \
  --private-key $PRIVATE_KEY --broadcast --gas-estimate-multiplier 3000
```

Somnia gas costs run well above standard EVM estimates, hence the multiplier.
A risk check needs at least 0.25 STT attached (`checkVault`), a rebalance
0.5 STT (`requestRebalance`), to fund the platform deposit and three validators.

### Frontend

```bash
cd frontend
npm install
npm run dev
```

React, Vite, Tailwind and ethers v6. Three vaults with allocation, performance,
risk and activity views, plus a demo panel for driving scenarios.

## Testing

159 tests across 17 suites, including fuzz tests. CI runs `forge fmt --check`,
`forge build --sizes` and `forge test` on every push.

| Area | Tests | Covers |
|---|---|---|
| Vault | 89 | ERC-4626 flows, fees, access control, timelock, every invariant I-1 to I-10 |
| Sentinel | 31 | Verdict mapping, precedence (AI cannot lower risk), consensus threshold, cooldowns |
| Strategist | 24 | Label handling, projection, fail-safe paths, prompt formatting |
| Oracle | 12 | TWAP, spike filter, flash-loan resistance (I-11) |
| Integration | 3 | Safe-to-critical cycle, independent vaults, deposit and redeem round trip |

## Repository structure

| Path | Contents |
|---|---|
| [`src/`](src) | Core contracts, interfaces and mocks |
| [`test/`](test) | Suites grouped by component; shared fixture in `TestBase.sol` |
| [`script/`](script) | Two-step deployment and operational scripts |
| [`frontend/`](frontend) | Web application |
| [`docs/design-spec.md`](docs/design-spec.md) | Design specification: architecture, invariants, prompt strategy, threat model, test plan |
| [`audits/`](audits) | Security self-review |

## Origin

Built for the [Encode Club](https://encode.club) Agentathon on Somnia, May to
June 2026.

## Security

A self-review found 12 issues, including an unrestricted `unpauseDeposits`, a
non-terminating prompt formatter that disabled every rebalance, and an idle-floor
bypass in `reallocate`. Eight are fixed with regression tests; four are
acknowledged. See [`audits/2026-10-self-review.md`](audits/2026-10-self-review.md).

Not audited by a third party.

## License

MIT, see [`LICENSE`](LICENSE).
