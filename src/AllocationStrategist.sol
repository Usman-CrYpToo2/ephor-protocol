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
/// @notice Phase 3 — full Tier-1 Somnia LLM lifecycle.
///
///  FLOW
///  ────
///  1. requestRebalance(vault) — anyone with ≥ minimumDeposit STT attached may trigger.
///  2. Reads five on-chain metrics from the vault (no external APIs).
///  3. Encodes them into a plain-English prompt and sends to Somnia LLM agent.
///     allowedValues = ["DEFENSIVE", "BALANCED", "YIELD_TILT", "DERISK"]
///  4. Platform calls back handleResponse() with the label.
///  5. Label → weights → AllocationProjection.project() → vault.reallocate().
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

    // ── AI label strings ─────────────────────────────────────────────────────
    bytes32 private constant LABEL_BALANCED   = keccak256("BALANCED");
    bytes32 private constant LABEL_YIELD_TILT = keccak256("YIELD_TILT");
    bytes32 private constant LABEL_DEFENSIVE  = keccak256("DEFENSIVE");
    bytes32 private constant LABEL_DERISK     = keccak256("DERISK");

    // ── Per-vault in-flight tracking ─────────────────────────────────────────
    struct PendingRebalance {
        address vault;
        uint256 snapshotTotalAssets;
        uint256 snapshotEpoch;
        uint256 timestamp;
    }

    // IMPORTANT: pendingRequests MUST remain public — MockSomniaPlatform
    // looks up the vault address by requestId during tests.
    mapping(uint256 => PendingRebalance) public pendingRequests;

    /// @notice requestId of the active in-flight request for each vault (0 = none).
    mapping(address => uint256) public activeRequest;

    /// @notice Last request timestamp per vault (for cooldown enforcement).
    mapping(address => uint256) public lastRequestAt;

    // ── Enums ────────────────────────────────────────────────────────────────
    enum StrategyLabel { Balanced, YieldTilt, Defensive, DeRisk, Unknown }

    // ── Events ───────────────────────────────────────────────────────────────
    event RebalanceRequested(address indexed vault_, uint256 indexed requestId);
    event RebalanceExecuted(address indexed vault_, string label, uint256 epoch);
    event RebalanceSkipped(address indexed vault_, string reason);
    event OracleSet(address indexed newOracle);
    event LlmAgentIdSet(uint256 newId);

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
     * @dev    msg.value must cover the platform's minimum deposit.
     *         5-minute cooldown per vault prevents DoS.
     *         Only one in-flight request per vault at a time.
     */
    function requestRebalance(address vault_) external payable nonReentrant {
        if (vault_ != address(vault)) revert ZeroAddress(); // only manages its own vault

        // ── Cooldown check ────────────────────────────────────────────────
        uint256 available = lastRequestAt[vault_] + REBALANCE_COOLDOWN;
        if (block.timestamp < available) revert RebalanceCooldown(available);

        // ── In-flight check ───────────────────────────────────────────────
        if (activeRequest[vault_] != 0) revert RebalanceInProgress();

        // ── Deposit check ─────────────────────────────────────────────────
        uint256 minDeposit = platform.getRequestDeposit();
        if (msg.value < minDeposit) revert InsufficientDeposit(msg.value, minDeposit);

        // ── Snapshot vault metrics (all on-chain, no external APIs) ──────
        IVault v = IVault(vault_);
        uint256 totalA  = v.totalAssets();
        uint256 idleBps = v.idleBufferBps();
        uint256 mCount  = v.marketCount();

        uint256[] memory mAllocBps = new uint256[](mCount);
        uint256[] memory mUtilBps  = new uint256[](mCount);

        IUtilizationOracle _oracle = oracle;
        for (uint256 i; i < mCount;) {
            address m = v.marketList(i);
            mAllocBps[i] = v.marketAllocationBps(m);

            if (address(_oracle) != address(0)) {
                // Use oracle for manipulation-resistant utilization
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

        // ── CEI: update state before external call ────────────────────────
        // Set activeRequest to a sentinel (type(uint256).max) to block re-entrancy
        // before the external createRequest call. Updated to real reqId after.
        uint256 snapEpoch = vault.currentEpoch();
        lastRequestAt[vault_] = block.timestamp;
        activeRequest[vault_] = type(uint256).max; // sentinel: blocks re-entrancy

        // ── Send to Somnia platform ───────────────────────────────────────
        uint256 reqId = platform.createRequest{value: msg.value}(
            llmAgentId,
            address(this),
            this.handleResponse.selector, // exact name — must not be renamed
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

    // ════════════════════════════════════════════════════════════════════════
    //  PHASE 3 — STEP 2: HANDLE RESPONSE (Somnia platform callback)
    //
    //  Function name is handleResponse — EXACT name from real Somnia docs.
    //  Selector: this.handleResponse.selector passed to createRequest().
    //  Only the platform contract may call this.
    // ════════════════════════════════════════════════════════════════════════

    /**
     * @notice Callback invoked by the Somnia platform with the AI allocation label.
     *
     *  Fail-safe: timeout / failure / unknown label → emit RebalanceSkipped, no movement.
     *  Happy path: decode label → map to weights → AllocationProjection.project() →
     *              vault.reallocate().
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
        PendingRebalance memory pending = pendingRequests[requestId];
        if (pending.vault == address(0)) revert UnknownRequest();

        address vault_ = pending.vault;

        // ── CEI: clear pending state BEFORE any external calls ────────────
        delete pendingRequests[requestId];
        delete activeRequest[vault_];

        // Suppress unused-variable warning for details (reserved for future D-6-style checks)
        details;

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
                weights[i] = util; // higher util → more weight
            } else if (label == StrategyLabel.Defensive) {
                weights[i] = 10_000 > util ? 10_000 - util : 0; // lower util → more weight
            }
            // DeRisk handled above; Unknown handled above

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

        // ── Build MarketTarget[] — only include nonzero targets (I-5 requires nonzero) ─
        uint256 nonzeroCount;
        for (uint256 i; i < mCount;) {
            if (targets_[i] > 0) nonzeroCount++;
            unchecked { ++i; }
        }

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

        // ── Staleness guard (using snapshot from requestRebalance) ─────────
        CuratedVault.RebalanceGuard memory guard = CuratedVault.RebalanceGuard({
            snapshotTotalAssets: pending.snapshotTotalAssets,
            snapshotEpoch:       pending.snapshotEpoch
        });

        // ── Execute reallocate (only if there are nonzero targets) ─────────
        if (nonzeroCount > 0) {
            vault.reallocate(mTargets, guard);
        }

        emit RebalanceExecuted(vault_, raw, vault.currentEpoch());
    }

    // ════════════════════════════════════════════════════════════════════════
    //  ADMIN
    // ════════════════════════════════════════════════════════════════════════

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
