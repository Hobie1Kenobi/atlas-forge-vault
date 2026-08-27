// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";

import { Fixture } from "./helpers/Fixture.sol";
import { AtlasVault } from "../src/AtlasVault.sol";
import { MockYieldStrategy } from "../src/demo/MockYieldStrategy.sol";
import { MockERC20 } from "../src/demo/MockERC20.sol";

/// @dev Stateful fuzzer over the accounting heart: deposit/withdraw/allocate/harvest/donate.
contract VaultHandler is Test {
    AtlasVault public vault;
    MockERC20 public asset;
    MockYieldStrategy public strategy;
    address public harvester;

    address[] public actors;

    uint256 public ghostDeposited;
    uint256 public ghostWithdrawn;
    uint256 public ghostDonated;
    uint256 public ghostYield;

    constructor(
        AtlasVault vault_,
        MockERC20 asset_,
        MockYieldStrategy strategy_,
        address harvester_,
        address[] memory actors_
    ) {
        vault = vault_;
        asset = asset_;
        strategy = strategy_;
        harvester = harvester_;
        actors = actors_;
        for (uint256 i; i < actors_.length; ++i) {
            vm.prank(actors_[i]);
            asset.approve(address(vault_), type(uint256).max);
        }
    }

    function actor(
        uint256 seed
    ) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function deposit(
        uint256 seed,
        uint256 amount
    ) external {
        address user = actor(seed);
        amount = bound(amount, 1, 10_000e18);
        asset.mint(user, amount);
        vm.prank(user);
        try vault.deposit(amount, user) {
            ghostDeposited += amount;
        } catch { }
    }

    function mintShares(
        uint256 seed,
        uint256 shares
    ) external {
        address user = actor(seed);
        shares = bound(shares, 1e6, 1e24);
        uint256 preview = vault.previewMint(shares);
        if (preview == 0 || preview > 10_000e18) return;
        asset.mint(user, preview);
        vm.prank(user);
        try vault.mint(shares, user) returns (uint256 paid) {
            ghostDeposited += paid;
        } catch { }
    }

    function withdraw(
        uint256 seed,
        uint256 amount
    ) external {
        address user = actor(seed);
        uint256 maxW = vault.maxWithdraw(user);
        if (maxW == 0) return;
        amount = bound(amount, 1, maxW);
        vm.prank(user);
        try vault.withdraw(amount, user, user) {
            ghostWithdrawn += amount;
        } catch { }
    }

    function redeem(
        uint256 seed,
        uint256 shares
    ) external {
        address user = actor(seed);
        uint256 bal = vault.balanceOf(user);
        if (bal == 0) return;
        shares = bound(shares, 1, bal);
        vm.prank(user);
        try vault.redeem(shares, user, user) returns (uint256 assets) {
            ghostWithdrawn += assets;
        } catch { }
    }

    function allocate(
        uint256 amount
    ) external {
        uint256 idle = vault.idleAssets();
        if (idle == 0) return;
        amount = bound(amount, 1, idle);
        vm.prank(harvester);
        try vault.allocate(amount) { } catch { }
    }

    function harvest(
        uint256 yieldAmount,
        uint256 minOut
    ) external {
        yieldAmount = bound(yieldAmount, 0, 100e18);
        if (yieldAmount > 0) strategy.demoAccrue(yieldAmount);
        minOut = bound(minOut, 0, yieldAmount);
        vm.prank(harvester);
        try vault.harvest(minOut) returns (uint256 gained) {
            ghostYield += gained;
        } catch {
            // Slippage revert: pending yield remains queued and is not in totalAssets.
        }
    }

    function donate(
        uint256 amount
    ) external {
        amount = bound(amount, 1, 1000e18);
        asset.mint(address(vault), amount);
        ghostDonated += amount;
    }
}

contract InvariantTest is Fixture {
    VaultHandler internal handler;

    function setUp() public override {
        super.setUp();
        address[] memory actors = new address[](3);
        actors[0] = alice;
        actors[1] = bob;
        actors[2] = attacker;
        handler = new VaultHandler(vault, asset, strategy, harvester, actors);

        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = VaultHandler.deposit.selector;
        selectors[1] = VaultHandler.mintShares.selector;
        selectors[2] = VaultHandler.withdraw.selector;
        selectors[3] = VaultHandler.redeem.selector;
        selectors[4] = VaultHandler.allocate.selector;
        selectors[5] = VaultHandler.harvest.selector;
        selectors[6] = VaultHandler.donate.selector;
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
        targetContract(address(handler));
        excludeContract(address(vault));
        excludeContract(address(strategy));
        excludeContract(address(asset));
        excludeContract(address(timelock));
        excludeContract(address(vaultImpl));
    }

    /// @notice Users' aggregate claim cannot exceed `totalAssets`.
    function invariant_solvency() public view {
        uint256 claimable = vault.convertToAssets(vault.totalSupply());
        assertLe(claimable, vault.totalAssets());
    }

    /// @notice Idle book is backed by tokens on the vault (donations may make balance strictly larger).
    function invariant_idleBackedByBalance() public view {
        assertGe(asset.balanceOf(address(vault)), vault.idleAssets());
    }

    /// @notice `totalAssets` is exactly idle + strategy, never raw `balanceOf`.
    function invariant_totalAssetsDefinition() public view {
        assertEq(vault.totalAssets(), vault.idleAssets() + strategy.totalAssets());
    }

    /// @notice Donations must not increase `totalAssets` (they are excluded from the book).
    function invariant_donationsDoNotMintValue() public view {
        assertLe(vault.totalAssets() + handler.ghostWithdrawn(), handler.ghostDeposited() + handler.ghostYield());
    }

    /// @notice Unaccounted tokens equal donations still sitting on the vault (not credited).
    function invariant_unaccountedEqualsDonationsOnVault() public view {
        uint256 unaccounted = asset.balanceOf(address(vault)) - vault.idleAssets();
        assertLe(unaccounted, handler.ghostDonated());
    }
}
