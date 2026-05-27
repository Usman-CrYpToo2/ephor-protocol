<div align="center">
  <img src="frontend/public/logoAndName.svg" alt="Ephor Protocol" width="420" />

  <br/>
  <br/>

  [![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
  [![Built on Somnia](https://img.shields.io/badge/Built%20on-Somnia%20Network-6366f1)](https://somnia.network)
  [![Solidity](https://img.shields.io/badge/Solidity-0.8.20-363636?logo=solidity)](https://soliditylang.org)
  [![Foundry](https://img.shields.io/badge/Tested%20with-Foundry-FFDB1C)](https://getfoundry.sh)
  [![Encode Club Agentathon](https://img.shields.io/badge/Encode%20Club-Agentathon-ff6b35)](https://encode.club)
  [![Live Demo](https://img.shields.io/badge/Live%20Demo-ephor--protocol.netlify.app-00C7B7?logo=netlify)](https://ephor-protocol.netlify.app)
</div>

---

**Ephor Protocol** is an autonomous AI-powered DeFi yield vault built on [Somnia Network](https://somnia.network). It combines an ERC-4626 curated vault with an on-chain AI risk sentinel that reads live metrics, reaches validator consensus via Somnia's native LLM Inference Agent, and autonomously executes protective actions — all without any off-chain infrastructure.

---

## Overview

Traditional DeFi risk management relies on off-chain monitoring bots, multisig councils, or reactive governance — all of which are slow, opaque, or centralized. Ephor Protocol replaces this with a fully on-chain AI agent that:

1. **Reads** live vault and market metrics via view calls (no oracles, no external APIs)
2. **Prompts** Somnia's on-chain LLM Inference Agent (Qwen3-30B) with those metrics
3. **Reaches consensus** deterministically across 3 independent validators
4. **Acts** autonomously — pausing deposits and deallocating capital when CRITICAL risk is detected

The result is a transparent, verifiable, and autonomous risk layer that any permissioned vault can plug into.

---

## Architecture

```
                    ┌─────────────────────────────────────────┐
                    │           CuratedVault (ERC-4626)        │
                    │                                          │
                    │  deposit() / redeem()                    │
                    │  allocate() / deallocate()               │
                    │  pauseDeposits() — SENTINEL_ROLE only    │
                    │  emergencyDeallocate() — SENTINEL_ROLE   │
                    └───────────────┬─────────────────────────┘
                                    │  SENTINEL_ROLE
                    ┌───────────────▼─────────────────────────┐
                    │           VaultSentinel                  │
                    │                                          │
                    │  checkVault()  ──► reads 5 metrics       │
                    │  builds prompt ──► createRequest()       │
                    │  handleResponse() ◄── platform callback  │
                    └───────────────┬─────────────────────────┘
                                    │
                    ┌───────────────▼─────────────────────────┐
                    │    Somnia LLM Inference Agent            │
                    │    (Qwen3-30B · 3 validators · temp=0)   │
                    │                                          │
                    │    Returns: SAFE | CAUTION | CRITICAL    │
                    └─────────────────────────────────────────┘
```

### Role Hierarchy

| Role | Holder | Permissions |
|---|---|---|
| `DEFAULT_ADMIN` | DAO / deployer | Grant roles, unpause deposits |
| `CURATOR_ROLE` | Risk manager | Add markets (timelocked), set fees & timelock |
| `ALLOCATOR_ROLE` | Yield bot | Move USDC between markets within supply caps |
| `SENTINEL_ROLE` | VaultSentinel contract | Pause deposits, emergency deallocate — risk-reducing only |

### AI Risk Check Flow

| Step | Action |
|---|---|
| 1 | Anyone calls `checkVault(vault)` with ≥ 0.25 STT attached |
| 2 | Sentinel reads `totalAssets`, `idleBufferPct`, `marketAllocationPct` (×2), `utilizationBps` (×2) |
| 3 | Metrics encoded into a plain-English prompt, sent to Somnia's LLM Agent via `createRequest()` |
| 4 | 3 validators run Qwen3-30B with fixed seed and temperature=0 — deterministic, reproducible output |
| 5 | Platform calls `handleResponse()` on VaultSentinel with consensus verdict |
| 6 | **SAFE** → snapshot stored, no action · **CAUTION** → `RiskAlert` event · **CRITICAL** → `pauseDeposits()` + `emergencyDeallocate(50%)` on highest-utilization market |

### Verdict Thresholds

| Condition | Verdict |
|---|---|
| Utilization < 80% and allocation < 25% on all markets | **SAFE** |
| Utilization 80–95% or allocation 25–40% on any market | **CAUTION** |
| Utilization > 95% **and** allocation > 40% on any market | **CRITICAL** |

---

## Smart Contracts

### Somnia Testnet Deployments

| Contract | Address |
|---|---|
| `CuratedVault` | [`0x9E37575c04A8B39A81B901ADb4514552DC450833`](https://shannon-explorer.somnia.network/address/0x9E37575c04A8B39A81B901ADb4514552DC450833) |
| `VaultSentinel` | [`0x89e5EadA95CB904B90495dbEb6df1Cf4B3e05412`](https://shannon-explorer.somnia.network/address/0x89e5EadA95CB904B90495dbEb6df1Cf4B3e05412) |
| `MockUSDC` | [`0xdF9F879e07bE0378e051B5319cEA7ea6e01D3a57`](https://shannon-explorer.somnia.network/address/0xdF9F879e07bE0378e051B5319cEA7ea6e01D3a57) |
| `MockLendingMarket A` | [`0x94AfD5262f71bf368580249af7fDc41805b64465`](https://shannon-explorer.somnia.network/address/0x94AfD5262f71bf368580249af7fDc41805b64465) |
| `MockLendingMarket B` | [`0x19Ff7b4e162D68103D18e1CEe518a3cA65198605`](https://shannon-explorer.somnia.network/address/0x19Ff7b4e162D68103D18e1CEe518a3cA65198605) |

**Network:** Somnia Testnet · **Chain ID:** 50312 · **Explorer:** [shannon-explorer.somnia.network](https://shannon-explorer.somnia.network)

### Contract Summary

**`CuratedVault`** — ERC-4626 tokenized yield vault. Accepts USDC deposits, mints yield-bearing shares, and allocates capital to whitelisted lending markets. Features role-based access control, timelocked market additions (1 min testnet / 24h+ mainnet), per-market supply caps, performance fees, and ERC-4626 inflation-attack protection via virtual shares/assets offsets.

**`VaultSentinel`** — Autonomous AI risk monitor. Holds `SENTINEL_ROLE` on the vault, allowing it to pause deposits and emergency-deallocate capital. Integrates with Somnia's native `IAgentRequester` platform. Enforces a 5-minute cooldown per vault and a fail-safe (timeout → CAUTION, never silently SAFE) to prevent silent risk misclassification.

---

## Key Design Decisions

- **No external APIs or oracles.** All five metrics (`totalAssets`, `idleBufferPct`, `marketAllocationPct`, `utilizationBps`) are direct view calls to the vault's own contracts. This works on any network, including testnets with no price feed support.
- **Deterministic AI verdicts.** Fixed seed and temperature=0 ensure all 3 validators produce identical output, making consensus reliable and the verdict fully reproducible.
- **Fail-safe by default.** If a request times out or fails, the sentinel records CAUTION — it never silently returns SAFE and misses a real risk event.
- **Sentinel is risk-reducing only.** `SENTINEL_ROLE` can pause deposits and withdraw from markets, but cannot add markets, increase caps, or move funds out of the vault — limiting its blast radius if compromised.
- **Inflation attack protection.** Virtual share (`VSHARES=1`) and asset (`VASSETS=1`) offsets in `_toShares` / `_toAssets` prevent first-depositor share price manipulation.
- **`handleResponse` name is exact.** The callback selector is passed literally as `this.handleResponse.selector` to `createRequest`. Renaming it breaks the Somnia platform integration.

---

## Getting Started

### Prerequisites

- [Foundry](https://getfoundry.sh) — `curl -L https://foundry.paradigm.xyz | bash && foundryup`
- [Node.js](https://nodejs.org) ≥ 18 (frontend only)
- MetaMask with Somnia Testnet configured

### Add Somnia Testnet to MetaMask

| Field | Value |
|---|---|
| Network Name | Somnia Testnet |
| RPC URL | `https://dream-rpc.somnia.network` |
| Chain ID | `50312` |
| Currency Symbol | `STT` |
| Explorer | `https://shannon-explorer.somnia.network` |

Get testnet STT from the [Somnia faucet](https://testnet.somnia.network).

### Clone & Build

```bash
git clone <repo-url>
cd ephor-protocol

# Install Foundry dependencies
forge install

# Compile contracts
forge build
```

### Run Tests

```bash
# Full test suite with trace
forge test -vvv

# Single test by name
forge test --match-test testCriticalVerdictPausesAndDeallocates -vvv

# Single contract
forge test --match-contract VaultSentinelTest -vvv
```

### Run Frontend

```bash
cd frontend
npm install
npm run dev
# Open http://localhost:5173
```

---

## Deployment

Copy `.env.example` to `.env` and populate your private key and deployer address.

```bash
# 1. Deploy all contracts and register the vault with the sentinel
forge script script/DeployAndSubmit.s.sol \
  --rpc-url somnia_testnet \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --gas-estimate-multiplier 3000

# 2. Execute timelock and seed initial market allocations
forge script script/ExecuteAndSeed.s.sol \
  --rpc-url somnia_testnet \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --gas-estimate-multiplier 3000

# 3. Trigger an AI risk check
# NOTE: forge script simulation fails on Somnia (NotActivated) — use cast send directly
cast send $VAULT_SENTINEL_ADDRESS \
  "checkVault(address)" $CURATED_VAULT_ADDRESS \
  --value 0.25ether \
  --rpc-url https://dream-rpc.somnia.network \
  --private-key $PRIVATE_KEY
```

> **Somnia Gas Note:** Somnia's gas costs run ~27× higher than standard EVM estimates. Always pass `--gas-estimate-multiplier 3000` to `forge script` deployments to avoid out-of-gas reverts.

---

## Security

### Audit Status

This codebase was developed for the Encode Club Agentathon hackathon. **It has not undergone a formal third-party security audit.** Do not deploy to mainnet with real funds without a full audit.

### Known Mitigations

| Risk | Mitigation |
|---|---|
| Reentrancy | `nonReentrant` guard on all external state-changing functions |
| ERC-4626 inflation attack | Virtual shares/assets offsets (`VSHARES=1`, `VASSETS=1`) |
| Malicious market addition | Timelocked queue (`submitAddMarket` → wait → `executeAddMarket`) |
| Sentinel over-reach | `SENTINEL_ROLE` scoped to `pauseDeposits` + `emergencyDeallocate` only |
| Fake AI verdict injection | `onlyPlatform` modifier on `handleResponse` — only the Somnia platform contract can call it |
| DoS via repeated checks | 5-minute cooldown per vault, one in-flight request enforced |
| Silent SAFE on failure | Timeout/fail path records CAUTION, never SAFE |

---

## Project Structure

```
├── src/
│   ├── CuratedVault.sol           # ERC-4626 vault with role-based access
│   ├── VaultSentinel.sol          # AI risk monitor — Somnia LLM integration
│   ├── Interface/
│   │   └── ISomnia.sol            # IAgentRequester, ILLMInferenceAgent interfaces
│   └── Mock/
│       ├── MockUSDC.sol           # Test USDC with mint()
│       ├── MockLendingMarket.sol  # Simulated market with fastForwardDays()
│       └── MockSomniaPlatform.sol # Simulates Somnia callback for tests
├── test/
│   └── VaultSentinelTest.t.sol    # Full integration test suite
├── script/
│   ├── DeployAndSubmit.s.sol      # Deploy all contracts + register vault
│   ├── ExecuteAndSeed.s.sol       # Execute timelock + seed market allocations
│   ├── TriggerCheck.s.sol         # Reference script for AI check (use cast send)
│   ├── ReplaceSentinel.s.sol      # Upgrade sentinel without redeploying vault
│   └── VerifyResponse.s.sol       # Read back latest AI verdict on-chain
└── frontend/
    ├── src/
    │   ├── App.jsx                # Wallet, transaction handlers, tab routing
    │   ├── config.js              # Addresses, ABIs, network config
    │   ├── hooks/useProtocol.js   # Polling hook — fetches all on-chain state
    │   ├── components/            # Header, TabNav, StatsBar
    │   └── pages/                 # Dashboard, My Position, AI Sentinel, Demo
    └── public/
        └── logo.svg               # Protocol logo (transparent background)
```

---

## Built With

| Layer | Technology |
|---|---|
| Smart Contracts | Solidity 0.8.20, Foundry |
| AI Inference | Somnia LLM Inference Agent (Qwen3-30B) |
| Network | Somnia Testnet (Chain ID 50312) |
| Frontend | React, Vite, Tailwind CSS v3, ethers.js v6 |

---

## License

MIT — see [LICENSE](LICENSE)

---

<div align="center">
  Built for <strong>Encode Club Agentathon</strong> · Powered by <a href="https://somnia.network">Somnia Network</a>
</div>
