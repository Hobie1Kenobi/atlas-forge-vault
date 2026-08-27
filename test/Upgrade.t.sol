// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { ERC1967Utils } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import { Fixture } from "./helpers/Fixture.sol";
import { AtlasVault } from "../src/AtlasVault.sol";
import { AtlasVaultV2 } from "./mocks/AtlasVaultV2.sol";

contract UpgradeTest is Fixture {
    function test_onlyTimelockCanUpgrade() public {
        AtlasVaultV2 v2 = new AtlasVaultV2();
        vm.prank(alice);
        vm.expectRevert();
        vault.upgradeToAndCall(address(v2), "");

        vm.prank(pauser);
        vm.expectRevert();
        vault.upgradeToAndCall(address(v2), "");
    }

    function test_v2StorageDoesNotCollideWithV1() public {
        uint256 shares = _deposit(alice, 250e18);
        uint256 idleBefore = vault.idleAssets();
        uint256 taBefore = vault.totalAssets();
        bytes32 v1Slot = vault.vaultStorageLocation();

        uint256 idlePacked = uint256(vm.load(address(vault), v1Slot));
        // slot layout: strategy (address) at offset 0 of the ERC-7201 struct
        address stratFromSlot = address(uint160(idlePacked));
        assertEq(stratFromSlot, address(strategy));

        bytes32 idleSlot = bytes32(uint256(v1Slot) + 1);
        assertEq(uint256(vm.load(address(vault), idleSlot)), idleBefore);

        AtlasVaultV2 v2impl = new AtlasVaultV2();
        _timelockCall(address(vault), abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (address(v2impl), bytes(""))));

        AtlasVaultV2 v2 = AtlasVaultV2(address(vault));
        assertEq(v2.idleAssets(), idleBefore);
        assertEq(v2.totalAssets(), taBefore);
        assertEq(v2.balanceOf(alice), shares);
        assertEq(uint256(vm.load(address(vault), idleSlot)), idleBefore);
        assertEq(v2.harvestFeeBps(), 0);

        _timelockCall(address(v2), abi.encodeCall(AtlasVaultV2.setHarvestFeeBps, (150)));
        assertEq(v2.harvestFeeBps(), 150);
        // V1 idle slot unchanged after writing the V2 field.
        assertEq(uint256(vm.load(address(vault), idleSlot)), idleBefore);
        assertTrue(v2.v2StorageLocation() != v1Slot);

        vm.prank(alice);
        uint256 out = v2.redeem(shares, alice, alice);
        assertGt(out, 0);
        assertLe(out, 250e18);
    }

    function test_implementationSlotUpdated() public {
        AtlasVaultV2 v2impl = new AtlasVaultV2();
        _timelockCall(address(vault), abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (address(v2impl), bytes(""))));
        bytes32 implSlot = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
        address impl = address(uint160(uint256(vm.load(address(vault), implSlot))));
        assertEq(impl, address(v2impl));
        // Silence unused import if compiler is picky about ERC1967Utils in some solc paths.
        implSlot = ERC1967Utils.IMPLEMENTATION_SLOT;
        impl = address(uint160(uint256(vm.load(address(vault), implSlot))));
        assertEq(impl, address(v2impl));
    }

    function test_cannotUpgradeWithoutTimelockDelay() public {
        AtlasVaultV2 v2impl = new AtlasVaultV2();
        bytes memory data = abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (address(v2impl), bytes("")));
        vm.prank(proposer);
        timelock.schedule(address(vault), 0, data, bytes32(0), bytes32(0), TIMELOCK_DELAY);
        vm.expectRevert();
        timelock.execute(address(vault), 0, data, bytes32(0), bytes32(0));
    }
}
