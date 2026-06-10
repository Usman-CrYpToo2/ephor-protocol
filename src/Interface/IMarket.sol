// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title  IMarket
/// @notice Minimal interface for reading spot utilization from a lending market.
///         Used by VaultSentinel as fallback when no UtilizationOracle is set.
interface IMarket {
    function balanceOf(address account) external view returns (uint256);
    function utilizationBps() external view returns (uint256);
    /// @notice Current supply APY in basis points (e.g. 500 = 5%). Optional — returns 0 if unsupported.
    function supplyRateBps() external view returns (uint256);
}
