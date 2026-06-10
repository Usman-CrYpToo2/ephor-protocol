// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title  DeployStrategist
 * @notice Deploys AllocationStrategist and wires it to the existing vault + oracle.
 *         Run this when the vault is already live but the strategist was not yet deployed.
 *
 *  Run:
 *    source .env
 *    forge script script/DeployStrategist.s.sol \
 *      --rpc-url somnia_testnet \
 *      --broadcast \
 *      --private-key $PRIVATE_KEY \
 *      --gas-estimate-multiplier 3000 \
 *      -vvvv
 *
 *  After running, copy the printed STRATEGIST_ADDRESS into .env.
 */

import {Script, console} from "forge-std/Script.sol";
import "../src/CuratedVault.sol";
import {AllocationStrategist} from "../src/AllocationStrategist.sol";

contract DeployStrategist is Script {
    address constant PLATFORM = 0x037Bb9C718F3f7fe5eCBDB0b600D607b52706776;
    bytes32 constant ALLOCATOR_ROLE = keccak256("ALLOCATOR_ROLE");

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        uint256 llmAgentId = vm.envUint("LLM_AGENT_ID");
        address vaultAddr = vm.envAddress("CURATED_VAULT_ADDRESS");
        address oracleAddr = vm.envOr("ORACLE_ADDRESS", address(0));

        CuratedVault vault = CuratedVault(vaultAddr);

        console.log("\n========= DEPLOY STRATEGIST =========");
        console.log("Vault:   ", vaultAddr);
        console.log("Oracle:  ", oracleAddr);
        console.log("Agent ID:", llmAgentId);
        console.log("=====================================\n");

        vm.startBroadcast(deployerKey);

        // 1. Deploy AllocationStrategist
        AllocationStrategist strategist = new AllocationStrategist(PLATFORM, llmAgentId, vaultAddr, deployer);
        console.log("AllocationStrategist deployed:", address(strategist));

        // 2. Grant ALLOCATOR_ROLE so it can call vault.reallocate()
        vault.grantRole(ALLOCATOR_ROLE, address(strategist));
        console.log("ALLOCATOR_ROLE granted to strategist");

        // 3. Wire oracle for manipulation-resistant utilization reads
        if (oracleAddr != address(0)) {
            strategist.setOracle(oracleAddr);
            console.log("Oracle wired into strategist:", oracleAddr);
        } else {
            console.log("ORACLE_ADDRESS not set -- strategist reads spot util (testnet-safe)");
        }

        vm.stopBroadcast();

        console.log("\n========= COPY INTO .env =========");
        console.log("STRATEGIST_ADDRESS=", address(strategist));
        console.log("==================================\n");
        console.log("NEXT: update .env, then run TestRiskAnalysis.s.sol or TestAIAllocation.s.sol");
    }
}
