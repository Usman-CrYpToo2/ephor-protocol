# 07 — Protocol Lifecycle: Deployment, Evolution & Incident Response

Smart contracts live in production for years. The decisions made about upgradeability, governance,
and emergency response determine whether a protocol survives — and whether users can trust it.

---

## Deployment Lifecycle

### Pre-Deployment Checklist
```
Security:
  □ Internal audit complete (all Critical/High findings resolved)
  □ External audit(s) complete (minimum one for protocols > $1M TVL)
  □ Audit report published (builds user trust)
  □ All audit findings addressed or formally accepted with documented rationale
  □ Bug bounty program live BEFORE launch

Testing:
  □ 100% coverage on critical paths
  □ Invariant tests pass after 10,000+ runs
  □ Fork tests pass on all target chains
  □ Deployment scripts tested on testnets (not just local)
  □ Contract addresses verified on block explorers

Configuration:
  □ All admin roles assigned to multi-sigs (not EOAs)
  □ Timelock deployed and configured
  □ All constructor/initializer parameters reviewed
  □ Initial liquidity/seed conditions verified safe
  □ Emergency pause capability confirmed working

Documentation:
  □ Technical documentation up-to-date
  □ User-facing documentation complete
  □ Contract addresses published
  □ ABI published (verified on Etherscan)
```

### Deployment Script Standards
```solidity
// Use Foundry scripts for reproducible, auditable deployments
contract Deploy is Script {
    function run() external returns (Vault vault) {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address admin = vm.envAddress("ADMIN_MULTISIG");
        address asset = vm.envAddress("ASSET_TOKEN");
        
        vm.startBroadcast(deployerKey);
        
        // Deploy logic contract
        Vault implementation = new Vault();
        
        // Deploy proxy
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation),
            abi.encodeCall(Vault.initialize, (asset, admin))
        );
        
        vault = Vault(address(proxy));
        
        // Transfer all roles to multi-sig — NOT to deployer
        vault.grantRole(vault.DEFAULT_ADMIN_ROLE(), admin);
        vault.renounceRole(vault.DEFAULT_ADMIN_ROLE(), msg.sender);
        
        vm.stopBroadcast();
        
        // Verify: deployer has NO remaining permissions
        assert(!vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), msg.sender));
        assert(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), admin));
    }
}
```

---

## Upgradeability & Governance

### The Timelock as Safety Foundation
```
Minimum timelock delays (by severity):
  Parameter changes (fees, limits):    24 hours
  Strategy changes (yield routing):    48 hours
  Contract upgrades:                   72 hours
  Core protocol changes:               7 days
  Emergency actions (via guardian):    0-24 hours (with constraints)

Timelock contract should:
  - Be the DEFAULT_ADMIN_ROLE holder (not any EOA or multi-sig directly)
  - Have proposers and executors clearly separated
  - Allow cancellation by the guardian in emergencies
```

### Upgrade Safety Checklist
Before any upgrade:
```
□ New implementation audited (treat every upgrade as a new audit)
□ Storage layout verified (no collisions with existing slots)
□ Initialization call (if any) specified in upgrade transaction
□ Test upgrade on mainnet fork: fork → upgrade → run full test suite
□ Rollback plan documented (can we redeploy old implementation?)
□ User communication: announce upgrade with timelock + notice period
□ Multi-sig approvals: require M-of-N signers
```

### The Immutability Premium
For the most critical components (custody, settlement, core accounting):
```
Consider: Deploy as immutable contracts
  - Users can verify exactly what code they're trusting
  - No upgrade risk, no governance attack on core
  - "Escape hatch" migrations (users can exit, not admin)
  
Tradeoff:
  - Cannot fix bugs
  - Cannot add features
  
Resolution: Immutable core + upgradeable periphery
  - Token custody: immutable
  - Yield strategy: upgradeable (timelocked)
  - Fee configuration: upgradeable (timelocked)
```

---

## Governance Design

### Governance Attack Resistance
```
Minimum viable governance security:
  1. Voting snapshot at proposal creation (not at vote time)
     → Prevents flash-loan voting power attacks
  
  2. Voting delay: 1-2 days between proposal and voting
     → Prevents same-block creation + voting
  
  3. Voting period: 3-7 days
     → Sufficient time for community participation
  
  4. Quorum: meaningful % of total supply
     → Prevents whale solo governance on low-activity days
  
  5. Timelock: 2-7 days between pass and execution
     → Users can exit if they disagree with passed proposal
  
  6. Guardian / Security Council with limited veto powers
     → Rapid response to malicious proposals (with sunset clause)
```

### Governance Parameter Constraints
Hard-code maximum bounds for all governance-settable parameters:
```solidity
uint256 public constant MAX_FEE = 1000;          // Governance can set fee, but never above 10%
uint256 public constant MIN_COLLATERAL_RATIO = 110; // Never less than 110%
uint256 public constant MAX_TIMELOCK_DELAY = 30 days; // Can extend but not shrink below current

function setFee(uint256 newFee) external onlyGovernance {
    require(newFee <= MAX_FEE, "Exceeds maximum");
    // Hard cap enforced on-chain — no governance vote can bypass it
}
```

