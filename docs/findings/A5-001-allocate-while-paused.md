# A5-001 — `allocate` succeeds while paused

- **ID:** A5-001
- **Severity:** Informational
- **Likelihood:** Certain (the function has no `whenNotPaused`)
- **Root cause:** `allocate` is gated by `HARVESTER_ROLE` + `nonReentrant` only. Pause is applied to `deposit` / `mint` (via `maxDeposit == 0`) and `harvest` (`whenNotPaused`). `withdraw` / `redeem` are also intentionally unpaused.
- **Impact:** A harvester can still deploy idle capital into the *currently attached* strategy after `pause()`. Users can still `withdraw` / `redeem`. If the incident that triggered pause is “this strategy is bad,” allocate can move remaining idle into that strategy and make exit depend on `IStrategy.withdraw`. That is a trusted-harvester residual, not a pauser-seizure path: the pauser cannot allocate, and the harvester can allocate whether or not the vault is paused.
- **PoC:** `test_A5_001_allocateSucceedsWhilePaused`
- **Fix:** Accepted design. Pause is an inflow freeze + harvest freeze so users can exit during a queued upgrade, not a full capital lock. Adding `whenNotPaused` would let a compromised pauser trap idle in the vault *and* still leave deployed capital in the strategy — it does not improve the “malicious strategy” case, and it does worsen ops if pause is used during a routine upgrade window. Documented in `docs/threat-model.md` (Pause policy).
- **Retest:** `forge test --match-test test_A5_001_allocateSucceedsWhilePaused`
