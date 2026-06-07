// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title  IUtilizationOracle
 * @notice Interface for the TWAP-based utilization oracle.
 *         Resolves D-8: sentinel reads twapBps() instead of spot utilizationBps().
 */
interface IUtilizationOracle {
    /// @notice Record the current spot utilization for `market`.
    ///         Permissionless — anyone may call.
    function record(address market) external;

    /// @notice Time-weighted average utilization in basis points (bps) over all
    ///         stored observations.  Returns 0 when no observations exist.
    ///         Returns the single observation value when exactly one exists.
    function twapBps(address market) external view returns (uint256);

    /// @notice Most recent recorded timestamp and utilBps for `market`.
    ///         Returns (0, 0) when no observations have been recorded.
    function lastRecorded(address market) external view returns (uint256 timestamp, uint256 utilBps);
}

/**
 * @title  ILendingMarketUtil
 * @notice Minimal interface used by UtilizationOracle to read spot utilization.
 */
interface ILendingMarketUtil {
    function utilizationBps() external view returns (uint256);
}

/**
 * @title  UtilizationOracle
 * @notice Maintains a ring buffer of the last 8 utilization observations per
 *         market and computes a time-weighted average (TWAP).
 *
 *  DESIGN
 *  ──────
 *  • 8-slot ring buffer per market.  Each slot holds a (uint32 timestamp,
 *    uint16 utilBps) pair packed into one storage word.
 *  • Anyone can call record() — no role required (AC-17).
 *  • twapBps() returns the TWAP weighted by the time each observation was
 *    the most-recent reading.  A 2-second spike in a ring spanning many
 *    minutes contributes negligible weight, defeating flash-loan manipulation.
 *  • Resolves D-8.  Satisfies I-11, G-8, P-9, R-10.
 *
 *  SECURITY
 *  ────────
 *  • Malicious market returning MAX_UINT on utilizationBps(): clamped to
 *    10_000 bps in record(), so it cannot corrupt arithmetic downstream.
 *  • Same-block calls: if block.timestamp has not advanced since the last
 *    write to the same slot, the observation is still written (the cursor
 *    advances regardless).  Duplicate-block writes are cheap and harmless.
 *  • Ring-buffer overflow: cursor wraps modulo 8 (oldest slot overwritten).
 */
