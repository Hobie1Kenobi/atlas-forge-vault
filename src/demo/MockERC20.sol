// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockERC20
/// @notice DEMO / TEST ONLY. Mintable vanilla ERC-20 used as the vault underlying in local
///         tests and optional local deploys. Not a flagship token and not a production asset.
contract MockERC20 is ERC20 {
    constructor() ERC20("Mock USD (DEMO)", "mUSD") { }

    /// @notice Permissionless mint. Acceptable only because this token is demo/test scoped.
    function mint(
        address to,
        uint256 amount
    ) external {
        _mint(to, amount);
    }

    /// @notice Permissionless burn. Used by the demo strategy to simulate losses.
    function burn(
        address from,
        uint256 amount
    ) external {
        _burn(from, amount);
    }
}
