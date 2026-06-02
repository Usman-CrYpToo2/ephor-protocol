// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title  ReplaceSentinel
 * @notice Deploys a fresh VaultSentinel and wires it to the existing vault.
 *
 *         Run this when the sentinel contract needs to be redeployed
 *         (e.g. after an interface fix) without touching the vault or markets.
 *
 *  Run:
 *    source .env
 *    forge script script/ReplaceSentinel.s.sol \
 *      --rpc-url $SOMNIA_TESTNET_RPC \
 *      --broadcast \
 *      --private-key $PRIVATE_KEY \
 *      --gas-estimate-multiplier 3000 \
 *      -vvvv
 *
 *  After running, copy the new VAULT_SENTINEL_ADDRESS into .env.
 */

import {Script, console} from "forge-std/Script.sol";
import "../src/CuratedVault.sol";
import "../src/VaultSentinel.sol";

contract ReplaceSentinel is Script {
    address constant PLATFORM = 0x037Bb9C718F3f7fe5eCBDB0b600D607b52706776;

    bytes32 constant SENTINEL_ROLE = keccak256("SENTINEL_ROLE");

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        uint256 llmAgentId = vm.envUint("LLM_AGENT_ID");
        address vaultAddr = vm.envAddress("CURATED_VAULT_ADDRESS");
        address oldSentinelAddr = vm.envAddress("VAULT_SENTINEL_ADDRESS");

        CuratedVault vault = CuratedVault(vaultAddr);

        vm.startBroadcast(deployerKey);

        // 1. Deploy new sentinel
        VaultSentinel newSentinel = new VaultSentinel(PLATFORM, llmAgentId, deployer);
        console.log("New VaultSentinel:  ", address(newSentinel));

        // 2. Grant SENTINEL_ROLE to new sentinel
        vault.grantRole(SENTINEL_ROLE, address(newSentinel));
        console.log("SENTINEL_ROLE granted to new sentinel");

        // 3. Revoke SENTINEL_ROLE from old sentinel
        vault.revokeRole(SENTINEL_ROLE, oldSentinelAddr);
        console.log("SENTINEL_ROLE revoked from old sentinel");

        // 4. Register vault in new sentinel
        newSentinel.registerVault(vaultAddr, true);
        console.log("Vault registered in new sentinel (autoPause=true)");

        vm.stopBroadcast();

        console.log("\n========= UPDATE YOUR .env =========");
        console.log("VAULT_SENTINEL_ADDRESS=", address(newSentinel));
        console.log("====================================\n");
        console.log("Then run TriggerCheck.s.sol");
    }
}
