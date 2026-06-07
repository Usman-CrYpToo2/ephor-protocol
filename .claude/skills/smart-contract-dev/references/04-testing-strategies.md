# 04 — Testing Strategies & Quality Assurance

A smart contract without comprehensive tests is an unaudited contract. The testing strategy is
as important as the code itself. This module covers the full testing hierarchy used by elite teams.

---

## Testing Hierarchy (Apply All Layers)

```
                    Formal Verification ← strongest guarantee, highest cost
                   /
          Invariant Tests ← stateful fuzzing, automated property checking
         /
    Fuzz Tests ← randomized input, find edge cases
   /
Integration Tests ← protocol interactions, fork testing
/
Unit Tests ← function-level correctness

All layers are required for production contracts.
Coverage target: 100% line + branch for core logic.
```

---

## 1. Unit Testing (Foundry / Hardhat)

### What Unit Tests Must Cover
```
□ Happy path: expected inputs produce expected outputs
□ Revert cases: every require/revert condition tested individually
□ Boundary values: zero, one, max uint, max address count
□ State transitions: before and after state verified
□ Event emission: correct events with correct parameters
□ Access control: unauthorized callers fail, authorized succeed
□ Return values: correct values returned
```

### Foundry Test Structure
```solidity
contract VaultTest is Test {
    Vault vault;
    MockERC20 token;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        token = new MockERC20();
        vault = new Vault(address(token));
        token.mint(alice, 1000e18);
        token.mint(bob, 1000e18);
    }

    // Test naming: test_functionName_scenario_expectedResult
    function test_deposit_withValidAmount_mintsCorrectShares() public {
        vm.startPrank(alice);
        token.approve(address(vault), 100e18);
        
        uint256 sharesBefore = vault.balanceOf(alice);
        vault.deposit(100e18, alice);
        uint256 sharesAfter = vault.balanceOf(alice);
        
        assertGt(sharesAfter, sharesBefore, "Should receive shares");
        assertEq(vault.totalAssets(), 100e18, "Total assets should match");
        vm.stopPrank();
    }

    function test_deposit_withZeroAmount_reverts() public {
        vm.prank(alice);
        vm.expectRevert(Vault.InvalidAmount.selector);
        vault.deposit(0, alice);
    }
    
    function test_withdraw_byNonOwner_reverts() public {
        // Setup: alice deposits
        vm.startPrank(alice);
        token.approve(address(vault), 100e18);
        vault.deposit(100e18, alice);
        vm.stopPrank();
        
        // Bob tries to withdraw alice's funds
        vm.prank(bob);
        vm.expectRevert();
        vault.withdraw(100e18, bob, alice);
    }
}
```

### Test Organization
```
test/
├── unit/
│   ├── VaultTest.t.sol       — isolated contract tests
│   ├── TokenTest.t.sol
│   └── AccessControlTest.t.sol
├── integration/
│   ├── VaultStrategyTest.t.sol   — cross-contract flows
│   └── ProtocolE2ETest.t.sol     — full user journeys
├── fuzz/
│   ├── VaultFuzz.t.sol
│   └── ArithmeticFuzz.t.sol
├── invariant/
│   ├── VaultInvariant.t.sol
│   └── handlers/
│       └── VaultHandler.sol
└── fork/
    └── MainnetForkTest.t.sol
```

---

## 2. Fuzz Testing (Stateless)

Fuzz testing discovers edge cases that manual test case design misses. The fuzzer tries random
inputs across the input space.

