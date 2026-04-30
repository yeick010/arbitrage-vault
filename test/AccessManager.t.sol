// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { AccessManager } from "../src/AccessManager.sol";
import { Errors } from "../src/common/Errors.sol";
import { Const } from "../src/common/Const.sol";

contract AccessManagerTest is Test {
    address internal admin = makeAddr("admin");
    address internal keeper = makeAddr("keeper");
    address internal pauser = makeAddr("pauser");

    AccessManager internal access;

    function setUp() public {
        access = new AccessManager(admin, keeper, pauser);
    }

    function test_rolesGranted() public view {
        assertTrue(access.isAdmin(admin));
        assertTrue(access.isKeeper(keeper));
        assertTrue(access.isPauser(pauser));
        assertFalse(access.isAdmin(keeper));
        assertFalse(access.isKeeper(pauser));
        assertFalse(access.isPauser(admin));
    }

    function test_constructor_revertsOnZeroAdmin() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        new AccessManager(address(0), keeper, pauser);
    }

    function test_constructor_revertsOnZeroKeeper() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        new AccessManager(admin, address(0), pauser);
    }

    function test_constructor_revertsOnZeroPauser() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        new AccessManager(admin, keeper, address(0));
    }

    function test_adminCanGrantKeeper() public {
        address newKeeper = makeAddr("nk");
        vm.prank(admin);
        access.grantRole(Const.KEEPER_ROLE, newKeeper);
        assertTrue(access.isKeeper(newKeeper));
    }
}
