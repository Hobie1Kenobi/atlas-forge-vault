// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IStrategy } from "../../src/interfaces/IStrategy.sol";

/// @dev TEST ONLY. `deposit` does not pull tokens. Used to lock allocate's transfer check.
contract NoPullStrategy is IStrategy {
    address public immutable override asset;
    address public immutable override vault;

    constructor(
        address asset_,
        address vault_
    ) {
        asset = asset_;
        vault = vault_;
    }

    function totalAssets() external pure override returns (uint256) {
        return 0;
    }

    function deposit(
        uint256
    ) external pure override { }

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

/// @dev TEST ONLY. `withdraw` returns `assets` but transfers nothing.
contract OverCreditingWithdrawStrategy is IStrategy {
    using SafeERC20 for IERC20;

    address public immutable override asset;
    address public immutable override vault;

    constructor(
        address asset_,
        address vault_
    ) {
        asset = asset_;
        vault = vault_;
    }

    function totalAssets() external view override returns (uint256) {
        return IERC20(asset).balanceOf(address(this));
    }

    function deposit(
        uint256 assets
    ) external override {
        IERC20(asset).safeTransferFrom(msg.sender, address(this), assets);
    }

    function withdraw(
        uint256 assets,
        address
    ) external pure override returns (uint256) {
        return assets;
    }

    function harvest() external pure override returns (uint256) {
        return 0;
    }
}

/// @dev TEST ONLY. `totalAssets` is an independent knob, not a token balance.
contract LyingNavStrategy is IStrategy {
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
        uint256 assets,
        address to
    ) external override returns (uint256 withdrawn) {
        uint256 bal = IERC20(asset).balanceOf(address(this));
        withdrawn = assets > bal ? bal : assets;
        if (withdrawn != 0) IERC20(asset).safeTransfer(to, withdrawn);
        if (reported >= withdrawn) reported -= withdrawn;
        else reported = 0;
    }

    function harvest() external pure override returns (uint256) {
        return 0;
    }
}

/// @dev TEST ONLY. Holds tokens and reports them before `setStrategy`, so attaching it
///      immediately changes vault NAV.
contract PreFundedStrategy is IStrategy {
    using SafeERC20 for IERC20;

    address public immutable override asset;
    address public immutable override vault;

    constructor(
        address asset_,
        address vault_
    ) {
        asset = asset_;
        vault = vault_;
    }

    function totalAssets() external view override returns (uint256) {
        return IERC20(asset).balanceOf(address(this));
    }

    function deposit(
        uint256 assets
    ) external override {
        IERC20(asset).safeTransferFrom(msg.sender, address(this), assets);
    }

    function withdraw(
        uint256 assets,
        address to
    ) external override returns (uint256 withdrawn) {
        uint256 bal = IERC20(asset).balanceOf(address(this));
        withdrawn = assets > bal ? bal : assets;
        if (withdrawn != 0) IERC20(asset).safeTransfer(to, withdrawn);
    }

    function harvest() external pure override returns (uint256) {
        return 0;
    }
}
