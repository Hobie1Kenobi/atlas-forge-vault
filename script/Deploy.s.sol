// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Script, console2 } from "forge-std/Script.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";

import { AtlasVault } from "../src/AtlasVault.sol";
import { MockERC20 } from "../src/demo/MockERC20.sol";
import { MockYieldStrategy } from "../src/demo/MockYieldStrategy.sol";

/// @title Deploy
/// @notice Deploys AtlasVault behind ERC1967 + UUPS, with a 48h TimelockController as
///         `DEFAULT_ADMIN_ROLE`. If `ASSET` is unset, deploys the labeled demo MockERC20 and
///         MockYieldStrategy — that path is for local/testnet rehearsal, not production.
contract Deploy is Script {
    uint256 public constant TIMELOCK_DELAY = 48 hours;

    function run() external {
        address proposer = vm.envOr("PROPOSER", msg.sender);
        address pauser = vm.envOr("PAUSER", msg.sender);
        address harvester = vm.envOr("HARVESTER", msg.sender);

        vm.startBroadcast();
        (address impl, address proxy, address timelock, address strategyAddr) =
            _deploy(proposer, pauser, harvester, vm.envOr("ASSET", address(0)));
        vm.stopBroadcast();

        console2.log("AtlasVault implementation", impl);
        console2.log("AtlasVault proxy", proxy);
        console2.log("TimelockController", timelock);
        console2.log("Asset", AtlasVault(proxy).asset());
        console2.log("MockYieldStrategy (0 if production asset set)", strategyAddr);
        console2.log("Proposer", proposer);
        console2.log("Pauser", pauser);
        console2.log("Harvester", harvester);
    }

    function _deploy(
        address proposer,
        address pauser,
        address harvester,
        address asset
    ) internal returns (address impl, address proxy, address timelock, address strategyAddr) {
        bool demoAsset = asset == address(0);
        if (demoAsset) asset = address(new MockERC20());

        address[] memory proposers = new address[](1);
        proposers[0] = proposer;
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        TimelockController tl = new TimelockController(TIMELOCK_DELAY, proposers, executors, address(0));
        timelock = address(tl);

        impl = address(new AtlasVault());
        bytes memory initData = abi.encodeCall(
            AtlasVault.initialize,
            (
                IERC20(asset),
                vm.envOr("VAULT_NAME", string("Atlas Forge Vault")),
                vm.envOr("VAULT_SYMBOL", string("afvUSD")),
                timelock,
                pauser,
                harvester
            )
        );
        proxy = address(new ERC1967Proxy(impl, initData));

        if (demoAsset) {
            strategyAddr = address(new MockYieldStrategy(asset, proxy));
            tl.schedule(
                proxy, 0, abi.encodeCall(AtlasVault.setStrategy, (strategyAddr)), bytes32(0), bytes32(0), TIMELOCK_DELAY
            );
        }
    }
}
