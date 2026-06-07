// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {CuratedVault} from "./CuratedVault.sol";
import {ILendingMarket} from "./Interface/ILendingMarket.sol";

/// @title  AllocationProjection
/// @notice Deterministic 6-step projection algorithm (SDD §11).
///         Given AI weights per market and vault risk parameters, computes
///         final target amounts[] satisfying all rebalance invariants.
///
///  Step 1: Budget B = totalAssets - ceil(minIdleFloor)
///  Step 2: Per-market ceiling u_i = min(cap_i, maxMarketBps * totalAssets / 1e4)
///  Step 3: Proportional split d_i = w_i * B / Σw_j
///  Step 4: Capped water-fill: t_i = min(d_i, u_i); redistribute overflow
///  Step 5: Turnover scale: if Σ|t_i - b_i| > maxTurnoverBps * A / 1e4, scale back
///  Step 6: Return final targets[]
library AllocationProjection {
    /// @notice Compute target amounts for a reallocate call.
    ///
    /// @param markets      Ordered list of market addresses to target.
    /// @param weights      AI-supplied weights (same length as markets; may be zero for idle).
    /// @param currentBals  Current market balances in asset units (ILendingMarket.balanceOf).
    /// @param supplyCaps   Per-market supply caps (markets[i].supplyCap).
    /// @param totalAssets_ Vault totalAssets() at snapshot time.
    /// @param minIdleBps   Vault minIdleBufferBps.
    /// @param maxMktBps    Vault maxMarketBps.
    /// @param maxTurnBps   Vault maxTurnoverBps.
    ///
    /// @return targets     Final target amounts in asset units, same order as markets[].
    function project(
        address[] memory markets,
        uint256[] memory weights,
        uint256[] memory currentBals,
        uint256[] memory supplyCaps,
        uint256 totalAssets_,
        uint256 minIdleBps,
        uint256 maxMktBps,
        uint256 maxTurnBps
    ) internal pure returns (uint256[] memory targets) {
        uint256 n = markets.length;
        require(weights.length == n && currentBals.length == n && supplyCaps.length == n, "length mismatch");

        targets = new uint256[](n);
        if (n == 0 || totalAssets_ == 0) return targets;

        // ── Step 1: Budget ────────────────────────────────────────────────
        // minIdleFloor = ceil(minIdleBps * totalAssets_ / 1e4)
        uint256 minIdle = (minIdleBps * totalAssets_ + 9_999) / 10_000;
        uint256 budget = totalAssets_ > minIdle ? totalAssets_ - minIdle : 0;

        // ── Step 2: Per-market ceiling ────────────────────────────────────
        uint256[] memory ceilings = new uint256[](n);
        for (uint256 i; i < n;) {
            uint256 mktCap = maxMktBps * totalAssets_ / 10_000;
            ceilings[i] = supplyCaps[i] < mktCap ? supplyCaps[i] : mktCap;
            unchecked { ++i; }
        }

        // ── Step 3: Weight sum + proportional split ───────────────────────
        uint256 wSum;
        for (uint256 i; i < n;) {
            wSum += weights[i];
            unchecked { ++i; }
        }

        uint256[] memory proportional = new uint256[](n);
        if (wSum == 0) {
            // All weights zero — everything stays idle (targets remain 0).
            return targets;
        }
        for (uint256 i; i < n;) {
            proportional[i] = weights[i] * budget / wSum;
            unchecked { ++i; }
        }

        // ── Step 4: Capped water-fill ─────────────────────────────────────
        // Iteratively cap at ceilings and redistribute overflow.
        // We run at most n passes (each pass caps at least one newly-overflowing entry).
        for (uint256 i; i < n;) {
            targets[i] = proportional[i];
            unchecked { ++i; }
        }

        bool changed = true;
        while (changed) {
            changed = false;
            uint256 overflow;
            uint256 uncappedSum;
            for (uint256 i; i < n;) {
                if (targets[i] > ceilings[i]) {
                    overflow += targets[i] - ceilings[i];
                    targets[i] = ceilings[i];
                    changed = true;
                } else {
                    uncappedSum += targets[i];
                }
                unchecked { ++i; }
            }
            if (overflow == 0) break;
            // Redistribute overflow proportionally to uncapped slots.
            if (uncappedSum == 0) break; // no room to redistribute
            for (uint256 i; i < n;) {
                if (targets[i] < ceilings[i]) {
                    uint256 share = targets[i] * overflow / uncappedSum;
                    targets[i] += share;
                }
                unchecked { ++i; }
            }
        }

        // ── Step 5: Turnover scale ────────────────────────────────────────
        // Σ|t_i - b_i| must be <= maxTurnBps * totalAssets_ / 1e4
        uint256 maxTurn = maxTurnBps * totalAssets_ / 10_000;
        uint256 totalDelta;
        for (uint256 i; i < n;) {
            uint256 b = currentBals[i];
            uint256 t = targets[i];
            totalDelta += t > b ? t - b : b - t;
            unchecked { ++i; }
        }
        if (totalDelta > maxTurn && totalDelta > 0) {
            // Scale all targets back toward current balances by ratio maxTurn/totalDelta.
            // For each market: t'_i = b_i + (t_i - b_i) * maxTurn / totalDelta
            for (uint256 i; i < n;) {
                uint256 b = currentBals[i];
                uint256 t = targets[i];
                if (t >= b) {
                    targets[i] = b + (t - b) * maxTurn / totalDelta;
                } else {
                    targets[i] = b - (b - t) * maxTurn / totalDelta;
                }
                unchecked { ++i; }
            }
        }

        // ── Step 6: Return ────────────────────────────────────────────────
        return targets;
    }
}
