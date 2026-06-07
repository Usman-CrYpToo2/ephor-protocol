// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../Interface/IMarketAdapter.sol";

/**
 * @title  GenericAdapter
 * @notice IMarketAdapter implementation for markets that directly expose a
 *         `utilizationBps()` view function — most notably MockLendingMarket
 *         and any protocol that already normalises its utilization into bps.
 *
 *  USE IN TESTS
 *  ────────────
 *  Deploy one instance of GenericAdapter.  Register it in UtilizationOracle
 *  via `oracle.setAdapter(marketAddress, address(genericAdapter))` for every
 *  MockLendingMarket used in the test.  The oracle will then call
 *  `genericAdapter.utilizationBps(marketAddress)` which forwards to
 *  `ILendingMarketBps(marketAddress).utilizationBps()`.
 *
 *  SECURITY
 *  ────────
 *  Pure view delegation — no state, no custody, no roles.  The oracle clamps
 *  the returned value to 10_000 bps so a hostile market cannot corrupt
 *  arithmetic downstream.
 *
 *  Satisfies: D-8, I-11, AC-17 (adapters are curator-registered per market).
 */

/// @dev Minimal interface for markets that expose utilizationBps() directly.
interface ILendingMarketBps {
    function utilizationBps() external view returns (uint256);
}

contract GenericAdapter is IMarketAdapter {
    /**
     * @notice Forward the `utilizationBps()` call to `market`.
     * @dev    The oracle clamps the return value to 10_000 before use.
     *         A market returning MAX_UINT is safe downstream.
     * @param  market  Address of the lending market to query.
     * @return         Spot utilization in bps (0–10_000 before clamping).
     */
    function utilizationBps(address market) external view override returns (uint256) {
        return ILendingMarketBps(market).utilizationBps();
    }
}
