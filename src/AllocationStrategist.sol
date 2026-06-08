// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {CuratedVault} from "./CuratedVault.sol";
import {AllocationProjection} from "./AllocationProjection.sol";
import {ILendingMarket} from "./Interface/ILendingMarket.sol";
import {IUtilizationOracle} from "./Interface/IUtilizationOracle.sol";
import {IVault} from "./Interface/IVault.sol";
import "./Interface/ISomnia.sol";

/// @title  AllocationStrategist
/// @notice Phase 3/4 — full Tier-1 and Tier-2 Somnia LLM lifecycle.
///
///  TIER-1 FLOW (default)
///  ─────────────────────
///  1. requestRebalance(vault) — anyone with ≥ minimumDeposit STT attached may trigger.
///  2. Reads on-chain metrics → builds prompt → sends one inferString call.
///  3. Platform calls back handleResponse() with a strategy label.
///  4. Label → weights → AllocationProjection.project() → vault.reallocate().
///
///  TIER-2 FLOW (AllocationMode.Tier2)
///  ────────────────────────────────────
///  1. requestRebalance(vault) issues N separate inferNumber calls (one per market).
///  2. Each call rates market attractiveness on [0, SCORE_MAX=10000].
///  3. When all N callbacks arrive, scores are normalized to weights → project() → reallocate().
///  4. If ANY sub-request fails or times out, the whole group is abandoned (RebalanceSkipped).
///
///  FAIL-SAFE
///  ─────────
///  Timeout / failure / unknown label → emit RebalanceSkipped, no vault movement.
///  AI failure never moves funds — last safe state preserved.
///
///  INVARIANTS
///  ──────────
///  • pendingRequests MUST remain public — MockSomniaPlatform looks it up by requestId.
///  • handleResponse name MUST NOT change — selector passed to createRequest literally.
///  • DERISK sends all-zero weights; AllocationProjection returns all-zero targets;
///    we skip reallocate entirely (no-op, everything stays idle).
///  • AC-5: vault.reallocate() enforces supply caps (I-2/I-4) — Tier-2 scores cannot override.
///
///  BACKWARD COMPATIBILITY
///  ──────────────────────
///  executeRebalance() (Phase 2 stub) is preserved for existing tests and tooling.
contract AllocationStrategist is ReentrancyGuard {
    // ── Somnia platform ──────────────────────────────────────────────────────
    IAgentRequester public immutable platform;

    /// @notice LLM Inference Agent ID (from agents.somnia.network).
    uint256 public llmAgentId;

    // ── Vault ────────────────────────────────────────────────────────────────
    /// @notice The vault this strategist may rebalance.
    CuratedVault public immutable vault;

    // ── Phase 2 admin (preserved for executeRebalance compatibility) ─────────
    address public immutable admin;

    // ── Utilization oracle (optional — when set, uses effectiveUtil()) ───────
    IUtilizationOracle public oracle;

    // ── Constants ────────────────────────────────────────────────────────────
    uint256 public constant REBALANCE_COOLDOWN = 5 minutes;
    uint256 public constant RESPONSE_TIMEOUT   = 10 minutes;
    uint256 public constant SCORE_MAX          = 10_000; // Tier-2 score upper bound

    // ── AI label strings ─────────────────────────────────────────────────────
    bytes32 private constant LABEL_BALANCED   = keccak256("BALANCED");
    bytes32 private constant LABEL_YIELD_TILT = keccak256("YIELD_TILT");
    bytes32 private constant LABEL_DEFENSIVE  = keccak256("DEFENSIVE");
    bytes32 private constant LABEL_DERISK     = keccak256("DERISK");

    // ── Enums ────────────────────────────────────────────────────────────────
    enum StrategyLabel { Balanced, YieldTilt, Defensive, DeRisk, Unknown }

    /// @notice Tier-1 uses one inferString call; Tier-2 uses N inferNumber calls.
    enum AllocationMode { Tier1, Tier2 }

    /// @notice Current allocation mode — curator-set via setAllocationMode().
    AllocationMode public allocationMode; // default: Tier1

    // ── Per-vault in-flight tracking ─────────────────────────────────────────

    /// @notice Tier-1 pending rebalance (one request per vault).
    struct PendingRebalance {
        address vault;
        uint256 snapshotTotalAssets;
        uint256 snapshotEpoch;
        uint256 timestamp;
    }

    /// @notice Tier-2 group state — aggregates N sub-request scores.
    struct PendingTier2Group {
        address vault;
        uint256 snapshotTotalAssets;
        uint256 snapshotEpoch;
        uint256 timestamp;
        uint256 marketCount;
        uint256 pendingCount;    // decremented on each callback; execute when 0
        bool    abandoned;       // set on first failure to suppress further execution
    }

    /// @notice Auto-incrementing counter for Tier-2 group IDs.
    ///         Starts at 1 so that 0 always means "no group".
    uint256 public nextGroupId = 1;

    /// @notice Maps sub-requestId → groupId (Tier-2 only).
    mapping(uint256 => uint256) public subRequestToGroup;

    /// @notice Maps sub-requestId → market index within the group (Tier-2 only).
    mapping(uint256 => uint256) public subRequestMarketIndex;

    /// @notice Maps groupId → Tier-2 group state.
    mapping(uint256 => PendingTier2Group) public pendingGroups;

    /// @notice Maps groupId → per-market scores array (filled as callbacks arrive).
    mapping(uint256 => uint256[]) public pendingScores;

    /// @notice Maps groupId → market addresses (needed at execution time).
    mapping(uint256 => address[]) public pendingMarkets;

    // IMPORTANT: pendingRequests MUST remain public — MockSomniaPlatform
    // looks up the vault address by requestId during tests.
    mapping(uint256 => PendingRebalance) public pendingRequests;

    /// @notice requestId of the active in-flight request for each vault (0 = none).
    ///         For Tier-2, this holds the groupId (first sub-requestId of that group).
    mapping(address => uint256) public activeRequest;

    /// @notice Last request timestamp per vault (for cooldown enforcement).
    mapping(address => uint256) public lastRequestAt;

    // ── Events ───────────────────────────────────────────────────────────────
    event RebalanceRequested(address indexed vault_, uint256 indexed requestId);
    event RebalanceExecuted(address indexed vault_, string label, uint256 epoch);
    event RebalanceSkipped(address indexed vault_, string reason);
    event OracleSet(address indexed newOracle);
    event LlmAgentIdSet(uint256 newId);
    event AllocationModeSet(AllocationMode mode);
    /// @notice Emitted when a Tier-2 group issues N sub-requests.
    event Tier2GroupCreated(address indexed vault_, uint256 indexed groupId, uint256 marketCount);
    /// @notice Emitted when a single Tier-2 sub-request score is stored.
    event Tier2ScoreReceived(uint256 indexed groupId, uint256 indexed marketIndex, uint256 score);

    // ── Errors ───────────────────────────────────────────────────────────────
    error NotAdmin();
    error NotPlatform();
    error RebalanceInProgress();
    error RebalanceCooldown(uint256 availableAt);
    error UnknownRequest();
    error InsufficientDeposit(uint256 sent, uint256 required);
    error ZeroAddress();

    // ── Modifiers ────────────────────────────────────────────────────────────
    modifier onlyPlatform() {
        if (msg.sender != address(platform)) revert NotPlatform();
        _;
    }

    // ── Constructor ──────────────────────────────────────────────────────────

    /// @param _platform  Somnia agent platform address.
    /// @param _llmAgentId  LLM Inference Agent ID from agents.somnia.network.
    /// @param _vault     CuratedVault this strategist manages.
    /// @param _admin     Phase 2 admin (preserved for executeRebalance).
    constructor(
        address _platform,
        uint256 _llmAgentId,
        address _vault,
        address _admin
    ) {
        if (_platform == address(0) || _vault == address(0) || _admin == address(0)) revert ZeroAddress();
        platform   = IAgentRequester(_platform);
        llmAgentId = _llmAgentId;
        vault      = CuratedVault(_vault);
        admin      = _admin;
    }

    // ════════════════════════════════════════════════════════════════════════
    //  PHASE 2 STUB — preserved for backward compatibility
    // ════════════════════════════════════════════════════════════════════════

    /// @notice Phase 2 stub: direct call to reallocate with caller-supplied targets.
    ///         Still used by existing tooling and StrategistTest.
    ///
    /// @param targets  Per-market target balances in asset base units.
    /// @param guard    Staleness guard (snapshotTotalAssets, snapshotEpoch).
    function executeRebalance(
        CuratedVault.MarketTarget[] calldata targets,
        CuratedVault.RebalanceGuard calldata guard
    ) external {
        if (msg.sender != admin) revert NotAdmin();
        vault.reallocate(targets, guard);
        emit RebalanceExecuted(address(vault), "MANUAL", vault.currentEpoch());
    }

    // ════════════════════════════════════════════════════════════════════════
    //  PHASE 3 — STEP 1: REQUEST REBALANCE
    // ════════════════════════════════════════════════════════════════════════

    /**
     * @notice Trigger an AI rebalance check for the vault.
     *
     *         Reads on-chain metrics → builds prompt → sends to Somnia LLM agent.
     *         Result arrives asynchronously in handleResponse().
     *
     *         In Tier-1 mode: one inferString call.
     *         In Tier-2 mode: N inferNumber calls (one per market).
     *
     * @dev    msg.value must cover the platform's minimum deposit × N (Tier-2).
     *         5-minute cooldown per vault prevents DoS.
     *         Only one in-flight group per vault at a time.
     */
    function requestRebalance(address vault_) external payable nonReentrant {
        if (vault_ != address(vault)) revert ZeroAddress(); // only manages its own vault

        // ── Cooldown check ────────────────────────────────────────────────
        uint256 available = lastRequestAt[vault_] + REBALANCE_COOLDOWN;
        if (block.timestamp < available) revert RebalanceCooldown(available);

        // ── In-flight check ───────────────────────────────────────────────
        if (activeRequest[vault_] != 0) revert RebalanceInProgress();

        // ── Deposit check ─────────────────────────────────────────────────
        // Minimum is one deposit. Tier-2 enforces N × minDeposit inside _requestTier2.
        uint256 minDeposit = platform.getRequestDeposit();
        if (msg.value < minDeposit) revert InsufficientDeposit(msg.value, minDeposit);

        // ── Snapshot vault metrics (all on-chain, no external APIs) ──────
        IVault v = IVault(vault_);
        uint256 totalA  = v.totalAssets();
        uint256 idleBps = v.idleBufferBps();
        uint256 mCount  = v.marketCount();

        uint256[] memory mAllocBps = new uint256[](mCount);
        uint256[] memory mUtilBps  = new uint256[](mCount);
        address[] memory mAddrs    = new address[](mCount);

        IUtilizationOracle _oracle = oracle;
        for (uint256 i; i < mCount;) {
            address m = v.marketList(i);
            mAddrs[i]    = m;
            mAllocBps[i] = v.marketAllocationBps(m);

            if (address(_oracle) != address(0)) {
                try _oracle.effectiveUtil(m) returns (uint256 util, bool) {
                    mUtilBps[i] = util;
                } catch {
                    mUtilBps[i] = ILendingMarket(m).utilizationBps();
                }
            } else {
                mUtilBps[i] = ILendingMarket(m).utilizationBps();
            }
            unchecked { ++i; }
        }

        // ── CEI: mark in-flight before any external call ──────────────────
        uint256 snapEpoch = vault.currentEpoch();
        lastRequestAt[vault_] = block.timestamp;
        activeRequest[vault_] = type(uint256).max; // sentinel: blocks re-entrancy

        if (allocationMode == AllocationMode.Tier2) {
            _requestTier2(vault_, totalA, snapEpoch, mCount, mAddrs, mAllocBps, mUtilBps);
        } else {
            _requestTier1(vault_, totalA, snapEpoch, idleBps, mCount, mAllocBps, mUtilBps);
        }
    }

    // ── Tier-1 internal ──────────────────────────────────────────────────────

    function _requestTier1(
        address vault_,
        uint256 totalA,
        uint256 snapEpoch,
        uint256 idleBps,
        uint256 mCount,
        uint256[] memory mAllocBps,
        uint256[] memory mUtilBps
    ) internal {
        // ── Build prompt ──────────────────────────────────────────────────
        string memory prompt = _buildPrompt(totalA, idleBps, mCount, mAllocBps, mUtilBps);

        // ── Encode LLM payload ────────────────────────────────────────────
        string[] memory allowed = new string[](4);
        allowed[0] = "DEFENSIVE";
        allowed[1] = "BALANCED";
        allowed[2] = "YIELD_TILT";
        allowed[3] = "DERISK";

        bytes memory payload = abi.encodeWithSelector(
            ILLMInferenceAgent.inferString.selector,
            prompt,
            _systemPrompt(),
            false,
            allowed
        );

        // ── Send to Somnia platform ───────────────────────────────────────
        uint256 reqId = platform.createRequest{value: msg.value}(
            llmAgentId,
            address(this),
            this.handleResponse.selector,
            payload
        );

        // ── Update state with real request ID ────────────────────────────
        pendingRequests[reqId] = PendingRebalance({
            vault: vault_,
            snapshotTotalAssets: totalA,
            snapshotEpoch: snapEpoch,
            timestamp: block.timestamp
        });
        activeRequest[vault_] = reqId;

        emit RebalanceRequested(vault_, reqId);
    }

    // ── Tier-2 internal ──────────────────────────────────────────────────────

    function _requestTier2(
        address vault_,
        uint256 totalA,
        uint256 snapEpoch,
        uint256 mCount,
        address[] memory mAddrs,
        uint256[] memory mAllocBps,
        uint256[] memory mUtilBps
    ) internal {
        uint256 minDeposit = platform.getRequestDeposit();

        // Ensure enough ETH for all sub-requests
        if (mCount > 0 && msg.value < minDeposit * mCount) {
            revert InsufficientDeposit(msg.value, minDeposit * mCount);
        }

        // ── CEI: assign groupId and store state BEFORE external calls ─────
        uint256 groupId = nextGroupId++;

        pendingGroups[groupId] = PendingTier2Group({
            vault: vault_,
            snapshotTotalAssets: totalA,
            snapshotEpoch: snapEpoch,
            timestamp: block.timestamp,
            marketCount: mCount,
            pendingCount: mCount,
            abandoned: false
        });

        // Initialize scores array and market list
        uint256[] storage scores = pendingScores[groupId];
        address[] storage mkts   = pendingMarkets[groupId];
        for (uint256 i; i < mCount;) {
            scores.push(0);
            mkts.push(mAddrs[i]);
            unchecked { ++i; }
        }

        // Update active tracking before external calls
        activeRequest[vault_] = groupId;

        // ── Issue N sub-requests (one per market) ─────────────────────────
        // Split msg.value evenly; last request gets any remainder.
        uint256 valuePerRequest = mCount > 0 ? msg.value / mCount : 0;
        uint256 remainder = mCount > 0 ? msg.value - (valuePerRequest * (mCount - 1)) : 0;

        for (uint256 i; i < mCount;) {
            string memory prompt = _buildTier2Prompt(
                i,
                mUtilBps[i],
                mAllocBps[i],
                totalA,
                mCount
            );

            bytes memory payload = abi.encodeWithSelector(
                ILLMInferenceAgent.inferNumber.selector,
                prompt,
                _tier2SystemPrompt(),
                false,
                uint256(0),
                SCORE_MAX
            );

            uint256 sendValue = (i == mCount - 1) ? remainder : valuePerRequest;

            uint256 subId = platform.createRequest{value: sendValue}(
                llmAgentId,
                address(this),
                this.handleResponse.selector,
                payload
            );

            // Map sub-requestId → group and market index
            subRequestToGroup[subId]      = groupId;
            subRequestMarketIndex[subId]  = i;

            unchecked { ++i; }
        }

        emit Tier2GroupCreated(vault_, groupId, mCount);
        emit RebalanceRequested(vault_, groupId);
    }

    // ════════════════════════════════════════════════════════════════════════
    //  PHASE 3 — STEP 2: HANDLE RESPONSE (Somnia platform callback)
    //
    //  Function name is handleResponse — EXACT name from real Somnia docs.
    //  Selector: this.handleResponse.selector passed to createRequest().
    //  Only the platform contract may call this.
    // ════════════════════════════════════════════════════════════════════════

    /**
     * @notice Callback invoked by the Somnia platform.
     *
     *  Routes to Tier-1 or Tier-2 handler based on which mapping the requestId belongs to.
     *
     *  Fail-safe: timeout / failure / unknown → emit RebalanceSkipped, no vault movement.
     *  Happy path (Tier-1): decode label → weights → project() → reallocate().
     *  Happy path (Tier-2): store score; when last sub-request arrives → normalize → reallocate().
     *
     * @param requestId  Matches the ID returned by requestRebalance → createRequest.
     * @param responses  Array of validator responses (use responses[0].result).
     * @param status     ResponseStatus enum (Success=2, Failed=3, TimedOut=4).
     * @param details    Full Request struct — available for future consensus checks.
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
        details; // reserved for future D-6-style consensus checks

        // ── Route: Tier-2 sub-request? ────────────────────────────────────
        uint256 groupId = subRequestToGroup[requestId];
        if (groupId != 0) {
            _handleTier2Response(requestId, groupId, responses, status);
            return;
        }

        // ── Route: Tier-1 ─────────────────────────────────────────────────
        _handleTier1Response(requestId, responses, status);
    }

    // ── Tier-1 handler ───────────────────────────────────────────────────────

    function _handleTier1Response(
        uint256 requestId,
        Response[] memory responses,
        ResponseStatus status
    ) internal {
        PendingRebalance memory pending = pendingRequests[requestId];
        if (pending.vault == address(0)) revert UnknownRequest();

        address vault_ = pending.vault;

        // ── CEI: clear pending state BEFORE any external calls ────────────
        delete pendingRequests[requestId];
        delete activeRequest[vault_];

        // ── Timeout check (fail-safe) ──────────────────────────────────────
        if (block.timestamp > pending.timestamp + RESPONSE_TIMEOUT) {
            emit RebalanceSkipped(vault_, "TIMEOUT");
            return;
        }

        // ── AI failure path (fail-safe) ────────────────────────────────────
        if (
            status == ResponseStatus.TimedOut ||
            status == ResponseStatus.Failed   ||
            responses.length == 0
        ) {
            emit RebalanceSkipped(vault_, "AI_UNAVAILABLE");
            return;
        }

        // ── Decode AI label ────────────────────────────────────────────────
        string memory raw = abi.decode(responses[0].result, (string));
        StrategyLabel label = _parseLabel(raw);

        // ── Unknown label → fail-safe (no vault movement) ─────────────────
        if (label == StrategyLabel.Unknown) {
            emit RebalanceSkipped(vault_, "UNKNOWN_LABEL");
            return;
        }

        // ── DERISK: everything idles, skip reallocate entirely ─────────────
        if (label == StrategyLabel.DeRisk) {
            emit RebalanceExecuted(vault_, raw, vault.currentEpoch());
            return;
        }

        // ── Build weights from label ───────────────────────────────────────
        IVault v = IVault(vault_);
        uint256 mCount = v.marketCount();

        address[] memory markets_   = new address[](mCount);
        uint256[] memory weights    = new uint256[](mCount);
        uint256[] memory currentBals = new uint256[](mCount);
        uint256[] memory supplyCaps = new uint256[](mCount);

        IUtilizationOracle _oracle = oracle;

        for (uint256 i; i < mCount;) {
            address m = v.marketList(i);
            markets_[i]    = m;
            currentBals[i] = ILendingMarket(m).balanceOf(vault_);
            (bool enabled, uint256 cap) = vault.markets(m);
            supplyCaps[i]  = enabled ? cap : 0;

            uint256 util;
            if (address(_oracle) != address(0)) {
                try _oracle.effectiveUtil(m) returns (uint256 u, bool) {
                    util = u;
                } catch {
                    util = ILendingMarket(m).utilizationBps();
                }
            } else {
                util = ILendingMarket(m).utilizationBps();
            }

            if (label == StrategyLabel.Balanced) {
                weights[i] = 1;
            } else if (label == StrategyLabel.YieldTilt) {
                weights[i] = util;
            } else if (label == StrategyLabel.Defensive) {
                weights[i] = 10_000 > util ? 10_000 - util : 0;
            }

            unchecked { ++i; }
        }

        // ── Run AllocationProjection ───────────────────────────────────────
        uint256 totalA   = v.totalAssets();
        uint256[] memory targets_ = AllocationProjection.project(
            markets_,
            weights,
            currentBals,
            supplyCaps,
            totalA,
            vault.minIdleBufferBps(),
            vault.maxMarketBps(),
            vault.maxTurnoverBps()
        );

        _executeReallocate(markets_, targets_, mCount, pending.snapshotTotalAssets, pending.snapshotEpoch);
        emit RebalanceExecuted(vault_, raw, vault.currentEpoch());
    }

    // ── Tier-2 handler ───────────────────────────────────────────────────────

    function _handleTier2Response(
        uint256 requestId,
        uint256 groupId,
        Response[] memory responses,
        ResponseStatus status
    ) internal {
        PendingTier2Group storage group = pendingGroups[groupId];

        // Group must exist (vault address set)
        if (group.vault == address(0)) revert UnknownRequest();

        address vault_ = group.vault;
        uint256 marketIdx = subRequestMarketIndex[requestId];

        // ── CEI: remove sub-request mapping before any external call ──────
        delete subRequestToGroup[requestId];
        delete subRequestMarketIndex[requestId];

        // ── If group already abandoned, silently ignore further callbacks ──
        if (group.abandoned) {
            // Decrement pendingCount so we can clean up when last arrives
            group.pendingCount -= 1;
            if (group.pendingCount == 0) {
                _cleanupTier2Group(groupId, vault_);
            }
            return;
        }

        // ── Timeout check (fail-safe) ──────────────────────────────────────
        if (block.timestamp > group.timestamp + RESPONSE_TIMEOUT) {
            group.abandoned = true;
            group.pendingCount -= 1;
            if (group.pendingCount == 0) {
                _cleanupTier2Group(groupId, vault_);
            } else {
                emit RebalanceSkipped(vault_, "TIER2_TIMEOUT");
            }
            return;
        }

        // ── AI failure path (fail-safe) ────────────────────────────────────
        if (
            status == ResponseStatus.TimedOut ||
            status == ResponseStatus.Failed   ||
            responses.length == 0
        ) {
            group.abandoned = true;
            group.pendingCount -= 1;
            if (group.pendingCount == 0) {
                _cleanupTier2Group(groupId, vault_);
            } else {
                emit RebalanceSkipped(vault_, "TIER2_AI_UNAVAILABLE");
            }
            return;
        }

        // ── Decode integer score, clamp to [0, SCORE_MAX] ─────────────────
        uint256 score = abi.decode(responses[0].result, (uint256));
        if (score > SCORE_MAX) score = SCORE_MAX;

        // Store score
        pendingScores[groupId][marketIdx] = score;
        emit Tier2ScoreReceived(groupId, marketIdx, score);

        group.pendingCount -= 1;

        // ── All scores received — execute ──────────────────────────────────
        if (group.pendingCount == 0) {
            _executeTier2(groupId, vault_, group);
            _cleanupTier2Group(groupId, vault_);
        }
    }

    /// @dev Normalize scores to weights and call vault.reallocate().
    function _executeTier2(
        uint256 groupId,
        address vault_,
        PendingTier2Group storage group
    ) internal {
        uint256 mCount = group.marketCount;
        address[] storage mkts = pendingMarkets[groupId];
        uint256[] storage scores = pendingScores[groupId];

        address[] memory markets_    = new address[](mCount);
        uint256[] memory weights     = new uint256[](mCount);
        uint256[] memory currentBals = new uint256[](mCount);
        uint256[] memory supplyCaps  = new uint256[](mCount);

        for (uint256 i; i < mCount;) {
            markets_[i]    = mkts[i];
            weights[i]     = scores[i]; // already clamped to [0, SCORE_MAX]
            currentBals[i] = ILendingMarket(mkts[i]).balanceOf(vault_);
            (bool enabled, uint256 cap) = vault.markets(mkts[i]);
            supplyCaps[i]  = enabled ? cap : 0;
            unchecked { ++i; }
        }

        IVault v = IVault(vault_);
        uint256 totalA = v.totalAssets();

        uint256[] memory targets_ = AllocationProjection.project(
            markets_,
            weights,
            currentBals,
            supplyCaps,
            totalA,
            vault.minIdleBufferBps(),
            vault.maxMarketBps(),
            vault.maxTurnoverBps()
        );

        _executeReallocate(markets_, targets_, mCount, group.snapshotTotalAssets, group.snapshotEpoch);
        emit RebalanceExecuted(vault_, "TIER2", vault.currentEpoch());
    }

    /// @dev Clean up Tier-2 group storage and release active lock.
    function _cleanupTier2Group(uint256 groupId, address vault_) internal {
        // If group was abandoned and all callbacks arrived, emit once
        if (pendingGroups[groupId].abandoned) {
            emit RebalanceSkipped(vault_, "TIER2_GROUP_ABANDONED");
        }
        delete pendingGroups[groupId];
        // Storage arrays are deleted by the EVM when mapping entry is deleted
        // but in Solidity mapping-to-array we need to explicitly clear
        delete pendingScores[groupId];
        delete pendingMarkets[groupId];
        delete activeRequest[vault_];
    }

    // ── Shared: build MarketTarget[] and call vault.reallocate() ────────────

    function _executeReallocate(
        address[] memory markets_,
        uint256[] memory targets_,
        uint256 mCount,
        uint256 snapTotalAssets,
        uint256 snapEpoch
    ) internal {
        uint256 nonzeroCount;
        for (uint256 i; i < mCount;) {
            if (targets_[i] > 0) nonzeroCount++;
            unchecked { ++i; }
        }

        if (nonzeroCount == 0) return;

        CuratedVault.MarketTarget[] memory mTargets = new CuratedVault.MarketTarget[](nonzeroCount);
        uint256 idx;
        for (uint256 i; i < mCount;) {
            if (targets_[i] > 0) {
                mTargets[idx] = CuratedVault.MarketTarget({
                    market: markets_[i],
                    targetAmount: targets_[i]
                });
                unchecked { ++idx; }
            }
            unchecked { ++i; }
        }

        CuratedVault.RebalanceGuard memory guard = CuratedVault.RebalanceGuard({
            snapshotTotalAssets: snapTotalAssets,
            snapshotEpoch:       snapEpoch
        });

        vault.reallocate(mTargets, guard);
    }

    // ════════════════════════════════════════════════════════════════════════
    //  ADMIN
    // ════════════════════════════════════════════════════════════════════════

    /// @notice Switch between Tier-1 (one inferString) and Tier-2 (N inferNumber) modes.
    ///         Only the admin may change this.
    function setAllocationMode(AllocationMode mode) external {
        if (msg.sender != admin) revert NotAdmin();
        allocationMode = mode;
        emit AllocationModeSet(mode);
    }

    /// @notice Set (or clear) the utilization oracle.
    ///         Pass address(0) to fall back to direct spot reads.
    function setOracle(address newOracle) external {
        if (msg.sender != admin) revert NotAdmin();
        oracle = IUtilizationOracle(newOracle);
        emit OracleSet(newOracle);
    }

    /// @notice Update the LLM agent ID (from agents.somnia.network).
    function setLlmAgentId(uint256 newId) external {
        if (msg.sender != admin) revert NotAdmin();
        llmAgentId = newId;
        emit LlmAgentIdSet(newId);
    }

    // ════════════════════════════════════════════════════════════════════════
    //  INTERNAL — PARSING
    // ════════════════════════════════════════════════════════════════════════

    function _parseLabel(string memory raw) internal pure returns (StrategyLabel) {
        bytes32 h = keccak256(bytes(raw));
        if (h == LABEL_BALANCED)   return StrategyLabel.Balanced;
        if (h == LABEL_YIELD_TILT) return StrategyLabel.YieldTilt;
        if (h == LABEL_DEFENSIVE)  return StrategyLabel.Defensive;
        if (h == LABEL_DERISK)     return StrategyLabel.DeRisk;
        return StrategyLabel.Unknown;
    }

    // ════════════════════════════════════════════════════════════════════════
    //  INTERNAL — PROMPT CONSTRUCTION
    // ════════════════════════════════════════════════════════════════════════

    function _systemPrompt() internal pure returns (string memory) {
        return "You are an allocation strategy selector for a yield vault. "
            "Inputs are canonical integer features in basis points (bps, 10000 = 100%). "
            "Choose the strategy that best matches the vault's current risk/return profile. "
            "DEFENSIVE: concentrate in low-utilization markets (capital preservation). "
            "BALANCED: equal weight across all markets (neutral). "
            "YIELD_TILT: concentrate in high-utilization markets (maximum yield). "
            "DERISK: move everything to idle (emergency, no market exposure). "
            "Output exactly one of: DEFENSIVE, BALANCED, YIELD_TILT, DERISK. No other text.";
    }

    /**
     * @dev Build canonical feature-block prompt encoding vault metrics.
     *      All values are integers (bps or raw amounts). No truncation.
     */
    function _buildPrompt(
        uint256 totalA,
        uint256 idleBps,
        uint256 mCount,
        uint256[] memory mAllocBps,
        uint256[] memory mUtilBps
    ) internal pure returns (string memory s) {
        s = string(
            abi.encodePacked(
                "PORTFOLIO|ta=", _u(totalA),
                "|idle=", _u(idleBps),
                "|mkts=", _u(mCount),
                " "
            )
        );
        for (uint256 i; i < mCount;) {
            s = string(
                abi.encodePacked(
                    s,
                    "M", _u(i + 1),
                    "|util=", _u(mUtilBps[i]),
                    "|alloc=", _u(mAllocBps[i]),
                    " "
                )
            );
            unchecked { ++i; }
        }
    }

    // ── Tier-2 prompts ────────────────────────────────────────────────────────

    function _tier2SystemPrompt() internal pure returns (string memory) {
        return "You are a per-market capital allocation scorer for a yield vault. "
            "Inputs describe a single lending market's current state in basis points (bps, 10000 = 100%). "
            "Rate the market's attractiveness for capital allocation on a scale of 0 to 10000. "
            "Higher score = more attractive. "
            "Consider: moderate utilization (4000-8000 bps) is ideal; extreme values are less attractive. "
            "Output exactly one integer in [0, 10000]. No other text.";
    }

    /**
     * @dev Build a per-market Tier-2 prompt.
     *      Format: MARKET_SCORE|market=<i+1>|util=<bps>|alloc=<bps>|ta=<totalA>|mkts=<count>
     */
    function _buildTier2Prompt(
        uint256 marketIndex,
        uint256 utilBps,
        uint256 allocBps,
        uint256 totalA,
        uint256 mCount
    ) internal pure returns (string memory) {
        return string(
            abi.encodePacked(
                "MARKET_SCORE|market=", _u(marketIndex + 1),
                "|util=", _u(utilBps),
                "|alloc=", _u(allocBps),
                "|ta=", _u(totalA),
                "|mkts=", _u(mCount),
                " Rate this market's attractiveness for capital allocation on a scale 0-10000."
                " Higher=more attractive."
            )
        );
    }

    // ════════════════════════════════════════════════════════════════════════
    //  HELPERS
    // ════════════════════════════════════════════════════════════════════════

    /// @dev Integer-to-decimal-string conversion (same as VaultSentinel._u).
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
