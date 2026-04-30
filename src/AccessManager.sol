// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { Const } from "./common/Const.sol";
import { Errors } from "./common/Errors.sol";

/// @title AccessManager
/// @notice Centralises role management for the ArbitrageVault system.
/// @dev Uses OpenZeppelin AccessControl with three roles:
///      - ADMIN_ROLE   (DEFAULT_ADMIN_ROLE): configuration, role granting
///      - KEEPER_ROLE : executes rebalance / strategy ops
///      - PAUSER_ROLE : emergency pause
///      No single EOA owner — deploy with a multisig as `admin`.
contract AccessManager is AccessControl {
    bytes32 public constant KEEPER_ROLE = Const.KEEPER_ROLE;
    bytes32 public constant PAUSER_ROLE = Const.PAUSER_ROLE;

    /// @param admin Initial ADMIN_ROLE holder (should be a multisig).
    /// @param keeper Initial KEEPER_ROLE holder.
    /// @param pauser Initial PAUSER_ROLE holder.
    constructor(address admin, address keeper, address pauser) {
        if (admin == address(0)) revert Errors.ZeroAddress();
        if (keeper == address(0)) revert Errors.ZeroAddress();
        if (pauser == address(0)) revert Errors.ZeroAddress();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(KEEPER_ROLE, keeper);
        _grantRole(PAUSER_ROLE, pauser);

        // ADMIN_ROLE administers itself + subordinate roles.
        _setRoleAdmin(KEEPER_ROLE, DEFAULT_ADMIN_ROLE);
        _setRoleAdmin(PAUSER_ROLE, DEFAULT_ADMIN_ROLE);
    }

    /// @notice Returns true if `account` has KEEPER_ROLE.
    function isKeeper(address account) external view returns (bool) {
        return hasRole(KEEPER_ROLE, account);
    }

    /// @notice Returns true if `account` has PAUSER_ROLE.
    function isPauser(address account) external view returns (bool) {
        return hasRole(PAUSER_ROLE, account);
    }

    /// @notice Returns true if `account` has ADMIN_ROLE.
    function isAdmin(address account) external view returns (bool) {
        return hasRole(DEFAULT_ADMIN_ROLE, account);
    }
}
