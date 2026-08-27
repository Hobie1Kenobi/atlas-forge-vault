// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IStrategy } from "../interfaces/IStrategy.sol";
import { MockERC20 } from "./MockERC20.sol";

/// @title MockYieldStrategy
/// @notice DEMO / TEST ONLY. Holds the vault's underlying and pretends to earn yield by minting
///         the demo `MockERC20`. Do not attach this to a vault that holds real user funds.
/// @dev Harvest realizes `pendingYield` by minting into this contract so `totalAssets` increases.
///      `demoAccrue` / `demoLose` are explicit cheat surfaces for tests — they are not production
///      strategy hooks.
contract MockYieldStrategy is IStrategy {
    using SafeERC20 for IERC20;

    address public immutable override asset;
    address public immutable override vault;

    uint256 public pendingYield;
    bool public payoutToVault;

    error NotVault();
    error ZeroAddress();

    modifier onlyVault() {
        if (msg.sender != vault) revert NotVault();
        _;
    }

    constructor(
        address asset_,
        address vault_
    ) {
        if (asset_ == address(0) || vault_ == address(0)) revert ZeroAddress();
        asset = asset_;
        vault = vault_;
    }

    /// @inheritdoc IStrategy
    function totalAssets() external view override returns (uint256) {
        return IERC20(asset).balanceOf(address(this));
    }

    /// @inheritdoc IStrategy
    function deposit(
        uint256 assets
    ) external override onlyVault {
        IERC20(asset).safeTransferFrom(msg.sender, address(this), assets);
    }

    /// @inheritdoc IStrategy
    function withdraw(
        uint256 assets,
        address to
    ) external override onlyVault returns (uint256 withdrawn) {
        uint256 bal = IERC20(asset).balanceOf(address(this));
        withdrawn = assets > bal ? bal : assets;
        if (withdrawn != 0) IERC20(asset).safeTransfer(to, withdrawn);
    }

    /// @inheritdoc IStrategy
    function harvest() external override onlyVault returns (uint256 harvested) {
        harvested = pendingYield;
        pendingYield = 0;
        if (harvested != 0) {
            address to = payoutToVault ? vault : address(this);
            MockERC20(asset).mint(to, harvested);
        }
    }

    /// @notice DEMO ONLY. Queue fake yield that `harvest` will mint.
    function demoAccrue(
        uint256 amount
    ) external {
        pendingYield += amount;
    }

    /// @notice DEMO ONLY. Destroy underlying held here to simulate a strategy loss.
    function demoLose(
        uint256 amount
    ) external {
        MockERC20(asset).burn(address(this), amount);
    }

    /// @notice DEMO ONLY. If true, `harvest` mints yield to the vault instead of this contract.
    function demoSetPayoutToVault(
        bool v
    ) external {
        payoutToVault = v;
    }
}
