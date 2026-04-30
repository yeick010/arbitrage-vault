// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title Shared constants for the ArbitrageVault system.
library Const {
    /// @dev Basis points denominator. 10_000 BPS = 100%.
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    /// @dev Maximum performance fee in BPS (10%).
    uint256 internal constant MAX_PERFORMANCE_FEE_BPS = 1_000;

    /// @dev Minimum deposit in raw asset units (1e6 wei, prevents dust / rounding abuse).
    uint256 internal constant MIN_DEPOSIT = 1e6;

    /// @dev Timelock delay for critical setters (48 hours).
    uint256 internal constant TIMELOCK_DELAY = 48 hours;

    /// @dev Maximum allowed price deviation between primary oracle and fallback TWAP (2%).
    uint256 internal constant MAX_ORACLE_DEVIATION_BPS = 200;

    /// @dev Roles — defined here so every contract imports the same hash.
    bytes32 internal constant ADMIN_ROLE = 0x00; // DEFAULT_ADMIN_ROLE from OZ AccessControl
    bytes32 internal constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    bytes32 internal constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
}
