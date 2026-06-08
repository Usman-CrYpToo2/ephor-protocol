# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
# Install dependencies
forge install

# Build
forge build

# Run all tests (summary only — saves ~3k tokens vs full output)
forge test 2>&1 | grep -E "Suite result|^Ran|total tests|FAIL|Error"

# Run all tests with full output (only when debugging a failure)
forge test

# Run a single test (add -vvv only when debugging a failure)
forge test --match-test testName

# Run a test contract
forge test --match-contract ContractName

# Format
forge fmt

# Gas snapshot
forge snapshot

# Local node
anvil

# Frontend dev server
cd frontend && npm install && npm run dev   # http://localhost:5173
```

`foundry.toml` configures Solidity 0.8.20, EVM `paris`, optimizer 200 runs, and fuzz with 256 runs. RPC endpoints `somnia_testnet` and `somnia_mainnet` are pre-configured via `${SOMNIA_TESTNET_RPC}` env var.

## Deployment (3-step process)

Copy `.env.example` → `.env`, populate `PRIVATE_KEY`, `DEPLOYER_ADDRESS`, `SOMNIA_TESTNET_RPC`, and `LLM_AGENT_ID` (from `agents.testnet.somnia.network`).

> **Gas note:** Somnia gas costs run ~27× higher than standard EVM estimates. Always pass `--gas-estimate-multiplier 3000` to `forge script`.

```bash
source .env

# Step 1 — Deploy all contracts, submit timelocked market additions
forge script script/DeployAndSubmit.s.sol \
  --rpc-url somnia_testnet --private-key $PRIVATE_KEY \
  --broadcast --gas-estimate-multiplier 3000
# Copy printed addresses back into .env

# Step 2 — Execute timelock + seed allocations (run ≥1 min after Step 1)
forge script script/ExecuteAndSeed.s.sol \
  --rpc-url somnia_testnet --private-key $PRIVATE_KEY \
  --broadcast --gas-estimate-multiplier 3000

# Step 3 — Trigger AI risk check (forge script simulation fails on Somnia — use cast send)
cast send $VAULT_SENTINEL_ADDRESS \
  "checkVault(address)" $CURATED_VAULT_ADDRESS \
  --value 0.25ether \
  --rpc-url $SOMNIA_TESTNET_RPC \
  --private-key $PRIVATE_KEY
```

Other scripts: `ReplaceSentinel.s.sol` upgrades the sentinel without redeploying the vault; `VerifyResponse.s.sol` reads back the latest on-chain AI verdict.

## Architecture

This is an AI-powered DeFi vault system targeting the **Somnia network**, where on-chain LLM inference is natively supported via the Somnia Agent Platform.

### Contract Roles

| Contract | Role |
|---|---|
| `CuratedVault` | ERC-4626 USDC vault with role-based access, timelocked market management, per-market supply caps, and performance fees |
| `VaultSentinel` | Autonomous AI risk monitor — holds `SENTINEL_ROLE` on vaults and can pause deposits / emergency-deallocate |
| `src/Interface/ISomnia.sol` | Exact interfaces from Somnia docs for `IAgentRequester`, `ILLMInferenceAgent`, `Response`, `Request`, etc. |
| `src/Mock/` | Test doubles: `MockUSDC`, `MockLendingMarket`, `MockSomniaPlatform` |

### AI Risk Check Flow

1. Anyone calls `VaultSentinel.checkVault(vault)` with ≥0.25 STT attached (covers platform deposit + 3 validator rewards at 0.03 STT each).
2. Sentinel reads five on-chain metrics from the vault (no external APIs): `totalAssets`, `idleBufferPct`, `marketAllocationPct`, `marketCount`, `utilizationBps` per market.
3. These metrics are encoded into a plain-English prompt and sent to Somnia's LLM Inference Agent (Qwen3-30B) via `platform.createRequest()`.
4. Validators run the LLM deterministically (fixed seed, temp=0) and reach consensus.
5. Platform calls back `VaultSentinel.handleResponse()` with `SAFE`, `CAUTION`, or `CRITICAL`.
6. `CRITICAL` → `pauseDeposits()` + `emergencyDeallocate()` on the highest-utilization market (50% withdrawal, only if util > 90%). Timeout/failure → fail-safe CAUTION, never silently SAFE.

### Verdict Thresholds

| Condition | Verdict |
|---|---|
| Utilization < 80% and allocation < 25% on all markets | **SAFE** |
| Utilization 80–95% or allocation 25–40% on any market | **CAUTION** |
| Utilization > 95% **and** allocation > 40% on any market | **CRITICAL** |

### CuratedVault Role Hierarchy

```
DEFAULT_ADMIN  — grants roles, unpauses deposits
CURATOR_ROLE   — adds markets (timelocked 1h–3weeks), sets fee/timelock
ALLOCATOR_ROLE — moves USDC between markets within supply caps
SENTINEL_ROLE  — pauses deposits, emergency deallocates (risk-reducing only)
```

Market additions and cap increases go through a timelock queue (`submitAddMarket` → wait → `executeAddMarket`). Cap decreases and action revocations are immediate.

### Key Design Decisions

- **ERC-4626 inflation attack protection**: virtual shares (`VSHARES=1`) and virtual assets (`VASSETS=1`) offsets in `_toShares` / `_toAssets`.
- **`pendingRequests` must be `public`**: `MockSomniaPlatform` looks up the vault address by requestId during tests. Do not rename to `_pending`.
- **Somnia platform addresses**: testnet `0x037Bb9C718F3f7fe5eCBDB0b600D607b52706776`, mainnet `0x5E5205CF39E766118C01636bED000A54D93163E6`. The real LLM Agent ID comes from `agents.somnia.network`.
- **`handleResponse` name is exact**: the callback selector is passed literally as `this.handleResponse.selector` to `createRequest`; renaming breaks the platform integration.
- **5-minute cooldown** per vault prevents sentinel DoS; one in-flight check per vault enforced via `activeRequest` mapping.

### Testing

All tests are in `test/VaultSentinelTest.t.sol`. The test suite uses `MockSomniaPlatform.simulateCallback(requestId, verdict)` to inject verdicts and `simulateTimeout(requestId)` to test the fail-safe path. The `vault.grantRole(ALLOCATOR_ROLE, address(this))` pattern grants roles to the test contract inline when needed.
