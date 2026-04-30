// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Strategy executor interface.
/// @notice Executes arbitrage swaps on behalf of the vault with mandatory slippage protection.
interface IStrategyExecutor {
    /// @notice Parameters for a single arbitrage execution.
    /// @param router DEX router address (must be whitelisted).
    /// @param path Encoded swap path (router-specific, e.g. Uniswap V3 bytes path).
    /// @param amountIn Amount of asset to swap.
    /// @param minAmountOut Slippage bound; tx reverts if received < minAmountOut.
    /// @param deadline Unix timestamp after which the tx reverts.
    struct ArbitrageParams {
        address router;
        bytes path;
        uint256 amountIn;
        uint256 minAmountOut;
        uint256 deadline;
    }

    /// @notice Executes an arbitrage with slippage protection.
    /// @param params Arbitrage parameters including minAmountOut.
    /// @return amountOut The actual amount received.
    function executeArbitrage(ArbitrageParams calldata params) external returns (uint256 amountOut);

    /// @notice Returns the vault this executor is bound to.
    function vault() external view returns (address);
}