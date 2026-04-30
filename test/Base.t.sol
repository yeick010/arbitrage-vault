// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";

import { ArbitrageVault } from "../src/ArbitrageVault.sol";
import { StrategyExecutor } from "../src/StrategyExecutor.sol";
import { FeeCollector } from "../src/FeeCollector.sol";
import { OracleAdapter } from "../src/OracleAdapter.sol";
import { AccessManager } from "../src/AccessManager.sol";
import { Const } from "../src/common/Const.sol";

import { MockERC20 } from "./mocks/MockERC20.sol";
import { MockChainlinkFeed } from "./mocks/MockChainlinkFeed.sol";
import { MockTWAPSource } from "./mocks/MockTWAPSource.sol";
import { MockSwapRouter } from "./mocks/MockSwapRouter.sol";

/// @notice Shared deployment harness for all test contracts.
abstract contract Base is Test {
    /* actors */
    address internal admin = makeAddr("admin");
    address internal keeper = makeAddr("keeper");
    address internal pauser = makeAddr("pauser");
    address internal treasury = makeAddr("treasury");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    /* deployed */
    MockERC20 internal asset;
    ArbitrageVault internal vault;
    StrategyExecutor internal executor;
    FeeCollector internal feeCollector;
    OracleAdapter internal oracle;
    AccessManager internal access;
    MockChainlinkFeed internal feed;
    MockTWAPSource internal twap;
    MockSwapRouter internal router;

    /* params */
    uint256 internal constant MAX_PER_TX = 1_000_000e18;
    uint256 internal constant FEE_BPS = 1_000; // 10%

    function setUp() public virtual {
        asset = new MockERC20("TestAsset", "TST", 18);

        feeCollector = new FeeCollector(admin, treasury, FEE_BPS);

        vault = new ArbitrageVault(asset, admin, keeper, pauser, address(feeCollector), MAX_PER_TX);

        executor = new StrategyExecutor(admin, address(vault), address(asset));
        router = new MockSwapRouter(asset);
        feed = new MockChainlinkFeed(8, 100e8); // 1e18 asset = $100
        twap = new MockTWAPSource(100e18);
        oracle = new OracleAdapter(admin, address(feed), address(twap), 3600);
        access = new AccessManager(admin, keeper, pauser);

        vm.startPrank(admin);
        feeCollector.setAuthorisedCollector(address(vault), true);
        executor.setRouterWhitelist(address(router), true);
        // Attach strategy via timelock.
        vault.scheduleStrategy(address(executor));
        vm.stopPrank();

        vm.warp(block.timestamp + Const.TIMELOCK_DELAY + 1);
        vm.prank(admin);
        vault.applyStrategy();

        // Refresh oracle feed timestamp so it is not stale after the warp above.
        feed.setAnswer(100e8);

        // Seed users.
        asset.mint(alice, 10_000_000e18);
        asset.mint(bob, 10_000_000e18);
        asset.mint(carol, 10_000_000e18);
        // Fund router with asset so it can pay outputs > input.
        asset.mint(address(this), 10_000_000e18);
        asset.approve(address(router), type(uint256).max);
        router.fund(10_000_000e18);
    }

    function _deposit(address user, uint256 amount) internal returns (uint256 shares) {
        vm.startPrank(user);
        asset.approve(address(vault), amount);
        shares = vault.deposit(amount, user);
        vm.stopPrank();
    }
}
