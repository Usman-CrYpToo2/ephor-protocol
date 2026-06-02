// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title  TriggerCheck
 * @notice Step 3 of 3 - fires a live AI risk check on the Somnia testnet.
 *
 *         Calls VaultSentinel.checkVault{value: 0.25 STT}(vault).
 *         The Somnia platform receives the request, runs the LLM deterministically
 *         across multiple validators, reaches consensus, and calls handleResponse()
 *         back on VaultSentinel.  This takes ~1-5 minutes on testnet.
 *
 *         After running, poll with VerifyResponse.s.sol to confirm the callback
 *         arrived and the correct action was taken.
 *
 *  Run:
 *    source .env
 *    forge script script/TriggerCheck.s.sol \
 *      --rpc-url $SOMNIA_TESTNET_RPC \
 *      --broadcast \
 *      --private-key $PRIVATE_KEY \
 *      --gas-estimate-multiplier 3000 \
 *      -vvvv
 *
 *  STT required: 0.25 STT (agent reward 0.07*3 = 0.21 STT, plus buffer).
 *  Excess is rebated by the platform to the sentinel contract.
 */

import {Script, console} from "forge-std/Script.sol";
import "../src/CuratedVault.sol";
import "../src/VaultSentinel.sol";

contract TriggerCheck is Script {
    // 0.07 STT per agent * 3 validators = 0.21 STT reward pot + buffer
    uint256 constant DEPOSIT = 0.25 ether;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address vaultAddr = vm.envAddress("CURATED_VAULT_ADDRESS");
        address sentinelAddr = vm.envAddress("VAULT_SENTINEL_ADDRESS");

        VaultSentinel sentinel = VaultSentinel(payable(sentinelAddr));
        CuratedVault vault = CuratedVault(vaultAddr);

        // ── Pre-flight checks ──────────────────────────────────────────────────
        (bool registered, bool autoPause,,, uint256 totalChecks,) = sentinel.vaultInfo(vaultAddr);

        require(registered, "vault not registered in sentinel");
        require(!sentinel.isCheckPending(vaultAddr), "check already in progress");
        require(DEPOSIT >= 0.21 ether, "deposit too low");

        console.log("\n========= PRE-FLIGHT =========");
        console.log("Vault:              ", vaultAddr);
        console.log("Sentinel:           ", sentinelAddr);
        console.log("autoPause:          ", autoPause);
        console.log("totalChecks so far: ", totalChecks);
        console.log("We will send (STT): ", DEPOSIT);
        console.log("totalAssets (USDC): ", vault.totalAssets() / 1e6);
        console.log("idleBufferPct:      ", vault.idleBufferPct(), "%");
        console.log("==============================\n");

        vm.startBroadcast(deployerKey);

        sentinel.checkVault{value: DEPOSIT}(vaultAddr);

        vm.stopBroadcast();

        uint256 requestId = sentinel.activeRequest(vaultAddr);

        console.log("\n========= REQUEST SUBMITTED =========");
        console.log("requestId:        ", requestId);
        console.log("isPending:        ", sentinel.isCheckPending(vaultAddr));
        console.log("=====================================");
        console.log("Wait 1-5 minutes for Somnia validators to reach consensus.");
        console.log("Then run: forge script script/VerifyResponse.s.sol --rpc-url $SOMNIA_TESTNET_RPC -vvv");
    }
}

