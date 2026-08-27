// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { AtlasVault } from "../../src/AtlasVault.sol";

/// @dev TEST ONLY. Adds a namespaced V2 field so we can prove it does not collide with V1 storage.
contract AtlasVaultV2 is AtlasVault {
    /// @custom:storage-location erc7201:atlasforge.storage.VaultV2
    struct V2Storage {
        uint256 harvestFeeBps;
    }

    // keccak256(abi.encode(uint256(keccak256("atlasforge.storage.VaultV2")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant V2_STORAGE_LOCATION = 0x7c6a3c1b8e4d0a91f2b5e6c9d0a3b4c7e1f8a2d5b6c9e0f3a4b7c8d1e2f30500;

    error FeeTooHigh(uint256 bps);

    event HarvestFeeBpsUpdated(uint256 bps);

    /// @notice New V2 admin knob. Must not share a slot with V1 `idleAssets` / `strategy`.
    function setHarvestFeeBps(
        uint256 bps
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (bps > 10_000) revert FeeTooHigh(bps);
        _v2().harvestFeeBps = bps;
        emit HarvestFeeBpsUpdated(bps);
    }

    function harvestFeeBps() external view returns (uint256) {
        return _v2().harvestFeeBps;
    }

    function v2StorageLocation() external pure returns (bytes32) {
        return V2_STORAGE_LOCATION;
    }

    function _v2() private pure returns (V2Storage storage $) {
        bytes32 location = V2_STORAGE_LOCATION;
        assembly {
            $.slot := location
        }
    }
}
