# A5-010 — No independent timelock canceller / guardian

- **ID:** A5-010
- **Severity:** Informational
- **Likelihood:** Certain in the intended deploy (`TimelockController` constructor grants `CANCELLER_ROLE` to each proposer and not to a separate guardian)
- **Root cause:** `script/Deploy.s.sol` / `Fixture` construct `TimelockController(delay, proposers, executors, admin=address(0))`. OZ grants `PROPOSER_ROLE` and `CANCELLER_ROLE` to `proposers[i]`. There is no second canceller. `admin = address(0)` means the timelock is self-administered after deploy (no leftover deployer admin).
- **Impact:** If the proposer key queues a malicious upgrade or `setStrategy`, that same key is the only canceller. Strangers cannot `cancel`. The 48h delay plus unpaused `withdraw` / `redeem` is the user-exit window (and pause cannot trap funds). Residual: no “security council abort” distinct from the compromised proposer.
- **PoC:** `test_A5_010_onlyProposerCanCancelQueuedOp`
- **Fix:** Accepted design for v1. A production fork that wants a guardian should `grantRole(CANCELLER_ROLE, guardian)` via the timelock (or pass an extra proposer/canceller at construction) and extend this test.
- **Retest:** `forge test --match-test test_A5_010_onlyProposerCanCancelQueuedOp`
