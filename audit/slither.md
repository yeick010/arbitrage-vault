**THIS CHECKLIST IS NOT COMPLETE**. Use `--show-ignored-findings` to show all the results.
Summary
 - [reentrancy-benign](#reentrancy-benign) (1 results) (Low)
 - [timestamp](#timestamp) (3 results) (Low)
## reentrancy-benign
Impact: Low
Confidence: Medium
 - [ ] ID-0
Reentrancy in [ArbitrageVault.executeRebalance(IStrategyExecutor.ArbitrageParams)](src/ArbitrageVault.sol#L204-L254):
	External calls:
	- [assetToken.forceApprove(address(_strategy),params.amountIn)](src/ArbitrageVault.sol#L221)
	- [amountOut = _strategy.executeArbitrage(params)](src/ArbitrageVault.sol#L224)
	- [assetToken.forceApprove(address(_strategy),0)](src/ArbitrageVault.sol#L228)
	State variables written after the call(s):
	- [highWaterMark = newHWM](src/ArbitrageVault.sol#L242)

src/ArbitrageVault.sol#L204-L254


## timestamp
Impact: Low
Confidence: Medium
 - [ ] ID-1
[StrategyExecutor.executeArbitrage(IStrategyExecutor.ArbitrageParams)](src/StrategyExecutor.sol#L86-L126) uses timestamp for comparisons
	Dangerous comparisons:
	- [params.deadline < block.timestamp](src/StrategyExecutor.sol#L98)

src/StrategyExecutor.sol#L86-L126


 - [ ] ID-2
[ArbitrageVault._consume(ArbitrageVault.PendingAddress)](src/ArbitrageVault.sol#L388-L395) uses timestamp for comparisons
	Dangerous comparisons:
	- [block.timestamp < slot.readyAt](src/ArbitrageVault.sol#L390)

src/ArbitrageVault.sol#L388-L395


 - [ ] ID-3
[OracleAdapter._getPrimaryPrice()](src/OracleAdapter.sol#L118-L142) uses timestamp for comparisons
	Dangerous comparisons:
	- [block.timestamp - updatedAt > maxPriceAge](src/OracleAdapter.sol#L127)

src/OracleAdapter.sol#L118-L142


