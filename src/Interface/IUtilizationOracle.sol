// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title  IUtilizationOracle
/// @notice Interface for the manipulation-resistant TWAP utilization oracle.
interface IUtilizationOracle {
    /// @notice Emitted when spot util deviates from TWAP beyond spikeToleranceBps (AC-18).
    event SuspiciousSpike(
        address indexed market,
        uint256 spot,
        uint256 twapVal,
        uint256 delta,
        uint256 timestamp
    );

    function update(address market) external;
    function twap(address market, uint256 window) external view returns (uint256);
    function effectiveUtil(address market) external returns (uint256 util, bool spikeDetected);
    function isValid(address market) external view returns (bool);
    function lastRecorded(address market) external view returns (uint256 timestamp, uint256 utilBps);
}
