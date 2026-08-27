// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Fixture } from "./helpers/Fixture.sol";

contract FuzzTest is Fixture {
    function testFuzz_depositWithdrawRoundTrip(
        uint256 amount
    ) public {
        amount = bound(amount, 1, 1_000_000e18);
        uint256 shares = _deposit(alice, amount);
        assertGt(shares, 0);

        uint256 claimable = vault.convertToAssets(shares);
        assertLe(claimable, amount, "rounding must favor the vault");

        vm.prank(alice);
        uint256 out = vault.redeem(shares, alice, alice);
        assertLe(out, amount);
        assertEq(vault.balanceOf(alice), 0);
        assertEq(out, claimable);
    }

    function testFuzz_depositThenPartialWithdraw(
        uint256 depositAmount,
        uint256 withdrawBps
    ) public {
        depositAmount = bound(depositAmount, 1e6, 1_000_000e18);
        withdrawBps = bound(withdrawBps, 1, 10_000);

        uint256 shares = _deposit(alice, depositAmount);
        uint256 assetsOut = (vault.convertToAssets(shares) * withdrawBps) / 10_000;
        if (assetsOut == 0) return;

        uint256 maxW = vault.maxWithdraw(alice);
        if (assetsOut > maxW) assetsOut = maxW;
        if (assetsOut == 0) return;

        vm.prank(alice);
        vault.withdraw(assetsOut, alice, alice);
        assertEq(asset.balanceOf(alice), assetsOut);
        assertLe(vault.convertToAssets(vault.balanceOf(alice)) + assetsOut, depositAmount);
    }

    function testFuzz_allocateAndRedeem(
        uint256 depositAmount,
        uint256 allocBps
    ) public {
        depositAmount = bound(depositAmount, 1e18, 100_000e18);
        allocBps = bound(allocBps, 0, 10_000);

        uint256 shares = _deposit(alice, depositAmount);
        uint256 alloc = (depositAmount * allocBps) / 10_000;
        if (alloc > 0) {
            vm.prank(harvester);
            vault.allocate(alloc);
        }
        assertEq(vault.totalAssets(), depositAmount);
        assertEq(vault.idleAssets() + strategy.totalAssets(), depositAmount);

        vm.prank(alice);
        uint256 out = vault.redeem(shares, alice, alice);
        assertLe(out, depositAmount);
        assertGt(out, 0);
    }

    function testFuzz_twoDepositorsSolvency(
        uint256 a,
        uint256 b
    ) public {
        a = bound(a, 1e6, 50_000e18);
        b = bound(b, 1e6, 50_000e18);
        uint256 sA = _deposit(alice, a);
        uint256 sB = _deposit(bob, b);

        uint256 claimA = vault.convertToAssets(sA);
        uint256 claimB = vault.convertToAssets(sB);
        assertLe(claimA + claimB, vault.totalAssets());

        vm.prank(alice);
        uint256 outA = vault.redeem(sA, alice, alice);
        vm.prank(bob);
        uint256 outB = vault.redeem(sB, bob, bob);
        assertLe(outA + outB, a + b);
    }
}
