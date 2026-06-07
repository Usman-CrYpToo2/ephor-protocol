// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./MockERC20.sol";

/// @title  MockUSDC
/// @notice Backward-compatible 6-decimal USDC mock for existing tests.
///         Thin wrapper over MockERC20 — all behaviour is inherited.
///
/// @dev    Resolves D-9: hardcoded USDC specifics removed from MockERC20.
///         Existing tests that use MockUSDC continue to work unchanged.
contract MockUSDC is MockERC20 {
    constructor() MockERC20("Mock USDC", "USDC", 6) {}
}