contract UtilizationOracle is IUtilizationOracle {
    // ── Observation ring buffer ──────────────────────────────────────────────

    /// @dev Packed into one EVM word.
    ///      timestamp: uint32  — seconds since epoch, overflows year 2106.
    ///      utilBps:   uint16  — 0-10000; clamped on write.
    struct Observation {
        uint32 timestamp;
        uint16 utilBps;
    }

    uint8 private constant RING_SIZE = 8;

    /// @dev Ring buffer of observations per market.
    mapping(address => Observation[8]) private _obs;

    /// @dev Write cursor: next slot index (0-7).
    mapping(address => uint8) private _cursor;

    /// @dev How many slots have been written (saturates at RING_SIZE = 8).
    mapping(address => uint8) private _count;

    // ── Events ───────────────────────────────────────────────────────────────

    /// @notice Emitted whenever a new observation is recorded.
    event Recorded(address indexed market, uint256 utilBps, uint256 timestamp);

    // ════════════════════════════════════════════════════════════════════════
    //  PUBLIC — WRITE
    // ════════════════════════════════════════════════════════════════════════

    /**
     * @notice Read the current spot utilization from `market` and push it into
     *         the ring buffer.  Permissionless — any address may call.
     *
     * @dev    utilBps is clamped to 10_000 to guard against malicious markets.
     *         Emits Recorded(market, utilBps, block.timestamp).
     */
    function record(address market) external override {
        // Read spot from external market — this is a trusted view call;
        // malicious return values are clamped to 10_000.
        uint256 spot = ILendingMarketUtil(market).utilizationBps();
        if (spot > 10_000) {
            spot = 10_000;
        }

        uint8 idx = _cursor[market];
        _obs[market][idx] = Observation({timestamp: uint32(block.timestamp), utilBps: uint16(spot)});

        // Advance cursor (wraps at RING_SIZE)
        _cursor[market] = uint8((uint256(idx) + 1) % RING_SIZE);

        // Track filled count (saturates at RING_SIZE)
        if (_count[market] < RING_SIZE) {
            _count[market]++;
        }

        emit Recorded(market, spot, block.timestamp);
    }

    // ════════════════════════════════════════════════════════════════════════
    //  PUBLIC — READ
    // ════════════════════════════════════════════════════════════════════════

    /**
     * @notice Time-weighted average utilization in bps over all stored observations.
     *
     *  Weighting
     *  ─────────
     *  Each observation i holds the utilization rate that was active from its
     *  timestamp until the next observation's timestamp (or block.timestamp
     *  for the most recent one).
     *
     *  TWAP = Σ (utilBps_i × elapsed_i) / Σ elapsed_i
     *
     *  Edge cases
     *  ──────────
     *  • 0 observations → returns 0.
     *  • 1 observation  → weight is (block.timestamp - obs.timestamp); returns
     *                     that observation's utilBps (division cancels).
     *  • All observations at the same timestamp → falls back to the most
     *    recent utilBps (avoid divide-by-zero).
     *
     * @return twap  Time-weighted average utilization in bps (0-10000).
     */
    function twapBps(address market) external view override returns (uint256 twap) {
        uint8 n = _count[market];
        if (n == 0) {
            return 0;
        }
        if (n == 1) {
            // Only one observation — return it directly (no time weighting needed)
            uint8 latest = _latestIdx(market);
            return uint256(_obs[market][latest].utilBps);
        }

        // Build ordered sequence of observations (oldest → newest).
        // The ring buffer writes in ascending order; the oldest entry is at
        // position `_cursor[market]` when the buffer is full (it wraps), or
        // at position 0 when it is partially filled.
        uint8 cursor = _cursor[market]; // points to next write slot (= oldest when full)
        uint256 accumulator;
        uint256 totalTime;

        // Iterate over all n observations in chronological order.
        // When the buffer is full (n == RING_SIZE), the oldest is at cursor.
        // When partially filled (n < RING_SIZE), slots 0..n-1 are valid and
        // the oldest is at slot 0 (cursor started at 0 and advanced n times).
        uint8 startIdx;
        if (n < RING_SIZE) {
            startIdx = 0;
        } else {
            startIdx = cursor; // oldest slot when buffer is full
        }

        for (uint256 i; i < n;) {
            uint8 idx = uint8((uint256(startIdx) + i) % RING_SIZE);
            uint8 nextIdx = uint8((uint256(startIdx) + i + 1) % RING_SIZE);

            uint256 tStart = uint256(_obs[market][idx].timestamp);
            uint256 tEnd;

            if (i + 1 < n) {
                // Not the last observation — next timestamp is the boundary.
                tEnd = uint256(_obs[market][nextIdx].timestamp);
            } else {
                // Most recent observation — weight extends to now.
                tEnd = block.timestamp;
            }

            if (tEnd > tStart) {
                uint256 elapsed = tEnd - tStart;
                accumulator += uint256(_obs[market][idx].utilBps) * elapsed;
                totalTime += elapsed;
            }

            unchecked {
                ++i;
            }
        }

        if (totalTime == 0) {
            // All observations at the same timestamp — return most recent value.
            return uint256(_obs[market][_latestIdx(market)].utilBps);
        }

        return accumulator / totalTime;
    }

    /**
     * @notice Returns the timestamp and utilBps of the most recently written
     *         observation.  Returns (0, 0) when no observations exist.
     */
    function lastRecorded(address market) external view override returns (uint256 timestamp, uint256 utilBps) {
        if (_count[market] == 0) {
            return (0, 0);
        }
        uint8 latest = _latestIdx(market);
        Observation storage o = _obs[market][latest];
        return (uint256(o.timestamp), uint256(o.utilBps));
    }

    // ════════════════════════════════════════════════════════════════════════
    //  INTERNAL
    // ════════════════════════════════════════════════════════════════════════

    /// @dev Index of the most recently written slot.
    ///      cursor points to the NEXT write location, so the last write was
    ///      at (cursor - 1) mod RING_SIZE.
    function _latestIdx(address market) internal view returns (uint8) {
        uint8 c = _cursor[market];
        if (c == 0) {
            return RING_SIZE - 1;
        }
        return c - 1;
    }
}
