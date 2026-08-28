# Local AtlasVault dApp (P4)

Minimal Next.js page that proves the vault is callable. Not a product, not a design award, not mainnet, not a farm.

Stack: Next.js App Router, TypeScript, viem, wagmi. Injected wallet only. Talks to a **local Anvil** deploy from `script/Deploy.s.sol`. There are no testnet or mainnet addresses in this repo — do not invent them.

`MockYieldStrategy` mints demo tokens to fake harvest. Treating `totalAssets()` as TVL would be a lie.

## Run (local Anvil)

From the repo root. Anvil account #0 is the well-known Foundry key — local only.

```bash
# terminal A
anvil
```

```bash
# terminal B — deploy (ASSET unset → demo MockERC20 + MockYieldStrategy)
forge script script/Deploy.s.sol \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
```

Copy `AtlasVault proxy` from that output, or:

```bash
cd web
node scripts/from-broadcast.mjs > .env.local
pnpm install
pnpm dev
```

Open http://localhost:3000. If you skip `.env.local`, paste the proxy into the address field.

Add Anvil to the injected wallet: chain id `31337`, RPC `http://127.0.0.1:8545`. Import Anvil account #0 only on a throwaway MetaMask.

## What you should see

- Connect wallet (injected)
- Reads: `asset`, `totalAssets`, `idleAssets`, share balance, `paused`, `depositCap`, `strategy`
- Writes with pending / success / revert reason: approve (if needed), deposit, withdraw
- When paused: deposit reverts (`maxDeposit == 0`); withdraw is still offered

`Deploy.s.sol` **schedules** `setStrategy` on the 48h timelock and does not execute it. `strategy()` stays `0x0` until someone waits and executes. Deposits still work into idle. That is expected.

Pause as the deployer (pauser defaults to the broadcaster):

```bash
cast send $VAULT "pause()" --rpc-url http://127.0.0.1:8545 \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
```

Or use the Pause button if that account is connected.

Mint on the page hits `MockERC20.mint` (permissionless demo token). It will revert on a real asset.

## Env

See `.env.example`. Only `NEXT_PUBLIC_VAULT_ADDRESS` is required (the ERC1967 proxy). Asset and strategy are read on-chain. Restart `pnpm dev` after editing `.env.local`, or paste the proxy in the UI.

## Out of scope

Foundry CI does not run `pnpm`. `foundry.toml` skips `web/`. This app is not deployed.
