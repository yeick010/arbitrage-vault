# ArbitrageVault

An ERC-4626 yield vault for cross-DEX arbitrage on EVM networks (ready for Sepolia testnet deployment).

Built with Foundry + OpenZeppelin Contracts **v5.0.2** + Solidity **^0.8.24**.

---

## Table of contents

1. [Architecture](#architecture)
2. [Security posture](#security-posture)
3. [Directory layout](#directory-layout)
4. [Build, test, coverage](#build-test-coverage)
5. [Static analysis](#static-analysis)
6. [Deployment (Sepolia)](#deployment-sepolia)
7. [Threat model](#threat-model)
8. [ABI surface](#abi-surface)
9. [License](#license)

---

## Architecture

```
┌────────────────────────────────────────────────────────────────┐
│                        ArbitrageVault                           │
│                   (ERC-4626, Pausable, AC)                      │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │  deposit / mint / withdraw / redeem   nonReentrant       │  │
│  │  executeRebalance(params)              onlyKeeper        │  │
│  │  HWM accounting → perf fee 10%                           │  │
│  │  Timelock 48h on setFeeCollector / setStrategy / setOracle│  │
│  └──────────────────────────────────────────────────────────┘  │
│      │                   │                    │                │
│      ▼                   ▼                    ▼                │
│  StrategyExecutor    FeeCollector         OracleAdapter        │
│  · whitelisted       · immutable          · Chainlink primary  │
│    routers             treasury           · TWAP fallback      │
│  · minAmountOut      · fee BPS ≤ 10%      · ≤ 2% deviation     │
│    enforced                                                     │
└────────────────────────────────────────────────────────────────┘

AccessManager  (role registry) · ADMIN_ROLE · KEEPER_ROLE · PAUSER_ROLE
```

### Contracts

| Contract                          | Purpose                                                                      |
| --------------------------------- | ---------------------------------------------------------------------------- |
| `src/ArbitrageVault.sol`          | ERC-4626 vault, HWM profit accounting, timelocked setters, emergency pause   |
| `src/StrategyExecutor.sol`        | Executes UniV3-style `exactInput` swaps; router whitelist + mandatory slippage |
| `src/FeeCollector.sol`            | Forwards 10% performance fee to an **immutable** treasury                    |
| `src/OracleAdapter.sol`           | Chainlink primary + TWAP fallback, 2% max deviation, stale-price revert      |
| `src/AccessManager.sol`           | Stand-alone AccessControl registry for ADMIN / KEEPER / PAUSER roles         |
| `src/common/Errors.sol`           | All custom errors (gas-efficient, structured revert data)                    |
| `src/common/Const.sol`            | Shared constants (BPS denominator, fee cap, min deposit, timelock delay)     |

### Share accounting (ERC-4626)

- OpenZeppelin v5 virtual shares with `_decimalsOffset = 6` → inflation-attack resistant.
- `totalAssets()` returns the vault's live ERC20 balance (strategy is synchronous — no pending escrow).
- `minDeposit = 1e6` wei and `maxAssetsPerTx` bound each user action to prevent dust griefing and DoS.

### Fee model

- Performance fee is charged **only on realised profit above the high-water mark**.
- Fee is capped at **1_000 BPS (10%)**; enforced both at `FeeCollector` constructor and on every `setPerformanceFee`.
- Treasury is **immutable** — reassigning it is impossible.

---

## Security posture

| Control                                  | Implementation                                                       |
| ---------------------------------------- | -------------------------------------------------------------------- |
| Reentrancy                               | `ReentrancyGuard` on `deposit/mint/withdraw/redeem/rebalance/syncHWM/rescue` |
| Emergency stop                           | `Pausable` gated by dedicated `PAUSER_ROLE`                          |
| Access control                           | OZ `AccessControl` (ADMIN / KEEPER / PAUSER) — no EOA owner          |
| Inflation attack                         | OZ v5 virtual shares + `_decimalsOffset = 6`                         |
| DoS / dust                               | `minDeposit = 1e6` + `maxAssetsPerTx` ceiling                        |
| Oracle manipulation                      | Chainlink primary + TWAP fallback, deviation ≤ 2%, staleness check   |
| Slippage                                 | Mandatory `minAmountOut` on `executeRebalance`, re-checked both sides |
| Privileged change                        | 48 h timelock on `setFeeCollector / setStrategy / setOracle`         |
| ERC20 safety                             | `SafeERC20` everywhere — `safeTransfer(From)` / `forceApprove`       |
| Arbitrary `from`                         | Eliminated — `FeeCollector.collect` & `StrategyExecutor` use `msg.sender` |
| CEI                                      | Effects (HWM update, events) emitted before external calls          |
| Non-standard tokens                      | `forceApprove` handles USDT-style `approve` reverts                  |
| Multisig-ready                           | All admin / pauser / treasury are plain addresses intended for multisigs |

### Pre-audit checklist status

- [x] `ReentrancyGuard` on all fund-moving entrypoints
- [x] No `tx.origin` auth
- [x] No `delegatecall` to untrusted code
- [x] All ERC20 interactions via `SafeERC20`
- [x] No hardcoded addresses in source
- [x] Events emitted for every state change (reason-annotated where branching: `ChangeScheduled/Applied/Cancelled`)
- [x] `.env` in `.gitignore`, `.env.example` provided
- [x] Oracle staleness + deviation checks
- [x] Test coverage ≥ 90% lines (achieved **97.98%**)
- [x] Fuzz with 10_000 runs on critical paths
- [x] Invariant tests (fee cap, minPricePerShare, asset conservation)
- [x] Slither 0 High, 0 Medium (only intentional timestamp-comparison Lows remain)

---

## Directory layout

```
arbitrage-vault/
├── src/
│   ├── ArbitrageVault.sol
│   ├── StrategyExecutor.sol
│   ├── FeeCollector.sol
│   ├── OracleAdapter.sol
│   ├── AccessManager.sol
│   ├── common/{Const.sol,Errors.sol}
│   └── interfaces/{IFeeCollector,IOracleAdapter,IStrategyExecutor}.sol
├── test/
│   ├── Base.t.sol                   # shared test harness
│   ├── ArbitrageVault.t.sol         # 39 unit / fuzz tests
│   ├── FeeCollector.t.sol           # 15 unit tests
│   ├── OracleAdapter.t.sol          # 18 unit tests
│   ├── StrategyExecutor.t.sol       # 5 unit tests
│   ├── AccessManager.t.sol          # 5 unit tests
│   ├── Invariants.t.sol             # 4 invariant tests + handler
│   └── mocks/{MockERC20,MockChainlinkFeed,MockTWAPSource,MockSwapRouter}.sol
├── script/
│   └── Deploy.s.sol                 # Sepolia deployment entrypoint
├── audit/
│   ├── slither.md                   # Slither checklist output
│   └── THREAT_MODEL.md              # STRIDE-based threat model
├── config/                          # (populated per network)
├── deployments/                     # (populated post-deploy)
├── foundry.toml
├── remappings.txt
├── .env.example
├── CHANGELOG.md
└── README.md
```

---

## Build, test, coverage

### Prerequisites

- [Foundry](https://book.getfoundry.sh/) (`forge`, `cast`, `anvil`)
- Python 3.9+ (for Slither)

### Commands

```bash
# install dependencies (pinned)
forge install

# compile
forge build

# run the full suite with traces
forge test -vvv

# run only the fuzz/invariant config (10_000 fuzz runs, 64 invariant runs × depth 32)
forge test

# fast CI profile (1_000 fuzz runs)
FOUNDRY_PROFILE=ci forge test

# coverage summary (src only)
FOUNDRY_PROFILE=ci forge coverage --no-match-coverage "test/" --report summary

# gas report
forge test --gas-report
```

### Test results (latest run)

```
Ran 6 test suites: 86 tests passed, 0 failed, 0 skipped (86 total tests)

src/AccessManager.sol     100.00% (15/15)   100.00% funcs
src/ArbitrageVault.sol     98.44% (126/128)  96.55% funcs
src/FeeCollector.sol      100.00% (27/27)   100.00% funcs
src/OracleAdapter.sol      96.15% (50/52)   100.00% funcs
src/StrategyExecutor.sol   96.15% (25/26)   100.00% funcs
────────────────────────────────────────────────────────
Total:                     97.98% lines · 94.24% stmts · 98.00% funcs
```

---

## Static analysis

### Slither

```bash
slither . --filter-paths "lib|test" --checklist > audit/slither.md
```

Current results (see `audit/slither.md`):

| Severity | Count | Status       |
| -------- | ----- | ------------ |
| High     | 0     | ✔ all fixed |
| Medium   | 0     | ✔ all fixed |
| Low      | 4     | intentional (see audit/slither.md — timestamps for deadline/timelock/staleness + benign allowance reset) |
| Info     | 0     | — |

Commit history documents each fix:

- `fix(security): eliminate arbitrary-send-erc20 HIGH` — removed arbitrary `from` in `FeeCollector.collect` and `StrategyExecutor.executeArbitrage`, which also resolves 3 × `reentrancy-balance` HIGH.
- `fix(security): resolve reentrancy-no-eth and unused-return MEDIUM` — `syncHighWaterMark` got `nonReentrant`; `_getPrimaryPrice` captures `startedAt`.
- `fix(security): address Slither informational findings` — indexed addresses in `ChangeScheduled/Applied`, CEI-reordered `rescueToken`.
- `fix(security): move highWaterMark update before fee-collect external call (CEI)` — downgrades the last MEDIUM to benign LOW.

---

## Deployment (Sepolia)

### 1. Copy and fill env

```bash
cp .env.example .env
$EDITOR .env   # fill PRIVATE_KEY, RPC, asset, admin multisig, etc.
source .env
```

Critical: `.env` is git-ignored. **Never commit** or paste private keys into logs.

### 2. Dry-run

```bash
forge script script/Deploy.s.sol \
  --rpc-url $SEPOLIA_RPC_URL \
  -vvvv
```

Check the printed `POST-DEPLOY CHECKLIST` before broadcasting.

### 3. Broadcast + verify

```bash
forge script script/Deploy.s.sol \
  --rpc-url $SEPOLIA_RPC_URL \
  --broadcast \
  --verify
```

### 4. Post-deploy wiring (from admin multisig)

1. `executor.setRouterWhitelist(<UniV3 router>, true)`
2. `vault.scheduleStrategy(executor)` → wait **48 h** → `vault.applyStrategy()`
3. (optional) `feeCollector.setAuthorisedCollector(vault, true)` if admin ≠ deployer
4. Update `deployments/sepolia.env` with printed addresses
5. Tag the release: `git tag v0.1.0-sepolia && git push --tags`

### 5. On-chain smoke test

```bash
cast call $VAULT "totalSupply()(uint256)" --rpc-url $SEPOLIA_RPC_URL
cast call $VAULT "asset()(address)"       --rpc-url $SEPOLIA_RPC_URL
cast call $FEE_COLLECTOR "treasury()(address)" --rpc-url $SEPOLIA_RPC_URL
```

---

## Threat model

See [`audit/THREAT_MODEL.md`](audit/THREAT_MODEL.md) for the full STRIDE walk-through.

Summary — the system defends against:

| Threat category    | Example                                   | Mitigation                                                                 |
| ------------------ | ----------------------------------------- | -------------------------------------------------------------------------- |
| **S**poofing       | EOA pretending to be the vault            | `onlyVault` (immutable) on executor; `msg.sender`-based auth everywhere    |
| **T**ampering      | Malicious admin swaps treasury / strategy | Treasury immutable; strategy/fc/oracle behind 48 h timelock               |
| **R**epudiation    | Denying fee forwarding                    | `FeesCollected` event + unambiguous on-chain transfer log                  |
| **I**nfo disclosure| Oracle price leakage                      | N/A — prices are public; TWAP prevents manipulation                        |
| **D**oS            | Dust deposit flood, oracle stale          | `minDeposit`, `maxAssetsPerTx`, `StalePrice` revert                        |
| **E**levation      | Keeper tries admin ops                    | Separate ADMIN / KEEPER / PAUSER roles; no cross-role implicit grants      |
| Economic           | Inflation attack, sandwich, flash-loan    | Virtual shares, slippage bound, deviation bound, nonReentrant              |

---

## ABI surface

Key vault entrypoints:

```solidity
// ERC-4626 standard
function deposit(uint256 assets, address receiver) external returns (uint256 shares);
function mint(uint256 shares, address receiver) external returns (uint256 assets);
function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);
function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);

// Vault-specific
function executeRebalance(IStrategyExecutor.ArbitrageParams calldata params)
    external returns (uint256 profit);
function pause() external;           // PAUSER_ROLE
function unpause() external;         // ADMIN_ROLE
function syncHighWaterMark() external; // ADMIN_ROLE

// Timelocked (48 h)
function scheduleFeeCollector(address newValue) external;
function applyFeeCollector() external;
function cancelFeeCollector() external;
// … and identical trio for strategy, oracle
```

Full artifacts are emitted to `out/` after `forge build`. To export ABIs:

```bash
forge inspect ArbitrageVault abi  > abi/ArbitrageVault.json
forge inspect FeeCollector  abi   > abi/FeeCollector.json
forge inspect OracleAdapter abi   > abi/OracleAdapter.json
```

---

## License

MIT — see SPDX headers in every source file.

Built by the ArbitrageVault Dev team. Not audited by a third party; **do not use in production without an independent security review**.