// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Shared custom errors for the ArbitrageVault system.
/// @notice Using custom errors saves gas and produces structured revert data.
library Errors {
    /* ─────────────── Access / Config ─────────────── */
    error ZeroAddress();
    error ZeroAmount();
    error Unauthorized(address caller);
    error SameValue();
    error InvalidParameter(string name);

    /* ─────────────── Vault ─────────────── */
    error DepositBelowMinimum(uint256 assets, uint256 minimum);
    error ExceedsMaxPerTx(uint256 amount, uint256 maximum);
    error TreasuryNotSet();
    error FeeTooHigh(uint256 feeBps, uint256 maxFeeBps);

    /* ─────────────── Strategy ─────────────── */
    error InsufficientOutput(uint256 received, uint256 minimum);
    error StrategyNotSet();
    error RouterNotWhitelisted(address router);
    error InvalidPath();

    /* ─────────────── Oracle ─────────────── */
    error StalePrice(uint256 updatedAt, uint256 maxAge);
    error InvalidPrice(int256 price);
    error PriceDeviationTooHigh(uint256 primary, uint256 fallback_, uint256 maxBps);
    error OracleNotConfigured();

    /* ─────────────── Timelock ─────────────── */
    error TimelockActive(uint256 readyAt);
    error TimelockNotScheduled();
    error TimelockAlreadyScheduled();
}