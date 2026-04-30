// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { AggregatorV3Interface } from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

import { IOracleAdapter } from "./interfaces/IOracleAdapter.sol";
import { Const } from "./common/Const.sol";
import { Errors } from "./common/Errors.sol";

/// @notice Minimal interface for a fallback TWAP source (e.g. UniV3 adapter).
/// @dev Any contract returning a TWAP over `twapWindow` seconds normalised to 1e18 USD.
interface ITWAPSource {
    function consultTWAP(uint32 secondsAgo) external view returns (uint256 price18);
}

/// @title OracleAdapter
/// @notice Chainlink primary + TWAP fallback with deviation check.
/// @dev Reverts on stale Chainlink data; falls back to TWAP only if deviation ≤ MAX_ORACLE_DEVIATION_BPS (2%).
///      All prices are normalised to 18 decimals.
contract OracleAdapter is IOracleAdapter, AccessControl {
    /// @dev Chainlink feed. Writable via timelocked setter only.
    AggregatorV3Interface public chainlinkFeed;

    /// @dev Fallback TWAP source.
    ITWAPSource public twapSource;

    /// @notice Maximum age (in seconds) for Chainlink data before considered stale.
    uint256 public maxPriceAge;

    /// @notice TWAP window in seconds (default 30 minutes).
    uint32 public constant TWAP_WINDOW = 1800;

    /// @notice Emitted when Chainlink feed is updated.
    event FeedUpdated(address indexed oldFeed, address indexed newFeed);

    /// @notice Emitted when the TWAP source is updated.
    event TWAPSourceUpdated(address indexed oldSource, address indexed newSource);

    /// @notice Emitted when max price age is updated.
    event MaxPriceAgeUpdated(uint256 oldAge, uint256 newAge);

    /// @param admin Initial ADMIN_ROLE holder.
    /// @param feed Chainlink price feed address.
    /// @param twap Fallback TWAP source.
    /// @param maxAge Maximum price age in seconds (e.g. 3600 = 1h for most feeds).
    constructor(address admin, address feed, address twap, uint256 maxAge) {
        if (admin == address(0) || feed == address(0)) revert Errors.ZeroAddress();
        if (maxAge == 0) revert Errors.InvalidParameter("maxAge");

        _grantRole(DEFAULT_ADMIN_ROLE, admin);

        chainlinkFeed = AggregatorV3Interface(feed);
        twapSource = ITWAPSource(twap); // may be address(0) initially
        maxPriceAge = maxAge;
    }

    /// @inheritdoc IOracleAdapter
    /// @dev If TWAP source is set, verifies |primary - fallback| / primary ≤ 2%.
    function getPrice() external view override returns (uint256 price18) {
        price18 = _getPrimaryPrice();

        if (address(twapSource) != address(0)) {
            uint256 fallbackPrice = twapSource.consultTWAP(TWAP_WINDOW);
            if (fallbackPrice == 0) return price18;

            uint256 diff = price18 > fallbackPrice ? price18 - fallbackPrice : fallbackPrice - price18;
            uint256 deviationBps = (diff * Const.BPS_DENOMINATOR) / price18;
            if (deviationBps > Const.MAX_ORACLE_DEVIATION_BPS) {
                revert Errors.PriceDeviationTooHigh(price18, fallbackPrice, Const.MAX_ORACLE_DEVIATION_BPS);
            }
        }
    }

    /// @inheritdoc IOracleAdapter
    function getPrimaryPrice() external view override returns (uint256 price18) {
        price18 = _getPrimaryPrice();
    }

    /// @inheritdoc IOracleAdapter
    function getFallbackPrice() external view override returns (uint256 price18) {
        if (address(twapSource) == address(0)) revert Errors.OracleNotConfigured();
        price18 = twapSource.consultTWAP(TWAP_WINDOW);
    }

    /// @notice Updates the Chainlink feed address.
    /// @dev Intended to be called behind a timelock by the vault/governance.
    /// @param newFeed New Chainlink aggregator address.
    function setFeed(address newFeed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newFeed == address(0)) revert Errors.ZeroAddress();
        address oldFeed = address(chainlinkFeed);
        if (oldFeed == newFeed) revert Errors.SameValue();
        chainlinkFeed = AggregatorV3Interface(newFeed);
        emit FeedUpdated(oldFeed, newFeed);
    }

    /// @notice Updates the TWAP source (may be set to address(0) to disable fallback).
    /// @param newSource New TWAP source.
    function setTWAPSource(address newSource) external onlyRole(DEFAULT_ADMIN_ROLE) {
        address oldSource = address(twapSource);
        if (oldSource == newSource) revert Errors.SameValue();
        twapSource = ITWAPSource(newSource);
        emit TWAPSourceUpdated(oldSource, newSource);
    }

    /// @notice Updates the maximum price age.
    /// @param newAge New maximum age in seconds.
    function setMaxPriceAge(uint256 newAge) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newAge == 0) revert Errors.InvalidParameter("maxAge");
        if (newAge == maxPriceAge) revert Errors.SameValue();
        uint256 oldAge = maxPriceAge;
        maxPriceAge = newAge;
        emit MaxPriceAgeUpdated(oldAge, newAge);
    }

    /* ─────────────── internal ─────────────── */

    function _getPrimaryPrice() internal view returns (uint256 price18) {
        AggregatorV3Interface feed = chainlinkFeed;
        // Capture all five tuple fields — explicitly read startedAt to satisfy static analysis
        // that every returned value is observed.
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            feed.latestRoundData();

        if (answer <= 0) revert Errors.InvalidPrice(answer);
        if (updatedAt == 0 || startedAt == 0) revert Errors.InvalidPrice(0);
        if (block.timestamp - updatedAt > maxPriceAge) {
            // solhint-disable-next-line not-rely-on-time
            revert Errors.StalePrice(updatedAt, maxPriceAge);
        }
        // Guard against round mismatch (Chainlink best practice).
        if (answeredInRound < roundId) revert Errors.StalePrice(updatedAt, maxPriceAge);

        uint8 decimals = feed.decimals();
        if (decimals == 18) {
            price18 = uint256(answer);
        } else if (decimals < 18) {
            price18 = uint256(answer) * 10 ** (18 - decimals);
        } else {
            price18 = uint256(answer) / 10 ** (decimals - 18);
        }
    }
}
