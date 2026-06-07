// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./Interface/IMarketAdapter.sol";

// ── Backward-compatible interface kept for existing callers ──────────────────
interface IUtilizationOracle {
    event SuspiciousSpike(
        address indexed market,
        uint256 spot,
        uint256 twapVal,
        uint256 delta,
        uint256 timestamp
    );

    function update(address market) external;
    function twap(address market, uint256 window) external view returns (uint256);
    function effectiveUtil(address market) external returns (uint256 util, bool spikeDetected);
    function isValid(address market) external view returns (bool);
    function lastRecorded(address market) external view returns (uint256 timestamp, uint256 utilBps);
}

/**
 * @title  UtilizationOracle
 * @notice Manipulation-resistant utilization oracle using a TWAP accumulator
 *         identical in principle to Uniswap V2's price accumulator, adapted for
 *         utilization (0–10_000 bps) instead of price.
 *
 *  WHY THIS DESIGN
 *  ───────────────
 *  Spot utilization from an external lending market is flash-loan manipulable
 *  in a single block.  A 2-second flash spike at +2000 bps contributes only
 *  `2 / 1800 × 2000 ≈ 2 bps` to a 30-minute TWAP — making it economically
 *  infeasible to push the oracle above a threshold.  (D-8, I-11, T-13, T-14)
 *
 *  ACCUMULATOR PATTERN
 *  ───────────────────
 *  Each market tracks:
 *    accumulator += lastSpotUtil × elapsed_seconds
 *  After any window [t0, t1]:
 *    TWAP = (accumulator[t1] - accumulator[t0]) / (t1 - t0)
 *
 *  CHECKPOINT RING BUFFER
 *  ──────────────────────
 *  7 checkpoints written every 5 minutes give at most 30 minutes of look-back
 *  without unbounded storage.  twap() finds the oldest checkpoint at or before
 *  `block.timestamp - window` using `_findCheckpointAt`.
 *
 *  DUAL-TRACK FILTER (effectiveUtil)
 *  ──────────────────────────────────
 *  │ spot - twap │ > spikeToleranceBps  → SuspiciousSpike; return (twap, true)
 *  spot > criticalUtilBps AND twap > cautionUtilBps → real emergency; return (spot, false)
 *  otherwise → return (spot, false)
 *
 *  SECURITY
 *  ────────
 *  • Permissionless update() — no role required (AC-17).
 *  • Same-block calls: elapsed == 0 → no-op; accumulator not advanced.
 *  • Adapter return values clamped to 10_000 before any math.
 *  • isValid() false until TWAP_WINDOW of history: new markets get cautionUtilBps (T-16, AC-16).
 *  • effectiveUtil calls this.update() first so the caller always gets fresh data.
 *  • Owner (admin) can register/replace adapters per market.
 *
 *  Resolves: D-8.  Satisfies: I-11, G-8, P-9, R-10, AC-13..AC-18.
 */
