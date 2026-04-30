# Changelog

All notable changes to the ArbitrageVault project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Foundry scaffolding with `solc = 0.8.24`, optimizer 200 runs, fuzz 10_000 runs (default), 1_000 runs (ci profile).
- OpenZeppelin Contracts **v5.0.2** + `chainlink-brownie-contracts` v1.2.0 + `forge-std` v1.9.4 pinned via git submodules.
- Core contracts:
  - `ArbitrageVault.sol` (ERC-4626 + ReentrancyGuard + Pausable + AccessControl, 48 h timelock, HWM accounting).
  - `StrategyExecutor.sol` (UniV3-style `exactInput`, whitelisted routers, mandatory `minAmountOut`).
  - `FeeCollector.sol` (immutable treasury, 10 % performance fee cap).
  - `OracleAdapter.sol` (Chainlink primary + TWAP fallback, 2 % max deviation, stale-round revert).
  - `AccessManager.sol` (standalone role registry: ADMIN / KEEPER / PAUSER).
  - Shared `common/Const.sol` + `common/Errors.sol`.
  - Interfaces: `IFeeCollector`, `IOracleAdapter`, `IStrategyExecutor`.
- Test suite: **86 tests**, coverage **97.98 % lines / 94.24 % statements / 98 % functions** on `src/`.
  - 39 unit tests on ArbitrageVault
  - 18 unit tests on OracleAdapter
  - 15 unit tests on FeeCollector
  - 5 unit tests each on StrategyExecutor and AccessManager
  - 4 invariant tests (fee cap ≤ 10 %, share-price floor, asset conservation, accounting consistency)
  - 3 fuzz tests with bounds `[1e6 … 1e30]`
  - Dedicated inflation-attack resistance test (OZ v5 virtual shares)
- `script/Deploy.s.sol` — Sepolia-ready deploy script, all parameters from `vm.envAddress / vm.envUint`; never hardcodes private keys. Prints post-deploy checklist.
- `audit/THREAT_MODEL.md` — STRIDE-based threat model + DeFi-specific attack catalogue.
- `audit/slither.md` — Slither `--checklist` report.
- `.env.example` with Sepolia LINK + LINK/USD feed preset values (commit-safe).
- Documentation: `README.md` with architecture diagram, security posture, deploy instructions, ABI surface.

### Security (fixed in this release)

- **HIGH × 2** `arbitrary-send-erc20` in `FeeCollector.collect` and `StrategyExecutor.executeArbitrage` — removed arbitrary `from` parameter; both now transfer from `msg.sender`.
- **HIGH × 3** `reentrancy-balance` in `StrategyExecutor` — removed redundant `balanceBefore` snapshot now that the router's `amountOutMinimum` and the vault's double-check are the primary slippage gates.
- **MEDIUM × 1** `reentrancy-no-eth` in `executeRebalance` — `highWaterMark` is now written before the fee-collect external call (strict CEI). `syncHighWaterMark` also gained `nonReentrant` for defence-in-depth.
- **MEDIUM × 1** `unused-return` in `OracleAdapter._getPrimaryPrice` — `startedAt` is captured and validated `!= 0`.
- **INFO × 2** `unindexed-event-address` — `ChangeScheduled / ChangeApplied` address params now `indexed`.
- **LOW × 1** `reentrancy-events` in `rescueToken` — event now emitted before the ERC20 transfer (CEI) + `nonReentrant`.

### Known (accepted) Slither findings

- **LOW × 1** `reentrancy-benign` — transient forceApprove reset inside `executeRebalance` (no exploitable surface, guarded by `nonReentrant`).
- **LOW × 3** `timestamp` — intentional comparisons on `deadline` (executor), `readyAt` (timelock), and `updatedAt` (oracle staleness). Miner influence ≤ 15 s, all comparison windows ≥ minutes.

---

[Unreleased]: https://github.com/<org>/arbitrage-vault/compare/HEAD