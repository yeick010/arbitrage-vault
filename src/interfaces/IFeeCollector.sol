// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Fee collector interface.
/// @notice Immutable treasury; fees accrue to it only.
interface IFeeCollector {
    /// @notice Treasury address — immutable after construction.
    function treasury() external view returns (address);

    /// @notice Current performance fee in basis points (≤ 1_000 = 10%).
    function performanceFeeBps() external view returns (uint256);

    /// @notice Pulls accrued fees in `token` from the caller (`msg.sender`) to the treasury.
    /// @dev Caller must have set allowance of `amount` for this contract. `msg.sender`
    ///      must be an authorised collector — this avoids any arbitrary `from` arg.
    function collect(address token, uint256 amount) external;

    /// @notice Computes the fee slice for a given profit amount.
    /// @param profit Profit realised (in asset units).
    /// @return fee The fee portion going to treasury.
    function computeFee(uint256 profit) external view returns (uint256 fee);
}