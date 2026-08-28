# Atlas Forge Vault

ERC-4626 strategy vault with isolated `IStrategy`, internal idle accounting, UUPS upgrades, and a 48h OpenZeppelin timelock as admin. Written as portfolio proof for **Smart Contract Engineer** / **DeFi Protocol Engineer** roles — not a tutorial token and not a live product.

This repo is **production-shaped** (roles, pause-exit, inflation defense, Foundry invariants) and **not production-certified**. There is no audit, no mainnet TVL, and **no deployment**. `forge test` is the deliverable.

## Why this is not a tutorial clone

Typical “my first vault” repos: a toy ERC-20, `totalAssets = balanceOf(this)`, owner-can-upgrade-now, pause that traps withdrawals, and a happy-path test. This one does the opposite:

- Underlying in tests is a labeled **demo** ERC-20. The flagship contract is the vault.
- `totalAssets = idleAssets + strategy.totalAssets()` so a donation cannot mint shares.
- `DEFAULT_ADMIN_ROLE` sits on `TimelockController` (48h). Pause does **not** block `withdraw`/`redeem`.
- `IStrategy` is a hard boundary; `MockYieldStrategy` is demo/test only.
- Tests include donation inflation, reentrancy, UUPS storage layout, fuzz, and a stateful invariant handler.

## Architecture

```
ERC1967 proxy ──delegatecall──► AtlasVault (UUPS)
                                    │
                                    ├─ ERC-4626 shares (decimals = asset + 6)
                                    ├─ idleAssets (internal book)
                                    ├─ IStrategy.totalAssets()
                                    ├─ PAUSER_ROLE / HARVESTER_ROLE
                                    └─ DEFAULT_ADMIN_ROLE → TimelockController (48h)
```

See [docs/threat-model.md](docs/threat-model.md) and [docs/adr-001-erc4626-offset.md](docs/adr-001-erc4626-offset.md).

Internal review notes (not an audit): [docs/findings/README.md](docs/findings/README.md).

## Install and test

Requires [Foundry](https://book.getfoundry.sh/getting-started/installation).

```bash
git clone https://github.com/Hobie1Kenobi/atlas-forge-vault.git
cd atlas-forge-vault
git submodule update --init --recursive
forge test
```

Optional: `forge coverage` (accounting/auth, not a vanity %) and `forge test --gas-report`.

## Invariants

Locked in `test/Invariant.t.sol`, `test/Inflation.t.sol`, `test/Vault.t.sol`, `test/Reentrancy.t.sol`, `test/Upgrade.t.sol`:

1. **Solvency** — `convertToAssets(totalSupply) <= totalAssets`.
2. **Rounding** — deposit rounding favors the vault.
3. **Donation / inflation** — a raw donation cannot steal from a subsequent depositor beyond rounding dust; credited donations are bound by the decimals offset.
4. **Auth** — only the timelock upgrades or `setStrategy`.
5. **Pause** — deposits and harvest revert; withdrawals succeed; `allocate` still succeeds (A5-001).
6. **Reentrancy** — strategy cannot reenter vault `deposit`.

## Admin powers

| Action | Role | Delay |
| --- | --- | --- |
| Upgrade, `setStrategy`, `setDepositCap`, emergency pull, loss write-off, `creditDonations`, unpause | Timelock (`DEFAULT_ADMIN_ROLE`) | 48h |
| Pause deposits / mint / harvest | `PAUSER_ROLE` | none |
| `harvest(minAssetsOut)`, `allocate` | `HARVESTER_ROLE` | none |
| `withdraw` / `redeem` | any shareholder | none (including while paused) |

`setStrategy` requires the old strategy to report zero assets unless `reportLossAndDetachStrategy` writes them off. Full table: [docs/threat-model.md](docs/threat-model.md).

## Tests

`forge test` on this revision: **58 passed, 1 skipped** (optional fork, skipped without `ETH_RPC_URL`).

| File | What it locks | Result |
| --- | --- | --- |
| `Vault.t.sol` | deposit/mint/withdraw/redeem, cap, pause, auth, harvest gain/zero/slippage, migration, loss write-off, initializer disabled, fee-on-transfer reject | 30 passed |
| `Findings.t.sol` | A5 review: accepted-design locks + Low accounting regressions | 11 passed |
| `Inflation.t.sol` | donation does not inflate; victim funds bound; offset hypothesis | 4 passed |
| `Reentrancy.t.sol` | malicious strategy and token | 4 passed |
| `Upgrade.t.sol` | V2 namespaced storage does not collide; delay enforced | 4 passed |
| `Fuzz.t.sol` | random deposit/withdraw/allocate | 4 passed, 256 runs each |
| `Invariant.t.sol` | stateful handler on the accounting heart (`fail_on_revert = true`) | 64 runs, 1600 calls, **0 reverts**, 5 invariants |
| `fork/Fork.t.sol` | skipped unless `ETH_RPC_URL` is set | 1 skipped |

Coverage (`forge coverage --report summary`): **AtlasVault 100% lines / 98.5% statements / 89% branches**. That is accounting + auth, not a vanity global %. Deploy script is untested on purpose (no broadcast in CI).

## Gas

`forge test --match-contract VaultTest --gas-report` (optimizer 200, solc 0.8.28, Cancun). Implementation runtime size **14,868 bytes**.

| Path | Median gas (this revision) |
| --- | --- |
| `deposit` | ~130k |
| `withdraw` | ~97k (higher when pulling from strategy) |
| `redeem` | ~68k |
| `allocate` | ~84k |
| `harvest` | ~36k |

Not gas-golfed. UUPS + AccessControl + idle book are accepted costs. Re-run locally; do not treat these as SLAs.

## Deployments

**Not deployed** on any testnet or mainnet. `script/Deploy.s.sol` broadcasts a proxy + 48h timelock. If `ASSET` is unset it deploys labeled demo `MockERC20` + `MockYieldStrategy` for local rehearsal only.

## Honest limitations

- Not audited. Not a live strategy. No oracle, no production yield source.
- `IStrategy.totalAssets()` is trusted. A lying strategy can inflate NAV at size; offset only bounds the empty-vault donation case.
- Fee-on-transfer and rebasing underlying are unsupported.
- `MockYieldStrategy` mints demo tokens to fake yield. Attaching it to real funds would be malpractice.
- 48h timelock is a product choice (exit window vs. ops speed), documented in the threat model — not a claim that 48h is always right.
- No bug bounty, no on-call, no mainnet invariant bot.

## Mapping to job titles

| Title | What in this repo maps |
| --- | --- |
| Smart Contract Engineer | UUPS + ERC-7201 storage, AccessControl, custom errors, CEI, Foundry unit/fuzz |
| DeFi Protocol Engineer | ERC-4626 rounding, donation inflation, strategy migration/loss, pause-exit, timelock admin |

Author: Hobie Cunningham ([Hobie1Kenobi](https://github.com/Hobie1Kenobi)). MIT license.