```solidity
// Foundry fuzzes automatically when parameters are present
function testFuzz_deposit_alwaysMintsPositiveShares(
    uint256 amount,
    address receiver
) public {
    amount = bound(amount, 1, type(uint128).max);  // Constrain to realistic range
    vm.assume(receiver != address(0));             // Exclude invalid inputs
    vm.assume(receiver != address(vault));         // Exclude vault itself
    
    token.mint(address(this), amount);
    token.approve(address(vault), amount);
    
    uint256 shares = vault.deposit(amount, receiver);
    assertGt(shares, 0, "Deposit must yield shares");
}

function testFuzz_shareConversion_isConsistent(uint256 shares) public {
    shares = bound(shares, 1, vault.totalSupply());
    uint256 assets = vault.convertToAssets(shares);
    uint256 sharesBack = vault.convertToShares(assets);
    
    // ERC-4626: convertToShares(convertToAssets(shares)) <= shares (rounding)
    assertLe(sharesBack, shares, "Rounding must favor vault");
}
```

### Fuzz Configuration (foundry.toml)
```toml
[fuzz]
runs = 10000          # Higher is better; 1000 for CI, 50000 for pre-audit
max_test_rejects = 65536
seed = 42             # Reproducible for CI

[invariant]
runs = 1000
depth = 100           # Calls per run
fail_on_revert = false  # Distinguish expected reverts from bugs
```

---

## 3. Invariant Testing (Stateful Fuzzing) — Most Powerful

Invariant tests define properties that must hold across ALL possible sequences of contract
interactions. The fuzzer tries random call sequences to violate them.

### Handler Pattern
```solidity
// Handler: wraps contract calls, tracks ghost variables for invariant checks
contract VaultHandler is Test {
    Vault public vault;
    MockERC20 public token;
    
    // Ghost variables: parallel tracking for invariant validation
    uint256 public ghost_totalDeposited;
    uint256 public ghost_totalWithdrawn;
    mapping(address => uint256) public ghost_userDeposits;
    
    address[] public actors;
    address internal currentActor;
    
    modifier useActor(uint256 actorIndexSeed) {
        currentActor = actors[bound(actorIndexSeed, 0, actors.length - 1)];
        vm.startPrank(currentActor);
        _;
        vm.stopPrank();
    }
    
    function deposit(uint256 amount, uint256 actorSeed) external useActor(actorSeed) {
        amount = bound(amount, 1, token.balanceOf(currentActor));
        
        token.approve(address(vault), amount);
        vault.deposit(amount, currentActor);
        
        ghost_totalDeposited += amount;
        ghost_userDeposits[currentActor] += amount;
    }
    
    function withdraw(uint256 shares, uint256 actorSeed) external useActor(actorSeed) {
        shares = bound(shares, 0, vault.balanceOf(currentActor));
        if (shares == 0) return;
        
        uint256 assets = vault.redeem(shares, currentActor, currentActor);
        ghost_totalWithdrawn += assets;
    }
}

// Invariant test contract
contract VaultInvariantTest is Test {
    Vault vault;
    VaultHandler handler;
    
    function setUp() public {
        vault = new Vault(...);
        handler = new VaultHandler(vault);
        
        // Only call handler functions — fuzzer will call these
        targetContract(address(handler));
    }
    
    // INVARIANT: Total assets in vault >= total shares outstanding (as assets)
    function invariant_solvency() public view {
        assertGe(
            vault.totalAssets(),
            vault.convertToAssets(vault.totalSupply()),
            "Vault must be solvent"
        );
    }
    
    // INVARIANT: No single user can extract more than they put in (no loss)
    function invariant_noUserLoss() public view {
        for (uint256 i = 0; i < handler.actorsLength(); i++) {
            address actor = handler.actors(i);
            uint256 currentValue = vault.convertToAssets(vault.balanceOf(actor));
            // Allow for yield: current value should be >= deposited (assuming no loss strategy)
            // This catches incorrect accounting
        }
    }
    
    // INVARIANT: Ghost variable consistency
    function invariant_ghostAccounting() public view {
        assertEq(
            handler.ghost_totalDeposited() - handler.ghost_totalWithdrawn(),
            vault.totalAssets(),
            "Ghost accounting must match"
        );
    }
}
```

