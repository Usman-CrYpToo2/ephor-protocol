// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title  ILendingMarket
/// @notice Minimal interface for an Aave/Morpho-style single-asset lending market.
interface ILendingMarket {
    function supply(uint256 amount) external;
    function withdraw(uint256 amount) external;
    function balanceOf(address account) external view returns (uint256);
    function utilizationBps() external view returns (uint256);
}
