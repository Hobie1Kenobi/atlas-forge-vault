# A5-004 — Timelock `EXECUTOR_ROLE` granted to `address(0)`

- **ID:** A5-004
- **Severity:** Informational
- **Likelihood:** Certain (constructor in `script/Deploy.s.sol` and `test/helpers/Fixture.sol` both pass `executors[0] = address(0)`)
- **Root cause:** OpenZeppelin `TimelockController` treats a role granted to `address(0)` as open (`onlyRoleOrOpenRole`). `execute` / `executeBatch` are therefore callable by any address once `minDelay` (48h) has elapsed. The proposer still exclusively `schedule`s.
- **Impact:** Anyone can push a *ready* operation on-chain. That does **not** shorten the 48h delay, does **not** let a stranger queue new admin calls, and does **not** bypass `DEFAULT_ADMIN_ROLE` on the vault. Residual: a stranger can execute at the first legal timestamp (usually desirable so a sleeping executor cannot grief), and execution ordering of several ready ops is not restricted to a privileged keeper.
- **PoC:** `test_A5_004_anyoneCanExecuteAfterDelay`
- **Fix:** Accepted design. Permissionless execute after delay is a standard OZ pattern and matches `docs/threat-model.md` (“Timelock executor | Anyone if executor = address(0)”). A production fork that wants a dedicated executor should pass that address in the constructor instead of `address(0)` and re-run this test (it should then fail).
- **Retest:** `forge test --match-test test_A5_004_anyoneCanExecuteAfterDelay`
