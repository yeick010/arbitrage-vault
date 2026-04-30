// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Base } from "./Base.t.sol";
import { Errors } from "../src/common/Errors.sol";
import { Const } from "../src/common/Const.sol";
import { IStrategyExecutor } from "../src/interfaces/IStrategyExecutor.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ArbitrageVault } from "../src/ArbitrageVault.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";

contract ArbitrageVaultTest is Base {
    /* ─────────────── Constructor / setup ─────────────── */

    function test_constructor_grantsRoles() public view {
        assertTrue(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(vault.hasRole(vault.KEEPER_ROLE(), keeper));
        assertTrue(vault.hasRole(vault.PAUSER_ROLE(), pauser));
    }

    function test_constructor_revertsOnZeroAdmin() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        new ArbitrageVault(asset, address(0), keeper, pauser, address(feeCollector), MAX_PER_TX);
    }

    function test_constructor_revertsOnZeroMaxPerTx() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidParameter.selector, "maxPerTx"));
        new ArbitrageVault(asset, admin, keeper, pauser, address(feeCollector), 0);
    }

    /* ─────────────── Deposit ─────────────── */

    function test_deposit_successMintsShares() public {
        uint256 shares = _deposit(alice, 1e18);
        assertGt(shares, 0);
        assertEq(vault.balanceOf(alice), shares);
        assertEq(asset.balanceOf(address(vault)), 1e18);
    }

    function test_deposit_revertsBelowMinimum() public {
        vm.startPrank(alice);
        asset.approve(address(vault), 1e5);
        vm.expectRevert(abi.encodeWithSelector(Errors.DepositBelowMinimum.selector, 1e5, Const.MIN_DEPOSIT));
        vault.deposit(1e5, alice);
        vm.stopPrank();
    }

    function test_deposit_revertsAboveMaxPerTx() public {
        uint256 tooMuch = MAX_PER_TX + 1;
        vm.startPrank(alice);
        asset.mint(alice, tooMuch);
        asset.approve(address(vault), tooMuch);
        vm.expectRevert(abi.encodeWithSelector(Errors.ExceedsMaxPerTx.selector, tooMuch, MAX_PER_TX));
        vault.deposit(tooMuch, alice);
        vm.stopPrank();
    }

    function test_deposit_revertsWhenPaused() public {
        vm.prank(pauser);
        vault.pause();
        vm.startPrank(alice);
        asset.approve(address(vault), 1e18);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.deposit(1e18, alice);
        vm.stopPrank();
    }

    /* ─────────────── Withdraw / Redeem ─────────────── */

    function test_withdraw_returnsAssets() public {
        _deposit(alice, 10e18);
        vm.prank(alice);
        uint256 sharesBurned = vault.withdraw(5e18, alice, alice);
        assertGt(sharesBurned, 0);
        assertEq(asset.balanceOf(alice), 10_000_000e18 - 10e18 + 5e18);
    }

    function test_redeem_returnsAssets() public {
        uint256 shares = _deposit(alice, 10e18);
        vm.prank(alice);
        uint256 assetsOut = vault.redeem(shares, alice, alice);
        assertApproxEqAbs(assetsOut, 10e18, 1); // rounding within 1 wei
    }

    function test_redeem_revertsAboveMaxPerTx() public {
        // deposit max
        _deposit(alice, MAX_PER_TX);
        uint256 aliceShares = vault.balanceOf(alice);
        // Shrink max so redeem will exceed it.
        vm.prank(admin);
        vault.setMaxAssetsPerTx(MAX_PER_TX / 2);
        vm.prank(alice);
        vm.expectRevert(); // ExceedsMaxPerTx
        vault.redeem(aliceShares, alice, alice);
    }

    /* ─────────────── Inflation attack resistance ─────────────── */

    function test_inflationAttack_mitigatedByVirtualShares() public {
        // Classic inflation: attacker makes tiny deposit then donates → victim's deposit rounds to 0.
        address attacker = makeAddr("attacker");
        address victim = makeAddr("victim");
        asset.mint(attacker, 10_000e18);
        asset.mint(victim, 1_000e18);

        vm.startPrank(attacker);
        asset.approve(address(vault), type(uint256).max);
        vault.deposit(Const.MIN_DEPOSIT, attacker); // MIN_DEPOSIT
        // Try to inflate by donating 1_000e18 directly.
        asset.transfer(address(vault), 1_000e18);
        vm.stopPrank();

        vm.startPrank(victim);
        asset.approve(address(vault), 1_000e18);
        uint256 shares = vault.deposit(1_000e18, victim);
        vm.stopPrank();

        // With offset=6 (1e6 virtual units) victim's shares must not round to 0.
        assertGt(shares, 0, "victim shares rounded to zero");

        // And victim should be able to redeem for ~most of their deposit.
        vm.prank(victim);
        uint256 out = vault.redeem(shares, victim, victim);
        // Attacker loses their single MIN_DEPOSIT to the donation buffer — victim preserves most.
        assertGe(out, 999e18, "victim lost too much to inflation");
    }

    /* ─────────────── Rebalance ─────────────── */

    function test_rebalance_successTakesFeeOnProfit() public {
        _deposit(alice, 100e18);
        // sync high water mark to deposit amount
        vm.prank(admin);
        vault.syncHighWaterMark();

        router.setMultiplier(11_000); // +10% profit

        IStrategyExecutor.ArbitrageParams memory p = IStrategyExecutor.ArbitrageParams({
            router: address(router),
            path: abi.encodePacked(address(asset)), // dummy path (mock ignores)
            amountIn: 100e18,
            minAmountOut: 100e18,
            deadline: block.timestamp + 1000
        });

        vm.prank(keeper);
        uint256 profit = vault.executeRebalance(p);

        assertEq(profit, 10e18, "profit = 10% of 100e18");
        // Fee = 10% of profit = 1e18 → treasury
        assertEq(asset.balanceOf(treasury), 1e18);
        // Vault now holds 100e18 (in) -100e18 (out) +110e18 (back) -1e18 (fee) = 109e18
        assertEq(asset.balanceOf(address(vault)), 109e18);
        assertEq(vault.highWaterMark(), 109e18);
    }

    function test_rebalance_revertsOnSlippage() public {
        _deposit(alice, 100e18);
        router.setMultiplier(9_500); // −5%

        IStrategyExecutor.ArbitrageParams memory p = IStrategyExecutor.ArbitrageParams({
            router: address(router),
            path: abi.encodePacked(address(asset)),
            amountIn: 100e18,
            minAmountOut: 100e18, // require full return → will fail
            deadline: block.timestamp + 1000
        });

        vm.prank(keeper);
        vm.expectRevert(); // MockSwapRouter: slippage bubble
        vault.executeRebalance(p);
    }

    function test_rebalance_revertsWhenNotKeeper() public {
        _deposit(alice, 100e18);
        IStrategyExecutor.ArbitrageParams memory p = IStrategyExecutor.ArbitrageParams({
            router: address(router),
            path: abi.encodePacked(address(asset)),
            amountIn: 100e18,
            minAmountOut: 100e18,
            deadline: block.timestamp + 1000
        });
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, vault.KEEPER_ROLE())
        );
        vm.prank(alice);
        vault.executeRebalance(p);
    }

    function test_rebalance_revertsOnZeroMinOut() public {
        _deposit(alice, 100e18);
        IStrategyExecutor.ArbitrageParams memory p = IStrategyExecutor.ArbitrageParams({
            router: address(router),
            path: abi.encodePacked(address(asset)),
            amountIn: 100e18,
            minAmountOut: 0,
            deadline: block.timestamp + 1000
        });
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Errors.InsufficientOutput.selector, 0, 1));
        vault.executeRebalance(p);
    }

    function test_rebalance_noFeeBelowHWM() public {
        _deposit(alice, 100e18);
        vm.prank(admin);
        vault.syncHighWaterMark();
        // Set HWM very high (manually by making a large deposit & re-syncing)
        vm.prank(admin);
        vault.setMaxAssetsPerTx(1_000_000_000e18);
        _deposit(bob, 1_000e18);
        vm.prank(admin);
        vault.syncHighWaterMark();

        router.setMultiplier(10_100); // 1% profit on the trade, but won't exceed HWM

        IStrategyExecutor.ArbitrageParams memory p = IStrategyExecutor.ArbitrageParams({
            router: address(router),
            path: abi.encodePacked(address(asset)),
            amountIn: 100e18,
            minAmountOut: 100e18,
            deadline: block.timestamp + 1000
        });
        // HWM = 1100e18; after trade balance = 1100e18 - 100e18 + 101e18 = 1101e18 → profit = 1e18
        vm.prank(keeper);
        uint256 profit = vault.executeRebalance(p);
        assertEq(profit, 1e18);
        assertEq(asset.balanceOf(treasury), 0.1e18); // 10% of 1e18
    }

    /* ─────────────── Pause / unpause ─────────────── */

    function test_pause_onlyPauser() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, vault.PAUSER_ROLE())
        );
        vm.prank(alice);
        vault.pause();

        vm.prank(pauser);
        vault.pause();
        assertTrue(vault.paused());
    }

    function test_unpause_onlyAdmin() public {
        vm.prank(pauser);
        vault.pause();
        vm.prank(pauser);
        vm.expectRevert();
        vault.unpause();
        vm.prank(admin);
        vault.unpause();
        assertFalse(vault.paused());
    }

    /* ─────────────── Timelock setters ─────────────── */

    function test_schedule_applyFeeCollector_afterDelay() public {
        address newFC = makeAddr("newFC");
        vm.prank(admin);
        vault.scheduleFeeCollector(newFC);
        (,, bool scheduled) = vault.pendingFeeCollector();
        assertTrue(scheduled);

        // Before delay → revert
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Errors.TimelockActive.selector, block.timestamp + Const.TIMELOCK_DELAY));
        vault.applyFeeCollector();

        vm.warp(block.timestamp + Const.TIMELOCK_DELAY + 1);
        vm.prank(admin);
        vault.applyFeeCollector();
        assertEq(address(vault.feeCollector()), newFC);
    }

    function test_cancel_timelockChange() public {
        address newStrat = makeAddr("newStrat");
        vm.prank(admin);
        vault.scheduleStrategy(newStrat);
        vm.prank(admin);
        vault.cancelStrategy();
        (,, bool scheduled) = vault.pendingStrategy();
        assertFalse(scheduled);
    }

    function test_schedule_revertsOnDoubleSchedule() public {
        vm.prank(admin);
        vault.scheduleFeeCollector(makeAddr("fc1"));
        vm.prank(admin);
        vm.expectRevert(Errors.TimelockAlreadyScheduled.selector);
        vault.scheduleFeeCollector(makeAddr("fc2"));
    }

    function test_apply_revertsWhenNotScheduled() public {
        vm.prank(admin);
        vm.expectRevert(Errors.TimelockNotScheduled.selector);
        vault.applyOracle();
    }

    /* ─────────────── Rescue ─────────────── */

    function test_rescueToken_cannotRescueAsset() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidParameter.selector, "asset"));
        vault.rescueToken(address(asset), admin, 1e18);
    }

    function test_rescueToken_sendsOther() public {
        MockERC20 other = new MockERC20("O", "O", 18);
        other.mint(address(vault), 5e18);
        vm.prank(admin);
        vault.rescueToken(address(other), admin, 5e18);
        assertEq(other.balanceOf(admin), 5e18);
    }

    /* ─────────────── Fuzz ─────────────── */

    /// @notice Fuzz deposit within realistic bounds.
    function testFuzz_deposit(uint256 amount) public {
        amount = bound(amount, Const.MIN_DEPOSIT, MAX_PER_TX);
        asset.mint(alice, amount);
        _deposit(alice, amount);
        assertEq(asset.balanceOf(address(vault)), amount);
        assertGt(vault.balanceOf(alice), 0);
    }

    /// @notice Fuzz deposit → redeem round trip preserves asset up to rounding.
    function testFuzz_depositRedeemRoundTrip(uint256 amount) public {
        amount = bound(amount, Const.MIN_DEPOSIT, MAX_PER_TX / 2);
        asset.mint(alice, amount);
        uint256 shares = _deposit(alice, amount);
        uint256 balBefore = asset.balanceOf(alice);
        vm.prank(alice);
        uint256 assetsOut = vault.redeem(shares, alice, alice);
        assertApproxEqAbs(assetsOut, amount, 2, "roundtrip rounding > 2 wei");
        assertEq(asset.balanceOf(alice), balBefore + assetsOut);
    }

    /* ─────────────── Additional coverage ─────────────── */

    function test_cancelFeeCollector_success() public {
        address newFC = makeAddr("fc");
        vm.prank(admin);
        vault.scheduleFeeCollector(newFC);
        vm.prank(admin);
        vault.cancelFeeCollector();
        (,, bool sched) = vault.pendingFeeCollector();
        assertFalse(sched);
    }

    function test_cancelOracle_success() public {
        address newO = makeAddr("o");
        vm.prank(admin);
        vault.scheduleOracle(newO);
        vm.prank(admin);
        vault.cancelOracle();
        (,, bool sched) = vault.pendingOracle();
        assertFalse(sched);
    }

    function test_applyOracle_afterDelay() public {
        address newO = makeAddr("o");
        vm.prank(admin);
        vault.scheduleOracle(newO);
        vm.warp(block.timestamp + Const.TIMELOCK_DELAY + 1);
        vm.prank(admin);
        vault.applyOracle();
        assertEq(vault.oracle(), newO);
    }

    function test_rebalance_revertsOnZeroAmountIn() public {
        _deposit(alice, 10e18);
        IStrategyExecutor.ArbitrageParams memory p = IStrategyExecutor.ArbitrageParams({
            router: address(router),
            path: abi.encodePacked(address(asset)),
            amountIn: 0,
            minAmountOut: 1,
            deadline: block.timestamp + 1000
        });
        vm.prank(keeper);
        vm.expectRevert(Errors.ZeroAmount.selector);
        vault.executeRebalance(p);
    }

    function test_rebalance_revertsWhenStrategyNotSet() public {
        // Deploy a fresh vault without strategy
        ArbitrageVault freshVault = new ArbitrageVault(asset, admin, keeper, pauser, address(feeCollector), MAX_PER_TX);
        IStrategyExecutor.ArbitrageParams memory p = IStrategyExecutor.ArbitrageParams({
            router: address(router),
            path: abi.encodePacked(address(asset)),
            amountIn: 1e18,
            minAmountOut: 1e18,
            deadline: block.timestamp + 1000
        });
        vm.prank(keeper);
        vm.expectRevert(Errors.StrategyNotSet.selector);
        freshVault.executeRebalance(p);
    }

    function test_setMaxAssetsPerTx_reverts() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidParameter.selector, "maxPerTx"));
        vault.setMaxAssetsPerTx(0);

        vm.prank(admin);
        vm.expectRevert(Errors.SameValue.selector);
        vault.setMaxAssetsPerTx(MAX_PER_TX);
    }

    function test_setMaxAssetsPerTx_success() public {
        vm.prank(admin);
        vault.setMaxAssetsPerTx(MAX_PER_TX + 1);
        assertEq(vault.maxAssetsPerTx(), MAX_PER_TX + 1);
    }

    function test_syncHighWaterMark_updatesToCurrent() public {
        _deposit(alice, 100e18);
        vm.prank(admin);
        vault.syncHighWaterMark();
        assertEq(vault.highWaterMark(), 100e18);
    }

    function test_rescueToken_revertsOnZeroAddress() public {
        MockERC20 other = new MockERC20("O", "O", 18);
        vm.prank(admin);
        vm.expectRevert(Errors.ZeroAddress.selector);
        vault.rescueToken(address(other), address(0), 1e18);
    }

    function test_rescueToken_revertsOnZeroAmount() public {
        MockERC20 other = new MockERC20("O", "O", 18);
        vm.prank(admin);
        vm.expectRevert(Errors.ZeroAmount.selector);
        vault.rescueToken(address(other), admin, 0);
    }

    function test_scheduleFeeCollector_revertsZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(Errors.ZeroAddress.selector);
        vault.scheduleFeeCollector(address(0));
    }

    function test_mint_success() public {
        vm.startPrank(alice);
        asset.approve(address(vault), type(uint256).max);
        uint256 shares = vault.previewDeposit(1e18);
        uint256 assets = vault.mint(shares, alice);
        vm.stopPrank();
        assertApproxEqAbs(assets, 1e18, 1);
    }

    /// @notice Fuzz withdraw bounded.
    function testFuzz_withdrawBounded(uint256 deposit, uint256 pct) public {
        deposit = bound(deposit, Const.MIN_DEPOSIT * 10, MAX_PER_TX / 2);
        pct = bound(pct, 1, 100);
        asset.mint(alice, deposit);
        _deposit(alice, deposit);
        uint256 withdrawAmt = (deposit * pct) / 100;
        if (withdrawAmt == 0) return;
        vm.prank(alice);
        vault.withdraw(withdrawAmt, alice, alice);
        assertApproxEqAbs(asset.balanceOf(address(vault)), deposit - withdrawAmt, 2);
    }
}

