// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";

/// @dev Optional mainnet fork smoke test. Skipped in CI when `ETH_RPC_URL` is unset.
///      Does not assert fake TVL or live deployments — this repo is not deployed.
contract ForkTest is Test {
    function test_forkSkipsWhenRpcUnset() public {
        string memory url = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(url).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(url);
        assertGt(block.number, 0);
        // Smoke: WETH exists. Not a vault integration and not a TVL claim.
        address weth = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
        assertGt(weth.code.length, 0);
    }
}
