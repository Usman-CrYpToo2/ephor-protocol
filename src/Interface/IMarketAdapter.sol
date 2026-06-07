// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title  IMarketAdapter
 * @notice Protocol-specific adapter that translates an external lending market's
 *         data into the standard `utilizationBps(market)` format understood by
 *         the UtilizationOracle.
 *
 *  DESIGN
 *  ──────
 *  Different lending protocols expose utilization differently:
 *    • Aave v3:   reads getReserveData(asset) → computes borrow/supply ratio
 *    • Compound:  reads totalBorrows(), getCash(), totalReserves()
 *    • Generic:   markets that directly expose utilizationBps()
 *
 *  All adapters implement this single interface so the oracle never has to
 *  know which protocol the market belongs to.
 *
 *  ASSET-AGNOSTIC
 *  ──────────────
 *  The returned value is in basis points (bps, 0–10_000) — a dimensionless
 *  ratio independent of the asset type.  An Aave WETH pool and an Aave USDC
 *  pool return the same scale.
 *
 *  SECURITY
 *  ────────
 *  The oracle clamps the returned value to 10_000 before use, so a malicious
 *  adapter returning uint256.max cannot corrupt downstream arithmetic.
 *
 *  Satisfies: D-8 (flash-loan manipulation resistance), I-11, G-8, P-9, R-10.
 */
interface IMarketAdapter {
    /**
     * @notice Read the current spot utilization of `market` in basis points.
     * @param  market  The lending market address to query.
     * @return         Utilization in bps (0 = 0%, 10_000 = 100%).
     *                 Values > 10_000 are clamped by the oracle caller.
     */
    function utilizationBps(address market) external view returns (uint256);
}
