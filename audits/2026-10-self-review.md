# Self-review: Ephor Protocol

| | |
|---|---|
| **Scope** | `src/` at commit `c27ebe6` (2,900 lines: `CuratedVault`, `VaultSentinel`, `AllocationStrategist`, `AllocationProjection`, `UtilizationOracle`) |
| **Reference** | [`docs/design-spec.md`](../docs/design-spec.md) (invariants I-1 to I-12, defects D-1 to D-9) |
| **Method** | Manual review against the spec, `git` history diff of `c27ebe6` against its parent, proof-of-concept tests |
| **Date** | 2026-10 |

## Summary

| ID | Title | Severity | Status |
|---|---|---|---|
| EP-01 | Anyone can unpause deposits after a sentinel emergency | Critical | Fixed |
| EP-02 | Integer formatter never terminates; every strategist rebalance runs out of gas | High | Fixed |
| EP-03 | Market and cap timelock removed; sentinel can raise caps | High | Fixed |
| EP-04 | `reallocate` counts unlisted market balances as idle | Medium | Fixed |
| EP-05 | Duplicate queued market additions both execute | Medium | Fixed |
| EP-06 | Strategist acts on responses that did not reach consensus | Medium | Fixed |
| EP-07 | `allocate` ignores the deposit pause | Low | Fixed |
| EP-08 | Raw ERC-20 calls fail for tokens that return no value | Low | Fixed |
| EP-09 | `DERISK` does not de-risk | Low | Acknowledged |
| EP-10 | Vault is not fully ERC-4626 compliant | Low | Acknowledged |
| EP-11 | Performance fee has no high-water mark | Informational | Acknowledged |
| EP-12 | Tier-2 allocation removed from `main` | Informational | Acknowledged |

EP-01 to EP-03 were introduced by `c27ebe6`, a commit described as a frontend change that also rewrote parts of `src/`. Each restores behaviour the parent commit and the design spec already required. The Somnia testnet addresses and deploy scripts were introduced in the same commit, so the live deployment should be assumed affected; redeploy from `main` to pick up the fixes.

---

## EP-01: Anyone can unpause deposits after a sentinel emergency

**Severity:** Critical

```solidity
function unpauseDeposits() external {
    depositsPaused = false;
```

`c27ebe6` removed `onlyRole(DEFAULT_ADMIN_ROLE)`. The sentinel's only circuit breaker is `pauseDeposits()`; any address could reverse it in the next transaction, so deposits could keep flowing into a vault the sentinel had classified as critical.

**Fix.** `onlyRole(DEFAULT_ADMIN_ROLE)` restored. `testVault_sentinelCanPauseDeposits` now asserts that a non-admin unpause reverts.

---

## EP-02: Integer formatter never terminates

**Severity:** High

```solidity
while (t != 0) d++;   // body is only d++; t never changes
t /= 10;
```

`AllocationStrategist._u` lost its loop braces in `c27ebe6`. For any non-zero input the first loop never ends, so `requestRebalance`, which formats every metric into the prompt, always ran out of gas. The AI allocation path could not complete. This is the same defect the spec records as D-2 for `VaultSentinel`, whose copy is correct. It also caused all 12 `StrategistTier1Test` failures behind the red CI.

**Fix.** Braces restored. `StrategistFormatTest` covers fixed vectors, a fuzz test against `vm.toString`, and a gas bound; all three fail on the previous code.

---

## EP-03: Market and cap timelock removed; sentinel can raise caps

**Severity:** High

`c27ebe6` replaced `submitAddMarket` / `executeAddMarket` with an instant `addMarket`, deleted `executeSetCap`, `revokeAction` and `setTimelock`, and collapsed `setSupplyCap` into:

```solidity
require(hasRole(CURATOR_ROLE, msg.sender) || hasRole(SENTINEL_ROLE, msg.sender), "unauthorized");
markets[market].supplyCap = newCap;
```

Risk-increasing curator actions took effect immediately, giving depositors no exit window. The sentinel, specified as risk-reducing only, could raise any cap, so a fault in its AI path could increase exposure.

