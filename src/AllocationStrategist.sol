// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {CuratedVault} from "./CuratedVault.sol";

/// @title  AllocationStrategist
/// @notice Phase 2 stub — holds ALLOCATOR_ROLE on a CuratedVault and calls reallocate().
///         Phase 3 will replace executeRebalance with an AI-driven proposal flow
///         (Somnia LLM inference → AllocationProjection → reallocate).
///
/// @dev    The admin (passed to constructor) is the only address permitted to
///         trigger a rebalance through this contract. In production this will be
///         the VaultSentinel or a DAO-controlled address.
contract AllocationStrategist {
    CuratedVault public immutable vault;
    address public immutable admin;

    error NotAdmin();

    event RebalanceExecuted(uint256 epoch);

    constructor(address _vault, address _admin) {
        require(_vault != address(0) && _admin != address(0), "zero addr");
        vault = CuratedVault(_vault);
        admin = _admin;
    }

    /// @notice Phase 2 stub: direct call to reallocate with caller-supplied targets.
    ///         Phase 3 will replace this with an AI-driven proposal flow.
    ///
    /// @param targets  Per-market target balances in asset base units.
    /// @param guard    Staleness guard (snapshotTotalAssets, snapshotEpoch).
    function executeRebalance(
        CuratedVault.MarketTarget[] calldata targets,
        CuratedVault.RebalanceGuard calldata guard
    ) external {
        if (msg.sender != admin) revert NotAdmin();
        vault.reallocate(targets, guard);
        emit RebalanceExecuted(vault.currentEpoch());
    }
}
