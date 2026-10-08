// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title  DeployAndSubmit
 * @notice Step 1 of 2 — Deploys the full Ephor Protocol with 3 vaults.
 *
 *  VAULTS DEPLOYED
 *  ───────────────
 *  • Ephor USDC Vault  (MockUSDC, 6 decimals)
 *  • Ephor WETH Vault  (MockWETH, 18 decimals)
 *  • Ephor WBTC Vault  (MockWBTC, 8 decimals)
 *
 *  SHARED INFRASTRUCTURE
 *  ──────────────────────
 *  • 1 × VaultSentinel         (multi-vault, all 3 registered)
 *  • 1 × UtilizationOracle     (shared)
 *  • 3 × AllocationStrategist  (one per vault — immutable vault ref)
 *  • 6 × MockLendingMarket     (2 per vault)
 *
 *  Run:
 *    source .env
 *    forge script script/DeployAndSubmit.s.sol \
 *      --rpc-url somnia_testnet \
 *      --broadcast \
 *      --private-key $PRIVATE_KEY \
 *      --gas-estimate-multiplier 3000
 *
 *  Copy the printed addresses into .env, then run ExecuteAndSeed.s.sol.
 */

import {Script, console} from "forge-std/Script.sol";
import "../src/Mock/MockUSDC.sol";
import "../src/Mock/MockERC20.sol";
import "../src/Mock/MockLendingMarket.sol";
import "../src/CuratedVault.sol";
import "../src/VaultSentinel.sol";
import {UtilizationOracle} from "../src/UtilizationOracle.sol";
import {AllocationStrategist} from "../src/AllocationStrategist.sol";

