// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IStrategy
/// @notice Isolated yield strategy interface. The vault never assumes a specific
///         implementation beyond this ABI. Production strategies are out of v1
///         scope; `MockYieldStrategy` is demo/test only.
interface IStrategy {
    /// @notice Underlying asset this strategy accepts. Must match the vault asset.
    function asset() external view returns (address);

    /// @notice Vault authorized to deposit, withdraw, and harvest.
    function vault() external view returns (address);

    /// @notice Assets this strategy currently attributes to the vault.
    /// @dev Must not report unowned or donated third-party balances as vault assets
    ///      unless the strategy's accounting explicitly credits them.
    function totalAssets() external view returns (uint256);

    /// @notice Pull `assets` of underlying from the vault via `transferFrom`.
    /// @param assets Amount of underlying to pull. Caller must have approved this strategy.
    function deposit(
        uint256 assets
    ) external;

    /// @notice Return underlying to `to`. May return less than requested on loss.
    /// @param assets Amount requested.
    /// @param to Recipient of withdrawn underlying.
    /// @return withdrawn Amount actually sent.
    function withdraw(
        uint256 assets,
        address to
    ) external returns (uint256 withdrawn);

    /// @notice Realize pending yield into `totalAssets` (or by sending tokens to the vault).
    /// @return harvested Assets realized by this call.
    function harvest() external returns (uint256 harvested);
}
