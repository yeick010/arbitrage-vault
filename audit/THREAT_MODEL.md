# ArbitrageVault — Threat Model (STRIDE)

**Version:** 0.1.0  
**Scope:** `src/ArbitrageVault.sol`, `src/StrategyExecutor.sol`, `src/FeeCollector.sol`, `src/OracleAdapter.sol`, `src/AccessManager.sol`.  
**Method:** STRIDE per entrypoint, then economic attacks specific to ERC-4626 / arbitrage vaults.

---

## Actors & trust boundaries

| Actor              | Trust level | Role / capability                                                          |
| ------------------ | ----------- | -------------------------------------------------------------------------- |
| Depositor          | Untrusted   | Deposits/withdraws the underlying asset                                    |
| Keeper (bot)       | Semi-trusted | Holds `KEEPER_ROLE`; submits rebalance transactions                         |
| Admin (multisig)   | Trusted     | Holds `ADMIN_ROLE`; reconfigures via timelock                              |
| Pauser (multisig)  | Trusted     | Holds `PAUSER_ROLE`; can pause (but not unpause)                           |
| Treasury (multisig)| Trusted     | Receives performance fees; **immutable**                                   |
| External DEX router| Untrusted   | Called with bounded `amountIn` + mandatory `minAmountOut`                  |
| Chainlink feed     | Trusted with staleness checks | Primary oracle                                            |
| UniV3 TWAP source  | Semi-trusted | Fallback oracle; deviation ≤ 2 % or revert                                |

Trust boundary between the vault and the DEX router is crossed only through the `StrategyExecutor`, which enforces the whitelist, deadline, and non-zero path.

---

## Data flow

```
 Depositor ─► Vault (deposit)
                │
                ▼
           Vault balance (asset ERC20)
                │
  Keeper ──► executeRebalance(params)
                │
                ▼
        Executor (whitelisted router)
                │       minAmountOut
                ▼
           UniV3 router  ─────► vault (swap output)
                                      │
                                      ▼
              HWM diff ──► FeeCollector ──► Treasury (immutable)
                                      │
                                      ▼
                      remaining balance stays in vault
```

---

## STRIDE analysis

### Spoofing (S)

| ID  | Asset                         | Threat                                                                 | Mitigation                                                           |
| --- | ----------------------------- | ---------------------------------------------------------------------- | -------------------------------------------------------------------- |
| S-1 | StrategyExecutor.executeArbitrage | Attacker contract claims to be the vault                             | `onlyVault` checks `msg.sender == vault` (immutable)                 |
| S-2 | FeeCollector.collect          | Arbitrary caller forces fee transfer from arbitrary victim             | `authorisedCollector[msg.sender]` whitelist; `from` dropped — uses `msg.sender` |
| S-3 | AccessControl roles           | Caller impersonates admin                                              | `hasRole` check on every privileged method                           |

### Tampering (T)

| ID  | Asset                       | Threat                                                                | Mitigation                                                           |
| --- | --------------------------- | --------------------------------------------------------------------- | -------------------------------------------------------------------- |
| T-1 | Treasury address            | Admin swaps treasury to self-address                                  | Treasury is `immutable` in `FeeCollector` — cannot be changed        |
| T-2 | Strategy / FeeCollector / Oracle | Admin malicious swap                                              | 48 h timelock; on-chain schedule visible to depositors               |
| T-3 | Performance fee             | Admin raises fee > 10 %                                               | Hard cap `MAX_PERFORMANCE_FEE_BPS = 1_000` enforced in constructor and setter |
| T-4 | HWM (profit accounting)     | External re-entry flips HWM stale                                     | `nonReentrant` + CEI: `highWaterMark` written before fee-collect call |
| T-5 | Oracle feed                 | Admin swaps to manipulated feed                                       | Behind 48 h timelock (`scheduleOracle / applyOracle`)                |

### Repudiation (R)

| ID  | Asset                       | Threat                                                               | Mitigation                                                            |
| --- | --------------------------- | -------------------------------------------------------------------- | --------------------------------------------------------------------- |
| R-1 | Fee collection              | Treasury claims it never received fee                                | `FeesCollected(token, sender, amount)` event + ERC20 `Transfer` event |
| R-2 | Admin action                | Admin denies scheduling malicious change                             | `ChangeScheduled / ChangeApplied / ChangeCancelled` events with indexed address |
| R-3 | Rebalance                   | Keeper denies submitting slippage-maxed trade                        | `Rebalanced(keeper, amountIn, amountOut, profit, fee)` event          |

### Information disclosure (I)

| ID  | Asset             | Threat                                              | Mitigation                                    |
| --- | ----------------- | --------------------------------------------------- | --------------------------------------------- |
| I-1 | Oracle prices     | Chain is public; no confidentiality expected        | N/A — public ledger                           |
| I-2 | User balances     | Standard ERC20 state is public                      | N/A — in line with ERC-4626 design            |

### Denial of Service (D)

