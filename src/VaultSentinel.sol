// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import "./Interface/ISomnia.sol";
import {IUtilizationOracle} from "./Interface/IUtilizationOracle.sol";
import {IVault} from "./Interface/IVault.sol";
import {IMarket} from "./Interface/IMarket.sol";

/**
 * @title  VaultSentinel
 * @notice Autonomous AI risk monitor. Holds SENTINEL_ROLE on CuratedVault.
 *
 *  FLOW (v2 — D-5 and D-6 fixed)
 *  ──────────────────────────────
 *  1. checkVault(vault)  — reads on-chain metrics via oracle + vault views
 *  2. Builds canonical feature-block prompt (lossless bps integers, SDD §9.3)
 *  3. createRequest() → Somnia LLM agent (regime classifier: STABLE/WATCH/DETERIORATING)
 *  4. Validators run LLM deterministically (fixed seed, temp=0) → consensus
 *  5. Platform calls handleResponse() callback
 *
 *  D-6 FIX — Consensus threshold verification:
 *    require(details.responseCount >= details.threshold) before processing response.
 *    If not met, treat as Failed.
 *
 *  D-5 FIX — Precedence rule (on-chain authority; AI is escalation modifier only):
 *    1. assessOnChain(vault) → HardLevel (deterministic, from oracle + on-chain data)
 *    2. Decode AI regime label (STABLE/WATCH/DETERIORATING + backward-compat mapping)
 *    3. AiAdjustedLevel:
 *         Critical  if AI == DETERIORATING and HardLevel >= Caution
 *         Caution   if AI == WATCH        and HardLevel == Safe
 *         HardLevel otherwise
 *    4. EffectiveLevel = max(HardLevel, AiAdjustedLevel)
 *       AI can NEVER lower the effective level.
 *
 *  ACTION MAPPING (EffectiveLevel):
 *    Safe     → store snapshot, no action
 *    Caution  → store snapshot + emit RiskAlert
 *    Critical → pauseDeposits() + emergencyDeallocate() on highest-effectiveUtil market
 *
 *  AI FAILURE / TIMEOUT / UNKNOWN:
 *    → EffectiveLevel = HardLevel (AI_UNAVAILABLE recorded). Fail-safe.
 *
 *  SECURITY
 *  ────────
 *  • onlyPlatform on handleResponse — nobody else can fake a verdict
 *  • pendingRequests mapping — prevents replay / orphan callbacks
 *  • 5-min cooldown per vault — prevents DoS
 *  • One in-flight check per vault
 *  • assessOnChain uses oracle.twap (not spot) when oracle set and valid
 *  • Deallocation uses oracle.effectiveUtil for true worst-market identification
 *
 *  IMPORTANT INVARIANTS
 *  ────────────────────
 *  • pendingRequests MUST remain public — MockSomniaPlatform looks it up by requestId
 *  • handleResponse name MUST NOT change — selector passed to createRequest literally
 */

// ════════════════════════════════════════════════════════════════════════════

