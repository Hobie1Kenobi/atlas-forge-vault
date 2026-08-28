# Atlas Forge — proof index

Owner: Hobie Cunningham ([Hobie1Kenobi](https://github.com/Hobie1Kenobi)). Every bullet maps to a file and a command. No fake TVL, no fake audit.

## Repos

| Artifact | Where | Run |
| --- | --- | --- |
| P1 ERC-4626 vault | this repo | `git submodule update --init --recursive && forge test` |
| P2 permissioned RWA token | [atlas-forge-rwa](https://github.com/Hobie1Kenobi/atlas-forge-rwa) | same |
| P3 internal review | [`docs/findings/`](docs/findings/) here and in the RWA repo | not a paid audit |
| P4 local dApp | [`web/`](web/README.md) | Anvil + `pnpm dev` |

## Title → proof

**Smart Contract Engineer** — `src/AtlasVault.sol` (UUPS, ERC-7201, AccessControl, pause-exit). `forge test` (58 passed, 1 skipped fork). Inflation: `test/Inflation.t.sol`.

**DeFi Protocol Engineer** — `totalAssets = idleAssets + strategy.totalAssets()`. Harvest/allocate/migration. Invariants: `test/Invariant.t.sol` (`fail_on_revert = true`).

**RWA / Tokenization** — [PermissionedToken](https://github.com/Hobie1Kenobi/atlas-forge-rwa/blob/main/src/PermissionedToken.sol). Registry, freeze, `forceTransfer`. README first line is the honest not-securities label. `forge test` (76 passed).

**Security-adjacent** — [vault findings](docs/findings/README.md), [rwa findings](https://github.com/Hobie1Kenobi/atlas-forge-rwa/tree/main/docs/findings). Internal review only.

**Full-stack Web3** — `web/` (Next.js, viem, wagmi). Deposit/withdraw tx states. Pause: deposit reverts, withdraw stays live. Local Anvil only.

## Will not claim

Mainnet TVL, paid audit, ERC-3643 certification, USD peg, live farm.
