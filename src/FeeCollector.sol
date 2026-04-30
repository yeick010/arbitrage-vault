// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

import {IFeeCollector} from "./interfaces/IFeeCollector.sol";
import {Const} from "./common/Const.sol";
import {Errors} from "./common/Errors.sol";

/// @title FeeCollector
/// @notice Routes performance fees to an immutable treasury.
/// @dev Treasury is immutable so it cannot be maliciously reassigned post-deploy.
///      Fee BPS can be lowered (but never exceed MAX_PERFORMANCE_FEE_BPS = 10%).
contract FeeCollector is IFeeCollector, AccessControl {
    using SafeERC20 for IERC20;

    /// @inheritdoc IFeeCollector
    address public immutable treasury;

    /// @notice Current performance fee in basis points (cap 10%).
    uint256 public performanceFeeBps;

    /// @notice Authorised callers for `collect()` (typically the vault).
    mapping(address collector => bool authorised) public authorisedCollector;

    /// @notice Emitted when performance fee is updated.
    /// @param oldFeeBps Previous fee in BPS.
    /// @param newFeeBps New fee in BPS.
    event PerformanceFeeUpdated(uint256 oldFeeBps, uint256 newFeeBps);

    /// @notice Emitted when fees are collected to the treasury.
    /// @param token ERC20 token collected.
    /// @param from Source address (the vault).
    /// @param amount Amount forwarded to treasury.
    event FeesCollected(address indexed token, address indexed from, uint256 amount);

    /// @notice Emitted when an authorised collector is added/removed.
    /// @param collector Address updated.
    /// @param authorised True = added, false = removed.
    event CollectorAuthorised(address indexed collector, bool authorised);

    /// @param admin Initial ADMIN_ROLE holder (multisig recommended).
    /// @param treasury_ Immutable treasury receiving all fees.
    /// @param feeBps Initial performance fee in BPS (≤ 1_000 = 10%).
    constructor(address admin, address treasury_, uint256 feeBps) {
        if (admin == address(0)) revert Errors.ZeroAddress();
        if (treasury_ == address(0)) revert Errors.ZeroAddress();
        if (feeBps > Const.MAX_PERFORMANCE_FEE_BPS) {
            revert Errors.FeeTooHigh(feeBps, Const.MAX_PERFORMANCE_FEE_BPS);
        }

        treasury = treasury_;
        performanceFeeBps = feeBps;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /// @notice Updates the performance fee (capped at 10%).
    /// @param newFeeBps New fee in BPS.
    function setPerformanceFee(uint256 newFeeBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newFeeBps > Const.MAX_PERFORMANCE_FEE_BPS) {
            revert Errors.FeeTooHigh(newFeeBps, Const.MAX_PERFORMANCE_FEE_BPS);
        }
        if (newFeeBps == performanceFeeBps) revert Errors.SameValue();

        uint256 oldFeeBps = performanceFeeBps;
        performanceFeeBps = newFeeBps;
        emit PerformanceFeeUpdated(oldFeeBps, newFeeBps);
    }

    /// @notice Authorises or revokes a collector (typically the vault contract).
    /// @param collector Address to update.
    /// @param authorised True to authorise, false to revoke.
    function setAuthorisedCollector(address collector, bool authorised) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (collector == address(0)) revert Errors.ZeroAddress();
        authorisedCollector[collector] = authorised;
        emit CollectorAuthorised(collector, authorised);
    }

    /// @inheritdoc IFeeCollector
    /// @dev Pulls exactly `amount` of `token` from `from` and forwards to the immutable treasury.
    ///      Caller MUST be an authorised collector AND `from` MUST have approved this contract.
    function collect(address token, address from, uint256 amount) external {
        if (!authorisedCollector[msg.sender]) revert Errors.Unauthorized(msg.sender);
        if (token == address(0) || from == address(0)) revert Errors.ZeroAddress();
        if (amount == 0) revert Errors.ZeroAmount();

        // Pull from `from`, then forward — CEI: no state changes here other than token balances.
        IERC20(token).safeTransferFrom(from, treasury, amount);
        emit FeesCollected(token, from, amount);
    }

    /// @notice Computes fee slice for a given profit amount.
    /// @param profit Profit realised (in asset units).
    /// @return fee The fee portion going to treasury.
    function computeFee(uint256 profit) external view returns (uint256 fee) {
        fee = (profit * performanceFeeBps) / Const.BPS_DENOMINATOR;
    }
}