### Writing Good Invariants for Testing
The best invariants are:
1. **Directly derived from protocol invariants** (the ones you wrote in the spec)
2. **Falsifiable** — they would actually catch real bugs
3. **Global** — they hold across all states, not just after specific operations
4. **Tracked with ghost variables** — parallel bookkeeping for comparison

---

## 4. Fork Testing

Test against real mainnet state without deploying:

```solidity
contract ForkTest is Test {
    // Fork from mainnet at specific block for reproducibility
    function setUp() public {
        vm.createSelectFork("mainnet", 19_000_000);  // Pin block number
    }
    
    function test_integratesWithAave() public {
        // Real AAVE addresses from mainnet
        address aavePool = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
        address usdc = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
        
        // Impersonate a whale to get real tokens
        address whale = 0x55FE002aefF02F77364de339a1292923A15844B8;
        vm.startPrank(whale);
        
        // Test protocol behavior with real mainnet state
        IERC20(usdc).transfer(address(this), 1_000_000e6);
        vm.stopPrank();
        
        // Now test your protocol with real tokens
        myProtocol.deposit(1_000_000e6);
        assertEq(myProtocol.totalAssets(), 1_000_000e6);
    }
}
```

**Fork test use cases**:
- Integration with existing DeFi protocols (AAVE, Compound, Uniswap)
- Behavior with real token contracts (USDC, USDT with blocklisting)
- Testing upgrade migrations with real protocol state
- Reproducing mainnet bug reports

---

## 5. Formal Verification (Certora / Halmos / SMTChecker)

### Solidity SMTChecker (built-in)
```solidity
// Enable in foundry.toml or via comment pragma
/// @custom:smtchecker abstract-function-nondet
pragma solidity ^0.8.0;

// SMTChecker will prove or find counterexamples for:
// - Overflow/underflow
// - Division by zero
// - Out-of-bounds array access
// - User-defined assertions
```

### Halmos (Symbolic Execution in Foundry)
```bash
# Run symbolic execution on your Foundry tests
halmos --contract VaultTest --function testFuzz_deposit
# Halmos proves or finds a concrete counterexample — stronger than fuzzing
```

### Certora Prover
```
rule noLossOnWithdraw(address user) {
    uint256 sharesBefore = balanceOf(user);
    uint256 assetsBefore = convertToAssets(sharesBefore);
    
    redeem(sharesBefore, user, user);
    
    // Assert: user received at least as many assets as their shares were worth
    assert token.balanceOf(user) >= assetsBefore;
}
```

**When to use formal verification**:
- Core arithmetic functions (share conversions, interest accrual)
- Critical access control invariants
- Protocols handling > $100M TVL
- After audit, for highest-confidence properties

---

## 6. Static Analysis

### Slither (Trail of Bits)
```bash
slither . --config-file slither.config.json

# Key detectors to always review:
# - reentrancy-eth, reentrancy-no-eth
# - controlled-delegatecall
# - suicidal, arbitrary-send-eth
# - unchecked-transfer, unchecked-lowlevel
# - uninitialized-storage
# - shadowing-state
# - incorrect-equality (use == on balance, use <= instead)
```

### Automated vs Manual Review
Static analysis finds ~30-40% of common issues automatically. Use it as:
- A first pass to catch obvious issues before manual review
- A CI gate to prevent regression
- A completeness check after manual review

Never rely on it as a substitute for manual review.

---

## Testing Quality Metrics

| Metric | Target | Notes |
|--------|--------|-------|
| Line coverage | >95% | 100% for critical paths |
| Branch coverage | >90% | Every if/else tested both ways |
| Fuzz runs | 10,000+ | 50,000+ pre-audit |
| Invariant runs | 1,000+ | With depth 100+ |
| Invariant count | 5-15 | Per core contract |
| Fork test | Required | For any external integration |

### CI Pipeline
```yaml
# Every PR should run:
- slither analysis (static)
- unit tests (full suite)
- fuzz tests (100 runs for speed, 10k on schedule)
- invariant tests
- coverage report (fail below threshold)
- gas snapshot diff (alert on regressions)
```