contract UtilizationOracle is IUtilizationOracle {
    // ── Constants ─────────────────────────────────────────────────────────────

    /// @notice Number of checkpoint slots in the ring buffer per market.
    uint8 private constant CP_SIZE = 7;

    /// @notice Minimum interval between checkpoint writes (5 minutes).
    uint256 public constant CHECKPOINT_INTERVAL = 5 minutes;

    // ── Oracle parameters (set at construction, updatable by owner) ───────────

    /// @notice TWAP window length in seconds. Default 30 minutes.
    uint256 public TWAP_WINDOW;

    /// @notice Max bps delta between spot and TWAP before spike classification.
    ///         Default 1000 (10%).
    uint256 public spikeToleranceBps;

    /// @notice TWAP returned when insufficient history (conservative). Default 8000 (80%).
    uint256 public cautionUtilBps;

    /// @notice Above this, secondary rule may fire (use spot despite spike). Default 9500 (95%).
    uint256 public criticalUtilBps;

    // ── Ownership ─────────────────────────────────────────────────────────────

    address public owner;

    // ── Adapter registry ──────────────────────────────────────────────────────

    /// @notice Maps market address → IMarketAdapter address.
    ///         Set by owner (curator) during market registration.
    mapping(address => address) public adapters;

    // ── Per-market observation state ──────────────────────────────────────────

    struct MarketObservation {
        uint256 lastSpotUtil; // bps 0-10_000, spot at lastObservationTime
        uint256 lastObservationTime; // block.timestamp of last update()
        uint256 accumulator; // Σ(lastSpotUtil × elapsed) since initialization
        uint256 firstObservationTime; // block.timestamp of first update()
        bool initialized;
        uint256[7] checkpointAccumulator; // ring buffer of accumulator snapshots
        uint256[7] checkpointTimestamp; // ring buffer of timestamps
        uint8 checkpointHead; // next write position in ring buffer (wraps at CP_SIZE)
    }

    mapping(address => MarketObservation) private _observations;

    // ── Events ────────────────────────────────────────────────────────────────

    /// @notice Emitted on every successful update() call (elapsed > 0).
    event Updated(address indexed market, uint256 spotUtil, uint256 timestamp);

    /// @notice Emitted when an adapter is registered for a market.
    event AdapterRegistered(address indexed market, address indexed adapter);

    /// @notice Emitted when ownership is transferred.
    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);

    // ── Custom Errors ─────────────────────────────────────────────────────────

    error NotOwner();
    error ZeroAddress();
    error NoAdapter(address market);

    // ── Modifiers ─────────────────────────────────────────────────────────────

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    // ── Constructor ───────────────────────────────────────────────────────────

    /**
     * @param _twapWindow          TWAP window in seconds (default 30 minutes).
     * @param _spikeToleranceBps   Max acceptable spot-TWAP delta before spike (default 1000 = 10%).
     * @param _cautionUtilBps      Returned when history insufficient (default 8000 = 80%).
     * @param _criticalUtilBps     Threshold for secondary-rule (default 9500 = 95%).
     * @param _owner               Admin who can register adapters.
     */
    constructor(
        uint256 _twapWindow,
        uint256 _spikeToleranceBps,
        uint256 _cautionUtilBps,
        uint256 _criticalUtilBps,
        address _owner
    ) {
        if (_owner == address(0)) revert ZeroAddress();
        TWAP_WINDOW = _twapWindow;
        spikeToleranceBps = _spikeToleranceBps;
        cautionUtilBps = _cautionUtilBps;
        criticalUtilBps = _criticalUtilBps;
        owner = _owner;
    }

    // ════════════════════════════════════════════════════════════════════════
    //  ADMIN
    // ════════════════════════════════════════════════════════════════════════

    /**
     * @notice Register the adapter to use for a market.
     * @dev    Called by owner (curator) during submitAddMarket lifecycle.
     *         Setting adapter to address(0) disables the market in the oracle.
     * @param  market   The lending market address.
     * @param  adapter  Address implementing IMarketAdapter for this market.
     */
    function setAdapter(address market, address adapter) external onlyOwner {
        if (market == address(0)) revert ZeroAddress();
        adapters[market] = adapter;
        emit AdapterRegistered(market, adapter);
    }

    /**
     * @notice Update oracle parameters. Risk-increasing changes should be timelocked
     *         by the caller (curator).
     */
    function setParameters(
        uint256 _twapWindow,
        uint256 _spikeToleranceBps,
        uint256 _cautionUtilBps,
        uint256 _criticalUtilBps
    ) external onlyOwner {
        TWAP_WINDOW = _twapWindow;
        spikeToleranceBps = _spikeToleranceBps;
        cautionUtilBps = _cautionUtilBps;
        criticalUtilBps = _criticalUtilBps;
    }

    /**
     * @notice Transfer ownership of the oracle.
     */
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        address old = owner;
        owner = newOwner;
        emit OwnershipTransferred(old, newOwner);
    }

    // ════════════════════════════════════════════════════════════════════════
    //  PUBLIC — update (permissionless)
    // ════════════════════════════════════════════════════════════════════════

    /**
     * @notice Record the current spot utilization for `market` and advance the
     *         TWAP accumulator.  Permissionless — any address may call (AC-17).
     *
     *  LOGIC
     *  ─────
     *  1. Read spot via adapter, clamp to 10_000.
     *  2. If not yet initialized: set all fields, write first checkpoint, return.
     *  3. If same block (elapsed == 0): no-op (avoids zero-weight accumulation).
     *  4. Advance: accumulator += lastSpotUtil × elapsed.
     *  5. Write checkpoint if ≥ CHECKPOINT_INTERVAL since last checkpoint.
     *  6. Update lastSpotUtil and lastObservationTime.
     *  7. Emit Updated.
     *
     * @param  market  The lending market to update.
     */
    function update(address market) external override {
        address adapterAddr = adapters[market];
        if (adapterAddr == address(0)) revert NoAdapter(market);

        uint256 spotNow = IMarketAdapter(adapterAddr).utilizationBps(market);
        if (spotNow > 10_000) spotNow = 10_000; // clamp

        uint256 timeNow = block.timestamp;
        MarketObservation storage obs = _observations[market];

        if (!obs.initialized) {
            obs.lastSpotUtil = spotNow;
            obs.lastObservationTime = timeNow;
            obs.firstObservationTime = timeNow;
            obs.initialized = true;
            // Write first checkpoint at accumulator=0
            _writeCheckpoint(obs, 0, timeNow);
            emit Updated(market, spotNow, timeNow);
            return;
        }

        uint256 elapsed = timeNow - obs.lastObservationTime;
        if (elapsed == 0) return; // same block, no-op

        // Advance accumulator with the rate that was active since last observation
        obs.accumulator += obs.lastSpotUtil * elapsed;

        // Write a checkpoint if enough time has passed since the last one
        uint8 lastHead = (obs.checkpointHead + CP_SIZE - 1) % CP_SIZE;
        uint256 lastCpTime = obs.checkpointTimestamp[lastHead];
        if (timeNow - lastCpTime >= CHECKPOINT_INTERVAL) {
            _writeCheckpoint(obs, obs.accumulator, timeNow);
        }

        obs.lastSpotUtil = spotNow;
        obs.lastObservationTime = timeNow;

        emit Updated(market, spotNow, timeNow);
    }

    // ════════════════════════════════════════════════════════════════════════
    //  PUBLIC VIEW — twap
    // ════════════════════════════════════════════════════════════════════════

    /**
     * @notice Compute the time-weighted average utilization over `window` seconds.
     *
     *  Returns `cautionUtilBps` (conservative) when:
     *    • Oracle not yet initialized for this market.
     *    • Observation age < window (insufficient history).
     *
     *  Otherwise:
     *    1. Find the oldest checkpoint at or before `block.timestamp - window`.
     *    2. Project the accumulator to now using the most-recent spot.
     *    3. Return (accDelta) / timeDelta.
     *
     * @param  market  The lending market to query.
     * @param  window  Look-back window in seconds.
     * @return         TWAP utilization in bps (0–10_000).
     */
    function twap(address market, uint256 window) external view override returns (uint256) {
        MarketObservation storage obs = _observations[market];
        if (!obs.initialized) return cautionUtilBps;

        uint256 age = block.timestamp - obs.firstObservationTime;
        if (age < window) return cautionUtilBps;

        uint256 targetTime = block.timestamp - window;
        (uint256 cpAcc, uint256 cpTime) = _findCheckpointAt(obs, targetTime);

        // Project accumulator to current block (spot has been constant since lastObservationTime)
        uint256 elapsedSinceLast = block.timestamp - obs.lastObservationTime;
        uint256 currentAcc = obs.accumulator + (obs.lastSpotUtil * elapsedSinceLast);

        // Guard against cpAcc somehow being larger than currentAcc (shouldn't happen but safe)
        if (currentAcc < cpAcc) return obs.lastSpotUtil;

        uint256 accDelta = currentAcc - cpAcc;
        uint256 timeDelta = block.timestamp - cpTime;

        if (timeDelta == 0) return obs.lastSpotUtil;

        return accDelta / timeDelta;
    }

    // ════════════════════════════════════════════════════════════════════════
    //  PUBLIC — effectiveUtil (dual-track filter)
    // ════════════════════════════════════════════════════════════════════════

    /**
     * @notice Return the manipulation-resistant effective utilization for `market`.
     *
     *  This is the PRIMARY entry point for the sentinel and strategist.
     *  It calls `this.update(market)` first to ensure fresh data, then applies
     *  the dual-track filter:
     *
     *  │ Condition                                     │ util    │ spike │
     *  │ spot - twap > spikeToleranceBps              │ TWAP    │ true  │
     *  │ spot > criticalUtilBps AND twap > cautionUtil │ spot    │ false │ (real emergency)
     *  │ otherwise                                     │ spot    │ false │
     *
     * @param  market  The lending market to query.
     * @return util           Effective utilization in bps (0–10_000).
     * @return spikeDetected  True when flash-loan manipulation was detected.
     */
    function effectiveUtil(address market) external override returns (uint256 util, bool spikeDetected) {
        // Always update first — ensures the accumulator and lastSpotUtil are current
        // Using `this.update` (external call to self) matches the SDD spec exactly
        // and keeps the call visible in traces for easier debugging.
        this.update(market);

        address adapterAddr = adapters[market];
        if (adapterAddr == address(0)) revert NoAdapter(market);

        uint256 spot = IMarketAdapter(adapterAddr).utilizationBps(market);
        if (spot > 10_000) spot = 10_000;

        uint256 twapVal = this.twap(market, TWAP_WINDOW);

        uint256 delta = spot > twapVal ? spot - twapVal : 0;

        if (delta > spikeToleranceBps) {
            emit SuspiciousSpike(market, spot, twapVal, delta, block.timestamp);
            return (twapVal, true);
        }

        // Secondary rule: both spot and TWAP are elevated → real sustained emergency
        if (spot > criticalUtilBps && twapVal > cautionUtilBps) {
            return (spot, false);
        }

        return (spot, false);
    }

    // ════════════════════════════════════════════════════════════════════════
    //  PUBLIC VIEW — isValid
    // ════════════════════════════════════════════════════════════════════════

    /**
     * @notice Returns true when the oracle has accumulated at least TWAP_WINDOW
     *         of history for `market`.
     *
     *  New markets return false until seeded (§5.4.3 Stage 3).  During this
     *  period twap() returns cautionUtilBps (conservative).
     *
     * @param  market  The lending market to check.
     * @return         True if TWAP is reliable (age >= TWAP_WINDOW).
     */
    function isValid(address market) external view override returns (bool) {
        MarketObservation storage obs = _observations[market];
        if (!obs.initialized) return false;
        return (block.timestamp - obs.firstObservationTime) >= TWAP_WINDOW;
    }

    // ════════════════════════════════════════════════════════════════════════
    //  PUBLIC VIEW — lastRecorded (backward compatibility)
    // ════════════════════════════════════════════════════════════════════════

    /**
     * @notice Returns the most recent recorded (timestamp, spotUtil) for `market`.
     *         Returns (0, 0) when no observations exist.
     * @dev    Preserved for backward compatibility with existing callers and tests.
     */
    function lastRecorded(address market)
        external
        view
        override
        returns (uint256 timestamp, uint256 utilBps)
    {
        MarketObservation storage obs = _observations[market];
        if (!obs.initialized) return (0, 0);
        return (obs.lastObservationTime, obs.lastSpotUtil);
    }

    // ════════════════════════════════════════════════════════════════════════
    //  INTERNAL
    // ════════════════════════════════════════════════════════════════════════

    /**
     * @dev Write a new checkpoint at `obs.checkpointHead`, then advance the head.
     */
    function _writeCheckpoint(
        MarketObservation storage obs,
        uint256 accValue,
        uint256 timestamp
    ) internal {
        obs.checkpointAccumulator[obs.checkpointHead] = accValue;
        obs.checkpointTimestamp[obs.checkpointHead] = timestamp;
        obs.checkpointHead = uint8((uint256(obs.checkpointHead) + 1) % CP_SIZE);
    }

    /**
     * @dev Find the checkpoint with the largest timestamp that is still <= `targetTime`.
     *
     *      Iterates all CP_SIZE slots (constant-cost) and returns the best match.
     *      If no checkpoint is at or before targetTime, returns the oldest available
     *      checkpoint (graceful degradation).
     *
     *      Returns (accumulator, timestamp) of the chosen checkpoint.
     */
    function _findCheckpointAt(
        MarketObservation storage obs,
        uint256 targetTime
    ) internal view returns (uint256 cpAcc, uint256 cpTime) {
        // The write head points to the next slot to be written.
        // Valid slots are (head-1) down to (head-CP_SIZE), wrapping.
        // We scan all CP_SIZE slots and pick the best.

        cpAcc = 0;
        cpTime = 0;
        bool found = false;

        // Track the oldest valid checkpoint as fallback
        uint256 oldestTime = type(uint256).max;
        uint256 oldestAcc = 0;

        for (uint8 i = 0; i < CP_SIZE; ) {
            uint256 cTime = obs.checkpointTimestamp[i];
            uint256 cAcc = obs.checkpointAccumulator[i];

            if (cTime == 0) {
                // Uninitialized slot — skip
                unchecked { ++i; }
                continue;
            }

            // Track oldest for fallback
            if (cTime < oldestTime) {
                oldestTime = cTime;
                oldestAcc = cAcc;
            }

            // Best checkpoint at or before targetTime (pick most-recent one <= targetTime)
            if (cTime <= targetTime) {
                if (!found || cTime > cpTime) {
                    cpTime = cTime;
                    cpAcc = cAcc;
                    found = true;
                }
            }

            unchecked { ++i; }
        }

        if (!found) {
            // Fallback: use oldest checkpoint available (twap will cover a longer window)
            cpTime = oldestTime;
            cpAcc = oldestAcc;
        }
    }
}