contract DeployAndSubmit is Script {
    address constant PLATFORM = 0x037Bb9C718F3f7fe5eCBDB0b600D607b52706776;

    bytes32 constant SENTINEL_ROLE = keccak256("SENTINEL_ROLE");
    bytes32 constant CURATOR_ROLE = keccak256("CURATOR_ROLE");
    bytes32 constant ALLOCATOR_ROLE = keccak256("ALLOCATOR_ROLE");

    uint256 constant TWAP_WINDOW = 30 minutes;
    uint256 constant SPIKE_THRESHOLD_BPS = 500;
    uint256 constant CAUTION_UTIL_BPS = 8000;
    uint256 constant CRITICAL_UTIL_BPS = 9500;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        uint256 llmAgentId = vm.envUint("LLM_AGENT_ID");

        require(llmAgentId != 0, "LLM_AGENT_ID not set in .env");

        vm.startBroadcast(deployerKey);

        // ══════════════════════════════════════════════════════════════════════
        // 1. Mock ERC-20 tokens
        // ══════════════════════════════════════════════════════════════════════

        MockUSDC usdc = new MockUSDC(); // 6 dec
        MockERC20 weth = new MockERC20("Mock Wrapped Ether", "WETH", 18); // 18 dec
        MockERC20 wbtc = new MockERC20("Mock Wrapped Bitcoin", "WBTC", 8); //  8 dec

        console.log("MockUSDC deployed:  ", address(usdc));
        console.log("MockWETH deployed:  ", address(weth));
        console.log("MockWBTC deployed:  ", address(wbtc));

        // ══════════════════════════════════════════════════════════════════════
        // 2. CuratedVaults (one per asset)
        // ══════════════════════════════════════════════════════════════════════

        CuratedVault vaultUSDC =
            new CuratedVault(address(usdc), "Ephor USDC Vault", "ephUSDC", deployer, deployer, deployer, deployer);
        CuratedVault vaultWETH =
            new CuratedVault(address(weth), "Ephor WETH Vault", "ephWETH", deployer, deployer, deployer, deployer);
        CuratedVault vaultWBTC =
            new CuratedVault(address(wbtc), "Ephor WBTC Vault", "ephWBTC", deployer, deployer, deployer, deployer);

        console.log("USDC Vault:         ", address(vaultUSDC));
        console.log("WETH Vault:         ", address(vaultWETH));
        console.log("WBTC Vault:         ", address(vaultWBTC));

        // ══════════════════════════════════════════════════════════════════════
        // 3. Shared infrastructure — Sentinel + Oracle
        // ══════════════════════════════════════════════════════════════════════

        VaultSentinel sentinel = new VaultSentinel(PLATFORM, llmAgentId, deployer);
        console.log("VaultSentinel:      ", address(sentinel));

        UtilizationOracle oracle =
            new UtilizationOracle(TWAP_WINDOW, SPIKE_THRESHOLD_BPS, CAUTION_UTIL_BPS, CRITICAL_UTIL_BPS, deployer);
        console.log("UtilizationOracle:  ", address(oracle));

        // ══════════════════════════════════════════════════════════════════════
        // 4. AllocationStrategist — one per vault (immutable vault reference)
        // ══════════════════════════════════════════════════════════════════════

        AllocationStrategist stratUSDC = new AllocationStrategist(PLATFORM, llmAgentId, address(vaultUSDC), deployer);
        AllocationStrategist stratWETH = new AllocationStrategist(PLATFORM, llmAgentId, address(vaultWETH), deployer);
        AllocationStrategist stratWBTC = new AllocationStrategist(PLATFORM, llmAgentId, address(vaultWBTC), deployer);

        console.log("Strategist USDC:    ", address(stratUSDC));
        console.log("Strategist WETH:    ", address(stratWETH));
        console.log("Strategist WBTC:    ", address(stratWBTC));

        // ══════════════════════════════════════════════════════════════════════
        // 5. Mock lending markets — 2 per vault
        // ══════════════════════════════════════════════════════════════════════

        MockLendingMarket usdcA = new MockLendingMarket(address(usdc), address(vaultUSDC), "USDC Lending Pool A");
        MockLendingMarket usdcB = new MockLendingMarket(address(usdc), address(vaultUSDC), "USDC Lending Pool B");
        MockLendingMarket wethA = new MockLendingMarket(address(weth), address(vaultWETH), "WETH Lending Pool A");
        MockLendingMarket wethB = new MockLendingMarket(address(weth), address(vaultWETH), "WETH Lending Pool B");
        MockLendingMarket wbtcA = new MockLendingMarket(address(wbtc), address(vaultWBTC), "WBTC Lending Pool A");
        MockLendingMarket wbtcB = new MockLendingMarket(address(wbtc), address(vaultWBTC), "WBTC Lending Pool B");

        console.log("USDC Market A:      ", address(usdcA));
        console.log("USDC Market B:      ", address(usdcB));
        console.log("WETH Market A:      ", address(wethA));
        console.log("WETH Market B:      ", address(wethB));
        console.log("WBTC Market A:      ", address(wbtcA));
        console.log("WBTC Market B:      ", address(wbtcB));

        // ══════════════════════════════════════════════════════════════════════
        // 6. Grant roles
        // ══════════════════════════════════════════════════════════════════════

        // SENTINEL_ROLE — one shared sentinel on all vaults
        vaultUSDC.grantRole(SENTINEL_ROLE, address(sentinel));
        vaultWETH.grantRole(SENTINEL_ROLE, address(sentinel));
        vaultWBTC.grantRole(SENTINEL_ROLE, address(sentinel));

        // ALLOCATOR_ROLE — each vault grants it to its own strategist
        vaultUSDC.grantRole(ALLOCATOR_ROLE, address(stratUSDC));
        vaultWETH.grantRole(ALLOCATOR_ROLE, address(stratWETH));
        vaultWBTC.grantRole(ALLOCATOR_ROLE, address(stratWBTC));

        console.log("Roles granted");

        // ══════════════════════════════════════════════════════════════════════
        // 7. Wire oracle into sentinel and all strategists
        // ══════════════════════════════════════════════════════════════════════

        sentinel.setOracle(address(oracle));
        stratUSDC.setOracle(address(oracle));
        stratWETH.setOracle(address(oracle));
        stratWBTC.setOracle(address(oracle));

        console.log("Oracle wired");

        // ══════════════════════════════════════════════════════════════════════
        // 8. Queue market additions (executed by ExecuteAndSeed after the timelock)
        // ══════════════════════════════════════════════════════════════════════

        // USDC: caps in 6-decimal units (50k USDC each)
        vaultUSDC.submitAddMarket(address(usdcA), 50_000 * 1e6);
        vaultUSDC.submitAddMarket(address(usdcB), 50_000 * 1e6);

        // WETH: caps in 18-decimal units (50 WETH each)
        vaultWETH.submitAddMarket(address(wethA), 50 * 1e18);
        vaultWETH.submitAddMarket(address(wethB), 50 * 1e18);

        // WBTC: caps in 8-decimal units (5 WBTC each)
        vaultWBTC.submitAddMarket(address(wbtcA), 5 * 1e8);
        vaultWBTC.submitAddMarket(address(wbtcB), 5 * 1e8);

        console.log("Market additions queued; execute after the vault timelock");

        // ══════════════════════════════════════════════════════════════════════
        // 9. Register all vaults in sentinel (autoPause = true)
        // ══════════════════════════════════════════════════════════════════════

        sentinel.registerVault(address(vaultUSDC), true);
        sentinel.registerVault(address(vaultWETH), true);
        sentinel.registerVault(address(vaultWBTC), true);

        console.log("All vaults registered in sentinel");

        vm.stopBroadcast();

        // ══════════════════════════════════════════════════════════════════════
        // Output — paste into .env
        // ══════════════════════════════════════════════════════════════════════
        console.log("\n====================================================");
        console.log("COPY INTO .env");
        console.log("====================================================");
        console.log("");
        console.log("# -- Shared --");
        console.log("VAULT_SENTINEL_ADDRESS=", address(sentinel));
        console.log("ORACLE_ADDRESS=", address(oracle));
        console.log("");
        console.log("# -- USDC Vault --");
        console.log("MOCK_USDC_ADDRESS=", address(usdc));
        console.log("USDC_VAULT_ADDRESS=", address(vaultUSDC));
        console.log("USDC_MARKET_A_ADDRESS=", address(usdcA));
        console.log("USDC_MARKET_B_ADDRESS=", address(usdcB));
        console.log("USDC_STRATEGIST_ADDRESS=", address(stratUSDC));
        console.log("");
        console.log("# -- WETH Vault --");
        console.log("MOCK_WETH_ADDRESS=", address(weth));
        console.log("WETH_VAULT_ADDRESS=", address(vaultWETH));
        console.log("WETH_MARKET_A_ADDRESS=", address(wethA));
        console.log("WETH_MARKET_B_ADDRESS=", address(wethB));
        console.log("WETH_STRATEGIST_ADDRESS=", address(stratWETH));
        console.log("");
        console.log("# -- WBTC Vault --");
        console.log("MOCK_WBTC_ADDRESS=", address(wbtc));
        console.log("WBTC_VAULT_ADDRESS=", address(vaultWBTC));
        console.log("WBTC_MARKET_A_ADDRESS=", address(wbtcA));
        console.log("WBTC_MARKET_B_ADDRESS=", address(wbtcB));
        console.log("WBTC_STRATEGIST_ADDRESS=", address(stratWBTC));
        console.log("====================================================");
        console.log("NEXT: run ExecuteAndSeed.s.sol");
    }
}
