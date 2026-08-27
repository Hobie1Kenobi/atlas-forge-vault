// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IStrategy } from "../../src/interfaces/IStrategy.sol";

/// @dev TEST ONLY. Reports `reported` assets but always returns 0 on withdraw.
contract ShortPayingStrategy is IStrategy {
    using SafeERC20 for IERC20;

    address public immutable override asset;
    address public immutable override vault;
    uint256 public reported;

    constructor(
        address asset_,
        address vault_
    ) {
        asset = asset_;
        vault = vault_;
    }

    function setReported(
        uint256 v
    ) external {
        reported = v;
    }

    function totalAssets() external view override returns (uint256) {
        return reported;
    }

    function deposit(
        uint256 assets
    ) external override {
        IERC20(asset).safeTransferFrom(msg.sender, address(this), assets);
        reported += assets;
    }

    function withdraw(
        uint256,
        address
    ) external pure override returns (uint256) {
        return 0;
    }

    function harvest() external pure override returns (uint256) {
        return 0;
    }
}
