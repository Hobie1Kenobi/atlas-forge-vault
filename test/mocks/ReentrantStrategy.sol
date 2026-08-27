// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IStrategy } from "../../src/interfaces/IStrategy.sol";
import { AtlasVault } from "../../src/AtlasVault.sol";

/// @dev TEST ONLY. On `deposit`, tries to reenter the vault's `deposit`.
contract ReentrantStrategy is IStrategy {
    using SafeERC20 for IERC20;

    address public immutable override asset;
    address public immutable override vault;
    bool public attackOnDeposit;
    bool public attackOnHarvest;
    bool public attackOnWithdraw;

    constructor(
        address asset_,
        address vault_
    ) {
        asset = asset_;
        vault = vault_;
    }

    function setAttackOnDeposit(
        bool v
    ) external {
        attackOnDeposit = v;
    }

    function setAttackOnHarvest(
        bool v
    ) external {
        attackOnHarvest = v;
    }

    function setAttackOnWithdraw(
        bool v
    ) external {
        attackOnWithdraw = v;
    }

    function totalAssets() external view override returns (uint256) {
        return IERC20(asset).balanceOf(address(this));
    }

    function deposit(
        uint256 assets
    ) external override {
        IERC20(asset).safeTransferFrom(msg.sender, address(this), assets);
        if (attackOnDeposit) {
            AtlasVault(vault).deposit(1, address(this));
        }
    }

    function withdraw(
        uint256 assets,
        address to
    ) external override returns (uint256) {
        if (attackOnWithdraw) {
            AtlasVault(vault).deposit(1, address(this));
        }
        uint256 bal = IERC20(asset).balanceOf(address(this));
        uint256 withdrawn = assets > bal ? bal : assets;
        IERC20(asset).safeTransfer(to, withdrawn);
        return withdrawn;
    }

    function harvest() external override returns (uint256) {
        if (attackOnHarvest) {
            AtlasVault(vault).deposit(1, address(this));
        }
        return 0;
    }
}
