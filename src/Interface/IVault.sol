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
    function pauseDeposits() external;
    function emergencyDeallocate(address market, uint256 amount) external;
}
