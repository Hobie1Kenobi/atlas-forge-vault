// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import { AtlasVault } from "../../src/AtlasVault.sol";

/// @dev TEST ONLY. Takes a 1% fee on every transfer/transferFrom.
contract FeeOnTransferToken is ERC20 {
    constructor() ERC20("Fee Token", "FEE") { }

    function mint(
        address to,
        uint256 amount
    ) external {
        _mint(to, amount);
    }

    function _update(
        address from,
        address to,
        uint256 value
    ) internal override {
        if (from != address(0) && to != address(0) && value != 0) {
            uint256 fee = value / 100;
            super._update(from, to, value - fee);
            super._update(from, address(0), fee);
            return;
        }
        super._update(from, to, value);
    }
}

/// @dev TEST ONLY. Attempts to reenter `deposit` during `transferFrom`.
contract ReentrantToken is ERC20 {
    AtlasVault public vault;
    bool public attack;

    constructor() ERC20("Reentrant Token", "RENT") { }

    function setVault(
        AtlasVault vault_
    ) external {
        vault = vault_;
    }

    function setAttack(
        bool v
    ) external {
        attack = v;
    }

    function mint(
        address to,
        uint256 amount
    ) external {
        _mint(to, amount);
    }

    function transferFrom(
        address from,
        address to,
        uint256 value
    ) public override returns (bool) {
        if (attack && address(vault) != address(0)) {
            attack = false;
            vault.deposit(1, address(this));
        }
        return super.transferFrom(from, to, value);
    }
}
