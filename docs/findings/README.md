# Internal A5 security review — Atlas Forge Vault

**This is not a paid audit. This is not a Trail of Bits report. This is not a certification.**

This folder is an **internal** A5 review of `Hobie1Kenobi/atlas-forge-vault` at `main` (`8bb1b5c` and this PR). It exists so the pause policy, strategy-NAV trust, timelock wiring, and two accounting hardenings cannot silently drift. It does **not** replace an independent audit, a bug bounty, or production monitoring.

There is **no mainnet TVL**, **no deployment**, and **no auditor branding** attached to these notes.

## Scope

| In scope | Out of scope |
| --- | --- |
| `src/AtlasVault.sol`, `src/interfaces/IStrategy.sol` | `atlas-forge-rwa` and any other repo |
| Deploy wiring in `script/Deploy.s.sol` (48h `TimelockController`, open executor) | Production yield strategies (Aave, Morpho, …) |
| Invariant config in `foundry.toml` + `test/Invariant.t.sol` | `MockYieldStrategy` / `MockERC20` as production code |
| Foundry tests that lock behavior or a fix | Exploit payloads, attack runbooks, mainnet-fork “TVL” claims |

Review method: read the contracts and tests on `main`, map each finding to a Foundry test, and change production code only when the vault’s own accounting was inconsistent even under a buggy `IStrategy`.

## What this is / is not

| This is | This is not |
| --- | --- |
| Internal review notes + regression tests | A paid security audit |
| Severity capped by evidence: Informational / Low / Medium; **High only if a test proves it** | A Trail of Bits, OpenZeppelin, Spearbit, or similar report |
| Accepted-design locks so policy cannot silently change | A claim that the vault is safe to launch |
| Two Low accounting hardenings in this PR | Formal verification |

## Findings index

| ID | Severity | Status | Title |
| --- | --- | --- | --- |
| [A5-001](A5-001-allocate-while-paused.md) | Informational | Accepted design | `allocate` succeeds while paused |
| [A5-002](A5-002-invariant-fail-on-revert.md) | Informational | Fixed (tests) | Invariant suite swallowed reverts |
| [A5-003](A5-003-trusted-strategy-nav.md) | Informational | Accepted design | `IStrategy.totalAssets()` is a trusted NAV oracle |
| [A5-004](A5-004-timelock-open-executor.md) | Informational | Accepted design | Timelock `EXECUTOR_ROLE` granted to `address(0)` |
| [A5-005](A5-005-withdraw-return-credited.md) | Low | Fixed | `withdraw` return value was credited as idle |
| [A5-006](A5-006-allocate-unverified-pull.md) | Low | Fixed | `allocate` did not verify the strategy pulled tokens |
| [A5-007](A5-007-maxwithdraw-illiquidity.md) | Informational | Accepted residual | `maxWithdraw` does not discount illiquid strategy NAV |
| [A5-008](A5-008-unpause-timelock-only.md) | Informational | Accepted design | `unpause` is timelock-only |
| [A5-009](A5-009-setstrategy-nonzero-nav.md) | Informational | Accepted design | `setStrategy` does not require the new strategy to report zero |
| [A5-010](A5-010-no-independent-canceller.md) | Informational | Accepted design | No independent timelock canceller / guardian |

No Critical or High findings. Nothing in this review proved unauthorized seizure of credited shareholder funds against an `IStrategy` that honors its token transfers.

## A0 nits (evaluated, not rubber-stamped)

These were called out before the review. Each has a dedicated note and a Foundry test:

1. **`allocate` while paused** — kept. Pause is an exit window, not a capital freeze. [A5-001](A5-001-allocate-while-paused.md)
2. **`fail_on_revert = false` + `try/catch`** — test gap. Handler is now precondition-gated and `fail_on_revert = true`. [A5-002](A5-002-invariant-fail-on-revert.md)
3. **Trusted `IStrategy.totalAssets()`** — kept. v1 has no independent oracle. [A5-003](A5-003-trusted-strategy-nav.md)
4. **Timelock executor = `address(0)`** — kept. Permissionless execute after the 48h delay. [A5-004](A5-004-timelock-open-executor.md)

## Code changes in this PR

- **A5-005:** `_ensureLiquidity` / `emergencyWithdrawFromStrategy` credit the observed underlying delta, matching `harvest`.
- **A5-006:** `allocate` reverts `AllocateTransferMismatch` if the strategy does not pull exactly `assets`.
- **A5-002:** invariant handler no longer swallows vault reverts.

## Retest

```bash
forge test
forge fmt --check
```

Behavior locks live in `test/Findings.t.sol`. Invariants: `forge test --match-contract InvariantTest`.
