# A5-007 — `maxWithdraw` does not discount illiquid strategy NAV

- **ID:** A5-007
- **Severity:** Informational
- **Likelihood:** Certain when the strategy reports assets it will not (or cannot) pay
- **Root cause:** `maxWithdraw` / `maxRedeem` are inherited from OpenZeppelin ERC-4626: claimable shares converted at `totalAssets()`, with no liquidity view on `IStrategy`. `withdraw` then calls `_ensureLiquidity`, which reverts `InsufficientLiquidity` if the strategy pays short.
- **Impact:** ERC-4626 integrators that trust `maxWithdraw` as “this amount will succeed” can see a revert. Users can still pass a smaller `assets` argument if *some* idle exists. v1 has no `IStrategy.maxWithdraw`; using `strategy.totalAssets()` as a liquidity proxy would still lie for a short-paying strategy (the same trusted-NAV assumption as A5-003).
- **PoC:** `test_A5_007_maxWithdrawDoesNotDiscountIlliquidStrategy`
- **Fix:** Accepted residual. Fixing it honestly needs a strategy-side liquidity view, which is out of v1 scope. The revert path is already tested (`test_withdrawInsufficientLiquidityWhenStrategyShort`).
- **Retest:** `forge test --match-test test_A5_007_maxWithdrawDoesNotDiscountIlliquidStrategy`
