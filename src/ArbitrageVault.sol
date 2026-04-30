// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20, IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IFeeCollector} from "./interfaces/IFeeCollector.sol";
import {IStrategyExecutor} from "./interfaces/IStrategyExecutor.sol";
import {Const} from "./common/Const.sol";
import {Errors} from "./common/Errors.sol";

/// @title ArbitrageVault
/// @notice ERC-4626 vault that deposits a single asset and routes capital through a whitelisted
///         arbitrage strategy, charging a performance fee (capped at 10%) on realised profits.
/// @dev Security posture:
///      - ReentrancyGuard on every public entrypoint that moves funds or triggers external calls.
///      - Pausable with a dedicated PAUSER_ROLE (emergency stop).
///      - AccessControl with ADMIN_ROLE / KEEPER_ROLE (multisig-ready — no EOA owner).
///      - OZ v5 virtual shares + offset (_decimalsOffset = 6) mitigates inflation attack.
///      - minDeposit (1e6 wei) + maxAssetsPerTx guard against DoS / dust griefing.
///      - Timelock (48h) required before any setFee / setOracle / setStrategy activation.
///      - Slippage mandatory on rebalance (minAmountOut bubbles from keeper to executor).
///      - CEI ordering everywhere.
contract ArbitrageVault is ERC4626, AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;
    using Math for uint256;

    /* ─────────────── Roles ─────────────── */
    bytes32 public constant KEEPER_ROLE = Const.KEEPER_ROLE;
    bytes32 public constant PAUSER_ROLE = Const.PAUSER_ROLE;

    /* ─────────────── Config (timelock-protected) ─────────────── */

    /// @notice Pending value wrapper for timelocked setters.
    struct PendingAddress {
        address value;
        uint256 readyAt;
        bool scheduled;
    }

    struct PendingUint {
        uint256 value;
        uint256 readyAt;
        bool scheduled;
    }

    /// @notice Fee collector contract (receives performance fees).
    IFeeCollector public feeCollector;

    /// @notice Strategy executor.
    IStrategyExecutor public strategy;

    /// @notice Oracle adapter address (informational — vault does not depend on it for share math).
    address public oracle;

    /// @notice Maximum raw assets per deposit / withdraw tx (DoS guard).
    uint256 public maxAssetsPerTx;

    /// @notice Total assets already counted as "high water mark" — used to compute realised profit.
    uint256 public highWaterMark;

    /// @dev Pending state for timelocked setters.
    PendingAddress internal _pendingFeeCollector;
    PendingAddress internal _pendingStrategy;
    PendingAddress internal _pendingOracle;

    /* ─────────────── Events ─────────────── */

    /// @notice Emitted when rebalance is executed.
    event Rebalanced(address indexed keeper, uint256 amountIn, uint256 amountOut, uint256 profit, uint256 fee);

    /// @notice Emitted when max assets per tx updated.
    event MaxAssetsPerTxUpdated(uint256 oldValue, uint256 newValue);

    /// @notice Emitted when a timelocked setter is scheduled.
    /// @param kind Config key ("feeCollector" | "strategy" | "oracle").
    event ChangeScheduled(string kind, address newValue, uint256 readyAt);

    /// @notice Emitted when a timelocked setter is cancelled.
    event ChangeCancelled(string kind);

    /// @notice Emitted when a timelocked setter is executed.
    event ChangeApplied(string kind, address oldValue, address newValue);

    /// @notice Emitted on emergency rescue of non-asset tokens.
    event EmergencyRescue(address indexed token, address indexed to, uint256 amount);

    /* ─────────────── Constructor ─────────────── */

    /// @param asset_ Underlying ERC20 (must have ≤ 18 decimals).
    /// @param admin ADMIN_ROLE holder (multisig).
    /// @param keeper KEEPER_ROLE holder.
    /// @param pauser PAUSER_ROLE holder.
    /// @param feeCollector_ Initial FeeCollector.
    /// @param maxPerTx Initial max assets per tx.
    constructor(
        IERC20 asset_,
        address admin,
        address keeper,
        address pauser,
        address feeCollector_,
        uint256 maxPerTx
    )
        ERC20(
            string(abi.encodePacked("ArbitrageVault ", IERC20Metadata(address(asset_)).symbol())),
            string(abi.encodePacked("av", IERC20Metadata(address(asset_)).symbol()))
        )
        ERC4626(asset_)
    {
        if (
            admin == address(0) || keeper == address(0) || pauser == address(0)
                || feeCollector_ == address(0) || address(asset_) == address(0)
        ) revert Errors.ZeroAddress();
        if (maxPerTx == 0) revert Errors.InvalidParameter("maxPerTx");
        if (IERC20Metadata(address(asset_)).decimals() > 18) revert Errors.InvalidParameter("assetDecimals");

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(KEEPER_ROLE, keeper);
        _grantRole(PAUSER_ROLE, pauser);

        feeCollector = IFeeCollector(feeCollector_);
        maxAssetsPerTx = maxPerTx;
    }

    /* ─────────────── ERC-4626 overrides (CEI + guards) ─────────────── */

    /// @dev OZ v5 ERC4626 uses virtual shares with _decimalsOffset to mitigate the classic
    ///      inflation attack. We raise the offset to 6 for stronger protection.
    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    /// @notice Total assets = balance of vault (excludes in-flight strategy amounts for simplicity).
    /// @dev Strategy ops pull + return assets atomically (see executeRebalance), so no external bookkeeping needed.
    function totalAssets() public view override returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
    }

    /// @inheritdoc ERC4626
    function deposit(uint256 assets, address receiver)
        public
        override
        whenNotPaused
        nonReentrant
        returns (uint256)
    {
        _enforceDepositLimits(assets);
        return super.deposit(assets, receiver);
    }

    /// @inheritdoc ERC4626
    function mint(uint256 shares, address receiver) public override whenNotPaused nonReentrant returns (uint256) {
        uint256 assets = previewMint(shares);
        _enforceDepositLimits(assets);
        return super.mint(shares, receiver);
    }

    /// @inheritdoc ERC4626
    function withdraw(uint256 assets, address receiver, address owner_)
        public
        override
        whenNotPaused
        nonReentrant
        returns (uint256)
    {
        if (assets > maxAssetsPerTx) revert Errors.ExceedsMaxPerTx(assets, maxAssetsPerTx);
        return super.withdraw(assets, receiver, owner_);
    }

    /// @inheritdoc ERC4626
    function redeem(uint256 shares, address receiver, address owner_)
        public
        override
        whenNotPaused
        nonReentrant
        returns (uint256)
    {
        uint256 assets = previewRedeem(shares);
        if (assets > maxAssetsPerTx) revert Errors.ExceedsMaxPerTx(assets, maxAssetsPerTx);
        return super.redeem(shares, receiver, owner_);
    }

    /// @dev Shared deposit-side guard.
    function _enforceDepositLimits(uint256 assets) internal view {
        if (assets < Const.MIN_DEPOSIT) revert Errors.DepositBelowMinimum(assets, Const.MIN_DEPOSIT);
        if (assets > maxAssetsPerTx) revert Errors.ExceedsMaxPerTx(assets, maxAssetsPerTx);
    }

    /* ─────────────── Rebalance ─────────────── */

    /// @notice Executes an arbitrage via the configured strategy, charging perf fee on profit.
    /// @dev Slippage enforced inside `strategy.executeArbitrage` (minAmountOut).
    ///      CEI: balance snapshot → external call → state update → fee forward.
    /// @param params Strategy parameters forwarded to the executor.
    /// @return profit Net profit realised for the vault (0 if no profit).
    function executeRebalance(IStrategyExecutor.ArbitrageParams calldata params)
        external
        whenNotPaused
        nonReentrant
        onlyRole(KEEPER_ROLE)
        returns (uint256 profit)
    {
        IStrategyExecutor _strategy = strategy;
        if (address(_strategy) == address(0)) revert Errors.StrategyNotSet();
        if (params.amountIn == 0) revert Errors.ZeroAmount();
        if (params.minAmountOut == 0) revert Errors.InsufficientOutput(0, 1);

        IERC20 assetToken = IERC20(asset());
        uint256 balanceBefore = assetToken.balanceOf(address(this));
        if (params.amountIn > balanceBefore) revert Errors.InsufficientOutput(balanceBefore, params.amountIn);

        // Checks done. Effects: approve strategy (exact amount).
        assetToken.forceApprove(address(_strategy), params.amountIn);

        // Interactions: executor pulls `amountIn`, performs arbitrage, returns `amountOut` to vault.
        uint256 amountOut = _strategy.executeArbitrage(params);
        if (amountOut < params.minAmountOut) revert Errors.InsufficientOutput(amountOut, params.minAmountOut);

        // Clear stale allowance (forceApprove handles non-standard tokens).
        assetToken.forceApprove(address(_strategy), 0);

        uint256 balanceAfter = assetToken.balanceOf(address(this));

        // Compute profit vs HWM. If balance fell (slippage within bound) no fee is taken.
        uint256 hwm = highWaterMark;
        if (balanceAfter > hwm) {
            profit = balanceAfter - hwm;
            uint256 fee = feeCollector.computeFee(profit);
            if (fee > 0) {
                // Approve exact fee, then pull via collector (pull pattern, CEI-safe).
                assetToken.forceApprove(address(feeCollector), fee);
                feeCollector.collect(address(assetToken), fee);
                assetToken.forceApprove(address(feeCollector), 0);
                balanceAfter -= fee;
            }
            highWaterMark = balanceAfter;
            emit Rebalanced(msg.sender, params.amountIn, amountOut, profit, fee);
        } else {
            emit Rebalanced(msg.sender, params.amountIn, amountOut, 0, 0);
        }
    }

    /* ─────────────── Pausable ─────────────── */

    /// @notice Emergency pause — halts deposit / mint / withdraw / redeem / rebalance.
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @notice Resume operations.
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /* ─────────────── Timelocked setters ─────────────── */

    /// @notice Schedule FeeCollector replacement (48h delay).
    function scheduleFeeCollector(address newValue) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newValue == address(0)) revert Errors.ZeroAddress();
        _schedule(_pendingFeeCollector, newValue, "feeCollector");
    }

    /// @notice Execute previously scheduled FeeCollector update.
    function applyFeeCollector() external onlyRole(DEFAULT_ADMIN_ROLE) {
        address oldV = address(feeCollector);
        address newV = _consume(_pendingFeeCollector);
        feeCollector = IFeeCollector(newV);
        emit ChangeApplied("feeCollector", oldV, newV);
    }

    /// @notice Cancel a scheduled FeeCollector change.
    function cancelFeeCollector() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _cancel(_pendingFeeCollector, "feeCollector");
    }

    /// @notice Schedule Strategy replacement (48h delay).
    function scheduleStrategy(address newValue) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newValue == address(0)) revert Errors.ZeroAddress();
        _schedule(_pendingStrategy, newValue, "strategy");
    }

    /// @notice Execute previously scheduled Strategy update.
    function applyStrategy() external onlyRole(DEFAULT_ADMIN_ROLE) {
        address oldV = address(strategy);
        address newV = _consume(_pendingStrategy);
        strategy = IStrategyExecutor(newV);
        emit ChangeApplied("strategy", oldV, newV);
    }

    /// @notice Cancel a scheduled Strategy change.
    function cancelStrategy() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _cancel(_pendingStrategy, "strategy");
    }

    /// @notice Schedule Oracle replacement (48h delay).
    function scheduleOracle(address newValue) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newValue == address(0)) revert Errors.ZeroAddress();
        _schedule(_pendingOracle, newValue, "oracle");
    }

    /// @notice Execute previously scheduled Oracle update.
    function applyOracle() external onlyRole(DEFAULT_ADMIN_ROLE) {
        address oldV = oracle;
        address newV = _consume(_pendingOracle);
        oracle = newV;
        emit ChangeApplied("oracle", oldV, newV);
    }

    /// @notice Cancel a scheduled Oracle change.
    function cancelOracle() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _cancel(_pendingOracle, "oracle");
    }

    /* ─────────────── Non-timelocked admin ─────────────── */

    /// @notice Update max assets per tx (no timelock — circuit-breaker).
    function setMaxAssetsPerTx(uint256 newMax) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newMax == 0) revert Errors.InvalidParameter("maxPerTx");
        if (newMax == maxAssetsPerTx) revert Errors.SameValue();
        uint256 oldV = maxAssetsPerTx;
        maxAssetsPerTx = newMax;
        emit MaxAssetsPerTxUpdated(oldV, newMax);
    }

    /// @notice Sync high-water mark to current balance. Called after intentional deposits
    ///         are fully included as principal, or after losses are realised.
    /// @dev nonReentrant is redundant (no external calls) but added for defence-in-depth
    ///      — prevents any cross-function reentrancy on `highWaterMark`.
    function syncHighWaterMark() external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        highWaterMark = totalAssets();
    }

    /// @notice Rescue non-asset ERC20s mistakenly sent to the vault.
    /// @dev Cannot rescue `asset()` — that is depositor funds.
    function rescueToken(address token, address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == asset()) revert Errors.InvalidParameter("asset");
        if (to == address(0)) revert Errors.ZeroAddress();
        if (amount == 0) revert Errors.ZeroAmount();
        IERC20(token).safeTransfer(to, amount);
        emit EmergencyRescue(token, to, amount);
    }

    /* ─────────────── View helpers ─────────────── */

    /// @notice Returns pending setter info.
    function pendingFeeCollector() external view returns (address value, uint256 readyAt, bool scheduled) {
        return (_pendingFeeCollector.value, _pendingFeeCollector.readyAt, _pendingFeeCollector.scheduled);
    }

    /// @notice Returns pending setter info.
    function pendingStrategy() external view returns (address value, uint256 readyAt, bool scheduled) {
        return (_pendingStrategy.value, _pendingStrategy.readyAt, _pendingStrategy.scheduled);
    }

    /// @notice Returns pending setter info.
    function pendingOracle() external view returns (address value, uint256 readyAt, bool scheduled) {
        return (_pendingOracle.value, _pendingOracle.readyAt, _pendingOracle.scheduled);
    }

    /* ─────────────── Internal timelock helpers ─────────────── */

    function _schedule(PendingAddress storage slot, address newValue, string memory kind) internal {
        if (slot.scheduled) revert Errors.TimelockAlreadyScheduled();
        slot.value = newValue;
        slot.readyAt = block.timestamp + Const.TIMELOCK_DELAY;
        slot.scheduled = true;
        emit ChangeScheduled(kind, newValue, slot.readyAt);
    }

    function _consume(PendingAddress storage slot) internal returns (address v) {
        if (!slot.scheduled) revert Errors.TimelockNotScheduled();
        if (block.timestamp < slot.readyAt) revert Errors.TimelockActive(slot.readyAt);
        v = slot.value;
        delete slot.value;
        slot.readyAt = 0;
        slot.scheduled = false;
    }

    function _cancel(PendingAddress storage slot, string memory kind) internal {
        if (!slot.scheduled) revert Errors.TimelockNotScheduled();
        delete slot.value;
        slot.readyAt = 0;
        slot.scheduled = false;
        emit ChangeCancelled(kind);
    }
}