| ID  | Asset                 | Threat                                                                   | Mitigation                                                                  |
| --- | --------------------- | ------------------------------------------------------------------------ | --------------------------------------------------------------------------- |
| D-1 | `deposit`             | Dust flood forces rounding to zero / high gas                            | `MIN_DEPOSIT = 1e6` floor + `maxAssetsPerTx` ceiling                        |
| D-2 | Oracle                | Chainlink feed goes stale and all deposits revert                        | `maxPriceAge` is admin-tunable; `unpause()` path keeps vault operational even without oracle (vault is oracle-independent for share math) |
| D-3 | `executeRebalance`    | Malicious router griefs by returning `amountOut == 0`                    | `if (amountOut < minAmountOut) revert`                                      |
| D-4 | Pausable              | Pauser pauses forever                                                    | `unpause` reserved to `ADMIN_ROLE` (separate multisig); pauser cannot unpause |
| D-5 | Strategy executor     | Router griefs via gas bomb                                               | Foundry tests include gas reports; per-call gas is bounded by deploy `--gas-limit` |

### Elevation of privilege (E)

| ID  | Asset           | Threat                                                                      | Mitigation                                                                 |
| --- | --------------- | --------------------------------------------------------------------------- | -------------------------------------------------------------------------- |
| E-1 | Role hierarchy  | `KEEPER_ROLE` or `PAUSER_ROLE` tries to execute admin ops                  | Every privileged function has explicit `onlyRole(DEFAULT_ADMIN_ROLE)` guard; no role inheritance |
| E-2 | Upgradeability  | Attacker upgrades implementation                                            | Contracts are **not** upgradeable — no UUPS / Transparent proxy anywhere   |
| E-3 | EOA owner       | EOA admin key compromise                                                    | `ADMIN_ROLE` is meant to be held by a multisig (pre-audit checklist item)  |

---

## Economic / DeFi-specific attacks

| ID  | Attack                       | Description                                                                | Mitigation                                                                           |
| --- | ---------------------------- | -------------------------------------------------------------------------- | ------------------------------------------------------------------------------------ |
| F-1 | ERC-4626 inflation attack    | First depositor inflates share price via direct asset donation             | OZ v5 virtual shares + `_decimalsOffset = 6` + `MIN_DEPOSIT` floor (tested: victim preserves ≥ 999e18 out of 1000e18 deposit) |
| F-2 | Reentrancy (classic)         | External call re-enters vault to drain                                     | `ReentrancyGuard` + CEI on every entrypoint (deposit/mint/withdraw/redeem/rebalance/syncHWM/rescue) |
| F-3 | Sandwich / MEV on rebalance  | Bot front-runs rebalance to skim slippage                                  | Mandatory `minAmountOut` on `executeArbitrage`; keeper tunes tight bound             |
| F-4 | Flash-loan oracle manipulation | Attacker moves UniV3 spot to distort fallback TWAP                       | TWAP window 30 min + `MAX_ORACLE_DEVIATION_BPS = 200` gate between Chainlink & TWAP  |
| F-5 | Malicious router whitelisting | Admin whitelists rogue router that steals funds                           | 48 h timelock on strategy swap; strategy re-deploy is the only way to "change router admin"; OR: admin compromise is out-of-scope (requires multisig compromise) |
| F-6 | Fee griefing                 | Admin sets fee to 0 to deny treasury, or to max (already capped at 10%)    | Fee cap ≤ 10 % in code; fee lowering requires admin multisig sign-off                |
| F-7 | Precision / rounding abuse   | Depositor spams tiny deposits/withdraws to drain via rounding              | `MIN_DEPOSIT = 1e6` blocks sub-wei dust; OZ v5 rounding is floor-down, favourable to remaining holders |
| F-8 | Approval dust                | Malicious ERC20 with `permit2` style hidden allowance                      | `forceApprove` resets to 0 after every rebalance leg                                 |
| F-9 | Asset ≠ share value drift   | `totalAssets` lies because strategy holds in-flight funds                  | Strategy is synchronous within the same tx: pulls + returns atomically; `totalAssets = vault balance` always accurate |
| F-10| Stale oracle exploit         | Use outdated Chainlink quote during market dislocation                     | `StalePrice` revert when `block.timestamp - updatedAt > maxPriceAge`; also checks `answeredInRound >= roundId` |

---

## Residual risks (accepted)

1. **Multisig compromise.** If ADMIN_ROLE multisig is compromised, attacker can schedule malicious strategy/fee collector/oracle swaps. 48 h timelock gives depositors a window to withdraw before takeover. Mitigation: use 3/5+ independent-custody multisig.
2. **Keeper liveness.** If the keeper is offline, no rebalance occurs and no fees are earned — **not** loss of deposits; depositors can still withdraw.
3. **DEX router bug.** The whitelisted router is upstream code outside our control; any bug in it is upstream scope. Mitigation: whitelist only audited routers (UniV3 / Sushi V2).
4. **Solidity compiler bug.** `solc 0.8.24` is the latest stable; contracts use `optimizer_runs = 200` which is well-tested.
5. **Timestamp arithmetic.** `block.timestamp` is used for deadline / timelock / oracle staleness. Miner influence is ≤ 15 s; all windows are ≥ minutes.

---

## References

- OpenZeppelin Contracts v5 ERC4626 virtual shares: <https://docs.openzeppelin.com/contracts/5.x/erc4626>
- Chainlink best-practice staleness/round-mismatch: <https://docs.chain.link/data-feeds/historical-data>
- EVMbench / Code4rena 2024–2026 patterns incorporated in `defi-security` skill checklist
- ConsenSys Ethereum Smart Contract Best Practices: <https://consensys.github.io/smart-contract-best-practices/>