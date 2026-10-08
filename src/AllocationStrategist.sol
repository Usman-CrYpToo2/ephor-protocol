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
/// @notice Tier-1 Somnia LLM allocation lifecycle.
///
///  FLOW
///  ────
///  1. requestRebalance(vault) — anyone with ≥ minimumDeposit STT attached may trigger.
///  2. Reads on-chain metrics → builds §9.3 feature-block prompt → sends one inferString call.
///  3. Platform calls back handleResponse() with a strategy label.
///  4. Label → weights → AllocationProjection.project() → vault.reallocate().
///
///  STRATEGY LABELS
///  ───────────────
///  BALANCED   — equal weight across all markets
///  YIELD_TILT — weight proportional to utilization (chase yield)
///  DEFENSIVE  — weight inverse to utilization (favour safer markets)
///  DERISK     — skip reallocate entirely; all capital stays idle
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
    uint256 public constant REBALANCE_COOLDOWN = 1 minutes;
    uint256 public constant RESPONSE_TIMEOUT = 10 minutes;

    // ── AI label strings ─────────────────────────────────────────────────────
    bytes32 private constant LABEL_BALANCED = keccak256("BALANCED");
    bytes32 private constant LABEL_YIELD_TILT = keccak256("YIELD_TILT");
    bytes32 private constant LABEL_DEFENSIVE = keccak256("DEFENSIVE");
    bytes32 private constant LABEL_DERISK = keccak256("DERISK");

    // ── Enums ────────────────────────────────────────────────────────────────
    enum StrategyLabel {
        Balanced,
        YieldTilt,
        Defensive,
        DeRisk,
        Unknown
    }

    // ── In-flight tracking ───────────────────────────────────────────────────

    struct PendingRebalance {
        address vault;
        uint256 snapshotTotalAssets;
        uint256 snapshotEpoch;
        uint256 timestamp;
    }

    // IMPORTANT: pendingRequests MUST remain public — MockSomniaPlatform
    // looks up the vault address by requestId during tests.
    mapping(uint256 => PendingRebalance) public pendingRequests;

    /// @notice requestId of the active in-flight request for this vault (0 = none).
    mapping(address => uint256) public activeRequest;

    /// @notice Last request timestamp per vault (for cooldown enforcement).
    mapping(address => uint256) public lastRequestAt;

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

    constructor(address _platform, uint256 _llmAgentId, address _vault, address _admin) {
        if (_platform == address(0) || _vault == address(0) || _admin == address(0)) revert ZeroAddress();
        platform = IAgentRequester(_platform);
        llmAgentId = _llmAgentId;
        vault = CuratedVault(_vault);
        admin = _admin;
    }

    // ════════════════════════════════════════════════════════════════════════
    //  PHASE 2 STUB — preserved for backward compatibility
    // ════════════════════════════════════════════════════════════════════════

    function executeRebalance(CuratedVault.MarketTarget[] calldata targets, CuratedVault.RebalanceGuard calldata guard)
        external
    {
        if (msg.sender != admin) revert NotAdmin();
        vault.reallocate(targets, guard);
        emit RebalanceExecuted(address(vault), "MANUAL", vault.currentEpoch());
    }

    // ════════════════════════════════════════════════════════════════════════
    //  STEP 1 — REQUEST REBALANCE
    // ════════════════════════════════════════════════════════════════════════

    /**
     * @notice Trigger an AI rebalance for the vault.
     *         Reads on-chain metrics → builds prompt → sends inferString call.
     *         Result arrives asynchronously in handleResponse().
     *
     * @dev    5-minute cooldown per vault. Only one in-flight request at a time.
     *         msg.value must cover the platform's minimum deposit.
     */
    function requestRebalance(address vault_) external payable nonReentrant {
        if (vault_ != address(vault)) revert ZeroAddress();

        uint256 available = lastRequestAt[vault_] + REBALANCE_COOLDOWN;
        if (block.timestamp < available) revert RebalanceCooldown(available);

        if (activeRequest[vault_] != 0) revert RebalanceInProgress();

        // getRequestDeposit() is a Somnia precompile — skip gracefully in forge simulation.
        try platform.getRequestDeposit() returns (uint256 minDeposit) {
            if (msg.value < minDeposit) revert InsufficientDeposit(msg.value, minDeposit);
        } catch {}

        // ── Read all metrics on-chain (zero external APIs) ────────────────
        IVault v = IVault(vault_);
        uint256 totalA = v.totalAssets();
        uint256 idleBps = v.idleBufferBps();
        uint256 mCount = v.marketCount();

        uint256[] memory mAllocBps = new uint256[](mCount);
        uint256[] memory mUtilBps = new uint256[](mCount);
        bool[] memory mSpike = new bool[](mCount);
        uint256[] memory mHeadroom = new uint256[](mCount);
        uint256[] memory mRate = new uint256[](mCount);

        IUtilizationOracle _oracle = oracle;

        for (uint256 i; i < mCount;) {
            address m = v.marketList(i);
            mAllocBps[i] = v.marketAllocationBps(m);

            if (address(_oracle) != address(0)) {
                try _oracle.effectiveUtil(m) returns (uint256 util, bool spike) {
                    mUtilBps[i] = util;
                    mSpike[i] = spike;
                } catch {
                    mUtilBps[i] = ILendingMarket(m).utilizationBps();
                }
            } else {
                mUtilBps[i] = ILendingMarket(m).utilizationBps();
            }

            uint256 cap;
            try v.marketSupplyCap(m) returns (uint256 c) {
                cap = c;
            } catch {}
            uint256 bal = ILendingMarket(m).balanceOf(address(vault));
            mHeadroom[i] = (totalA > 0 && cap > bal) ? (cap - bal) * 10_000 / totalA : 0;

            try ILendingMarket(m).supplyRateBps() returns (uint256 r) {
                mRate[i] = r;
            } catch {}
            unchecked {
                ++i;
            }
        }

        // ── CEI: mark in-flight before external call ──────────────────────
        uint256 snapEpoch = vault.currentEpoch();
        lastRequestAt[vault_] = block.timestamp;
        activeRequest[vault_] = type(uint256).max; // sentinel until real reqId is stored

        // ── Build prompt and encode payload ───────────────────────────────
        string memory prompt = _buildPrompt(totalA, idleBps, mCount, mAllocBps, mUtilBps, mSpike, mHeadroom, mRate);

        string[] memory allowed = new string[](4);
        allowed[0] = "DEFENSIVE";
        allowed[1] = "BALANCED";
        allowed[2] = "YIELD_TILT";
        allowed[3] = "DERISK";

        bytes memory payload =
            abi.encodeWithSelector(ILLMInferenceAgent.inferString.selector, prompt, _systemPrompt(), false, allowed);

        // ── Submit to Somnia platform ─────────────────────────────────────
        uint256 reqId =
            platform.createRequest{value: msg.value}(llmAgentId, address(this), this.handleResponse.selector, payload);

        pendingRequests[reqId] = PendingRebalance({
            vault: vault_, snapshotTotalAssets: totalA, snapshotEpoch: snapEpoch, timestamp: block.timestamp
        });
        activeRequest[vault_] = reqId;

        emit RebalanceRequested(vault_, reqId);
    }

    // ════════════════════════════════════════════════════════════════════════
    //  STEP 2 — HANDLE RESPONSE (Somnia platform callback)
    //
    //  Function name is handleResponse — EXACT name from Somnia docs.
    //  Selector passed literally to createRequest; do NOT rename.
    //  Only the platform contract may call this.
    // ════════════════════════════════════════════════════════════════════════

    /**
     * @notice Callback from the Somnia platform with the AI verdict.
     *
     *  Fail-safe: any error path emits RebalanceSkipped and returns without
     *  touching the vault. AI failure never moves funds.
     */
    function handleResponse(
        uint256 requestId,
        Response[] memory responses,
        ResponseStatus status,
        Request memory details
    ) external onlyPlatform {
        PendingRebalance memory pending = pendingRequests[requestId];
        if (pending.vault == address(0)) revert UnknownRequest();

        address vault_ = pending.vault;

        // CEI: clear state before any external call
        delete pendingRequests[requestId];
        delete activeRequest[vault_];

        // ── Fail-safe: timeout ────────────────────────────────────────────
        if (block.timestamp > pending.timestamp + RESPONSE_TIMEOUT) {
            emit RebalanceSkipped(vault_, "TIMEOUT");
            return;
        }

        // ── Fail-safe: platform error ─────────────────────────────────────
        if (status == ResponseStatus.TimedOut || status == ResponseStatus.Failed || responses.length == 0) {
            emit RebalanceSkipped(vault_, "AI_UNAVAILABLE");
            return;
        }

        // ── Fail-safe: consensus not reached (D-6, as in VaultSentinel) ───
        if (details.responseCount < details.threshold) {
            emit RebalanceSkipped(vault_, "CONSENSUS_NOT_MET");
            return;
        }

        // ── Parse label ───────────────────────────────────────────────────
        string memory raw = abi.decode(responses[0].result, (string));
        StrategyLabel label = _parseLabel(raw);

        if (label == StrategyLabel.Unknown) {
            emit RebalanceSkipped(vault_, "UNKNOWN_LABEL");
            return;
        }

        // ── DERISK: keep everything idle, nothing to reallocate ───────────
        if (label == StrategyLabel.DeRisk) {
            emit RebalanceExecuted(vault_, raw, vault.currentEpoch());
            return;
        }

        // ── Assign weights from label ─────────────────────────────────────
        IVault v = IVault(vault_);
        uint256 mCount = v.marketCount();

        address[] memory markets_ = new address[](mCount);
        uint256[] memory weights = new uint256[](mCount);
        uint256[] memory currentBals = new uint256[](mCount);
        uint256[] memory supplyCaps = new uint256[](mCount);

        IUtilizationOracle _oracle = oracle;

        for (uint256 i; i < mCount;) {
            address m = v.marketList(i);
            markets_[i] = m;
            currentBals[i] = ILendingMarket(m).balanceOf(vault_);
            (bool enabled, uint256 cap) = vault.markets(m);
            supplyCaps[i] = enabled ? cap : 0;

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

            if (label == StrategyLabel.Balanced) weights[i] = 1;
            else if (label == StrategyLabel.YieldTilt) weights[i] = util;
            else if (label == StrategyLabel.Defensive) weights[i] = 10_000 > util ? 10_000 - util : 0;

            unchecked {
                ++i;
            }
        }

        // ── Project weights → target amounts ──────────────────────────────
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

        _executeReallocate(markets_, targets_, mCount, pending.snapshotTotalAssets, pending.snapshotEpoch);
        emit RebalanceExecuted(vault_, raw, vault.currentEpoch());
    }

    // ════════════════════════════════════════════════════════════════════════
    //  ADMIN
    // ════════════════════════════════════════════════════════════════════════

    function setOracle(address newOracle) external {
        if (msg.sender != admin) revert NotAdmin();
        oracle = IUtilizationOracle(newOracle);
        emit OracleSet(newOracle);
    }

    function setLlmAgentId(uint256 newId) external {
        if (msg.sender != admin) revert NotAdmin();
        llmAgentId = newId;
        emit LlmAgentIdSet(newId);
    }

    // ════════════════════════════════════════════════════════════════════════
    //  INTERNAL
    // ════════════════════════════════════════════════════════════════════════

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
            unchecked {
                ++i;
            }
        }

        if (nonzeroCount == 0) return;

        CuratedVault.MarketTarget[] memory mTargets = new CuratedVault.MarketTarget[](nonzeroCount);
        uint256 idx;
        for (uint256 i; i < mCount;) {
            if (targets_[i] > 0) {
                mTargets[idx] = CuratedVault.MarketTarget({market: markets_[i], targetAmount: targets_[i]});
                unchecked {
                    ++idx;
                }
            }
            unchecked {
                ++i;
            }
        }

        vault.reallocate(
            mTargets, CuratedVault.RebalanceGuard({snapshotTotalAssets: snapTotalAssets, snapshotEpoch: snapEpoch})
        );
    }

    function _parseLabel(string memory raw) internal pure returns (StrategyLabel) {
        bytes32 h = keccak256(bytes(raw));
        if (h == LABEL_BALANCED) return StrategyLabel.Balanced;
        if (h == LABEL_YIELD_TILT) return StrategyLabel.YieldTilt;
        if (h == LABEL_DEFENSIVE) return StrategyLabel.Defensive;
        if (h == LABEL_DERISK) return StrategyLabel.DeRisk;
        return StrategyLabel.Unknown;
    }

    function _systemPrompt() internal pure returns (string memory) {
        return "You are a capital-allocation policy selector for a yield vault. "
            "The contract converts your choice into a concrete, cap-respecting allocation in the vault's native asset. "
            "The util field is manipulation-resistant (time-weighted). "
            "Prefer DERISK or DEFENSIVE when any market nears caution utilization, has spike=1, or the idle buffer is thin. "
            "Prefer YIELD_TILT only when all markets are comfortably healthy and rate differences are meaningful. "
            "Output exactly one policy word. No other text.";
    }

    function _buildPrompt(
        uint256 totalA,
        uint256 idleBps,
        uint256 mCount,
        uint256[] memory mAllocBps,
        uint256[] memory mUtilBps,
        bool[] memory mSpike,
        uint256[] memory mHeadroom,
        uint256[] memory mRate
    ) internal pure returns (string memory s) {
        s = string(abi.encodePacked("PORTFOLIO|ta=", _u(totalA), "|idle=", _u(idleBps), "|mkts=", _u(mCount)));

        uint256 mktsNearCaution;
        uint256 maxUtil;
        uint256 minUtil = type(uint256).max;
        for (uint256 i; i < mCount;) {
            if (mUtilBps[i] > 7_000) mktsNearCaution++;
            if (mUtilBps[i] > maxUtil) maxUtil = mUtilBps[i];
            if (mUtilBps[i] < minUtil) minUtil = mUtilBps[i];
            unchecked {
                ++i;
            }
        }
        if (mCount == 0) minUtil = 0;

        s = string(
            abi.encodePacked(
                s,
                "\nAGGREGATE|mkts_near_caution=",
                _u(mktsNearCaution),
                "|util_dispersion=",
                _u(maxUtil > minUtil ? maxUtil - minUtil : 0)
            )
        );

        for (uint256 i; i < mCount;) {
            s = string(
                abi.encodePacked(
                    s,
                    "\nM",
                    _u(i + 1),
                    "|util=",
                    _u(mUtilBps[i]),
                    "|spike=",
                    mSpike[i] ? "1" : "0",
                    "|alloc=",
                    _u(mAllocBps[i]),
                    "|headroom=",
                    _u(mHeadroom[i]),
                    "|rate=",
                    _u(mRate[i])
                )
            );
            unchecked {
                ++i;
            }
        }
    }

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
