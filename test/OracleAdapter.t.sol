// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Base} from "./Base.t.sol";
import {OracleAdapter} from "../src/OracleAdapter.sol";
import {Errors} from "../src/common/Errors.sol";
import {Const} from "../src/common/Const.sol";
import {MockChainlinkFeed} from "./mocks/MockChainlinkFeed.sol";
import {MockTWAPSource} from "./mocks/MockTWAPSource.sol";

contract OracleAdapterTest is Base {
    function test_getPrice_normalisesDecimals() public view {
        // feed = 8 decimals, answer 100e8 → expected 100e18
        assertEq(oracle.getPrice(), 100e18);
    }

    function test_getPrice_revertsWhenStale() public {
        vm.warp(block.timestamp + 3601 + 1);
        vm.expectRevert();
        oracle.getPrice();
    }

    function test_getPrice_revertsOnNegative() public {
        feed.setAnswer(-1);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidPrice.selector, -1));
        oracle.getPrice();
    }

    function test_getPrice_revertsOnRoundMismatch() public {
        feed.setRoundMismatch();
        vm.expectRevert();
        oracle.getPrice();
    }

    function test_getPrice_revertsOnHighDeviation() public {
        // TWAP says 110e18, primary 100e18 → 10% deviation > 2% limit
        twap.setPrice(110e18);
        vm.expectRevert(
            abi.encodeWithSelector(Errors.PriceDeviationTooHigh.selector, 100e18, 110e18, Const.MAX_ORACLE_DEVIATION_BPS)
        );
        oracle.getPrice();
    }

    function test_getPrice_acceptsSmallDeviation() public {
        twap.setPrice(101e18); // 1% deviation
        assertEq(oracle.getPrice(), 100e18);
    }

    function test_setFeed_onlyAdmin() public {
        MockChainlinkFeed newFeed = new MockChainlinkFeed(8, 200e8);
        vm.prank(alice);
        vm.expectRevert();
        oracle.setFeed(address(newFeed));
        vm.prank(admin);
        oracle.setFeed(address(newFeed));
        assertEq(address(oracle.chainlinkFeed()), address(newFeed));
    }

    function test_setTWAPSource_toZeroDisablesFallback() public {
        twap.setPrice(200e18); // would deviate, but disable fallback
        vm.prank(admin);
        oracle.setTWAPSource(address(0));
        assertEq(oracle.getPrice(), 100e18);
    }

    function test_getFallbackPrice_revertsWhenUnset() public {
        vm.prank(admin);
        oracle.setTWAPSource(address(0));
        vm.expectRevert(Errors.OracleNotConfigured.selector);
        oracle.getFallbackPrice();
    }

    function test_setMaxPriceAge_success() public {
        vm.prank(admin);
        oracle.setMaxPriceAge(600);
        assertEq(oracle.maxPriceAge(), 600);
    }

    function test_setMaxPriceAge_revertsZero() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidParameter.selector, "maxAge"));
        oracle.setMaxPriceAge(0);
    }

    function test_setFeed_revertsZero() public {
        vm.prank(admin);
        vm.expectRevert(Errors.ZeroAddress.selector);
        oracle.setFeed(address(0));
    }

    function test_setFeed_revertsSameValue() public {
        vm.prank(admin);
        vm.expectRevert(Errors.SameValue.selector);
        oracle.setFeed(address(feed));
    }

    function test_setTWAPSource_revertsSameValue() public {
        vm.prank(admin);
        vm.expectRevert(Errors.SameValue.selector);
        oracle.setTWAPSource(address(twap));
    }

    function test_setMaxPriceAge_revertsSameValue() public {
        vm.prank(admin);
        vm.expectRevert(Errors.SameValue.selector);
        oracle.setMaxPriceAge(3600);
    }

    function test_constructor_revertsOnZeroFeed() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        new OracleAdapter(admin, address(0), address(twap), 3600);
    }

    function test_constructor_revertsOnZeroMaxAge() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidParameter.selector, "maxAge"));
        new OracleAdapter(admin, address(feed), address(twap), 0);
    }

    function test_getPrice_higherDecimalsNormalised() public {
        // Swap in a feed with 20 decimals (rare but valid): should divide.
        MockChainlinkFeed feed20 = new MockChainlinkFeed(20, 100e20);
        vm.prank(admin);
        oracle.setFeed(address(feed20));
        assertEq(oracle.getPrimaryPrice(), 100e18);
    }
}