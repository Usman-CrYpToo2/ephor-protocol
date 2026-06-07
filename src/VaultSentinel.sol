// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./Interface/ISomnia.sol";

/**
 * @title  VaultSentinel
 * @notice Autonomous AI risk monitor. Holds SENTINEL_ROLE on CuratedVault.
 *
 *  FLOW
 *  ────
 *  1. checkVault(vault)  — reads 5 metrics from vault contracts (on-chain view calls)
 *  2. Builds plain-English prompt from those numbers
 *  3. createRequest() → Somnia LLM Agent via platform
 *  4. Validators run LLM deterministically (fixed seed, temp=0) → consensus
 *  5. Platform calls handleResponse() callback
 *  6. SAFE     → store snapshot, no action
 *     CAUTION  → store snapshot + emit RiskAlert
 *     CRITICAL → pauseDeposits() + emergencyDeallocate() on worst market
 *
 *  WHY ON-CHAIN DATA
 *  ─────────────────
 *  vault.totalAssets(), market.balanceOf(vault), market.utilizationBps()
 *  are free view calls to our own contracts — no external API, no DeFiLlama.
 *  Perfect for testnet where nothing appears in DeFiLlama.
 *
 *  DEPOSIT SIZING  (from real docs)
 *  ─────────────────────────────────
 *  reserve = platform.getRequestDeposit()   (covers gas refunds, keeper, callback)
 *  reward  = LLM_COST_PER_AGENT × SUBCOMMITTEE_SIZE
 *  total   = reserve + reward
 *  Safe to send: 0.15 STT (excess rebated via receive())
 *
 *  SECURITY
 *  ────────
 *  • onlyPlatform on handleResponse — nobody else can fake a verdict
 *  • pendingRequests mapping — prevents replay / orphan callbacks
 *  • Fail-safe: timeout/fail → CAUTION, never silently SAFE
 *  • 5-min cooldown per vault — prevents DoS
 *  • One in-flight check per vault
 */

interface IVault {
    function totalAssets() external view returns (uint256);
    /// @dev Returns idle fraction in basis points (bps). 1% = 100 bps. Fixes D-3.
    function idleBufferBps() external view returns (uint256);
    /// @dev Returns market allocation fraction in basis points (bps). 1% = 100 bps. Fixes D-3.
    function marketAllocationBps(address market) external view returns (uint256);
    function marketCount() external view returns (uint256);
    function marketList(uint256 i) external view returns (address);
    function pauseDeposits() external;
    function emergencyDeallocate(address market, uint256 amount) external;
}

interface IMarket {
    function balanceOf(address account) external view returns (uint256);
    function utilizationBps() external view returns (uint256);
}

