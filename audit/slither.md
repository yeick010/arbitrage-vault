**THIS CHECKLIST IS NOT COMPLETE**. Use `--show-ignored-findings` to show all the results.
Summary
 - [arbitrary-send-erc20](#arbitrary-send-erc20) (2 results) (High)
 - [reentrancy-balance](#reentrancy-balance) (3 results) (High)
 - [reentrancy-no-eth](#reentrancy-no-eth) (1 results) (Medium)
 - [unused-return](#unused-return) (1 results) (Medium)
 - [reentrancy-events](#reentrancy-events) (2 results) (Low)
 - [timestamp](#timestamp) (3 results) (Low)
 - [unindexed-event-address](#unindexed-event-address) (2 results) (Informational)
## arbitrary-send-erc20
Impact: High
Confidence: High
 - [ ] ID-0
[FeeCollector.collect(address,address,uint256)](src/FeeCollector.sol#L85-L93) uses arbitrary from in transferFrom: [IERC20(token).safeTransferFrom(from,treasury,amount)](src/FeeCollector.sol#L91)

src/FeeCollector.sol#L85-L93


 - [ ] ID-1
[StrategyExecutor.executeArbitrage(IStrategyExecutor.ArbitrageParams)](src/StrategyExecutor.sol#L86-L129) uses arbitrary from in transferFrom: [assetToken.safeTransferFrom(vault,address(this),params.amountIn)](src/StrategyExecutor.sol#L103)

src/StrategyExecutor.sol#L86-L129


## reentrancy-balance
Impact: High
Confidence: Medium
 - [ ] ID-2
Reentrancy in [StrategyExecutor.executeArbitrage(IStrategyExecutor.ArbitrageParams)](src/StrategyExecutor.sol#L86-L129):
	External call allowing reentrancy:
	- [assetToken.forceApprove(params.router,params.amountIn)](src/StrategyExecutor.sol#L104)
	Balance read before the call:
	- [balanceBefore = assetToken.balanceOf(vault)](src/StrategyExecutor.sol#L101)
	Possible stale balance used after the call in a condition:
	- [balanceAfter + params.amountIn < balanceBefore + params.minAmountOut](src/StrategyExecutor.sol#L121)
		- stale variable `balanceBefore`

src/StrategyExecutor.sol#L86-L129


 - [ ] ID-3
Reentrancy in [StrategyExecutor.executeArbitrage(IStrategyExecutor.ArbitrageParams)](src/StrategyExecutor.sol#L86-L129):
	External call allowing reentrancy:
	- [assetToken.safeTransferFrom(vault,address(this),params.amountIn)](src/StrategyExecutor.sol#L103)
	Balance read before the call:
	- [balanceBefore = assetToken.balanceOf(vault)](src/StrategyExecutor.sol#L101)
	Possible stale balance used after the call in a condition:
	- [balanceAfter + params.amountIn < balanceBefore + params.minAmountOut](src/StrategyExecutor.sol#L121)
		- stale variable `balanceBefore`

src/StrategyExecutor.sol#L86-L129


 - [ ] ID-4
Reentrancy in [StrategyExecutor.executeArbitrage(IStrategyExecutor.ArbitrageParams)](src/StrategyExecutor.sol#L86-L129):
	External call allowing reentrancy:
	- [amountOut = ISwapRouter(params.router).exactInput(ISwapRouter.ExactInputParams({path:params.path,recipient:vault,deadline:params.deadline,amountIn:params.amountIn,amountOutMinimum:params.minAmountOut}))](src/StrategyExecutor.sol#L107-L115)
	Balance read before the call:
	- [balanceBefore = assetToken.balanceOf(vault)](src/StrategyExecutor.sol#L101)
	Possible stale balance used after the call in a condition:
	- [balanceAfter + params.amountIn < balanceBefore + params.minAmountOut](src/StrategyExecutor.sol#L121)
		- stale variable `balanceBefore`

src/StrategyExecutor.sol#L86-L129


## reentrancy-no-eth
Impact: Medium
Confidence: Medium
 - [ ] ID-5
Reentrancy in [ArbitrageVault.executeRebalance(IStrategyExecutor.ArbitrageParams)](src/ArbitrageVault.sol#L202-L247):
	External calls:
	- [assetToken.forceApprove(address(_strategy),params.amountIn)](src/ArbitrageVault.sol#L219)
	- [amountOut = _strategy.executeArbitrage(params)](src/ArbitrageVault.sol#L222)
	- [assetToken.forceApprove(address(_strategy),0)](src/ArbitrageVault.sol#L226)
	- [assetToken.forceApprove(address(feeCollector),fee)](src/ArbitrageVault.sol#L237)
	- [feeCollector.collect(address(assetToken),address(this),fee)](src/ArbitrageVault.sol#L238)
	- [assetToken.forceApprove(address(feeCollector),0)](src/ArbitrageVault.sol#L239)
	State variables written after the call(s):
	- [highWaterMark = balanceAfter](src/ArbitrageVault.sol#L242)
	[ArbitrageVault.highWaterMark](src/ArbitrageVault.sol#L66) can be used in cross function reentrancies:
	- [ArbitrageVault.highWaterMark](src/ArbitrageVault.sol#L66)
	- [ArbitrageVault.syncHighWaterMark()](src/ArbitrageVault.sol#L333-L335)

src/ArbitrageVault.sol#L202-L247


## unused-return
Impact: Medium
Confidence: Medium
 - [ ] ID-6
[OracleAdapter._getPrimaryPrice()](src/OracleAdapter.sol#L118-L138) ignores return value by [(roundId,answer,None,updatedAt,answeredInRound) = feed.latestRoundData()](src/OracleAdapter.sol#L120)

src/OracleAdapter.sol#L118-L138


## reentrancy-events
Impact: Low
Confidence: Medium
 - [ ] ID-7
Reentrancy in [FeeCollector.collect(address,address,uint256)](src/FeeCollector.sol#L85-L93):
	External calls:
	- [IERC20(token).safeTransferFrom(from,treasury,amount)](src/FeeCollector.sol#L91)
	Event emitted after the call(s):
	- [FeesCollected(token,from,amount)](src/FeeCollector.sol#L92)

src/FeeCollector.sol#L85-L93


 - [ ] ID-8
Reentrancy in [ArbitrageVault.rescueToken(address,address,uint256)](src/ArbitrageVault.sol#L339-L345):
	External calls:
	- [IERC20(token).safeTransfer(to,amount)](src/ArbitrageVault.sol#L343)
	Event emitted after the call(s):
	- [EmergencyRescue(token,to,amount)](src/ArbitrageVault.sol#L344)

src/ArbitrageVault.sol#L339-L345


## timestamp
Impact: Low
Confidence: Medium
 - [ ] ID-9
[StrategyExecutor.executeArbitrage(IStrategyExecutor.ArbitrageParams)](src/StrategyExecutor.sol#L86-L129) uses timestamp for comparisons
	Dangerous comparisons:
	- [params.deadline < block.timestamp](src/StrategyExecutor.sol#L98)

src/StrategyExecutor.sol#L86-L129


 - [ ] ID-10
[ArbitrageVault._consume(ArbitrageVault.PendingAddress)](src/ArbitrageVault.sol#L374-L381) uses timestamp for comparisons
	Dangerous comparisons:
	- [block.timestamp < slot.readyAt](src/ArbitrageVault.sol#L376)

src/ArbitrageVault.sol#L374-L381


 - [ ] ID-11
[OracleAdapter._getPrimaryPrice()](src/OracleAdapter.sol#L118-L138) uses timestamp for comparisons
	Dangerous comparisons:
	- [block.timestamp - updatedAt > maxPriceAge](src/OracleAdapter.sol#L124)

src/OracleAdapter.sol#L118-L138


## unindexed-event-address
Impact: Informational
Confidence: High
 - [ ] ID-12
Event [ArbitrageVault.ChangeApplied(string,address,address)](src/ArbitrageVault.sol#L89) has address parameters but no indexed parameters

src/ArbitrageVault.sol#L89


 - [ ] ID-13
Event [ArbitrageVault.ChangeScheduled(string,address,uint256)](src/ArbitrageVault.sol#L83) has address parameters but no indexed parameters

src/ArbitrageVault.sol#L83


