// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { Fixture } from "./helpers/Fixture.sol";
import { AtlasVault } from "../src/AtlasVault.sol";
import { ReentrantStrategy } from "./mocks/ReentrantStrategy.sol";
import { ReentrantToken } from "./mocks/MaliciousTokens.sol";

contract ReentrancyTest is Fixture {
    function test_strategyCannotReenterDepositOnAllocate() public {
        ReentrantStrategy evil = new ReentrantStrategy(address(asset), address(vault));
        evil.setAttackOnDeposit(true);

        _timelockCall(address(vault), abi.encodeCall(AtlasVault.emergencyWithdrawFromStrategy, ()));
        _timelockCall(address(vault), abi.encodeCall(AtlasVault.setStrategy, (address(evil))));

        _deposit(alice, 10e18);
        vm.prank(harvester);
        vm.expectRevert(ReentrancyGuardUpgradeable.ReentrancyGuardReentrantCall.selector);
        vault.allocate(10e18);

        // Idle still credited; funds not lost to the attacker.
        assertEq(vault.idleAssets(), 10e18);
        assertEq(vault.totalAssets(), 10e18);
    }

    function test_strategyCannotReenterOnHarvest() public {
        ReentrantStrategy evil = new ReentrantStrategy(address(asset), address(vault));
        evil.setAttackOnHarvest(true);

        _timelockCall(address(vault), abi.encodeCall(AtlasVault.emergencyWithdrawFromStrategy, ()));
        _timelockCall(address(vault), abi.encodeCall(AtlasVault.setStrategy, (address(evil))));

        vm.prank(harvester);
        vm.expectRevert(ReentrancyGuardUpgradeable.ReentrancyGuardReentrantCall.selector);
        vault.harvest(0);
    }

    function test_strategyCannotReenterOnWithdraw() public {
        ReentrantStrategy evil = new ReentrantStrategy(address(asset), address(vault));
        _timelockCall(address(vault), abi.encodeCall(AtlasVault.emergencyWithdrawFromStrategy, ()));
        _timelockCall(address(vault), abi.encodeCall(AtlasVault.setStrategy, (address(evil))));

        _deposit(alice, 10e18);
        vm.prank(harvester);
        vault.allocate(10e18);
        evil.setAttackOnWithdraw(true);

        vm.prank(alice);
        vm.expectRevert(ReentrancyGuardUpgradeable.ReentrancyGuardReentrantCall.selector);
        vault.withdraw(1e18, alice, alice);
    }

    function test_maliciousTokenCannotReenterDeposit() public {
        ReentrantToken token = new ReentrantToken();
        AtlasVault impl = new AtlasVault();
        bytes memory initData = abi.encodeCall(
            AtlasVault.initialize, (IERC20(token), "RVault", "rv", address(timelock), pauser, harvester)
        );
        AtlasVault rVault = AtlasVault(address(new ERC1967Proxy(address(impl), initData)));
        token.setVault(rVault);

        token.mint(alice, 10e18);
        vm.prank(alice);
        token.approve(address(rVault), type(uint256).max);
        token.setAttack(true);

        vm.prank(alice);
        vm.expectRevert(ReentrancyGuardUpgradeable.ReentrancyGuardReentrantCall.selector);
        rVault.deposit(5e18, alice);
    }
}
