// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Base } from "./Base.t.sol";
import { StrategyExecutor } from "../src/StrategyExecutor.sol";
import { Errors } from "../src/common/Errors.sol";
import { IStrategyExecutor } from "../src/interfaces/IStrategyExecutor.sol";

contract StrategyExecutorTest is Base {
    function test_onlyVaultCanExecute() public {
        IStrategyExecutor.ArbitrageParams memory p = IStrategyExecutor.ArbitrageParams({
            router: address(router),
            path: abi.encodePacked(address(asset)),
            amountIn: 1e18,
            minAmountOut: 1e18,
            deadline: block.timestamp + 1000
        });
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.Unauthorized.selector, alice));
        executor.executeArbitrage(p);
    }

    function test_rejectsUnwhitelistedRouter() public {
        address evilRouter = makeAddr("evil");
        _deposit(alice, 10e18);
        IStrategyExecutor.ArbitrageParams memory p = IStrategyExecutor.ArbitrageParams({
            router: evilRouter,
            path: abi.encodePacked(address(asset)),
            amountIn: 1e18,
            minAmountOut: 1e18,
            deadline: block.timestamp + 1000
        });
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Errors.RouterNotWhitelisted.selector, evilRouter));
        vault.executeRebalance(p);
    }

    function test_rejectsExpiredDeadline() public {
        _deposit(alice, 10e18);
        IStrategyExecutor.ArbitrageParams memory p = IStrategyExecutor.ArbitrageParams({
            router: address(router),
            path: abi.encodePacked(address(asset)),
            amountIn: 1e18,
            minAmountOut: 1e18,
            deadline: block.timestamp - 1
        });
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidParameter.selector, "deadline"));
        vault.executeRebalance(p);
    }

    function test_rejectsEmptyPath() public {
        _deposit(alice, 10e18);
        IStrategyExecutor.ArbitrageParams memory p = IStrategyExecutor.ArbitrageParams({
            router: address(router), path: "", amountIn: 1e18, minAmountOut: 1e18, deadline: block.timestamp + 1000
        });
        vm.prank(keeper);
        vm.expectRevert(Errors.InvalidPath.selector);
        vault.executeRebalance(p);
    }

    function test_setRouterWhitelist_onlyAdmin() public {
        vm.prank(alice);
        vm.expectRevert();
        executor.setRouterWhitelist(address(router), false);
        vm.prank(admin);
        executor.setRouterWhitelist(address(router), false);
        assertFalse(executor.whitelistedRouter(address(router)));
    }
}
