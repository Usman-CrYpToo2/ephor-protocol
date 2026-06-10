// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title  IVault
/// @notice Minimal interface for CuratedVault as seen by VaultSentinel.
interface IVault {
    function totalAssets() external view returns (uint256);
    /// @dev Returns idle fraction in bps (1% = 100 bps). Fixes D-3.
    function idleBufferBps() external view returns (uint256);
    /// @dev Returns market allocation fraction in bps. Fixes D-3.
    function marketAllocationBps(address market) external view returns (uint256);
    function marketCount() external view returns (uint256);
    function marketList(uint256 i) external view returns (address);
    /// @dev Supply cap for a market in asset base units (§9.3 headroom field).
    function marketSupplyCap(address market) external view returns (uint256);
    /// @dev Current rebalance epoch — changes after each executed rebalance (§9.3).
    function currentEpoch() external view returns (uint256);
    /// @dev Decimal count of the vault's configured ERC-20 asset (§9.3 decimals field).
    function assetDecimals() external view returns (uint8);
    function pauseDeposits() external;
    function emergencyDeallocate(address market, uint256 amount) external;
}
