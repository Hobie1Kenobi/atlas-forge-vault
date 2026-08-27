// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";

import { AtlasVault } from "../../src/AtlasVault.sol";
import { MockYieldStrategy } from "../../src/demo/MockYieldStrategy.sol";
import { MockERC20 } from "../../src/demo/MockERC20.sol";

/// @dev Shared fixture: real 48h timelock as vault admin, proxy + implementation, demo strategy.
abstract contract Fixture is Test {
    uint256 internal constant TIMELOCK_DELAY = 48 hours;

    MockERC20 internal asset;
    AtlasVault internal vault;
    AtlasVault internal vaultImpl;
    MockYieldStrategy internal strategy;
    TimelockController internal timelock;

    address internal proposer = makeAddr("proposer");
    address internal pauser = makeAddr("pauser");
    address internal harvester = makeAddr("harvester");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal attacker = makeAddr("attacker");

    function setUp() public virtual {
        asset = new MockERC20();
        vaultImpl = new AtlasVault();

        address[] memory proposers = new address[](1);
        proposers[0] = proposer;
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        timelock = new TimelockController(TIMELOCK_DELAY, proposers, executors, address(0));

        bytes memory initData = abi.encodeCall(
            AtlasVault.initialize, (IERC20(asset), "Atlas Forge Vault", "afvUSD", address(timelock), pauser, harvester)
        );
        vault = AtlasVault(address(new ERC1967Proxy(address(vaultImpl), initData)));

        strategy = new MockYieldStrategy(address(asset), address(vault));
        _timelockCall(address(vault), abi.encodeCall(AtlasVault.setStrategy, (address(strategy))));
    }

    function _timelockCall(
        address target,
        bytes memory data
    ) internal {
        vm.prank(proposer);
        timelock.schedule(target, 0, data, bytes32(0), bytes32(0), TIMELOCK_DELAY);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        timelock.execute(target, 0, data, bytes32(0), bytes32(0));
    }

    function _mintApprove(
        address user,
        uint256 amount
    ) internal {
        asset.mint(user, amount);
        vm.prank(user);
        asset.approve(address(vault), type(uint256).max);
    }

    function _deposit(
        address user,
        uint256 amount
    ) internal returns (uint256 shares) {
        _mintApprove(user, amount);
        vm.prank(user);
        shares = vault.deposit(amount, user);
    }
}
