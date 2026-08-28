# A5-003 — `IStrategy.totalAssets()` is a trusted NAV oracle

- **ID:** A5-003
- **Severity:** Informational
- **Likelihood:** Certain *if* the attached strategy lies or bugs its book; the attach path is timelocked 48h
- **Root cause:** `AtlasVault.totalAssets()` is `idleAssets + strategy.totalAssets()` with no independent oracle, sanity bound, or TWAP. Share price (`convertToAssets` / `convertToShares`) follows that sum on every ERC-4626 call. The decimals offset and idle book defend *donation-to-vault* inflation, not strategy-side NAV.
- **Impact:** A strategy that over-reports assets inflates share price for remaining holders and can dilute a subsequent depositor. A strategy that under-reports (or cannot pay) makes `withdraw` / `redeem` revert `InsufficientLiquidity` until admin `emergencyWithdrawFromStrategy` or `reportLossAndDetachStrategy`. This is explicit v1 trust, not an unauthenticated attacker path: only `DEFAULT_ADMIN_ROLE` (the 48h timelock) can `setStrategy`.
- **PoC:** `test_A5_003_lyingStrategyNavMovesSharePrice`
- **Fix:** Accepted design. v1 does not include a NAV oracle. Mitigations that *are* in the code: 48h `setStrategy`, `setStrategy` asset/vault checks, loss write-off with `expectedRemaining`, users can exit while a change is queued, `_decimalsOffset = 6` bounds the empty-vault donation case only.
- **Retest:** `forge test --match-test test_A5_003_lyingStrategyNavMovesSharePrice`
