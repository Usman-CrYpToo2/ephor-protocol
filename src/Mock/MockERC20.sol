// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title  MockERC20
/// @notice Generic mintable ERC-20 for testing.
///         Name, symbol, and decimal count are configured at deployment.
///         Anyone can mint — this is a test double only.
///
/// @dev    Resolves D-9: replaces the USDC-specific MockUSDC with an
///         asset-agnostic mock.  All tests that previously used MockUSDC
///         still work because MockUSDC is now a thin wrapper over this contract.
contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public decimals;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    /// @param _name     Human-readable token name (e.g. "Mock USDC", "Wrapped Ether")
    /// @param _symbol   Token symbol (e.g. "USDC", "WETH", "WBTC")
    /// @param _decimals Decimal count for the token (e.g. 6, 18, 8)
    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
    }

    /// @notice Mint `amount` tokens to `to`. No role required — test use only.
    function mint(address to, uint256 amount) external {
        require(to != address(0), "zero to");
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 al = allowance[from][msg.sender];
        if (al != type(uint256).max) {
            require(al >= amount, "allowance");
            allowance[from][msg.sender] = al - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(to != address(0), "zero to");
        require(balanceOf[from] >= amount, "balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}
