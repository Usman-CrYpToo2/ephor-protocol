// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {AllocationStrategist} from "../../src/AllocationStrategist.sol";

/// @dev Exposes the internal integer formatter used to build LLM prompts.
contract StrategistHarness is AllocationStrategist {
    constructor() AllocationStrategist(address(1), 1, address(1), address(1)) {}

    function u(uint256 v) external pure returns (string memory) {
        return _u(v);
    }
}

/// @title  StrategistFormatTest
/// @notice Regression tests for `_u`. A version whose loop counters never
///         advanced shipped in c27ebe6 and made every `requestRebalance` with
///         a non-zero metric run out of gas.
contract StrategistFormatTest is Test {
    StrategistHarness harness;

    function setUp() public {
        harness = new StrategistHarness();
    }

    function test_u_formatsDigits() public view {
        assertEq(harness.u(0), "0");
        assertEq(harness.u(7), "7");
        assertEq(harness.u(10), "10");
        assertEq(harness.u(9_500), "9500");
        assertEq(harness.u(100_000_000_000), "100000000000");
        assertEq(
            harness.u(type(uint256).max),
            "115792089237316195423570985008687907853269984665640564039457584007913129639935"
        );
    }

    function testFuzz_u_matchesVmToString(uint256 v) public view {
        assertEq(harness.u(v), vm.toString(v));
    }

    /// @dev Bounded gas: the broken loop consumed the entire block gas limit.
    function test_u_gasIsBounded() public view {
        uint256 before = gasleft();
        harness.u(type(uint256).max);
        assertLt(before - gasleft(), 100_000);
    }
}
