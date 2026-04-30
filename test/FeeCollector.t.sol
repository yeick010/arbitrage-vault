// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Base} from "./Base.t.sol";
import {FeeCollector} from "../src/FeeCollector.sol";
import {Errors} from "../src/common/Errors.sol";
import {Const} from "../src/common/Const.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract FeeCollectorTest is Base {
    function test_treasury_immutable() public view {
        assertEq(feeCollector.treasury(), treasury);
    }

    function test_constructor_revertsOnZeroAdmin() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        new FeeCollector(address(0), treasury, 1_000);
    }

    function test_constructor_revertsOnZeroTreasury() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        new FeeCollector(admin, address(0), 1_000);
    }

    function test_constructor_revertsOnFeeTooHigh() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.FeeTooHigh.selector, 1_001, Const.MAX_PERFORMANCE_FEE_BPS));
        new FeeCollector(admin, treasury, 1_001);
    }

    function test_setPerformanceFee_success() public {
        vm.prank(admin);
        feeCollector.setPerformanceFee(500);
        assertEq(feeCollector.performanceFeeBps(), 500);
    }

    function test_setPerformanceFee_revertsAboveCap() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Errors.FeeTooHigh.selector, 1_001, Const.MAX_PERFORMANCE_FEE_BPS));
        feeCollector.setPerformanceFee(1_001);
    }

    function test_setPerformanceFee_revertsSameValue() public {
        vm.prank(admin);
        vm.expectRevert(Errors.SameValue.selector);
        feeCollector.setPerformanceFee(FEE_BPS);
    }

    function test_setPerformanceFee_onlyAdmin() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, feeCollector.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(alice);
        feeCollector.setPerformanceFee(500);
    }

    function test_collect_onlyAuthorised() public {
        asset.mint(alice, 100e18);
        vm.startPrank(alice);
        asset.approve(address(feeCollector), 100e18);
        vm.expectRevert(abi.encodeWithSelector(Errors.Unauthorized.selector, alice));
        feeCollector.collect(address(asset), alice, 100e18);
        vm.stopPrank();
    }

    function test_computeFee_math() public view {
        assertEq(feeCollector.computeFee(1000e18), 100e18); // 10% of 1000
        assertEq(feeCollector.computeFee(0), 0);
    }

    function test_setAuthorisedCollector_success() public {
        address newCol = makeAddr("col");
        vm.prank(admin);
        feeCollector.setAuthorisedCollector(newCol, true);
        assertTrue(feeCollector.authorisedCollector(newCol));
        vm.prank(admin);
        feeCollector.setAuthorisedCollector(newCol, false);
        assertFalse(feeCollector.authorisedCollector(newCol));
    }

    function test_setAuthorisedCollector_revertsZero() public {
        vm.prank(admin);
        vm.expectRevert(Errors.ZeroAddress.selector);
        feeCollector.setAuthorisedCollector(address(0), true);
    }

    function test_collect_revertsOnZeroAmount() public {
        vm.prank(address(vault));
        vm.expectRevert(Errors.ZeroAmount.selector);
        feeCollector.collect(address(asset), address(vault), 0);
    }

    function test_collect_revertsOnZeroToken() public {
        vm.prank(address(vault));
        vm.expectRevert(Errors.ZeroAddress.selector);
        feeCollector.collect(address(0), address(vault), 1e18);
    }

    function testFuzz_computeFee_monotonic(uint256 profit) public view {
        profit = bound(profit, 0, type(uint128).max);
        uint256 fee = feeCollector.computeFee(profit);
        assertLe(fee, profit); // fee never exceeds profit
    }
}