**Fix.** The timelock queue is restored. Cap increases are curator-only and timelocked; decreases stay immediate for curator or sentinel. Deploy scripts queue markets in step 1 and execute them in step 2. Five tests cover the queue, revocation, cap timelock, sentinel decrease-only and timelock bounds.

---

## EP-04: `reallocate` counts unlisted market balances as idle

**Severity:** Medium

```solidity
uint256 impliedIdle = ta >= targetSum ? ta - targetSum : 0;
```

`reallocate` only moves markets listed in `targets`. A market left out keeps its balance, yet that balance was treated as idle, so I-1 and the I-3 idle floor could pass on paper while real idle fell below the floor. With a 20% floor: A at 45%, B at 35%, then a call listing only B at 45% passes with "55% idle" while real idle is 10%. A market listed twice was also summed twice.

**Fix.** Balances of enabled markets missing from `targets` are reserved before idle is derived, and duplicate markets revert with `I-1`. Proof-of-concept tests `testReallocate_I3_unlistedMarketIsNotIdle` and `testReallocate_I1_duplicateMarketRejected` failed before the fix.

---

## EP-05: Duplicate queued market additions both execute

**Severity:** Medium

`submitAddMarket` checks that a market is not yet enabled, but two submissions for the same market with different caps produce different action IDs. `executeAddMarket` did not re-check, so both could execute, listing the market twice in `_mlist`. `totalAssets()` iterates `_mlist`, so the market's balance would be counted twice and share prices inflated. This was present in the original timelock, before `c27ebe6`.

**Fix.** `executeAddMarket` requires the market to still be disabled. Covered by `testVault_duplicateQueuedMarketCannotExecuteTwice`.

---

## EP-06: Strategist acts on responses that did not reach consensus

**Severity:** Medium

`VaultSentinel.handleResponse` rejects responses where `details.responseCount < details.threshold` (spec D-6). `AllocationStrategist.handleResponse` ignored `details` entirely, so a single validator's answer could drive a reallocation.

**Fix.** The strategist applies the same check and skips with `CONSENSUS_NOT_MET`. Covered by `testHandleResponse_belowThresholdSkipped`.

---

## EP-07: `allocate` ignores the deposit pause

**Severity:** Low

I-9 forbids moving funds into markets while deposits are paused. `reallocate` enforced it; the single-market `allocate` did not.

**Fix.** `allocate` reverts while paused. Covered by `testVault_allocateBlockedWhilePaused`.

---

## EP-08: Raw ERC-20 calls fail for tokens that return no value

**Severity:** Low

The vault is specified as asset-agnostic, but `require(asset.approve(...))` and `require(asset.transfer(...))` revert for tokens such as USDT that return nothing, and `allocate` ignored the return of `approve` entirely.

**Fix.** `SafeERC20` (`safeTransfer`, `safeTransferFrom`, `forceApprove`).

---

## EP-09: `DERISK` does not de-risk

**Severity:** Low

The strategist documents `DERISK` as moving capital to idle, but it returns without calling the vault, leaving existing allocations in place. `reallocate` cannot express a full withdrawal either, because I-5 rejects zero targets. Defensive action therefore rests with the sentinel's `emergencyDeallocate`.

**Status.** Acknowledged. A fix needs zero targets to be valid for enabled markets.

---

## EP-10: Vault is not fully ERC-4626 compliant

**Severity:** Low

`CuratedVault` implements `deposit`, `redeem`, `totalAssets`, `maxDeposit` and previews, but not `mint`, `withdraw`, `convertToShares`, `convertToAssets`, `maxMint`, `maxWithdraw` or `maxRedeem`, and emits `Deposited` / `Redeemed` rather than the standard events. Integrations expecting the full interface will fail.

**Status.** Acknowledged. The README describes the vault as ERC-4626-style.

---

## EP-11: Performance fee has no high-water mark

**Severity:** Informational

`_accruePerformanceFee` resets `_lastTA` downward after a loss, so a later recovery to the previous level is charged as new gain.

**Status.** Acknowledged.

---

## EP-12: Tier-2 allocation removed from `main`

**Severity:** Informational

The per-market `inferNumber` scoring mode from Phase 4 (`d49c61e`) and its 390-line test file were removed in `c27ebe6`. The design spec still describes it.

**Status.** Acknowledged. The implementation remains in history.
