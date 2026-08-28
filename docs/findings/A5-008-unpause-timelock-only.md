# A5-008 — `unpause` is timelock-only

- **ID:** A5-008
- **Severity:** Informational
- **Likelihood:** Certain (`unpause` is `onlyRole(DEFAULT_ADMIN_ROLE)`; that role is the 48h timelock)
- **Root cause:** `PAUSER_ROLE` can `_pause()` immediately. Restoring deposits/harvest requires a timelocked `unpause()`. A compromised pauser therefore cannot unpause in the same transaction as a pause (no pause-toggle sandwich). A compromised pauser *can* freeze inflows and harvest for at least `minDelay` (48h in the intended deploy).
- **Impact:** Liveness, not seizure. `withdraw` / `redeem` remain available (A5-001). The residual is a 48h deposit freeze if the pauser key is malicious or lost — by design, so a panic pause cannot be silently undone by the same key.
- **PoC:** `test_A5_008_pauserCannotUnpause` (also `VaultTest.test_unpauseIsTimelockOnly`)
- **Fix:** Accepted design. Documented in `docs/threat-model.md` and the README admin table.
- **Retest:** `forge test --match-test test_A5_008_pauserCannotUnpause`
