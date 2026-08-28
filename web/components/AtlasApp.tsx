"use client";

import { useMemo, useState, useSyncExternalStore } from "react";
import { useQueryClient } from "@tanstack/react-query";
import {
  type Address,
  getAddress,
  isAddress,
  parseUnits,
  zeroAddress,
} from "viem";
import {
  useAccount,
  useChainId,
  useConnect,
  useDisconnect,
  useReadContracts,
  useSwitchChain,
  useWriteContract,
} from "wagmi";
import { waitForTransactionReceipt } from "wagmi/actions";
import { erc20Abi, vaultAbi } from "@/lib/abi";
import { anvil, config } from "@/lib/config";
import { fmtAmount, formatTxError } from "@/lib/format";

const STORAGE_KEY = "atlas.vaultAddress";
const VAULT_EVENT = "atlas-vault-address";
const envVault = process.env.NEXT_PUBLIC_VAULT_ADDRESS ?? "";

type Phase = "idle" | "wallet" | "pending" | "success" | "error";

function parseVault(value: string): Address | undefined {
  return isAddress(value) ? getAddress(value) : undefined;
}

function subscribeVault(onStoreChange: () => void) {
  window.addEventListener("storage", onStoreChange);
  window.addEventListener(VAULT_EVENT, onStoreChange);
  return () => {
    window.removeEventListener("storage", onStoreChange);
    window.removeEventListener(VAULT_EVENT, onStoreChange);
  };
}

function readStoredVault(): Address | undefined {
  try {
    const saved = window.localStorage.getItem(STORAGE_KEY);
    if (saved && isAddress(saved)) return getAddress(saved);
  } catch {
    /* ignore */
  }
  return parseVault(envVault);
}

function subscribeInjected(onStoreChange: () => void) {
  window.addEventListener("ethereum#initialized", onStoreChange);
  return () => window.removeEventListener("ethereum#initialized", onStoreChange);
}

