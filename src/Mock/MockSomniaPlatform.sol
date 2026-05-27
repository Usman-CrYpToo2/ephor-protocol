// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../Interface/ISomnia.sol";

/**
 * @title  MockSomniaPlatform
 * @notice Test double for the Somnia Agent Platform.
 *
 *         Mirrors the real IAgentRequester interface exactly:
 *         - createRequest() stores requests and assigns incrementing IDs
 *         - simulateCallback() lets tests inject any verdict string
 *         - simulateTimeout() tests the fail-safe CAUTION path
 *
 *         The callback function called on VaultSentinel is handleResponse()
 *         (matching the exact name from docs.somnia.network).
 */
contract MockSomniaPlatform {

    uint256 public nextRequestId = 1;
    uint256 public minimumDeposit = 0.01 ether;

    struct StoredReq {
        address callbackAddress;
        bytes4  callbackSelector;
        bytes   payload;
        bool    exists;
    }
    mapping(uint256 => StoredReq) public requests;

    event RequestCreated(
        uint256 indexed requestId,
        uint256 indexed agentId,
        uint256 perAgentBudget,
        bytes   payload,
        address[] subcommittee
    );

    // ── IAgentRequester ──────────────────────────────────────────────────────

    function createRequest(
        uint256      agentId,
        address      callbackAddress,
        bytes4       callbackSelector,
        bytes calldata payload
    ) external payable returns (uint256 requestId) {
        require(msg.value >= minimumDeposit, "MockPlatform: insufficient deposit");
        requestId = nextRequestId++;
        requests[requestId] = StoredReq({
            callbackAddress:  callbackAddress,
            callbackSelector: callbackSelector,
            payload:          payload,
            exists:           true
        });
        address[] memory sub = new address[](0);
        emit RequestCreated(requestId, agentId, msg.value / 3, payload, sub);
    }

    function getRequestDeposit() external view returns (uint256) {
        return minimumDeposit;
    }

    // ── Test helpers ─────────────────────────────────────────────────────────

    /**
     * @notice Simulate the platform delivering a verdict to VaultSentinel.
     * @param requestId  ID from createRequest().
     * @param verdict    "SAFE", "CAUTION", or "CRITICAL".
     */
    function simulateCallback(uint256 requestId, string calldata verdict) external {
        StoredReq storage req = requests[requestId];
        require(req.exists, "MockPlatform: no such request");

        // Build one successful Response
        Response[] memory resps = new Response[](1);
        resps[0] = Response({
            validator:     address(this),
            result:        abi.encode(verdict),
            status:        ResponseStatus.Success,
            receipt:       uint256(keccak256(bytes(verdict))),
            timestamp:     block.timestamp,
            executionCost: 0
        });

        // Minimal Request struct
        address[]  memory sub  = new address[](1);
        sub[0] = address(this);
        Response[] memory empty = new Response[](0);

        Request memory fullReq = Request({
            id:               requestId,
            requester:        msg.sender,
            callbackAddress:  req.callbackAddress,
            callbackSelector: req.callbackSelector,
            subcommittee:     sub,
            responses:        empty,
            responseCount:    1,
            failureCount:     0,
            threshold:        2,
            createdAt:        block.timestamp - 10,
            deadline:         block.timestamp + 60,
            status:           ResponseStatus.Success,
            consensusType:    ConsensusType.Majority,
            remainingBudget:  0,
            perAgentBudget:   0
        });

        (bool ok, bytes memory err) = req.callbackAddress.call(
            abi.encodeWithSelector(
                req.callbackSelector,
                requestId,
                resps,
                ResponseStatus.Success,
                fullReq
            )
        );
        if (!ok) {
            if (err.length > 0) assembly { revert(add(err, 32), mload(err)) }
            revert("MockPlatform: callback reverted");
        }
        delete requests[requestId];
    }

    /**
     * @notice Simulate a timed-out request (tests the fail-safe CAUTION path).
     */
    function simulateTimeout(uint256 requestId) external {
        StoredReq storage req = requests[requestId];
        require(req.exists, "MockPlatform: no such request");

        Response[] memory empty = new Response[](0);
        address[]  memory sub   = new address[](0);

        Request memory fullReq = Request({
            id:               requestId,
            requester:        msg.sender,
            callbackAddress:  req.callbackAddress,
            callbackSelector: req.callbackSelector,
            subcommittee:     sub,
            responses:        empty,
            responseCount:    0,
            failureCount:     3,
            threshold:        2,
            createdAt:        block.timestamp - 120,
            deadline:         block.timestamp - 1,
            status:           ResponseStatus.TimedOut,
            consensusType:    ConsensusType.Majority,
            remainingBudget:  0,
            perAgentBudget:   0
        });

        (bool ok,) = req.callbackAddress.call(
            abi.encodeWithSelector(
                req.callbackSelector,
                requestId,
                empty,
                ResponseStatus.TimedOut,
                fullReq
            )
        );
        require(ok, "MockPlatform: timeout callback failed");
        delete requests[requestId];
    }

    function setMinimumDeposit(uint256 amount) external { minimumDeposit = amount; }
    receive() external payable {}
}
