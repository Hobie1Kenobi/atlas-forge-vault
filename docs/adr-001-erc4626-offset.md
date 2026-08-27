# ADR-001: ERC-4626 decimals offset = 6 (plus internal idle accounting)

**Status:** Accepted for Atlas Forge v1  
**Date:** 2026-08-27

## Context

Empty (or nearly empty) ERC-4626 vaults are exposed to share-inflation / donation attacks: an attacker deposits 1 wei, donates a large amount of underlying, and a victim’s subsequent deposit mints zero or dust shares. OpenZeppelin v5 documents this in `ERC4626` and introduces `_decimalsOffset()` virtual shares (`10 ** offset` virtual shares and 1 virtual asset).

The product brief hypothesized that the OZ offset alone is sufficient and asked for offset 3 or 6, plus an explicit Foundry donation test. It also required `totalAssets` **not** to be `balanceOf(vault)` so a raw donation cannot mint extra shares.

## Decision

1. **`_decimalsOffset() = 6`**, not 3. Share token decimals = underlying decimals + 6.
2. **Internal `idleAssets` book** is the primary donation defense. `totalAssets = idleAssets + strategy.totalAssets()`. Naked transfers do not change the book.
3. **`creditDonations`** (timelock-only, 48h) is the explicit path that socializes unaccounted balance as yield. The offset still applies on that path.
4. Keep the donation **test** even though (2) already defeats the classic attack. The second test credits the donation and asserts the victim’s loss is below a documented dust bound (`1e15` wei on a `1e18`-scale deposit in `Inflation.t.sol`).

## Why 6 instead of 3

OZ’s analysis: larger offset makes the attack orders of magnitude more expensive relative to profit, at the cost of (a) more virtual-share leakage of yield and (b) slightly worse last-exiter behavior under loss. Offset 3 (`1e3` virtual shares) is already a large improvement over 0; offset 6 (`1e6`) is the same defense with a 1000× larger virtual float.

This vault is a strategy wrapper that may sit empty between testnet rehearsals and first deposits. Empty-vault cost is the case we care about. Leakage of 1e-6 of accrued yield to virtual shares is acceptable for v1. If a production fork wants offset 3 for friendlier share decimals, change the constant and re-run `Inflation.t.sol` — do not drop the test.

## Why internal accounting anyway

Offset is a *cost* defense, not a *correctness* defense. A vault that treats `balanceOf` as NAV will still reprice on every donation. That is surprising for users and for keepers. Idle-book accounting matches how production vaults (Yearn-style, ERC-4626 routers) separate “managed assets” from “tokens someone sent by mistake.”

Strategy-side inflation (lying `totalAssets`) is **not** solved by either defense at large TVL. v1 does not include an oracle; the strategy is a trusted valuation oracle for its own book. See `docs/threat-model.md`.

## Consequences

- Tests must mint/approve the demo underlying; they must not assume `balanceOf(vault) == totalAssets`.
- Rescue of accidental transfers requires a 48h `creditDonations` (or a future sweep-to-treasury, not in v1).
- Share UIs should display 24 decimals when the underlying is 18 decimals.

## Rejected alternatives

- **Offset 0 + dead-shares seed.** Requires a protocol-owned first deposit and still uses `balanceOf` unless we add the idle book. Worse empty-vault UX for a demo repo.
- **Offset 3.** Acceptable; we prefer 6 for the empty-vault rehearsal case and document the trade.
- **Inflation-attack “exploit PoC” as a script.** Out of policy. Defense is proven by `test/Inflation.t.sol` only.