export function AtlasApp() {
  const queryClient = useQueryClient();
  const { address, isConnected, status: accountStatus } = useAccount();
  const chainId = useChainId();
  const { connectors, connect, isPending: connecting, error: connectError } =
    useConnect();
  const { disconnect } = useDisconnect();
  const { switchChain, isPending: switching } = useSwitchChain();
  const { writeContractAsync } = useWriteContract();

  const vault = useSyncExternalStore(
    subscribeVault,
    readStoredVault,
    () => parseVault(envVault),
  );
  const hasInjected = useSyncExternalStore(
    subscribeInjected,
    () => "ethereum" in window,
    () => false,
  );

  const [draft, setDraft] = useState(envVault);
  const [depositInput, setDepositInput] = useState("100");
  const [withdrawInput, setWithdrawInput] = useState("10");
  const [action, setAction] = useState<string>("");
  const [phase, setPhase] = useState<Phase>("idle");
  const [hash, setHash] = useState<`0x${string}` | undefined>();
  const [txError, setTxError] = useState<string>("");
  const [minedReverted, setMinedReverted] = useState(false);

  const injected = connectors.find((c) => c.id === "injected") ?? connectors[0];
  const wrongChain = isConnected && chainId !== anvil.id;

  const vaultReads = useReadContracts({
    contracts: vault
      ? [
          { address: vault, abi: vaultAbi, functionName: "asset" },
          { address: vault, abi: vaultAbi, functionName: "totalAssets" },
          { address: vault, abi: vaultAbi, functionName: "idleAssets" },
          { address: vault, abi: vaultAbi, functionName: "paused" },
          { address: vault, abi: vaultAbi, functionName: "depositCap" },
          { address: vault, abi: vaultAbi, functionName: "strategy" },
          { address: vault, abi: vaultAbi, functionName: "decimals" },
          {
            address: vault,
            abi: vaultAbi,
            functionName: "balanceOf",
            args: [address ?? zeroAddress],
          },
          {
            address: vault,
            abi: vaultAbi,
            functionName: "maxDeposit",
            args: [address ?? zeroAddress],
          },
        ]
      : [],
    query: { enabled: Boolean(vault), refetchInterval: 4_000 },
  });

  const asset = vaultReads.data?.[0]?.result as Address | undefined;
  const totalAssets = vaultReads.data?.[1]?.result as bigint | undefined;
  const idleAssets = vaultReads.data?.[2]?.result as bigint | undefined;
  const paused = vaultReads.data?.[3]?.result as boolean | undefined;
  const depositCap = vaultReads.data?.[4]?.result as bigint | undefined;
  const strategy = vaultReads.data?.[5]?.result as Address | undefined;
  const shareDecimals = vaultReads.data?.[6]?.result as number | undefined;
  const shareBalance = vaultReads.data?.[7]?.result as bigint | undefined;
  const maxDeposit = vaultReads.data?.[8]?.result as bigint | undefined;

  const shareValueReads = useReadContracts({
    contracts:
      vault && shareBalance !== undefined
        ? [
            {
              address: vault,
              abi: vaultAbi,
              functionName: "convertToAssets",
              args: [shareBalance],
            },
          ]
        : [],
    query: {
      enabled: Boolean(vault) && shareBalance !== undefined,
      refetchInterval: 4_000,
    },
  });
  const shareAssets = shareValueReads.data?.[0]?.result as bigint | undefined;

  const tokenReads = useReadContracts({
    contracts:
      asset && vault
        ? [
            { address: asset, abi: erc20Abi, functionName: "symbol" },
            { address: asset, abi: erc20Abi, functionName: "decimals" },
            {
              address: asset,
              abi: erc20Abi,
              functionName: "balanceOf",
              args: [address ?? zeroAddress],
            },
            {
              address: asset,
              abi: erc20Abi,
              functionName: "allowance",
              args: [address ?? zeroAddress, vault],
            },
          ]
        : [],
    query: { enabled: Boolean(asset && vault), refetchInterval: 4_000 },
  });

  const symbol = tokenReads.data?.[0]?.result as string | undefined;
  const assetDecimals = tokenReads.data?.[1]?.result as number | undefined;
  const assetBalance = tokenReads.data?.[2]?.result as bigint | undefined;
  const allowance = tokenReads.data?.[3]?.result as bigint | undefined;

  const depositAmount = useMemo(() => {
    try {
      if (!depositInput || assetDecimals === undefined) return undefined;
      return parseUnits(depositInput, assetDecimals);
    } catch {
      return undefined;
    }
  }, [depositInput, assetDecimals]);

  const withdrawAmount = useMemo(() => {
    try {
      if (!withdrawInput || assetDecimals === undefined) return undefined;
      return parseUnits(withdrawInput, assetDecimals);
    } catch {
      return undefined;
    }
  }, [withdrawInput, assetDecimals]);

  const needsApprove =
    depositAmount !== undefined &&
    allowance !== undefined &&
    allowance < depositAmount;

  function applyVault() {
    const parsed = parseVault(draft.trim());
    if (!parsed) {
      window.localStorage.removeItem(STORAGE_KEY);
    } else {
      window.localStorage.setItem(STORAGE_KEY, parsed);
    }
    window.dispatchEvent(new Event(VAULT_EVENT));
  }

  async function send(
    label: string,
    args: Parameters<typeof writeContractAsync>[0],
  ) {
    setAction(label);
    setTxError("");
    setHash(undefined);
    setMinedReverted(false);
    setPhase("wallet");
    try {
      const txHash = await writeContractAsync(args);
      setHash(txHash);
      setPhase("pending");
      const receipt = await waitForTransactionReceipt(config, { hash: txHash });
      if (receipt.status === "reverted") {
        setPhase("error");
        setMinedReverted(true);
        setTxError("mined but reverted");
      } else {
        setPhase("success");
        await queryClient.invalidateQueries();
      }
    } catch (err) {
      setPhase("error");
      setTxError(formatTxError(err));
    }
  }

  const readError =
    vaultReads.failureReason ||
    vaultReads.data?.find((r) => r.status === "failure")?.error;

  return (
    <main>
      <div className="banner">
        <strong>DEMO — not production.</strong>
        Not deployed on mainnet. No TVL, no farm, no yield. This page talks to
        a local Anvil vault from <code>script/Deploy.s.sol</code>.{" "}
        <code>MockYieldStrategy</code> mints demo tokens to fake harvest — it
        is not a farm. Addresses come from that deploy output / env. Do not
        paste invented testnet addresses.
      </div>

      <h1>AtlasVault local dApp</h1>
      <p className="muted">
        Companion UI (P4). Ugly on purpose. Chain {anvil.id} @{" "}
        {anvil.rpcUrls.default.http[0]}.
      </p>

      <section className="card">
        <h2>Vault address</h2>
        <p className="note">
          Paste the <code>AtlasVault proxy</code> line from the forge script.
          Optional: <code>NEXT_PUBLIC_VAULT_ADDRESS</code> in{" "}
          <code>web/.env.local</code>.
        </p>
        <div className="row">
          <input
            type="text"
            spellCheck={false}
            placeholder="0x… proxy from Deploy.s.sol"
            value={draft}
            onChange={(e) => setDraft(e.target.value)}
          />
          <button type="button" onClick={applyVault}>
            Use address
          </button>
        </div>
        <p className="mono muted">
          active: {vault ?? "(none — deploy locally, then paste)"}
        </p>
      </section>

      <section className="card">
        <h2>Wallet</h2>
        {!hasInjected && (
          <p>
            No injected wallet. Install MetaMask (or similar), add Anvil:
            chain id {anvil.id}, RPC {anvil.rpcUrls.default.http[0]}, then
            import an Anvil key for this machine only.
          </p>
        )}
        <div className="row">
          {isConnected ? (
            <>
              <span className="mono">{address}</span>
              <button type="button" onClick={() => disconnect()}>
                Disconnect
              </button>
            </>
          ) : (
            <button
              type="button"
              className="primary"
              disabled={!injected || connecting || !hasInjected}
              onClick={() => injected && connect({ connector: injected })}
            >
              {connecting ? "Connecting…" : "Connect wallet (injected)"}
            </button>
          )}
        </div>
        <p className="muted">
          status {accountStatus}
          {connectError ? ` — ${connectError.message}` : ""}
        </p>
        {wrongChain && (
          <div className="row">
            <span>Wrong chain ({chainId}). Need {anvil.id}.</span>
            <button
              type="button"
              disabled={switching}
              onClick={() => switchChain({ chainId: anvil.id })}
            >
              Switch to Anvil
            </button>
          </div>
        )}
      </section>

      <section className="card">
        <h2>On-chain reads</h2>
        {!vault && <p>Set a vault address first.</p>}
        {vault && vaultReads.isLoading && <p>Reading…</p>}
        {vault && readError && (
          <p className="status error">
            Read failed. Is Anvil up? Is this the proxy from this Anvil
            process? {formatTxError(readError)}
          </p>
        )}
        {vault && !readError && (
          <table>
            <tbody>
              <tr>
                <th>asset()</th>
                <td className="mono">
                  {asset ? `${asset} (${symbol ?? "…"}${assetDecimals !== undefined ? `, ${assetDecimals} dp` : ""})` : "—"}
                </td>
              </tr>
              <tr>
                <th>totalAssets()</th>
                <td>
                  {fmtAmount(totalAssets, assetDecimals)}{" "}
                  <span className="muted">
                    (idle + strategy NAV; not a USD TVL)
                  </span>
                </td>
              </tr>
              <tr>
                <th>idleAssets()</th>
                <td>{fmtAmount(idleAssets, assetDecimals)}</td>
              </tr>
              <tr>
                <th>share balance</th>
                <td>
                  {isConnected
                    ? `${fmtAmount(shareBalance, shareDecimals)} shares`
                    : "connect wallet"}
                  {shareDecimals !== undefined && (
                    <span className="muted">
                      {" "}
                      (share decimals = asset + 6 = {shareDecimals})
                    </span>
                  )}
                  {isConnected && shareAssets !== undefined && (
                    <div className="muted">
                      convertToAssets(shares) ={" "}
                      {fmtAmount(shareAssets, assetDecimals)}
                    </div>
                  )}
                </td>
              </tr>
              <tr>
                <th>paused()</th>
                <td>{paused === undefined ? "—" : paused ? "true" : "false"}</td>
              </tr>
              <tr>
                <th>depositCap()</th>
                <td>
                  {depositCap === undefined
                    ? "—"
                    : depositCap === BigInt(0)
                      ? "0 (uncapped)"
                      : fmtAmount(depositCap, assetDecimals)}
                </td>
              </tr>
              <tr>
                <th>strategy()</th>
                <td className="mono">
                  {strategy === undefined
                    ? "—"
                    : strategy === zeroAddress
                      ? "0x0 (idle-only. Deploy.s.sol only schedules setStrategy; 48h timelock has not executed.)"
                      : `${strategy} — still a mock if you used the demo deploy, not a farm`}
                </td>
              </tr>
              <tr>
                <th>maxDeposit(you)</th>
                <td>
                  {maxDeposit === undefined
                    ? "—"
                    : maxDeposit === (BigInt(1) << BigInt(256)) - BigInt(1)
                      ? "uint256.max"
                      : fmtAmount(maxDeposit, assetDecimals)}
                </td>
              </tr>
              <tr>
                <th>your asset wallet</th>
                <td>
                  {isConnected
                    ? `${fmtAmount(assetBalance, assetDecimals)} ${symbol ?? ""}`
                    : "connect wallet"}
                </td>
              </tr>
            </tbody>
          </table>
        )}
      </section>

      {paused && (
        <div className="paused">
          Vault is paused. Deposits / mint / harvest revert (
          <code>maxDeposit == 0</code> → typically{" "}
          <code>ERC4626ExceededMaxDeposit</code>). Withdraw stays live — that
          is the product rule, not a bug.
        </div>
      )}

      <section className="card">
        <h2>Writes</h2>
        <p className="note">
          Approve if allowance is short, then deposit. Withdraw takes{" "}
          <strong>assets</strong> (underlying), not shares. Mint is{" "}
          <code>MockERC20.mint</code> — permissionless on the demo token,
          malpractice on anything real.
        </p>

        <div className="row">
          <button
            type="button"
            disabled={!isConnected || !asset || !address || wrongChain}
            onClick={() =>
              asset &&
              address &&
              send("mint", {
                address: asset,
                abi: erc20Abi,
                functionName: "mint",
                args: [address, parseUnits("10000", assetDecimals ?? 18)],
              })
            }
          >
            Mint 10_000 demo mUSD
          </button>
          <button
            type="button"
            disabled={!isConnected || !vault || wrongChain || paused === true}
            onClick={() =>
              vault &&
              send("pause", {
                address: vault,
                abi: vaultAbi,
                functionName: "pause",
              })
            }
          >
            Pause (PAUSER_ROLE / Anvil deployer)
          </button>
        </div>

        <h2>Deposit</h2>
        <div className="row">
          <input
            type="text"
            value={depositInput}
            onChange={(e) => setDepositInput(e.target.value)}
            placeholder="assets"
          />
          {needsApprove ? (
            <button
              type="button"
              className="primary"
              disabled={
                !isConnected ||
                !vault ||
                !asset ||
                !depositAmount ||
                wrongChain
              }
              onClick={() =>
                vault &&
                asset &&
                depositAmount !== undefined &&
                send("approve", {
                  address: asset,
                  abi: erc20Abi,
                  functionName: "approve",
                  args: [vault, depositAmount],
                })
              }
            >
              Approve {depositInput} {symbol ?? "asset"}
            </button>
          ) : (
            <button
              type="button"
              className="primary"
              disabled={
                !isConnected ||
                !vault ||
                !address ||
                !depositAmount ||
                wrongChain
              }
              onClick={() =>
                vault &&
                address &&
                depositAmount !== undefined &&
                send("deposit", {
                  address: vault,
                  abi: vaultAbi,
                  functionName: "deposit",
                  args: [depositAmount, address],
                })
              }
            >
              {paused ? "Deposit (will revert — paused)" : "Deposit"}
            </button>
          )}
        </div>
        <p className="note">
          allowance {fmtAmount(allowance, assetDecimals)}
          {paused ? " · paused: expect revert" : ""}
        </p>

        <h2>Withdraw</h2>
        <p className="note">Offered even while paused.</p>
        <div className="row">
          <input
            type="text"
            value={withdrawInput}
            onChange={(e) => setWithdrawInput(e.target.value)}
            placeholder="assets"
          />
          <button
            type="button"
            className="primary"
            disabled={
              !isConnected ||
              !vault ||
              !address ||
              !withdrawAmount ||
              wrongChain
            }
            onClick={() =>
              vault &&
              address &&
              withdrawAmount !== undefined &&
              send("withdraw", {
                address: vault,
                abi: vaultAbi,
                functionName: "withdraw",
                args: [withdrawAmount, address, address],
              })
            }
          >
            Withdraw
          </button>
        </div>
        {phase !== "idle" && (
          <div className={`status ${phase}`}>
            <div>
              {action} — {phase}
            </div>
            {hash && <div className="mono">{hash}</div>}
            {txError && <div>{txError}</div>}
            {minedReverted && <div>mined but reverted</div>}
          </div>
        )}
      </section>
    </main>
  );
}
