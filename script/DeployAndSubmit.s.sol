// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title  DeployAndSubmit
 * @notice Step 1 of 3 for testnet deployment.
 *
 *         Deploys all contracts and submits the timelock market additions.
 *         CuratedVault enforces a 1-minute timelock on market additions (testnet demo),
 *         so ExecuteAndSeed.s.sol must be run at least 1 minute after this script.
 *
 *  Run:
 *    source .env
 *    forge script script/DeployAndSubmit.s.sol \
 *      --rpc-url $SOMNIA_TESTNET_RPC \
 *      --broadcast \
 *      --private-key $PRIVATE_KEY \
 *      -vvvv
 *
 *  After running, copy the printed addresses into .env before running Step 2.
 *
 *  STT required: ~0.1 STT for gas (deployment costs).
 *  Get testnet STT from: https://testnet.somnia.network/
 */

import {Script, console} from "forge-std/Script.sol";
import "../src/Mock/MockUSDC.sol";
import "../src/Mock/MockLendingMarket.sol";
import "../src/CuratedVault.sol";
import "../src/VaultSentinel.sol";

contract DeployAndSubmit is Script {

    // ── Somnia testnet platform (verified: docs.somnia.network/agents) ─────────
    address constant PLATFORM = 0x037Bb9C718F3f7fe5eCBDB0b600D607b52706776;

    // ── Role constants ─────────────────────────────────────────────────────────
    bytes32 constant SENTINEL_ROLE  = keccak256("SENTINEL_ROLE");
    bytes32 constant CURATOR_ROLE   = keccak256("CURATOR_ROLE");
    bytes32 constant ALLOCATOR_ROLE = keccak256("ALLOCATOR_ROLE");

    function run() external {
        uint256 deployerKey     = vm.envUint("PRIVATE_KEY");
        address deployer        = vm.envAddress("DEPLOYER_ADDRESS");
        uint256 llmAgentId      = vm.envUint("LLM_AGENT_ID");

        require(llmAgentId != 0, "LLM_AGENT_ID not set in .env - visit agents.testnet.somnia.network");

        vm.startBroadcast(deployerKey);

        // ── 1. Mock USDC (6 decimals, open-mint on testnet) ───────────────────
        MockUSDC usdc = new MockUSDC();
        console.log("MockUSDC deployed:         ", address(usdc));

        // ── 2. CuratedVault ────────────────────────────────────────────────────
        // Deployer holds all roles so the script is self-contained.
        // In production, replace with a DAO multisig and separate role holders.
        CuratedVault vault = new CuratedVault(
            address(usdc),
            "Ephor Protocol vsUSDC",
            "vsUSDC",
            deployer,    // admin
            deployer,    // curator
            deployer,    // allocator
            deployer     // feeRecipient
        );
        console.log("CuratedVault deployed:     ", address(vault));

        // ── 3. VaultSentinel ───────────────────────────────────────────────────
        VaultSentinel sentinel = new VaultSentinel(
            PLATFORM,
            llmAgentId,
            deployer     // sentinel admin
        );
        console.log("VaultSentinel deployed:    ", address(sentinel));

        // ── 4. Grant SENTINEL_ROLE to VaultSentinel ────────────────────────────
        vault.grantRole(SENTINEL_ROLE, address(sentinel));
        console.log("SENTINEL_ROLE granted to sentinel");

        // ── 5. Deploy two mock lending markets ────────────────────────────────
        MockLendingMarket marketA = new MockLendingMarket(
            address(usdc), address(vault), "Ephor Market A"
        );
        MockLendingMarket marketB = new MockLendingMarket(
            address(usdc), address(vault), "Ephor Market B"
        );
        console.log("MockLendingMarket A:       ", address(marketA));
        console.log("MockLendingMarket B:       ", address(marketB));

        // ── 6. Submit market additions via timelock ────────────────────────────
        // Timelock is 1 hour (MIN_TIMELOCK). Run ExecuteAndSeed.s.sol after that.
        vault.submitAddMarket(address(marketA), 50_000 * 1e6);   // 50k USDC cap
        vault.submitAddMarket(address(marketB), 50_000 * 1e6);
        console.log("Market additions submitted to timelock queue");
        console.log("WAIT AT LEAST 1 MINUTE before running ExecuteAndSeed.s.sol");

        // ── 7. Register vault in sentinel ─────────────────────────────────────
        sentinel.registerVault(address(vault), true);  // autoPause = true
        console.log("Vault registered in sentinel with autoPause=true");

        vm.stopBroadcast();

        // ── Output: paste these into .env ─────────────────────────────────────
        console.log("\n========= COPY INTO .env =========");
        console.log("MOCK_USDC_ADDRESS=",    address(usdc));
        console.log("CURATED_VAULT_ADDRESS=", address(vault));
        console.log("VAULT_SENTINEL_ADDRESS=", address(sentinel));
        console.log("MARKET_A_ADDRESS=",      address(marketA));
        console.log("MARKET_B_ADDRESS=",      address(marketB));
        console.log("==================================\n");
        console.log("NEXT STEP: wait 1 minute, then run ExecuteAndSeed.s.sol");
    }
}