contract VaultSentinel is Ownable {
    // ── Somnia platform ──────────────────────────────────────────────────────
    // Testnet:  0x037Bb9C718F3f7fe5eCBDB0b600D607b52706776
    // Mainnet:  0x5E5205CF39E766118C01636bED000A54D93163E6
    IAgentRequester public immutable platform;

    /// @notice LLM Inference Agent ID (from agents.somnia.network).
    uint256 public llmAgentId;

    /// @notice Default subcommittee size (matches platform default).
    uint256 public constant SUBCOMMITTEE_SIZE = 3;

    /// @notice Per-agent cost for LLM inference (from Somnia docs: 0.07 STT).
    uint256 public constant LLM_COST_PER_AGENT = 0.07 ether;

    // ── Admin ────────────────────────────────────────────────────────────────
    // Admin is managed by OZ Ownable: use owner() / transferOwnership().

    // ── Utilization oracle ────────────────────────────────────────────────────
    /// @notice TWAP oracle for manipulation-resistant utilization readings (D-8).
    ///         When address(0), sentinel falls back to reading spot utilizationBps()
    ///         directly from each market. When set, ALL utilization reads use the oracle.
    IUtilizationOracle public oracle;

    // ── On-chain hard threshold constants (D-5) ───────────────────────────────
    /// @notice TWAP window to use when querying oracle.twap() in assessOnChain.
    uint256 public constant TWAP_WINDOW = 30 minutes;

    /// @notice Utilization threshold for Caution classification (80%).
    uint256 public constant CAUTION_UTIL_BPS = 8_000;

    /// @notice Utilization threshold for Critical classification (95%).
    uint256 public constant CRITICAL_UTIL_BPS = 9_500;

    /// @notice Allocation threshold for Caution classification (25%).
    uint256 public constant CAUTION_ALLOC_BPS = 2_500;

    /// @notice Allocation threshold for Critical classification (40%).
    uint256 public constant CRITICAL_ALLOC_BPS = 4_000;

    /// @notice Caution utilization returned by oracle when history insufficient (80%).
    uint256 public constant ORACLE_CAUTION_UTIL_BPS = 8_000;

    /// @notice Minimum utilization threshold for emergency deallocation (90%).
    uint256 public constant EMERGENCY_UTIL_THRESHOLD = 9_000;

    // ── Risk levels ──────────────────────────────────────────────────────────
    enum RiskLevel {
        Safe,
        Caution,
        Critical
    }

    // ── AI regime labels ─────────────────────────────────────────────────────
    /// @dev Internal enum for parsed AI regime label.
    enum RegimeLabel {
        Stable,      // AI says risk is stable / acceptable
        Watch,       // AI says risk is elevated but manageable
        Deteriorating, // AI says risk is worsening
        Unknown      // unrecognized output (fail-safe: no escalation)
    }

    // ── Per-vault registry ───────────────────────────────────────────────────
    struct VaultInfo {
        bool registered;
        bool autoPauseEnabled;
        RiskLevel lastLevel;
        uint256 lastCheckedAt;
        uint256 totalChecks;
        uint256 criticalCount;
    }
    mapping(address => VaultInfo) public vaultInfo;
    address[] private _vaultList;

    // ── Immutable audit trail ────────────────────────────────────────────────
    struct RiskSnapshot {
        uint256 timestamp;
        RiskLevel level;
        string rawVerdict;
        uint256 totalAssets;
        /// @dev Idle buffer in bps (1% = 100 bps). Renamed from idlePct (D-3 fix).
        uint256 idleBps;
    }
    mapping(address => RiskSnapshot[]) private _history;

    // ── In-flight request tracking ───────────────────────────────────────────
    // IMPORTANT: pendingRequests MUST remain public — MockSomniaPlatform looks
    // up the vault address by requestId during tests. Do NOT rename to _pending.
    mapping(uint256 => address) public pendingRequests; // requestId → vault
    mapping(address => uint256) public activeRequest; // vault → requestId (0=none)

    uint256 public constant CHECK_COOLDOWN = 5 minutes;

    // ── Events ───────────────────────────────────────────────────────────────
    event VaultRegistered(address indexed vault, bool autoPause);
    event CheckRequested(address indexed vault, uint256 indexed requestId, address indexed by);
    event VerdictReceived(address indexed vault, RiskLevel level, string verdict);
    event RiskAlert(address indexed vault, RiskLevel level, string reason);
    event VaultPausedByAI(address indexed vault, string reason);
    event EmergencyDeallocated(address indexed vault, address indexed market, uint256 amount);
    event AgentIdSet(uint256 newId);
    /// @notice Emitted when the utilization oracle address is changed.
    event OracleSet(address indexed newOracle);
    /// @notice Emitted when AI response was ignored because consensus threshold was not met (D-6).
    event ConsensusThresholdNotMet(address indexed vault, uint256 requestId, uint256 responseCount, uint256 threshold);
    /// @notice Emitted when AI is unavailable; on-chain HardLevel used instead (D-5).
    event AiUnavailable(address indexed vault, RiskLevel hardLevel, string reason);
    /// @notice Emitted when AI escalates the HardLevel (D-5 precedence rule applied).
    event AiEscalated(address indexed vault, RiskLevel hardLevel, RiskLevel effectiveLevel, string aiLabel);

    // ── Modifiers ────────────────────────────────────────────────────────────
    modifier onlyPlatform() {
        require(msg.sender == address(platform), "Sentinel: not platform");
        _;
    }

    constructor(address _platform, uint256 _llmAgentId, address _admin) Ownable(_admin) {
        require(_platform != address(0), "zero platform");
        platform = IAgentRequester(_platform);
        llmAgentId = _llmAgentId;
    }

    // ════════════════════════════════════════════════════════════════════════
    //  STEP 1 — TRIGGER A VAULT CHECK
    // ════════════════════════════════════════════════════════════════════════

    /**
     * @notice Trigger an AI risk check for a registered vault.
     *
     *         Reads on-chain metrics → builds canonical feature-block prompt →
     *         sends to Somnia LLM platform.  Result arrives async in handleResponse().
     *
     * @dev    If oracle is set, calls oracle.update(market) for each market before
     *         reading metrics (ensures TWAP is fresh).
     *         msg.value must cover:
     *           platform.getRequestDeposit()
     *           + LLM_COST_PER_AGENT × SUBCOMMITTEE_SIZE
     *
     * @param  vault  The registered vault to check.
     */
    function checkVault(address vault) external payable {
        VaultInfo storage info = vaultInfo[vault];
        require(info.registered, "not registered");
        require(block.timestamp >= info.lastCheckedAt + CHECK_COOLDOWN, "cooldown");
        require(activeRequest[vault] == 0, "check in progress");
        require(msg.value >= LLM_COST_PER_AGENT * SUBCOMMITTEE_SIZE, "insufficient deposit");

        // ── If oracle is set, refresh it for each market before reading metrics ──
        IUtilizationOracle _oracle = oracle;
        if (address(_oracle) != address(0)) {
            uint256 cnt = IVault(vault).marketCount();
            for (uint256 i; i < cnt; ) {
                address m = IVault(vault).marketList(i);
                try _oracle.update(m) {} catch {}
                unchecked { ++i; }
            }
        }

        // ── Read all metrics from vault's own contracts (zero external API) ──
        (
            uint256 totalA,
            uint256 idleBps,
            uint256 mCount,
            address[] memory mAddrs,
            uint256[] memory mAllocBps,
            uint256[] memory mUtilBps,
            uint256[] memory mTwapBps,
            bool[] memory mSpike
        ) = _readMetrics(vault);

        // ── Build canonical feature-block prompt (§9.3) ───────────────────
        string memory userPrompt = _buildUserPrompt(
            totalA, idleBps, mCount, mAddrs, mAllocBps, mUtilBps, mTwapBps, mSpike
        );

        // ── Encode LLM agent call ──────────────────────────────────────────
        // AI is a regime classifier (SDD §7.3): STABLE / WATCH / DETERIORATING
        // Backward-compatible labels SAFE / CAUTION / CRITICAL also accepted.
        string[] memory allowed = new string[](3);
        allowed[0] = "STABLE";
        allowed[1] = "WATCH";
        allowed[2] = "DETERIORATING";
        bytes memory payload = abi.encodeWithSelector(
            ILLMInferenceAgent.inferString.selector,
            userPrompt,       // prompt   — vault metrics feature block
            _systemPrompt(),  // system   — regime classifier instructions
            false,            // chainOfThought — off; constrained output only
            allowed           // allowedValues — constrains model output
        );

        // ── Send to Somnia platform ────────────────────────────────────────
        uint256 reqId = platform.createRequest{value: msg.value}(
            llmAgentId,
            address(this),
            this.handleResponse.selector, // ← exact name; must not be renamed
            payload
        );

        pendingRequests[reqId] = vault;
        activeRequest[vault] = reqId;
        info.lastCheckedAt = block.timestamp;
        info.totalChecks++;

        emit CheckRequested(vault, reqId, msg.sender);
    }

    // ════════════════════════════════════════════════════════════════════════
    //  STEP 2 — ON-CHAIN HARD GUARDS (D-5 — assessOnChain)
    // ════════════════════════════════════════════════════════════════════════

    /**
     * @notice Compute the deterministic HardLevel for `vault` using only on-chain data.
     *
     *  For each enabled market:
     *    • Reads oracle.twap(market, TWAP_WINDOW) if oracle set and isValid.
     *    • Falls back to oracle.cautionUtilBps (8000) if oracle set but not yet valid.
     *    • Falls back to spot utilizationBps() if no oracle.
     *  Computes maxEffectiveUtilBps, maxAllocBps, idleBps.
     *  Returns:
     *    Critical  if maxEffectiveUtilBps > CRITICAL_UTIL_BPS AND maxAllocBps > CRITICAL_ALLOC_BPS
     *    Caution   if maxEffectiveUtilBps > CAUTION_UTIL_BPS  OR  maxAllocBps > CAUTION_ALLOC_BPS
     *    Safe      otherwise
     *
     * @param  vault  The vault to assess.
     * @return hardLevel  The deterministic hard risk classification.
     */
    function assessOnChain(address vault) public view returns (RiskLevel hardLevel) {
        IVault v = IVault(vault);
        uint256 cnt = v.marketCount();

        uint256 maxEffectiveUtilBps = 0;
        uint256 maxAllocBps = 0;

        IUtilizationOracle _oracle = oracle;

        for (uint256 i; i < cnt; ) {
            address m = v.marketList(i);

            // Allocation bps — vault-internal, not flash-loan manipulable
            uint256 allocBps = v.marketAllocationBps(m);
            if (allocBps > maxAllocBps) {
                maxAllocBps = allocBps;
            }

            // Utilization — manipulation-resistant via oracle when available
            uint256 utilBps;
            if (address(_oracle) != address(0)) {
                bool valid = _oracle.isValid(m);
                if (valid) {
                    utilBps = _oracle.twap(m, TWAP_WINDOW);
                } else {
                    // Oracle not yet valid for this market — conservative
                    utilBps = ORACLE_CAUTION_UTIL_BPS;
                }
            } else {
                // No oracle — fall back to spot (legacy behaviour)
                utilBps = IMarket(m).utilizationBps();
            }

            if (utilBps > maxEffectiveUtilBps) {
                maxEffectiveUtilBps = utilBps;
            }

            unchecked { ++i; }
        }

        // Deterministic classification (SDD §7.2)
        if (maxEffectiveUtilBps > CRITICAL_UTIL_BPS && maxAllocBps > CRITICAL_ALLOC_BPS) {
            return RiskLevel.Critical;
        }
        if (maxEffectiveUtilBps > CAUTION_UTIL_BPS || maxAllocBps > CAUTION_ALLOC_BPS) {
            return RiskLevel.Caution;
        }
        return RiskLevel.Safe;
    }

    // ════════════════════════════════════════════════════════════════════════
    //  STEP 3 — SOMNIA PLATFORM DELIVERS THE VERDICT
    //
    //  Function name is handleResponse — EXACT name from real Somnia docs.
    //  Selector: this.handleResponse.selector passed to createRequest().
    //  Only the platform contract may call this.
    // ════════════════════════════════════════════════════════════════════════

    /**
     * @notice Callback invoked by the Somnia platform with the AI verdict.
     *
     *  D-6 fix: verify responseCount >= threshold before trusting the response.
     *  D-5 fix: compute HardLevel on-chain; AI is an escalation modifier only.
     *           EffectiveLevel = max(HardLevel, AiAdjustedLevel).
     *
     * @param  requestId  Matches the ID returned by checkVault → createRequest.
     * @param  responses  Array of validator responses (use responses[0].result).
     * @param  status     ResponseStatus enum (Success=2, Failed=3, TimedOut=4).
     * @param  details    Full Request struct — used for responseCount/threshold (D-6).
     */
    function handleResponse(
        uint256 requestId,
        Response[] memory responses,
        ResponseStatus status,
        Request memory details
    )
        external
        onlyPlatform
    {
        address vault = pendingRequests[requestId];
        require(vault != address(0), "unknown request");

        // CEI: clear pending state BEFORE any external calls
        delete pendingRequests[requestId];
        delete activeRequest[vault];

        VaultInfo storage info = vaultInfo[vault];

        // ── Compute on-chain HardLevel (always; D-5) ───────────────────────
        RiskLevel hardLevel = assessOnChain(vault);

        // ── AI failure path — EffectiveLevel = max(Caution, HardLevel) ──────
        // Fail-safe: AI absence never produces Silent Safe — always at least Caution.
        // This preserves P-5 and the original "timeout → at least CAUTION" guarantee.
        // D-5: HardLevel is the floor; if HardLevel > Caution, that fires instead.
        if (
            status == ResponseStatus.TimedOut ||
            status == ResponseStatus.Failed ||
            responses.length == 0
        ) {
            RiskLevel failLevel = hardLevel > RiskLevel.Caution ? hardLevel : RiskLevel.Caution;
            _applyEffectiveLevel(vault, failLevel, "AI_UNAVAILABLE");
            info.lastLevel = failLevel;
            emit AiUnavailable(vault, failLevel, "AI_UNAVAILABLE");
            return;
        }

        // ── D-6: Verify consensus threshold before trusting response ───────
        if (details.responseCount < details.threshold) {
            emit ConsensusThresholdNotMet(vault, requestId, details.responseCount, details.threshold);
            // Treat as Failed: EffectiveLevel = max(Caution, HardLevel)
            RiskLevel consensusFailLevel = hardLevel > RiskLevel.Caution ? hardLevel : RiskLevel.Caution;
            _applyEffectiveLevel(vault, consensusFailLevel, "CONSENSUS_NOT_MET");
            info.lastLevel = consensusFailLevel;
            emit AiUnavailable(vault, consensusFailLevel, "CONSENSUS_NOT_MET");
            return;
        }

        // ── Decode AI regime label ─────────────────────────────────────────
        string memory raw = abi.decode(responses[0].result, (string));
        RegimeLabel aiLabel = _parseRegimeLabel(raw);

        // ── Unknown AI output → treat as failure (fail-safe Caution floor) ─
        // Preserves original "unknown → CAUTION" behavior from v1.
        if (aiLabel == RegimeLabel.Unknown) {
            RiskLevel unknownFailLevel = hardLevel > RiskLevel.Caution ? hardLevel : RiskLevel.Caution;
            _applyEffectiveLevel(vault, unknownFailLevel, raw);
            info.lastLevel = unknownFailLevel;
            emit AiUnavailable(vault, unknownFailLevel, raw);
            return;
        }

        // ── D-5: Apply precedence rule — AI can only escalate ─────────────
        //  AiAdjustedLevel:
        //    Critical  if AI == DETERIORATING and HardLevel >= Caution
        //    Caution   if AI == WATCH         and HardLevel == Safe
        //    HardLevel otherwise
        RiskLevel aiAdjustedLevel = hardLevel;
        if (aiLabel == RegimeLabel.Deteriorating && hardLevel >= RiskLevel.Caution) {
            aiAdjustedLevel = RiskLevel.Critical;
        } else if (aiLabel == RegimeLabel.Watch && hardLevel == RiskLevel.Safe) {
            aiAdjustedLevel = RiskLevel.Caution;
        }

        // EffectiveLevel = max(HardLevel, AiAdjustedLevel)
        RiskLevel effectiveLevel = hardLevel > aiAdjustedLevel ? hardLevel : aiAdjustedLevel;

        if (effectiveLevel != hardLevel) {
            emit AiEscalated(vault, hardLevel, effectiveLevel, raw);
        }

        _applyEffectiveLevel(vault, effectiveLevel, raw);
        info.lastLevel = effectiveLevel;

        emit VerdictReceived(vault, effectiveLevel, raw);
    }

    // ════════════════════════════════════════════════════════════════════════
    //  INTERNAL — APPLY EFFECTIVE LEVEL
    // ════════════════════════════════════════════════════════════════════════

    /// @dev Apply the EffectiveLevel: store snapshot + emit events + trigger actions.
    function _applyEffectiveLevel(address vault, RiskLevel level, string memory reason) internal {
        _store(vault, level, reason);
        emit RiskAlert(vault, level, reason);

        if (level == RiskLevel.Critical) {
            vaultInfo[vault].criticalCount++;
            _respondToCritical(vault, reason);
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    //  INTERNAL — CRITICAL RESPONSE
    // ════════════════════════════════════════════════════════════════════════

    function _respondToCritical(address vault, string memory reason) internal {
        if (vaultInfo[vault].autoPauseEnabled) {
            try IVault(vault).pauseDeposits() {
                emit VaultPausedByAI(vault, reason);
            } catch { /* already paused */ }
        }
        _deallocateWorstMarket(vault);
    }

    /**
     * @dev Find the market with the highest effective utilization and withdraw 50%.
     *      Only acts when effectiveUtil > EMERGENCY_UTIL_THRESHOLD (9000 bps).
     *
     *      D-1 fix: `worst` is only updated inside the `if (u > worstUtil)` block.
     *      D-8 fix: when oracle is set, uses oracle.effectiveUtil() (manipulation-resistant).
     *               When oracle is not set, falls back to spot utilizationBps().
     */
    function _deallocateWorstMarket(address vault) internal {
        IVault v = IVault(vault);
        uint256 cnt = v.marketCount();
        if (cnt == 0) return;

        address worst = address(0);
        uint256 worstUtil = 0;

        IUtilizationOracle _oracle = oracle;
        for (uint256 i; i < cnt; ) {
            address m = v.marketList(i);
            uint256 u;
            if (address(_oracle) != address(0)) {
                // effectiveUtil is non-view (calls update internally) — use try/catch
                try _oracle.effectiveUtil(m) returns (uint256 util, bool) {
                    u = util;
                } catch {
                    u = IMarket(m).utilizationBps();
                }
            } else {
                u = IMarket(m).utilizationBps();
            }
            // D-1 fix: only update worst INSIDE the guard
            if (u > worstUtil) {
                worstUtil = u;
                worst = m;
            }
            unchecked { ++i; }
        }

        // Only pull if util > EMERGENCY_UTIL_THRESHOLD (9000 bps = 90%)
        if (worst == address(0) || worstUtil < EMERGENCY_UTIL_THRESHOLD) return;

        uint256 bal = IMarket(worst).balanceOf(vault);
        if (bal == 0) return;

        // Withdraw 50% — avoids spiking rates for other depositors
        uint256 amt = bal / 2;
        try IVault(vault).emergencyDeallocate(worst, amt) {
            emit EmergencyDeallocated(vault, worst, amt);
        } catch { /* market may lack liquidity */ }
    }

    // ════════════════════════════════════════════════════════════════════════
    //  INTERNAL — READ METRICS (pure on-chain)
    // ════════════════════════════════════════════════════════════════════════

    /**
     * @dev Reads all vault metrics in bps. Returns spot, TWAP, and spike flag per market.
     *      When oracle is set, uses oracle TWAP for utilization. Otherwise uses spot.
     */
    function _readMetrics(address vault)
        internal
        view
        returns (
            uint256 totalA,
            uint256 idleBps,
            uint256 mCount,
            address[] memory mAddrs,
            uint256[] memory mAllocBps,
            uint256[] memory mUtilBps,
            uint256[] memory mTwapBps,
            bool[] memory mSpike
        )
    {
        IVault v = IVault(vault);
        totalA = v.totalAssets();
        idleBps = v.idleBufferBps();
        mCount = v.marketCount();
        mAddrs = new address[](mCount);
        mAllocBps = new uint256[](mCount);
        mUtilBps = new uint256[](mCount);
        mTwapBps = new uint256[](mCount);
        mSpike = new bool[](mCount);

        IUtilizationOracle _oracle = oracle;
        for (uint256 i; i < mCount; ) {
            address m = v.marketList(i);
            mAddrs[i] = m;
            mAllocBps[i] = v.marketAllocationBps(m);

            if (address(_oracle) != address(0)) {
                // Read TWAP (view) — do not call effectiveUtil here (non-view)
                uint256 twapVal = _oracle.twap(m, TWAP_WINDOW);
                uint256 spotVal = IMarket(m).utilizationBps();
                uint256 delta = spotVal > twapVal ? spotVal - twapVal : 0;
                bool spikeFlag = delta > 1_000; // 10% = 1000 bps (default spikeToleranceBps)
                mUtilBps[i] = spikeFlag ? twapVal : spotVal;
                mTwapBps[i] = twapVal;
                mSpike[i] = spikeFlag;
            } else {
                uint256 spotVal = IMarket(m).utilizationBps();
                mUtilBps[i] = spotVal;
                mTwapBps[i] = spotVal;
                mSpike[i] = false;
            }
            unchecked { ++i; }
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    //  INTERNAL — PROMPT CONSTRUCTION (§9.3 canonical feature block)
    // ════════════════════════════════════════════════════════════════════════

    /// @dev System prompt for the regime classifier (SDD §9.4).
    ///      allowedValues constrain the model to STABLE/WATCH/DETERIORATING.
    function _systemPrompt() internal pure returns (string memory) {
        return "You are a portfolio-risk regime classifier for a yield vault holding a single configured asset. "
            "Inputs are canonical integer features: ratios in basis points (dimensionless, asset-agnostic), "
            "amounts in the vault asset native units with decimal count given in the PORTFOLIO header. "
            "The smart contract enforces all hard numeric limits. "
            "Your job: judge the overall trajectory and concentration of risk no single limit captures. "
            "A spike=1 means a flash-loan manipulation was detected -- treat this as an additional risk signal. "
            "Output exactly one of: STABLE, WATCH, DETERIORATING. No other text.";
    }

    /**
     * @dev Build the canonical feature-block user prompt (SDD §9.3).
     *      All values are integers (bps or raw amounts). No truncation.
     *      Lossless canonical inputs (P-4, L-2, D-2 fix: no _u formatter).
     */
    function _buildUserPrompt(
        uint256 totalA,
        uint256 idleBps,
        uint256 mCount,
        address[] memory,
        uint256[] memory mAllocBps,
        uint256[] memory mUtilBps,
        uint256[] memory mTwapBps,
        bool[] memory mSpike
    ) internal pure returns (string memory s) {
        s = string(
            abi.encodePacked(
                "PORTFOLIO|ta=", _u(totalA), "|idle=", _u(idleBps), "|mkts=", _u(mCount), " "
            )
        );
        for (uint256 i; i < mCount; ) {
            s = string(
                abi.encodePacked(
                    s,
                    "M", _u(i + 1),
                    "|util=", _u(mUtilBps[i]),
                    "|twap=", _u(mTwapBps[i]),
                    "|spike=", mSpike[i] ? "1" : "0",
                    "|alloc=", _u(mAllocBps[i]),
                    " "
                )
            );
            unchecked { ++i; }
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    //  INTERNAL — PARSING
    // ════════════════════════════════════════════════════════════════════════

    /**
     * @dev Parse AI output into a RegimeLabel.
     *      Accepts new labels: STABLE, WATCH, DETERIORATING.
     *      Backward-compatible mapping: CRITICAL→DETERIORATING, CAUTION→WATCH, SAFE→STABLE.
     *      Unrecognized → Unknown (no escalation).
     */
    function _parseRegimeLabel(string memory raw) internal pure returns (RegimeLabel) {
        bytes32 h = keccak256(bytes(raw));

        // New labels (SDD §7.3)
        if (h == keccak256(bytes("DETERIORATING"))) return RegimeLabel.Deteriorating;
        if (h == keccak256(bytes("WATCH"))) return RegimeLabel.Watch;
        if (h == keccak256(bytes("STABLE"))) return RegimeLabel.Stable;

        // Backward-compatible mapping (old allowedValues)
        if (h == keccak256(bytes("CRITICAL"))) return RegimeLabel.Deteriorating;
        if (h == keccak256(bytes("CAUTION"))) return RegimeLabel.Watch;
        if (h == keccak256(bytes("SAFE"))) return RegimeLabel.Stable;

        // Unknown output — no escalation (fail-safe)
        return RegimeLabel.Unknown;
    }

    /// @dev Legacy parse function kept for backward-compat views (getLatestRisk stores raw string).
    function _parse(string memory raw) internal pure returns (RiskLevel) {
        bytes32 h = keccak256(bytes(raw));
        if (h == keccak256(bytes("CRITICAL")) || h == keccak256(bytes("DETERIORATING"))) {
            return RiskLevel.Critical;
        }
        if (h == keccak256(bytes("CAUTION")) || h == keccak256(bytes("WATCH"))) {
            return RiskLevel.Caution;
        }
        if (h == keccak256(bytes("SAFE")) || h == keccak256(bytes("STABLE"))) {
            return RiskLevel.Safe;
        }
        return RiskLevel.Caution; // unknown → fail-safe caution
    }

    function _store(address vault, RiskLevel level, string memory verdict) internal {
        _history[vault].push(
            RiskSnapshot({
                timestamp: block.timestamp,
                level: level,
                rawVerdict: verdict,
                totalAssets: IVault(vault).totalAssets(),
                idleBps: IVault(vault).idleBufferBps()
            })
        );
    }

    // ════════════════════════════════════════════════════════════════════════
    //  ADMIN
    // ════════════════════════════════════════════════════════════════════════

    /// @notice Register a vault for monitoring.
    function registerVault(address vault, bool autoPause) external onlyOwner {
        require(vault != address(0), "zero vault");
        require(!vaultInfo[vault].registered, "already registered");
        vaultInfo[vault] = VaultInfo(true, autoPause, RiskLevel.Safe, 0, 0, 0);
        _vaultList.push(vault);
        emit VaultRegistered(vault, autoPause);
    }

    /// @notice Update the LLM agent ID (from agents.somnia.network).
    function setLlmAgentId(uint256 newId) external onlyOwner {
        llmAgentId = newId;
        emit AgentIdSet(newId);
    }

    /**
     * @notice Set (or clear) the utilization oracle.
     *         Pass address(0) to fall back to direct spot reads (original behaviour).
     *         When a valid oracle is set, all utilization reads go through it.
     *
     * @dev    Resolves D-8.  Only the sentinel admin may call this.
     * @param  newOracle  Address of IUtilizationOracle implementation, or address(0).
     */
    function setOracle(address newOracle) external onlyOwner {
        oracle = IUtilizationOracle(newOracle);
        emit OracleSet(newOracle);
    }

    // ════════════════════════════════════════════════════════════════════════
    //  VIEW (for frontend)
    // ════════════════════════════════════════════════════════════════════════

    function getHistory(address vault) external view returns (RiskSnapshot[] memory) {
        return _history[vault];
    }

    function getLatestRisk(address vault)
        external
        view
        returns (RiskLevel level, uint256 ts, string memory verdict)
    {
        RiskSnapshot[] storage h = _history[vault];
        if (h.length == 0) return (RiskLevel.Safe, 0, "NOT_CHECKED");
        RiskSnapshot storage latest = h[h.length - 1];
        return (latest.level, latest.timestamp, latest.rawVerdict);
    }

    function getVaultList() external view returns (address[] memory) {
        return _vaultList;
    }

    function isCheckPending(address vault) external view returns (bool) {
        return activeRequest[vault] != 0;
    }

    // ════════════════════════════════════════════════════════════════════════
    //  HELPERS
    // ════════════════════════════════════════════════════════════════════════

    /**
     * @dev Integer-to-decimal-string conversion.
     *      D-2 fix: counters properly advance — no infinite loop.
     */
    function _u(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0";
        uint256 t = v;
        uint256 d = 0;
        while (t != 0) {
            d++;
            t /= 10;
        }
        bytes memory b = new bytes(d);
        while (v != 0) {
            b[--d] = bytes1(uint8(48 + v % 10));
            v /= 10;
        }
        return string(b);
    }

    receive() external payable {}
    fallback() external payable {}
}
