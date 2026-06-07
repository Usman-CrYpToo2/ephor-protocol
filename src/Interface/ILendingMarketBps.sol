// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title  ILendingMarketBps
/// @notice Minimal interface for markets that expose utilizationBps() directly.
///         Used by GenericAdapter to forward oracle queries.
interface ILendingMarketBps {
    function utilizationBps() external view returns (uint256);
}
