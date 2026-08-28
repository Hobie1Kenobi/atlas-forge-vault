# A5-002 — Invariant suite swallowed reverts

- **ID:** A5-002
- **Severity:** Informational
- **Likelihood:** High for *missing* a reverting vault bug (the suite would stay green); N/A for production fund flow
- **Root cause:** `foundry.toml` set `[profile.default.invariant] fail_on_revert = false`, and `VaultHandler` wrapped `deposit` / `mint` / `withdraw` / `redeem` / `allocate` / `harvest` in `try/catch {}`. A real revert inside those vault calls was counted as a no-op. The README line “0 reverts” was therefore not evidence that the vault never reverted.
- **Impact:** Test-coverage gap only. Stateful invariants (`solvency`, idle backing, donation exclusion) still ran on the states the handler *did* reach, but they could not fail the suite when a selector reverted unexpectedly. This is not a vault solvency bug.
- **PoC:** `test_A5_002_allocateZeroStillReverts` (proves allocate still reverts on a broken input). Suite lock: `InvariantTest` + `fail_on_revert = true`.
- **Fix:** Handler selectors are precondition-gated (`bound` / early `return`) and call the vault without `try/catch`. `fail_on_revert = true` in default and intense profiles. Unexpected vault reverts now fail CI.
- **Retest:** `forge test --match-contract InvariantTest` and `forge test --match-test test_A5_002_allocateZeroStillReverts`