---

## Emergency Response

### Circuit Breaker Design
```
Every production protocol needs:
  1. Emergency pause (immediate, by PAUSER_ROLE)
     - Stops all deposits and withdrawals
     - Should NOT require governance (too slow)
     - Should NOT require timelock in emergencies
  
  2. Emergency withdrawal (if paused, users should be able to exit)
     - Separate from normal flow; uses raw balances
     - Activated only after pause + governance decision
  
  3. Rate limiting / circuit breakers
     - Max withdrawal per block/hour (limits damage from exploit in progress)
     - Price change circuit breaker (reject oracle updates with >X% deviation)
```

### Implementation Example
```solidity
// Multi-tier pause system
bool public paused;
bool public emergencyShutdown;  // More severe than paused

modifier whenOperational() {
    require(!paused, "Protocol paused");
    require(!emergencyShutdown, "Emergency shutdown");
    _;
}

modifier onlyPauserOrAdmin() {
    require(
        hasRole(PAUSER_ROLE, msg.sender) || hasRole(DEFAULT_ADMIN_ROLE, msg.sender),
        "Unauthorized"
    );
    _;
}

// Pause: rapid response, no timelock needed
function pause() external onlyPauserOrAdmin {
    paused = true;
    emit Paused(msg.sender);
}

// Unpause: goes through normal governance/timelock
function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
    paused = false;
    emit Unpaused(msg.sender);
}

// Emergency withdrawal: available even during shutdown
function emergencyWithdraw() external nonReentrant {
    require(emergencyShutdown, "Not in emergency shutdown");
    uint256 shares = balanceOf(msg.sender);
    uint256 assets = _rawAssetValue(shares);  // Use raw values, bypass yield calc
    _burn(msg.sender, shares);
    IERC20(asset).safeTransfer(msg.sender, assets);
    emit EmergencyWithdrawal(msg.sender, assets);
}
```

---

## Incident Response Protocol

### When an Exploit is Detected

```
IMMEDIATE (0-15 minutes):
  1. Activate pause (if available)
  2. Alert multi-sig holders
  3. Inform community via official channels (Twitter, Discord)
  4. DO NOT attempt to interact with exploit txs (front-running risks)

SHORT-TERM (15 minutes - 2 hours):
  5. Reproduce exploit in fork environment
  6. Assess: Is the attack ongoing? What is remaining exposure?
  7. Evaluate: White-hat recovery possible?
  8. Communicate: "We are aware of an incident. Funds are [safe/at risk]. We are investigating."

MEDIUM-TERM (2-24 hours):
  9. Root cause analysis complete
  10. Patch developed and reviewed
  11. Decision: patch + redeploy vs migrate vs compensate
  12. User communication with full transparency
  13. Coordinate with affected protocols (if composability risk)

LONG-TERM:
  14. Full post-mortem published (within 1 week)
  15. Compensation plan (if user funds lost)
  16. Upgraded system with fix deployed
  17. Additional audits commissioned
```

### Post-Mortem Structure
Every incident deserves a thorough public post-mortem:
```
1. Executive Summary: What happened, what was the impact?
2. Timeline: Minute-by-minute sequence of events
3. Root Cause Analysis: The technical explanation, simplified for users
4. What Went Right: Incident response successes
5. What Went Wrong: Honest assessment
6. Remediation: What has been fixed and how
7. Future Prevention: Process and code changes to prevent recurrence
```

Publishing a thorough post-mortem is an act of technical leadership and community trust-building.
Teams that hide incidents permanently damage trust. Teams that publish honest post-mortems build it.

---

## Protocol Sunset / Migration

When a protocol must be deprecated:
```
1. Announce deprecation with adequate notice (minimum 60 days)
2. Disable new deposits immediately
3. Incentivize migration (bonus rewards, discounted migration)
4. Keep withdrawal functionality forever — users must always be able to exit
5. If migrating to V2: provide migration contract that users can trigger
6. Never forcibly move user funds — always user-initiated

Migration contract pattern:
  migrateV1ToV2(uint256 v1Shares) → burns V1 shares, deposits equivalent in V2
```

---

## Long-Term Protocol Health

Regular protocol maintenance cadence:
```
Weekly:
  □ Monitor oracle health (staleness, deviation)
  □ Review on-chain metrics (utilization, liquidity depth)
  □ Check for abnormal transaction patterns

Monthly:
  □ Review parameter health (are configured values still appropriate?)
  □ Assess new attack patterns in DeFi ecosystem
  □ Update threat model with new vulnerability classes discovered elsewhere

Quarterly:
  □ Partial audit of any modified code
  □ Re-evaluate insurance coverage
  □ Review admin key security hygiene

Annually:
  □ Full protocol audit
  □ Re-evaluate architecture for protocol ossification readiness
  □ Review governance health and participation
```
