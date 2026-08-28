#!/usr/bin/env node
/**
 * Print NEXT_PUBLIC_* lines from a Foundry broadcast log.
 * Does not invent addresses — exits if ERC1967Proxy is missing.
 */
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

const path =
  process.argv[2] ??
  resolve(
    import.meta.dirname,
    "../../broadcast/Deploy.s.sol/31337/run-latest.json",
  );

let run;
try {
  run = JSON.parse(readFileSync(path, "utf8"));
} catch (err) {
  console.error(`Cannot read ${path}: ${err instanceof Error ? err.message : err}`);
  process.exit(1);
}

const txs = Array.isArray(run.transactions) ? run.transactions : [];
const find = (name) =>
  txs.find((t) => t.contractName === name && t.contractAddress)?.contractAddress;

const proxy = find("ERC1967Proxy");
if (!proxy) {
  console.error(`No ERC1967Proxy in ${path}. Deploy first: forge script script/Deploy.s.sol --broadcast`);
  process.exit(1);
}

console.log(`# generated from ${path}`);
console.log(`NEXT_PUBLIC_VAULT_ADDRESS=${proxy}`);
console.log("NEXT_PUBLIC_CHAIN_ID=31337");
console.log("NEXT_PUBLIC_RPC_URL=http://127.0.0.1:8545");
console.error(`# AtlasVault proxy ${proxy}`);
const asset = find("MockERC20");
const strategy = find("MockYieldStrategy");
if (asset) console.error(`# MockERC20 (info only) ${asset}`);
if (strategy) {
  console.error(`# MockYieldStrategy (info only) ${strategy}`);
  console.error("# setStrategy is scheduled, not executed (48h timelock). strategy() stays 0x0 until then.");
}
