# A5-006 — `allocate` did not verify the strategy pulled tokens

- **ID:** A5-006
- **Severity:** Low
- **Likelihood:** Low (requires `IStrategy.deposit` not to `transferFrom` the approved amount; attach is timelocked)
- **Root cause:** `allocate` decremented `idleAssets`, approved the strategy, called `deposit(assets)`, and cleared the approval. It never checked that `asset.balanceOf(vault)` fell by `assets`. A no-op `deposit` left tokens on the vault as unaccounted balance while shrinking the idle book (and therefore `totalAssets`).
- **Impact:** Credited user capital could disappear from NAV and become a donation-shaped residual until a 48h `creditDonations`. Withdrawals would then be limited by the shrunk book. This is the allocate-side counterpart of the deposit-path `FeeOnTransferUnsupported` check, which already requires the observed transfer to match.
- **PoC:** `test_A5_006_allocateRevertsIfStrategyDoesNotPull`
- **Fix:** After `deposit`, require `pulled == assets` or revert `AllocateTransferMismatch`. The whole call reverts, so idle is unchanged.
- **Retest:** `forge test --match-test test_A5_006_allocateRevertsIfStrategyDoesNotPull`
