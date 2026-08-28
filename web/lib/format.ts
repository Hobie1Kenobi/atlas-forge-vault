import {
  BaseError,
  ContractFunctionRevertedError,
  formatUnits,
  zeroAddress,
  type Address,
} from "viem";

export function shortAddr(value: Address | string): string {
  if (!value) return "—";
  if (value === zeroAddress) return "0x0";
  return `${value.slice(0, 6)}…${value.slice(-4)}`;
}

export function fmtAmount(
  value: bigint | undefined,
  decimals: number | undefined,
): string {
  if (value === undefined || decimals === undefined) return "—";
  return formatUnits(value, decimals);
}

export function formatTxError(err: unknown): string {
  if (err instanceof BaseError) {
    const reverted = err.walk(
      (e) => e instanceof ContractFunctionRevertedError,
    );
    if (reverted instanceof ContractFunctionRevertedError) {
      const name = reverted.data?.errorName;
      const args = reverted.data?.args;
      if (name) {
        const rendered = Array.isArray(args)
          ? args.map((a) => String(a)).join(", ")
          : "";
        return rendered ? `${name}(${rendered})` : name;
      }
      if (reverted.reason) return reverted.reason;
    }
    return err.shortMessage || err.message;
  }
  if (err instanceof Error) return err.message;
  return String(err);
}
