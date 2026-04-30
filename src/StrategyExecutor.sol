// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";

import { IStrategyExecutor } from "./interfaces/IStrategyExecutor.sol";
import { Errors } from "./common/Errors.sol";

/// @notice Minimal Uniswap V3–style swap router interface used by the executor.
interface ISwapRouter {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
}

/// @title StrategyExecutor
/// @notice Executes cross-DEX arbitrage swaps on behalf of the vault.
/// @dev Swap path flow:
///      1. vault approves executor for `amountIn`
///      2. vault calls `executeArbitrage(params)` (vault has KEEPER_ROLE on itself → we use msg.sender == vault check)
///      3. executor pulls `amountIn`, approves router, calls `exactInput`
///      4. router sends output directly back to vault (recipient = vault)
///      5. executor returns amountOut
///
///      Security:
///      - Bound to a single vault (immutable) — no cross-vault trust boundary bypass.
///      - Router must be whitelisted by ADMIN_ROLE.
///      - minAmountOut enforced both at router level and at vault level.
///      - ReentrancyGuard (executor does not hold funds between calls).
contract StrategyExecutor is IStrategyExecutor, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @inheritdoc IStrategyExecutor
    address public immutable vault;

    /// @notice Asset managed by the bound vault.
    IERC20 public immutable assetToken;

    /// @notice Routers allowed for swaps.
    mapping(address router => bool whitelisted) public whitelistedRouter;

    /// @notice Emitted when a router is added / removed from the whitelist.
    event RouterWhitelisted(address indexed router, bool whitelisted);

    /// @notice Emitted after a successful arbitrage.
    /// @param router Router used.
    /// @param amountIn Amount swapped in.
    /// @param amountOut Amount received back to vault.
    event ArbitrageExecuted(address indexed router, uint256 amountIn, uint256 amountOut);

    modifier onlyVault() {
        if (msg.sender != vault) revert Errors.Unauthorized(msg.sender);
        _;
    }

    /// @param admin ADMIN_ROLE holder (multisig).
    /// @param vault_ Vault address (immutable binding).
    /// @param asset_ Underlying asset of the vault.
    constructor(address admin, address vault_, address asset_) {
        if (admin == address(0) || vault_ == address(0) || asset_ == address(0)) revert Errors.ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);

        vault = vault_;
        assetToken = IERC20(asset_);
    }

    /// @notice Whitelist / de-whitelist a router.
    /// @param router Router address.
    /// @param allowed True to allow, false to revoke.
    function setRouterWhitelist(address router, bool allowed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (router == address(0)) revert Errors.ZeroAddress();
        whitelistedRouter[router] = allowed;
        emit RouterWhitelisted(router, allowed);
    }

    /// @inheritdoc IStrategyExecutor
    function executeArbitrage(ArbitrageParams calldata params)
        external
        override
        nonReentrant
        onlyVault
        returns (uint256 amountOut)
    {
        if (!whitelistedRouter[params.router]) revert Errors.RouterNotWhitelisted(params.router);
        if (params.amountIn == 0) revert Errors.ZeroAmount();
        if (params.minAmountOut == 0) revert Errors.InsufficientOutput(0, 1);
        if (params.path.length == 0) revert Errors.InvalidPath();
        // solhint-disable-next-line not-rely-on-time
        if (params.deadline < block.timestamp) revert Errors.InvalidParameter("deadline");

        // Checks done. Effects: pull funds from msg.sender (== vault, enforced by onlyVault).
        // Using msg.sender (not an arbitrary `from`) eliminates the arbitrary-send-erc20 surface.
        assetToken.safeTransferFrom(msg.sender, address(this), params.amountIn);
        assetToken.forceApprove(params.router, params.amountIn);

        // Interactions: execute swap — router sends output directly back to vault.
        // The router's `amountOutMinimum` is the primary slippage gate. We then re-check
        // `amountOut >= minAmountOut` (defence-in-depth against non-conforming routers).
        amountOut = ISwapRouter(params.router)
            .exactInput(
                ISwapRouter.ExactInputParams({
                path: params.path,
                recipient: vault,
                deadline: params.deadline,
                amountIn: params.amountIn,
                amountOutMinimum: params.minAmountOut
            })
            );

        if (amountOut < params.minAmountOut) {
            revert Errors.InsufficientOutput(amountOut, params.minAmountOut);
        }

        // Clear allowance (defence-in-depth for non-standard tokens).
        assetToken.forceApprove(params.router, 0);

        emit ArbitrageExecuted(params.router, params.amountIn, amountOut);
    }
}
