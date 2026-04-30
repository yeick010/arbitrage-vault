// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {ArbitrageVault} from "../src/ArbitrageVault.sol";
import {StrategyExecutor} from "../src/StrategyExecutor.sol";
import {FeeCollector} from "../src/FeeCollector.sol";
import {OracleAdapter} from "../src/OracleAdapter.sol";
import {AccessManager} from "../src/AccessManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title Deploy
/// @notice Deploys the ArbitrageVault system to Sepolia (or any EVM network).
/// @dev Environment variables required (load via `source .env`):
///      - PRIVATE_KEY           deployer key (NEVER hardcode)
///      - SEPOLIA_RPC_URL       Sepolia RPC
///      - ETHERSCAN_API_KEY     for --verify
///      - ASSET_ADDR            underlying ERC20 (e.g. Sepolia LINK 0x779877...)
///      - TREASURY_ADDR         immutable treasury (multisig!)
///      - ADMIN_ADDR            ADMIN_ROLE holder (multisig!)
///      - KEEPER_ADDR           KEEPER_ROLE holder
///      - PAUSER_ADDR           PAUSER_ROLE holder
///      - CHAINLINK_FEED        price feed (e.g. LINK/USD 0xc59E36...)
///      - MAX_PRICE_AGE         staleness threshold in seconds (e.g. 3600)
///
/// Usage:
///   Dry-run:
///     forge script script/Deploy.s.sol --rpc-url $SEPOLIA_RPC_URL -vvvv
///   Broadcast & verify:
///     forge script script/Deploy.s.sol --rpc-url $SEPOLIA_RPC_URL --broadcast --verify
contract Deploy is Script {
    struct DeployConfig {
        address asset;
        address admin;
        address keeper;
        address pauser;
        address treasury;
        address chainlinkFeed;
        uint256 maxPriceAge;
        uint256 maxAssetsPerTx;
        uint256 performanceFeeBps;
    }

    struct Deployed {
        AccessManager access;
        FeeCollector feeCollector;
        OracleAdapter oracle;
        ArbitrageVault vault;
        StrategyExecutor executor;
    }

    function run() external returns (Deployed memory d) {
        DeployConfig memory cfg = _loadConfig();

        // NEVER hardcode private key — always via env.
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        console2.log("Deployer:", deployer);
        console2.log("Chain ID:", block.chainid);

        vm.startBroadcast(pk);

        // 1. AccessManager (standalone role registry, useful for future strategies).
        d.access = new AccessManager(cfg.admin, cfg.keeper, cfg.pauser);
        console2.log("AccessManager:", address(d.access));

        // 2. FeeCollector — treasury is IMMUTABLE after this step.
        d.feeCollector = new FeeCollector(cfg.admin, cfg.treasury, cfg.performanceFeeBps);
        console2.log("FeeCollector:", address(d.feeCollector));

        // 3. OracleAdapter (TWAP source may be wired later via timelocked setter).
        d.oracle = new OracleAdapter(cfg.admin, cfg.chainlinkFeed, address(0), cfg.maxPriceAge);
        console2.log("OracleAdapter:", address(d.oracle));

        // 4. ArbitrageVault.
        d.vault = new ArbitrageVault(
            IERC20(cfg.asset),
            cfg.admin,
            cfg.keeper,
            cfg.pauser,
            address(d.feeCollector),
            cfg.maxAssetsPerTx
        );
        console2.log("ArbitrageVault:", address(d.vault));

        // 5. StrategyExecutor — immutably bound to vault.
        d.executor = new StrategyExecutor(cfg.admin, address(d.vault), cfg.asset);
        console2.log("StrategyExecutor:", address(d.executor));

        // 6. Authorize vault to pull fees from itself through the collector.
        //    Deployer holds admin role momentarily only if deployer == admin; otherwise this
        //    call will revert and must be executed by the admin multisig in a follow-up tx.
        if (deployer == cfg.admin) {
            d.feeCollector.setAuthorisedCollector(address(d.vault), true);
            console2.log("FeeCollector: authorised vault as collector");
        } else {
            console2.log(
                "NOTE: admin != deployer; call FeeCollector.setAuthorisedCollector(vault, true) from admin multisig"
            );
        }

        vm.stopBroadcast();

        _logPostDeploySteps(cfg, d);
    }

    function _loadConfig() internal view returns (DeployConfig memory cfg) {
        cfg.asset = vm.envAddress("ASSET_ADDR");
        cfg.admin = vm.envAddress("ADMIN_ADDR");
        cfg.keeper = vm.envAddress("KEEPER_ADDR");
        cfg.pauser = vm.envAddress("PAUSER_ADDR");
        cfg.treasury = vm.envAddress("TREASURY_ADDR");
        cfg.chainlinkFeed = vm.envAddress("CHAINLINK_FEED");
        cfg.maxPriceAge = vm.envOr("MAX_PRICE_AGE", uint256(3600));
        cfg.maxAssetsPerTx = vm.envOr("MAX_ASSETS_PER_TX", uint256(1_000_000e18));
        cfg.performanceFeeBps = vm.envOr("PERFORMANCE_FEE_BPS", uint256(1_000)); // 10%
    }

    function _logPostDeploySteps(DeployConfig memory cfg, Deployed memory d) internal pure {
        console2.log("\n====================== POST-DEPLOY CHECKLIST ======================");
        console2.log("1. Verify contracts on Etherscan (use --verify flag at deploy time)");
        console2.log("2. From admin multisig, call executor.setRouterWhitelist(<UniV3Router>, true)");
        console2.log("3. From admin multisig, call vault.scheduleStrategy(executor) then wait 48h");
        console2.log("4. After 48h, call vault.applyStrategy()");
        console2.log("5. Update deployments/sepolia.env with:");
        console2.log("   VAULT=", address(d.vault));
        console2.log("   EXECUTOR=", address(d.executor));
        console2.log("   ORACLE=", address(d.oracle));
        console2.log("   FEE_COLLECTOR=", address(d.feeCollector));
        console2.log("   ACCESS_MANAGER=", address(d.access));
        console2.log("6. Tag this commit: git tag v0.1.0-sepolia");
        console2.log("================= CONFIG SUMMARY =================");
        console2.log("asset    :", cfg.asset);
        console2.log("admin    :", cfg.admin);
        console2.log("treasury :", cfg.treasury);
        console2.log("maxPerTx :", cfg.maxAssetsPerTx);
        console2.log("feeBps   :", cfg.performanceFeeBps);
    }
}