# A5-005 — `withdraw` return value was credited as idle

- **ID:** A5-005
- **Severity:** Low
- **Likelihood:** Low (requires an `IStrategy` that transfers fewer tokens than its `withdraw` return value; attach is timelocked)
- **Root cause:** `harvest` already credits `idleAssets` from the observed `balanceOf` delta. `_ensureLiquidity` and `emergencyWithdrawFromStrategy` instead did `idleAssets += s.withdraw(...)` and trusted the return. A strategy that returned `assets` but transferred nothing inflated the idle book without tokens.
- **Impact:** With unaccounted donations sitting on the vault, a user withdraw could succeed by transferring those donated tokens while the strategy still held the credited capital (idle book went up by the lie, then down by the withdraw). Without donations, `safeTransfer` reverted and the user simply could not exit. Shareholder `totalAssets` still followed `strategy.totalAssets()`, so this was not a general theft of *credited* deposits against an honest strategy. It was an accounting inconsistency and a donation-sweep footgun.
- **PoC:** `test_A5_005_overCreditingWithdrawCannotInflateIdleOrSweepDonations`, `test_A5_005_emergencyWithdrawCreditsObservedTokensNotReturnValue`
- **Fix:** `_creditObservedWithdraw` measures `balanceOf` before/after `s.withdraw` and credits that delta. The return value is ignored for accounting. `IStrategy.withdraw` NatSpec updated.
- **Retest:** `forge test --match-test test_A5_005`
