// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Oracle adapter interface.
/// @notice Abstracts Chainlink primary + TWAP fallback pricing.
interface IOracleAdapter {
    /// @notice Returns asset price in 1e18 fixed-point USD.
    /// @return price18 Normalised to 18 decimals.
    function getPrice() external view returns (uint256 price18);

    /// @notice Returns primary Chainlink price (18 decimals) without fallback logic.
    function getPrimaryPrice() external view returns (uint256 price18);

    /// @notice Returns fallback TWAP price (18 decimals).
    function getFallbackPrice() external view returns (uint256 price18);
}