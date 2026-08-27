// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { ERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import { ERC4626Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import { AccessControlUpgradeable } from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import { IStrategy } from "./interfaces/IStrategy.sol";

/// @title AtlasVault
/// @author Hobie Cunningham
/// @notice Production-shaped ERC-4626 strategy vault: UUPS, AccessControl, 48h timelock admin,
///         internal idle accounting, and an isolated `IStrategy` boundary.
/// @dev This is portfolio-grade reference architecture, not a tutorial clone and not a live
///      audited product. See `docs/threat-model.md` and README limitations.
///
///      Accounting: `totalAssets = idleAssets + strategy.totalAssets()`. Donations to the
///      vault address do not inflate share price until `creditDonations` (timelock-only).
///
///      Inflation defense: OpenZeppelin v5 `_decimalsOffset()` of 6 virtual-share decades
///      plus internal idle accounting. See `docs/adr-001-erc4626-offset.md`.
///
///      Pause: deposits, mints, and harvest revert. Withdraw and redeem remain available so
///      users can exit during a queued malicious upgrade.
///
///      Unsupported: fee-on-transfer and rebasing underlying (deposits revert or ignore rebase).
contract AtlasVault is
    Initializable,
    ERC20Upgradeable,
    ERC4626Upgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;
    using Math for uint256;

    /// @notice Fast-path pause of deposits, mints, and harvest.
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /// @notice Permission to harvest yield and allocate idle capital into the strategy.
    bytes32 public constant HARVESTER_ROLE = keccak256("HARVESTER_ROLE");

    /// @notice Virtual-share decimal offset. Share token decimals = asset decimals + this.
    uint8 private constant DECIMALS_OFFSET = 6;

    /// @custom:storage-location erc7201:atlasforge.storage.Vault
    struct AtlasVaultStorage {
        IStrategy strategy;
        uint256 idleAssets;
        uint256 depositCap;
    }

    // keccak256(abi.encode(uint256(keccak256("atlasforge.storage.Vault")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ATLAS_VAULT_STORAGE_LOCATION =
        0xd3e0fd0ae8eb6fad18bddb6cbc75139c2a9bd50750cb03cf636c07f1dc427900;

    error ZeroAddress();
    error ZeroAmount();
    error NoStrategy();
    error StrategyNotEmpty(uint256 remaining);
    error StrategyAssetMismatch(address expected, address actual);
    error StrategyVaultMismatch(address expected, address actual);
    error SlippageExceeded(uint256 gained, uint256 minAssetsOut);
    error FeeOnTransferUnsupported(uint256 expected, uint256 received);
    error InsufficientIdle(uint256 idle, uint256 requested);
    error InsufficientLiquidity(uint256 available, uint256 requested);
    error LossMismatch(uint256 actualRemaining, uint256 expectedRemaining);
    error CapTooLow(uint256 cap, uint256 totalAssets_);

    event StrategyUpdated(address indexed previous, address indexed current);
    event DepositCapUpdated(uint256 previous, uint256 current);
    event Harvested(address indexed caller, uint256 gained, uint256 reported);
    event Allocated(uint256 assets);
    event EmergencyWithdrawn(address indexed strategy, uint256 withdrawn);
    event StrategyLossReported(address indexed strategy, uint256 writtenOff);
    event DonationsCredited(uint256 assets);

    /// @notice Disable initializers on the implementation so it cannot be taken over.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the proxy. `timelock_` receives `DEFAULT_ADMIN_ROLE` and is the only
    ///         address that can upgrade, set the strategy, set the cap, emergency-withdraw, or
    ///         report a strategy loss.
    /// @param asset_ Underlying ERC-20. Must not be fee-on-transfer or rebasing.
    /// @param name_ Share token name.
    /// @param symbol_ Share token symbol.
    /// @param timelock_ OpenZeppelin `TimelockController` (48h delay in the intended deploy).
    /// @param pauser_ Recipient of `PAUSER_ROLE`.
    /// @param harvester_ Recipient of `HARVESTER_ROLE`.
    function initialize(
        IERC20 asset_,
        string memory name_,
        string memory symbol_,
        address timelock_,
        address pauser_,
        address harvester_
    ) external initializer {
        if (
            address(asset_) == address(0) || timelock_ == address(0) || pauser_ == address(0)
                || harvester_ == address(0)
        ) {
            revert ZeroAddress();
        }

        __ERC20_init(name_, symbol_);
        __ERC4626_init(asset_);
        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, timelock_);
        _grantRole(PAUSER_ROLE, pauser_);
        _grantRole(HARVESTER_ROLE, harvester_);

        // 0 = uncapped.
        _vaultStorage().depositCap = 0;
    }

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    /// @notice Currently attached strategy, or address(0) if idle-only.
    function strategy() public view returns (IStrategy) {
        return _vaultStorage().strategy;
    }

    /// @notice Underlying credited to the vault and not deployed to the strategy.
    /// @dev Independent of `asset.balanceOf(vault)`. Direct donations do not increase this.
    function idleAssets() public view returns (uint256) {
        return _vaultStorage().idleAssets;
    }

    /// @notice Maximum `totalAssets` after which deposits revert. Zero means no cap.
    function depositCap() public view returns (uint256) {
        return _vaultStorage().depositCap;
    }

    /// @notice ERC-7201 slot for vault-owned storage. Used by upgrade tests.
    function vaultStorageLocation() external pure returns (bytes32) {
        return ATLAS_VAULT_STORAGE_LOCATION;
    }

    /// @inheritdoc ERC4626Upgradeable
    /// @dev Idle book + strategy book. Does not read `balanceOf(vault)` so donations cannot mint
    ///      extra shares.
    function totalAssets() public view override returns (uint256) {
        AtlasVaultStorage storage $ = _vaultStorage();
        uint256 deployed = address($.strategy) == address(0) ? 0 : $.strategy.totalAssets();
        return $.idleAssets + deployed;
    }

    /// @inheritdoc ERC4626Upgradeable
    function maxDeposit(
        address
    ) public view override returns (uint256) {
        if (paused()) return 0;
        return _assetsUntilCap();
    }

    /// @inheritdoc ERC4626Upgradeable
    function maxMint(
        address receiver
    ) public view override returns (uint256) {
        uint256 maxAssets = maxDeposit(receiver);
        if (maxAssets == 0) return 0;
        if (maxAssets == type(uint256).max) return type(uint256).max;
        return _convertToShares(maxAssets, Math.Rounding.Floor);
    }

    /// @notice Remaining capacity before the deposit cap. `type(uint256).max` if uncapped.
    function assetsUntilCap() external view returns (uint256) {
        if (paused()) return 0;
        return _assetsUntilCap();
    }

    // -------------------------------------------------------------------------
    // ERC-4626 entry points (reentrancy + pause policy)
    // -------------------------------------------------------------------------

    /// @inheritdoc ERC4626Upgradeable
    /// @dev Paused deposits revert via `maxDeposit == 0`.
    function deposit(
        uint256 assets,
        address receiver
    ) public override nonReentrant returns (uint256) {
        return super.deposit(assets, receiver);
    }

    /// @inheritdoc ERC4626Upgradeable
    function mint(
        uint256 shares,
        address receiver
    ) public override nonReentrant returns (uint256) {
        return super.mint(shares, receiver);
    }

    /// @inheritdoc ERC4626Upgradeable
    /// @dev Intentionally not paused. Users must be able to exit while an upgrade is queued.
    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) public override nonReentrant returns (uint256) {
        return super.withdraw(assets, receiver, owner);
    }

    /// @inheritdoc ERC4626Upgradeable
    /// @dev Intentionally not paused.
    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) public override nonReentrant returns (uint256) {
        return super.redeem(shares, receiver, owner);
    }

    // -------------------------------------------------------------------------
    // Strategy operations
    // -------------------------------------------------------------------------

    /// @notice Realize strategy yield. Reverts if realized gain is below `minAssetsOut`.
    /// @param minAssetsOut Minimum increase in `totalAssets` required (0 allows a no-op harvest).
    /// @return gained Increase in `totalAssets` attributed to this call.
    function harvest(
        uint256 minAssetsOut
    ) external onlyRole(HARVESTER_ROLE) whenNotPaused nonReentrant returns (uint256 gained) {
        AtlasVaultStorage storage $ = _vaultStorage();
        IStrategy s = $.strategy;
        if (address(s) == address(0)) revert NoStrategy();

        uint256 beforeTotal = totalAssets();
        uint256 beforeBal = IERC20(asset()).balanceOf(address(this));

        uint256 reported = s.harvest();

        uint256 afterBal = IERC20(asset()).balanceOf(address(this));
        if (afterBal > beforeBal) {
            $.idleAssets += afterBal - beforeBal;
        }

        uint256 afterTotal = totalAssets();
        gained = afterTotal > beforeTotal ? afterTotal - beforeTotal : 0;
        if (gained < minAssetsOut) revert SlippageExceeded(gained, minAssetsOut);

        emit Harvested(_msgSender(), gained, reported);
    }

    /// @notice Deploy idle underlying into the attached strategy.
    /// @param assets Amount of idle assets to deploy.
    function allocate(
        uint256 assets
    ) external onlyRole(HARVESTER_ROLE) nonReentrant {
        if (assets == 0) revert ZeroAmount();
        AtlasVaultStorage storage $ = _vaultStorage();
        IStrategy s = $.strategy;
        if (address(s) == address(0)) revert NoStrategy();
        if (assets > $.idleAssets) revert InsufficientIdle($.idleAssets, assets);

        $.idleAssets -= assets;
        IERC20 token = IERC20(asset());
        token.forceApprove(address(s), assets);
        s.deposit(assets);
        token.forceApprove(address(s), 0);

        emit Allocated(assets);
    }

    // -------------------------------------------------------------------------
    // Admin (timelock / DEFAULT_ADMIN_ROLE)
    // -------------------------------------------------------------------------

    /// @notice Attach a new strategy. The previous strategy must report zero remaining assets.
    /// @dev Use `emergencyWithdrawFromStrategy` then `reportLossAndDetachStrategy` if capital is
    ///      stuck or lost. `newStrategy` may be address(0) to run idle-only.
    /// @param newStrategy Next strategy, or address(0).
    function setStrategy(
        address newStrategy
    ) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        AtlasVaultStorage storage $ = _vaultStorage();
        IStrategy current = $.strategy;
        if (address(current) != address(0)) {
            uint256 remaining = current.totalAssets();
            if (remaining != 0) revert StrategyNotEmpty(remaining);
        }
        if (newStrategy != address(0)) {
            address stratAsset = IStrategy(newStrategy).asset();
            if (stratAsset != asset()) revert StrategyAssetMismatch(asset(), stratAsset);
            address stratVault = IStrategy(newStrategy).vault();
            if (stratVault != address(this)) revert StrategyVaultMismatch(address(this), stratVault);
        }
        $.strategy = IStrategy(newStrategy);
        emit StrategyUpdated(address(current), newStrategy);
    }

    /// @notice Pull all recoverable assets from the strategy into idle. Does not detach it.
    function emergencyWithdrawFromStrategy() external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        AtlasVaultStorage storage $ = _vaultStorage();
        IStrategy s = $.strategy;
        if (address(s) == address(0)) revert NoStrategy();

        uint256 reported = s.totalAssets();
        uint256 withdrawn = 0;
        if (reported != 0) {
            withdrawn = s.withdraw(reported, address(this));
            $.idleAssets += withdrawn;
        }
        emit EmergencyWithdrawn(address(s), withdrawn);
    }

    /// @notice Write off remaining strategy assets and detach. Socializes the loss.
    /// @param expectedRemaining Must equal `strategy.totalAssets()` to prevent fat-finger writes.
    function reportLossAndDetachStrategy(
        uint256 expectedRemaining
    ) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        AtlasVaultStorage storage $ = _vaultStorage();
        IStrategy s = $.strategy;
        if (address(s) == address(0)) revert NoStrategy();
        uint256 remaining = s.totalAssets();
        if (remaining != expectedRemaining) revert LossMismatch(remaining, expectedRemaining);

        emit StrategyLossReported(address(s), remaining);
        $.strategy = IStrategy(address(0));
        emit StrategyUpdated(address(s), address(0));
    }

    /// @notice Credit unaccounted underlying sitting on the vault (donations) into idle.
    /// @dev Timelocked. Socializes donations as yield to existing shareholders. This is the
    ///      only path that lets a raw `transfer` affect share price.
    function creditDonations() external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        AtlasVaultStorage storage $ = _vaultStorage();
        uint256 bal = IERC20(asset()).balanceOf(address(this));
        uint256 idle = $.idleAssets;
        if (bal <= idle) return;
        uint256 gift = bal - idle;
        $.idleAssets = bal;
        emit DonationsCredited(gift);
    }

    /// @notice Set the deposit cap. Zero means uncapped.
    /// @param newCap New cap in underlying units.
    function setDepositCap(
        uint256 newCap
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 ta = totalAssets();
        if (newCap != 0 && newCap < ta) revert CapTooLow(newCap, ta);
        AtlasVaultStorage storage $ = _vaultStorage();
        uint256 previous = $.depositCap;
        $.depositCap = newCap;
        emit DepositCapUpdated(previous, newCap);
    }

    /// @notice Pause deposits, mints, and harvest. Withdrawals remain live.
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @notice Unpause. Timelock-only so a compromised pauser cannot toggle at will.
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    // -------------------------------------------------------------------------
    // Internals
    // -------------------------------------------------------------------------

    /// @inheritdoc ERC4626Upgradeable
    function _decimalsOffset() internal pure override returns (uint8) {
        return DECIMALS_OFFSET;
    }

    /// @inheritdoc ERC4626Upgradeable
    function _deposit(
        address caller,
        address receiver,
        uint256 assets,
        uint256 shares
    ) internal override {
        uint256 beforeBal = IERC20(asset()).balanceOf(address(this));
        super._deposit(caller, receiver, assets, shares);
        uint256 received = IERC20(asset()).balanceOf(address(this)) - beforeBal;
        if (received != assets) revert FeeOnTransferUnsupported(assets, received);
        _vaultStorage().idleAssets += assets;
    }

    /// @inheritdoc ERC4626Upgradeable
    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    ) internal override {
        _ensureLiquidity(assets);
        _vaultStorage().idleAssets -= assets;
        super._withdraw(caller, receiver, owner, assets, shares);
    }

    /// @dev Pull from the strategy if idle is insufficient.
    function _ensureLiquidity(
        uint256 assets
    ) internal {
        AtlasVaultStorage storage $ = _vaultStorage();
        if ($.idleAssets >= assets) return;
        IStrategy s = $.strategy;
        if (address(s) == address(0)) revert InsufficientLiquidity($.idleAssets, assets);

        uint256 needed = assets - $.idleAssets;
        uint256 withdrawn = s.withdraw(needed, address(this));
        $.idleAssets += withdrawn;
        if ($.idleAssets < assets) revert InsufficientLiquidity($.idleAssets, assets);
    }

    function _assetsUntilCap() internal view returns (uint256) {
        uint256 cap = _vaultStorage().depositCap;
        if (cap == 0) return type(uint256).max;
        uint256 ta = totalAssets();
        if (ta >= cap) return 0;
        return cap - ta;
    }

    function _vaultStorage() private pure returns (AtlasVaultStorage storage $) {
        bytes32 location = ATLAS_VAULT_STORAGE_LOCATION;
        assembly {
            $.slot := location
        }
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(
        address
    ) internal override onlyRole(DEFAULT_ADMIN_ROLE) { }

    /// @inheritdoc ERC20Upgradeable
    function decimals() public view override(ERC20Upgradeable, ERC4626Upgradeable) returns (uint8) {
        return super.decimals();
    }
}
