// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Fixture } from "./helpers/Fixture.sol";
import { AtlasVault } from "../src/AtlasVault.sol";

/// @dev Defensive inflation / donation tests. These prove the vault's accounting and the
///      OZ v5 decimals-offset together bound victim loss. They are not an attack runbook.
contract InflationTest is Fixture {
    /// @notice Direct `transfer` of underlying into the vault must not mint extra shares or
    ///         change `totalAssets` / share price.
    function test_donationDoesNotInflateSharePrice() public {
        uint256 attackerShares = _deposit(attacker, 1e18);
        uint256 priceBefore = vault.convertToAssets(1e18);

        asset.mint(attacker, 1000e18);
        vm.prank(attacker);
        asset.transfer(address(vault), 1000e18);

        assertEq(vault.totalAssets(), 1e18);
        assertEq(vault.idleAssets(), 1e18);
        assertEq(vault.convertToAssets(1e18), priceBefore);
        assertEq(vault.balanceOf(attacker), attackerShares);
        assertEq(asset.balanceOf(address(vault)), 1001e18);
    }

    /// @notice Classic empty-vault donation: attacker seeds 1 wei, donates a large amount, then
    ///         a victim deposits. Because donations are not in `totalAssets`, the victim's
    ///         redeemable assets stay within 1 wei of their deposit (ERC-4626 rounding).
    function test_attackerDonationCannotStealVictimDeposit() public {
        uint256 attackerSeed = 1;
        uint256 donation = 1000e18;
        uint256 victimDeposit = 1000e18;

        _deposit(attacker, attackerSeed);

        asset.mint(attacker, donation);
        vm.prank(attacker);
        asset.transfer(address(vault), donation);

        uint256 victimShares = _deposit(bob, victimDeposit);
        uint256 victimClaimable = vault.convertToAssets(victimShares);

        // Bound: rounding may shave 1 wei; donation must not steal victim principal.
        assertGe(victimClaimable, victimDeposit - 1);
        assertLe(victimClaimable, victimDeposit);

        vm.prank(bob);
        uint256 out = vault.redeem(victimShares, bob, bob);
        assertGe(out, victimDeposit - 1);
        assertLe(out, victimDeposit);

        // Attacker cannot redeem the donated tokens; they sit unaccounted.
        uint256 attackerOut = vault.convertToAssets(vault.balanceOf(attacker));
        assertLe(attackerOut, attackerSeed);
    }

    /// @notice Hypothesis check: even if the timelock credits the donation (the only path that
    ///         lets a raw transfer affect price), `_decimalsOffset == 6` bounds victim loss
    ///         far below the donated amount. Offset-0 would let a 1-wei seed steal the deposit.
    function test_creditedDonationVictimLossBoundedByOffset() public {
        uint256 attackerSeed = 1;
        uint256 donation = 1000e18;
        uint256 victimDeposit = 1000e18;

        _deposit(attacker, attackerSeed);
        asset.mint(attacker, donation);
        vm.prank(attacker);
        asset.transfer(address(vault), donation);

        _timelockCall(address(vault), abi.encodeCall(AtlasVault.creditDonations, ()));

        uint256 victimShares = _deposit(bob, victimDeposit);
        vm.prank(bob);
        uint256 out = vault.redeem(victimShares, bob, bob);

        // Documented dust bound for offset=6, 1-wei seed, 1e21-scale donation+deposit.
        // Empirically the loss is << 1e15; we lock 1e15 (0.001 of 1e18) as the CI bound.
        uint256 maxDust = 1e15;
        assertGe(out, victimDeposit - maxDust, "offset-6 dust bound exceeded");
        assertLe(out, victimDeposit);

        // Attacker does capture credited donation (they were the only pre-existing holder)
        // plus virtual-share leakage — that is the inflation surface the offset is bounding
        // for *subsequent* depositors, not a promise that the first depositor cannot earn yield.
        uint256 attackerClaimable = vault.convertToAssets(vault.balanceOf(attacker));
        assertGt(attackerClaimable, attackerSeed);
    }

    function test_firstDepositTinyAmountDoesNotBrickVault() public {
        _deposit(attacker, 1);
        uint256 shares = _deposit(bob, 1e18);
        assertGt(shares, 0);
        vm.prank(bob);
        uint256 out = vault.redeem(shares, bob, bob);
        assertGt(out, 0);
        assertGe(out, 1e18 - 1e6);
    }
}
