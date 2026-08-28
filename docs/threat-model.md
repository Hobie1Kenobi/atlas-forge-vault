# Threat model — Atlas Forge Vault

**Status:** v1 architecture, not an audit report. No audit has been performed. This document describes intended trust boundaries and residual risk so a reviewer can map tests to code.

Internal A5 notes (not a paid audit, not Trail of Bits): [docs/findings/README.md](findings/README.md).

**Scope:** `AtlasVault` + `IStrategy` + OpenZeppelin `TimelockController` (48h). `MockYieldStrategy` / `MockERC20` are demo/test doubles and are **out of the production threat model**.

## System boundary

```
Users ──ERC-4626──► AtlasVault (proxy, UUPS)
                      │ idleAssets (internal book)
                      │ strategy.totalAssets()
                      ▼
                   IStrategy  (untrusted beyond the interface;
                               assumed not to report phantom assets
                               unless the attached implementation is honest)
Admin path: TimelockController (48h) holds DEFAULT_ADMIN_ROLE
Fast path:  PAUSER_ROLE (pause deposits/harvest only)
Keeper:     HARVESTER_ROLE (harvest, allocate)
```

`totalAssets` is **not** `asset.balanceOf(vault)`. Direct donations, airdrops, and positive rebases of vault-held tokens do not mint shares.

## Actors

| Actor | Trust | Capabilities |
| --- | --- | --- |
| Depositor | Untrusted | `deposit` / `mint` / `withdraw` / `redeem` |
| Harvester | Trusted for liveness, not for solvency | `harvest(minAssetsOut)`, `allocate` |
| Pauser | Trusted for freeze of inflows | `pause` (cannot unpause, cannot seize funds) |
| Timelock proposer | Trusted after 48h delay | Queue upgrade, `setStrategy`, `setDepositCap`, `emergencyWithdrawFromStrategy`, `reportLossAndDetachStrategy`, `creditDonations`, `unpause`, role grants |
| Timelock executor | Anyone if executor = `address(0)` | Execute ready operations |
| Strategy | Trusted for valuation of *its* `totalAssets` | Pull approved underlying, return assets on withdraw |
| Token | Must be standard ERC-20 | Fee-on-transfer rejected; rebasing unsupported |

## Admin powers

| Action | Who | Delay | User exit during delay? |
| --- | --- | --- | --- |
| `upgradeToAndCall` | Timelock (`DEFAULT_ADMIN_ROLE`) | 48h | Yes — withdraw/redeem stay live even if paused |
| `setStrategy` | Timelock | 48h | Yes |
| `setDepositCap` | Timelock | 48h | Yes (cap only affects new deposits) |
| `emergencyWithdrawFromStrategy` | Timelock | 48h | Yes |
| `reportLossAndDetachStrategy` | Timelock | 48h | Yes — remaining shareholders socialize the write-off |
| `creditDonations` | Timelock | 48h | Yes — credits unaccounted balance as yield to current holders |
| `unpause` | Timelock | 48h | n/a |
| `pause` | `PAUSER_ROLE` | none | Withdrawals remain available |
| `harvest` / `allocate` | `HARVESTER_ROLE` | none | Cannot steal; can realize yield or deploy idle |

A compromised pauser can freeze deposits and harvest but cannot trap user funds. A compromised harvester can deploy idle into the *currently attached* strategy or harvest with `minAssetsOut = 0`; they cannot upgrade or retarget the strategy. A compromised proposer can queue a malicious upgrade; users have 48h to exit.

## Assets and share inflation

Two defenses, both tested:

1. **Internal idle accounting.** `deposit` credits `idleAssets` by the transferred amount. Naked `transfer` into the vault does not change `totalAssets`. This defeats the classic “donate to `balanceOf`” inflation without any admin action.
2. **OpenZeppelin v5 `_decimalsOffset() = 6`.** If an admin later `creditDonations` or a strategy over-reports assets, virtual shares (`10^6`) make a 1-wei seed attack orders of magnitude more expensive than it is profitable. See `docs/adr-001-erc4626-offset.md` and `test/Inflation.t.sol`.

Residual: the **first depositor** after `creditDonations` still captures credited value (they held the only shares). That is yield, not theft of a *subsequent* depositor beyond the documented dust bound.

## Strategy trust

The vault believes `IStrategy.totalAssets()`. A malicious or buggy strategy can:

- Over-report assets → inflate share price (offset bounds empty-vault theft; large TVL still requires an honest strategy or an oracle, which v1 does not have).
- Under-report / lock funds → withdrawals revert with `InsufficientLiquidity` until admin emergency-withdraws or writes off via `reportLossAndDetachStrategy`.
- Reenter vault entry points — blocked by `nonReentrant` (`test/Reentrancy.t.sol`).

`setStrategy` requires the old strategy to report **zero** remaining assets. The documented loss path is `emergencyWithdrawFromStrategy` then either `setStrategy` (if fully recovered) or `reportLossAndDetachStrategy(expectedRemaining)` (explicit write-off; `expectedRemaining` must match to avoid fat-finger).

## Pause policy

| Function | Paused |
| --- | --- |
| `deposit` / `mint` / `harvest` | Revert (`maxDeposit`/`maxMint` = 0, `whenNotPaused`) |
| `withdraw` / `redeem` | **Succeed** |
| `allocate` | Not paused (moves idle only; harvester). Locked by `test_A5_001_allocateSucceedsWhilePaused`. |

This exists so a queued malicious upgrade plus a panic-pause cannot trap users.

## Out of scope / explicit non-goals

- Fee-on-transfer underlying (deposit reverts `FeeOnTransferUnsupported`).
- Rebasing underlying (rebase is ignored by the book; transfers may fail if balance < idle).
- External price oracles, NAV oracles, LST/RWA valuation.
- Production yield strategies (Aave, Morpho, Pendle, etc.).
- MEV / sandwich protection on harvest swaps (v1 harvest has no DEX).
- Governance token, fees, or insurance fund.
- Formal verification / on-chain audit.

## Invariants (tested)

1. Solvency: `convertToAssets(totalSupply) <= totalAssets`.
2. ERC-4626 rounding on deposit favors the vault.
3. Donation without `creditDonations` cannot steal from a subsequent depositor beyond 1 wei rounding; credited donation loss is bound by the offset test.
4. Only the timelock upgrades or `setStrategy`.
5. Paused: deposits + harvest revert; withdrawals succeed.
6. Strategy cannot reenter vault `deposit`.

## What this is not

This is not a substitute for an audit, bug bounty, or production monitoring. It is a portfolio-grade vault **shape**: accounting, roles, pause, upgrade delay, and tests a hiring manager can run with `forge test`.
