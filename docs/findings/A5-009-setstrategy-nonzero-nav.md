# A5-009 — `setStrategy` does not require the new strategy to report zero

- **ID:** A5-009
- **Severity:** Informational
- **Likelihood:** Admin-only (48h timelock). Certain *if* the new strategy already reports NAV.
- **Root cause:** `setStrategy` requires the *outgoing* strategy to report `totalAssets() == 0` (or to have been detached via `reportLossAndDetachStrategy`). It checks the incoming strategy’s `asset()` and `vault()`, but not `totalAssets() == 0`. Attaching a pre-funded or lying strategy immediately adds that figure to vault NAV (A5-003).
- **Impact:** Current shareholders receive that NAV as yield (honest leftover tokens) or as phantom price (lying report). Subsequent depositors buy in at the new price. Users have 48h after `schedule` to exit. Requiring zero on the incoming strategy would block a deliberate “seed the new strategy first” migration; that is a product choice, not an auth hole.
- **PoC:** `test_A5_009_setStrategyAcceptsPreFundedStrategy`
- **Fix:** Accepted design. Same trust boundary as A5-003. Operators who want a hard empty-attach rule can add it in a later revision and flip this test.
- **Retest:** `forge test --match-test test_A5_009_setStrategyAcceptsPreFundedStrategy`
