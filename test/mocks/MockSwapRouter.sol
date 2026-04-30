// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ISwapRouter } from "../../src/StrategyExecutor.sol";

/// @notice Deterministic swap router mock — for same-asset arbitrage simulation.
///         `outputMultiplierBps` controls the return (10_000 = 100% = no-op).
contract MockSwapRouter is ISwapRouter {
    using SafeERC20 for IERC20;

    IERC20 public immutable token;
    // 10_500 = +5% profit, 9_500 = −5% loss.
    uint256 public outputMultiplierBps = 10_000;

    constructor(IERC20 token_) {
        token = token_;
    }

    function setMultiplier(uint256 bps) external {
        outputMultiplierBps = bps;
    }

    function exactInput(ExactInputParams calldata params) external payable override returns (uint256 amountOut) {
        // Pull input from executor.
        token.safeTransferFrom(msg.sender, address(this), params.amountIn);

        amountOut = (params.amountIn * outputMultiplierBps) / 10_000;
        require(amountOut >= params.amountOutMinimum, "MockSwapRouter: slippage");

        // Send output directly to recipient (as a real V3 router would).
        token.safeTransfer(params.recipient, amountOut);
    }

    /// @notice Fund the router with tokens to cover output.
    function fund(uint256 amount) external {
        token.safeTransferFrom(msg.sender, address(this), amount);
    }
}