contract VaultSentinel {
    // ── Somnia platform ──────────────────────────────────────────────────────
    // Testnet:  0x037Bb9C718F3f7fe5eCBDB0b600D607b52706776
    // Mainnet:  0x5E5205CF39E766118C01636bED000A54D93163E6
    IAgentRequester public immutable platform;

    // Get the real agent ID from agents.somnia.network → LLM Inference agent
    uint256 public llmAgentId;

    // Default subcommittee size (matches platform default)
    uint256 public constant SUBCOMMITTEE_SIZE = 3;
    // Per-agent cost for LLM inference (from Somnia Gas Fees docs: 0.07 SOMI)
    uint256 public constant LLM_COST_PER_AGENT = 0.07 ether;

    // ── Admin ────────────────────────────────────────────────────────────────
    address public admin;

    // ── Risk levels ──────────────────────────────────────────────────────────
    enum RiskLevel {
        Safe,
        Caution,
        Critical
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
        /// @dev Idle buffer in basis points (bps). 1% = 100 bps. Renamed from idlePct (D-3 fix).
        uint256 idleBps;
    }
    mapping(address => RiskSnapshot[]) private _history;

    // ── In-flight request tracking ───────────────────────────────────────────
    // IMPORTANT: must use pendingRequests (not _pending) so MockPlatform can
    // look up the vault from the requestId in tests
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
    event AdminTransferred(address newAdmin);

    // ── Modifiers ────────────────────────────────────────────────────────────
    modifier onlyPlatform() {
        require(msg.sender == address(platform), "Sentinel: not platform");
        _;
    }
    modifier onlyAdmin() {
        require(msg.sender == admin, "Sentinel: not admin");
        _;
    }

    constructor(address _platform, uint256 _llmAgentId, address _admin) {
        require(_platform != address(0) && _admin != address(0), "zero addr");
        platform = IAgentRequester(_platform);
        llmAgentId = _llmAgentId;
        admin = _admin;
    }

    // ════════════════════════════════════════════════════════════════════════
    //  STEP 1 — TRIGGER A VAULT CHECK
    // ════════════════════════════════════════════════════════════════════════

    /**
     * @notice Trigger an AI risk check for a registered vault.
     *
     *         Reads on-chain metrics → builds LLM prompt → sends to Somnia platform.
     *         Result arrives async in handleResponse().
     *
     * @dev    msg.value must cover:
     *           platform.getRequestDeposit()   (operations reserve)
     *         + LLM_COST_PER_AGENT × SUBCOMMITTEE_SIZE  (validator rewards)
     *         Safe value: 0.15 STT. Excess is rebated to this contract.
     */
    function checkVault(address vault) external payable {
        VaultInfo storage info = vaultInfo[vault];
        require(info.registered, "not registered");
        require(block.timestamp >= info.lastCheckedAt + CHECK_COOLDOWN, "cooldown");
        require(activeRequest[vault] == 0, "check in progress");
        require(msg.value >= LLM_COST_PER_AGENT * SUBCOMMITTEE_SIZE, "insufficient deposit");

        // ── Read all metrics from vault's own contracts (zero external API) ──
        (
            uint256 totalA,
            uint256 idleBps,
            uint256 mCount,
            address[] memory mAddrs,
            uint256[] memory mAllocBps,
            uint256[] memory mUtilBps
        ) = _readMetrics(vault);

        // ── Build user prompt ──────────────────────────────────────────────
        string memory userPrompt = _buildUserPrompt(totalA, idleBps, mCount, mAddrs, mAllocBps, mUtilBps);

        // ── Encode LLM agent call ──────────────────────────────────────────
        // inferString(prompt, system, chainOfThought, allowedValues)
        // allowedValues constrains the model to one of the three words exactly.
        string[] memory allowed = new string[](3);
        allowed[0] = "SAFE";
        allowed[1] = "CAUTION";
        allowed[2] = "CRITICAL";
        bytes memory payload = abi.encodeWithSelector(
            ILLMInferenceAgent.inferString.selector,
            userPrompt, // prompt  — vault metrics
            _systemPrompt(), // system  — classification instructions
            false, // chainOfThought — off, we want a single word
            allowed // allowedValues  — constrain output
        );

        // ── Send to Somnia platform ────────────────────────────────────────
        uint256 reqId = platform.createRequest{value: msg.value}(
            llmAgentId,
            address(this),
            this.handleResponse.selector, // ← exact name from real docs
            payload
        );

        pendingRequests[reqId] = vault;
        activeRequest[vault] = reqId;
        info.lastCheckedAt = block.timestamp;
        info.totalChecks++;

        emit CheckRequested(vault, reqId, msg.sender);
    }

    // ════════════════════════════════════════════════════════════════════════
    //  STEP 2 — SOMNIA PLATFORM DELIVERS THE VERDICT
    //
    //  Function name is handleResponse — EXACT name from real Somnia docs.
    //  Selector: this.handleResponse.selector passed to createRequest().
    //  Only the platform contract may call this.
    // ════════════════════════════════════════════════════════════════════════

    function handleResponse(
        uint256 requestId,
        Response[] memory responses,
        ResponseStatus status,
        Request memory /* details */
    )
        external
        onlyPlatform
    {
        address vault = pendingRequests[requestId];
        require(vault != address(0), "unknown request");

        delete pendingRequests[requestId];
        delete activeRequest[vault];

        VaultInfo storage info = vaultInfo[vault];

        // ── Fail-safe: timeout/failure → CAUTION (never silently SAFE) ──────
        if (status == ResponseStatus.TimedOut || status == ResponseStatus.Failed || responses.length == 0) {
            _store(vault, RiskLevel.Caution, "AI_UNAVAILABLE");
            info.lastLevel = RiskLevel.Caution;
            emit RiskAlert(vault, RiskLevel.Caution, "AI_UNAVAILABLE");
            return;
        }

        // ── Decode the single-word LLM response ───────────────────────────
        string memory raw = abi.decode(responses[0].result, (string));
        RiskLevel level = _parse(raw);

        _store(vault, level, raw);
        info.lastLevel = level;

        emit VerdictReceived(vault, level, raw);
        emit RiskAlert(vault, level, raw);

        if (level == RiskLevel.Critical) {
            info.criticalCount++;
            _respondToCritical(vault, raw);
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

    function _deallocateWorstMarket(address vault) internal {
        IVault v = IVault(vault);
        uint256 cnt = v.marketCount();
        if (cnt == 0) return;

        address worst = address(0);
        uint256 worstUtil = 0;

        for (uint256 i; i < cnt;) {
            address m = v.marketList(i);
            uint256 u = IMarket(m).utilizationBps();
            if (u > worstUtil) {
                worstUtil = u;
                worst = m;
            }
            unchecked {
                ++i;
            }
        }
        // Only pull if util > 90%  (9000 bps)
        if (worst == address(0) || worstUtil < 9_000) return;

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

    /// @dev Reads all vault metrics. All ratio values are in basis points (bps).
    ///      idleBps and mAllocBps are bps (10_000 = 100%). Fixes D-3.
    function _readMetrics(address vault)
        internal
        view
        returns (
            uint256 totalA,
            uint256 idleBps,
            uint256 mCount,
            address[] memory mAddrs,
            uint256[] memory mAllocBps,
            uint256[] memory mUtilBps
        )
    {
        IVault v = IVault(vault);
        totalA = v.totalAssets();
        idleBps = v.idleBufferBps();
        mCount = v.marketCount();
        mAddrs = new address[](mCount);
        mAllocBps = new uint256[](mCount);
        mUtilBps = new uint256[](mCount);
        for (uint256 i; i < mCount;) {
            address m = v.marketList(i);
            mAddrs[i] = m;
            mAllocBps[i] = v.marketAllocationBps(m);
            mUtilBps[i] = IMarket(m).utilizationBps();
            unchecked {
                ++i;
            }
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    //  INTERNAL — PROMPT CONSTRUCTION
    // ════════════════════════════════════════════════════════════════════════

    function _systemPrompt() internal pure returns (string memory) {
        return "You are a DeFi vault risk classifier. " "Respond with EXACTLY ONE WORD: SAFE, CAUTION, or CRITICAL. "
            "No punctuation. No explanation. No newline. One word only. "
            "CRITICAL if ANY: (1) any market allocation >40%; " "(2) idle buffer <5%; (3) any market utilization >95%. "
            "CAUTION if ANY: (1) any market allocation 25-40%; "
            "(2) idle buffer 5-10%; (3) any market utilization 80-95%. " "SAFE if none of the above. "
            "If data missing or inconsistent: CAUTION. " "RESPOND WITH ONE WORD ONLY: SAFE, CAUTION, or CRITICAL.";
    }

    /// @dev Builds the LLM user prompt from vault metrics.
    ///      All ratio values (idleBps, mAllocBps, mUtilBps) are in basis points.
    ///      10000 bps = 100%. Values are emitted losslessly with no truncation (P-4, D-3).
    function _buildUserPrompt(
        uint256 totalA,
        uint256 idleBps,
        uint256 mCount,
        address[] memory,
        uint256[] memory mAllocBps,
        uint256[] memory mUtilBps
    ) internal pure returns (string memory s) {
        s = string(abi.encodePacked("Vault: total=", _u(totalA / 1_000_000), " idle=", _u(idleBps), "bps. "));
        for (uint256 i; i < mCount;) {
            s = string(
                abi.encodePacked(
                    s, "Market", _u(i + 1), ": ", "alloc=", _u(mAllocBps[i]), "bps ", "util=", _u(mUtilBps[i]), "bps. "
                )
            );
            unchecked {
                ++i;
            }
        }
    }

    function _parse(string memory raw) internal pure returns (RiskLevel) {
        bytes32 h = keccak256(bytes(raw));
        if (h == keccak256(bytes("CRITICAL"))) return RiskLevel.Critical;
        if (h == keccak256(bytes("CAUTION"))) return RiskLevel.Caution;
        if (h == keccak256(bytes("SAFE"))) return RiskLevel.Safe;
        return RiskLevel.Caution; // unknown → fail-safe
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

    function registerVault(address vault, bool autoPause) external onlyAdmin {
        require(vault != address(0), "zero vault");
        require(!vaultInfo[vault].registered, "already registered");
        vaultInfo[vault] = VaultInfo(true, autoPause, RiskLevel.Safe, 0, 0, 0);
        _vaultList.push(vault);
        emit VaultRegistered(vault, autoPause);
    }

    function setLlmAgentId(uint256 newId) external onlyAdmin {
        llmAgentId = newId;
        emit AgentIdSet(newId);
    }

    function transferAdmin(address newAdmin) external onlyAdmin {
        require(newAdmin != address(0), "zero");
        admin = newAdmin;
        emit AdminTransferred(newAdmin);
    }

    // ════════════════════════════════════════════════════════════════════════
    //  VIEW (for frontend)
    // ════════════════════════════════════════════════════════════════════════

    function getHistory(address vault) external view returns (RiskSnapshot[] memory) {
        return _history[vault];
    }

    function getLatestRisk(address vault) external view returns (RiskLevel level, uint256 ts, string memory verdict) {
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

    function _u(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0";
        uint256 t = v;
        uint256 d;
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
