// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ============================================================
//  ISomnia.sol
//  Exact interfaces from docs.somnia.network/agents/invoking-agents/from-solidity
//
//  Testnet  (chain 50312): 0x037Bb9C718F3f7fe5eCBDB0b600D607b52706776
//  Mainnet  (chain 5031):  0x5E5205CF39E766118C01636bED000A54D93163E6
// ============================================================

// ── NOTE: ConsensusType EXISTS in the real platform ─────────
// The real docs show TWO consensus modes:
//   Majority  – validators must agree on the SAME result bytes
//   Threshold – results may differ (each validator counted individually)
// For LLM / JSON agents you always use the default (Majority).
enum ConsensusType {
    Majority,
    Threshold
}

enum ResponseStatus {
    None, // 0 – default / uninitialized
    Pending, // 1 – awaiting responses
    Success, // 2 – consensus reached
    Failed, // 3 – validators reported failure
    TimedOut // 4 – deadline passed
}

struct Response {
    address validator;
    bytes result; // abi-encoded return value of the agent method
    ResponseStatus status;
    uint256 receipt; // on-chain audit receipt hash
    uint256 timestamp;
    uint256 executionCost; // actual cost; median used for payout
}

struct Request {
    uint256 id;
    address requester;
    address callbackAddress;
    bytes4 callbackSelector;
    address[] subcommittee;
    Response[] responses;
    uint256 responseCount;
    uint256 failureCount;
    uint256 threshold;
    uint256 createdAt;
    uint256 deadline;
    ResponseStatus status;
    ConsensusType consensusType; // ← real field, must match
    uint256 remainingBudget;
    uint256 perAgentBudget;
}

// ── Platform ─────────────────────────────────────────────────
interface IAgentRequester {
    // Events (for off-chain listeners)
    event RequestCreated(
        uint256 indexed requestId,
        uint256 indexed agentId,
        uint256 perAgentBudget,
        bytes payload,
        address[] subcommittee
    );
    event RequestFinalized(uint256 indexed requestId, ResponseStatus status);
    event SubcommitteePaid(uint256 indexed requestId, uint256 totalPaid, uint256 perMember);
    event CommitteeDepositFailed(uint256 indexed requestId, uint256 attemptedAmount);

    // ── Standard request ─────────────────────────────────────
    // deposit = getRequestDeposit() + (costPerAgent × subcommitteeSize)
    function createRequest(uint256 agentId, address callbackAddress, bytes4 callbackSelector, bytes calldata payload)
        external
        payable
        returns (uint256 requestId);

    // ── Advanced request (custom subcommittee / timeout / consensus) ──
    function createAdvancedRequest(
        uint256 agentId,
        address callbackAddress,
        bytes4 callbackSelector,
        bytes calldata payload,
        uint256 subcommitteeSize,
        uint256 threshold,
        ConsensusType consensusType,
        uint256 timeout
    ) external payable returns (uint256 requestId);

    // ── Deposit helpers ───────────────────────────────────────
    function getRequestDeposit() external view returns (uint256);
    function getAdvancedRequestDeposit(uint256 subSize) external view returns (uint256);

    // ── Query ─────────────────────────────────────────────────
    function getRequest(uint256 requestId) external view returns (Request memory);
    function hasRequest(uint256 requestId) external view returns (bool);
}

// ── Callback interface your contract must implement ──────────
// The function can have any name but the PARAMETER TYPES must
// match exactly and you must pass the correct selector to createRequest.
interface IAgentRequesterHandler {
    function handleResponse(
        uint256 requestId,
        Response[] memory responses,
        ResponseStatus status,
        Request memory details
    ) external;
}

// ── Agent method interfaces ───────────────────────────────────
// These are encoded into the payload sent to createRequest.
// Validators decode and execute them.  You never call them directly.

interface IJsonApiAgent {
    function fetchUint(string calldata url, string calldata selector, uint8 decimals) external returns (uint256);

    function fetchString(string calldata url, string calldata selector) external returns (string memory);
}

interface ILLMInferenceAgent {
    // Fixed seed + temperature = 0  →  same input = same bytes on every validator
    // This determinism is what enables consensus on AI output.
    // allowedValues constrains the model output to one of the given strings.
    function inferString(
        string calldata prompt,
        string calldata system,
        bool chainOfThought,
        string[] calldata allowedValues
    ) external returns (string memory response);
}

interface ILLMParseWebsiteAgent {
    // Fetch a URL and extract structured data with an LLM.
    function parse(string calldata url, string calldata instruction) external returns (string memory);
}
