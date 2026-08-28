// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";

import { Fixture } from "./helpers/Fixture.sol";
import { AtlasVault } from "../src/AtlasVault.sol";
import {
    NoPullStrategy,
    OverCreditingWithdrawStrategy,
    LyingNavStrategy,
    PreFundedStrategy
} from "./mocks/AccountingStrategies.sol";
import { ShortPayingStrategy } from "./mocks/ShortPayingStrategy.sol";

/// @dev Locks A5 review behavior: accepted design plus regression tests for the two Low fixes.
///      These are defensive behavior locks, not attack runbooks.
contract FindingsTest is Fixture {
    // -------------------------------------------------------------------------
    // A5-001 — allocate is intentionally callable while paused
    // -------------------------------------------------------------------------

    function test_A5_001_allocateSucceedsWhilePaused() public {
        _deposit(alice, 100e18);
        vm.prank(pauser);
        vault.pause();

        vm.prank(harvester);
        vault.allocate(40e18);

        assertTrue(vault.paused());
        assertEq(vault.idleAssets(), 60e18);
        assertEq(strategy.totalAssets(), 40e18);
        assertEq(vault.totalAssets(), 100e18);
    }

    // -------------------------------------------------------------------------
    // A5-003 — IStrategy.totalAssets is a trusted valuation oracle
    // -------------------------------------------------------------------------

    function test_A5_003_lyingStrategyNavMovesSharePrice() public {
        LyingNavStrategy lying = new LyingNavStrategy(address(asset), address(vault));
        _timelockCall(address(vault), abi.encodeCall(AtlasVault.emergencyWithdrawFromStrategy, ()));
        _timelockCall(address(vault), abi.encodeCall(AtlasVault.setStrategy, (address(lying))));

        _deposit(alice, 100e18);
        uint256 priceBefore = vault.convertToAssets(1e18);
        uint256 idle = vault.idleAssets();

        lying.setReported(1000e18);
        // Idle book is unchanged; NAV still follows the strategy's report.
        assertEq(vault.idleAssets(), idle);
        assertEq(vault.totalAssets(), idle + 1000e18);
        assertGt(vault.convertToAssets(1e18), priceBefore);
    }

    // -------------------------------------------------------------------------
    // A5-004 — Timelock executor = address(0) means anyone may execute
    // -------------------------------------------------------------------------

    function test_A5_004_anyoneCanExecuteAfterDelay() public {
        assertTrue(timelock.hasRole(timelock.EXECUTOR_ROLE(), address(0)));

        bytes memory data = abi.encodeCall(AtlasVault.setDepositCap, (1000e18));
        vm.prank(proposer);
        timelock.schedule(address(vault), 0, data, bytes32(0), bytes32(0), TIMELOCK_DELAY);
        vm.warp(block.timestamp + TIMELOCK_DELAY);

        vm.prank(attacker);
        timelock.execute(address(vault), 0, data, bytes32(0), bytes32(0));
        assertEq(vault.depositCap(), 1000e18);
    }

    // -------------------------------------------------------------------------
    // A5-005 — idle credits observed withdraw delta, not the return value
    // -------------------------------------------------------------------------

    function test_A5_005_overCreditingWithdrawCannotInflateIdleOrSweepDonations() public {
        OverCreditingWithdrawStrategy liar = new OverCreditingWithdrawStrategy(address(asset), address(vault));
        _timelockCall(address(vault), abi.encodeCall(AtlasVault.emergencyWithdrawFromStrategy, ()));
        _timelockCall(address(vault), abi.encodeCall(AtlasVault.setStrategy, (address(liar))));

        _deposit(alice, 10e18);
        vm.prank(harvester);
        vault.allocate(10e18);
        assertEq(vault.idleAssets(), 0);

        asset.mint(address(vault), 5e18);
        uint256 donations = asset.balanceOf(address(vault)) - vault.idleAssets();
        assertEq(donations, 5e18);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AtlasVault.InsufficientLiquidity.selector, 0, 5e18));
        vault.withdraw(5e18, alice, alice);

        assertEq(vault.idleAssets(), 0);
        assertEq(asset.balanceOf(address(vault)), 5e18);
        assertEq(asset.balanceOf(alice), 0);
    }

    function test_A5_005_emergencyWithdrawCreditsObservedTokensNotReturnValue() public {
        OverCreditingWithdrawStrategy liar = new OverCreditingWithdrawStrategy(address(asset), address(vault));
        _timelockCall(address(vault), abi.encodeCall(AtlasVault.emergencyWithdrawFromStrategy, ()));
        _timelockCall(address(vault), abi.encodeCall(AtlasVault.setStrategy, (address(liar))));

        _deposit(alice, 8e18);
        vm.prank(harvester);
        vault.allocate(8e18);

        _timelockCall(address(vault), abi.encodeCall(AtlasVault.emergencyWithdrawFromStrategy, ()), bytes32(uint256(1)));
        assertEq(vault.idleAssets(), 0);
        assertEq(asset.balanceOf(address(liar)), 8e18);
    }

    // -------------------------------------------------------------------------
    // A5-006 — allocate reverts unless the strategy actually pulls tokens
    // -------------------------------------------------------------------------

    function test_A5_006_allocateRevertsIfStrategyDoesNotPull() public {
        NoPullStrategy nopull = new NoPullStrategy(address(asset), address(vault));
        _timelockCall(address(vault), abi.encodeCall(AtlasVault.emergencyWithdrawFromStrategy, ()));
        _timelockCall(address(vault), abi.encodeCall(AtlasVault.setStrategy, (address(nopull))));

        _deposit(alice, 10e18);
        vm.prank(harvester);
        vm.expectRevert(abi.encodeWithSelector(AtlasVault.AllocateTransferMismatch.selector, 10e18, 0));
        vault.allocate(10e18);

        assertEq(vault.idleAssets(), 10e18);
        assertEq(vault.totalAssets(), 10e18);
        assertEq(asset.balanceOf(address(vault)), 10e18);
    }

    // -------------------------------------------------------------------------
    // A5-007 — maxWithdraw follows OZ default and does not discount illiquid NAV
    // -------------------------------------------------------------------------

    function test_A5_007_maxWithdrawDoesNotDiscountIlliquidStrategy() public {
        ShortPayingStrategy short_ = new ShortPayingStrategy(address(asset), address(vault));
        _timelockCall(address(vault), abi.encodeCall(AtlasVault.emergencyWithdrawFromStrategy, ()));
        _timelockCall(address(vault), abi.encodeCall(AtlasVault.setStrategy, (address(short_))));

        uint256 shares = _deposit(alice, 10e18);
        vm.prank(harvester);
        vault.allocate(10e18);

        uint256 claimable = vault.convertToAssets(shares);
        assertEq(vault.maxWithdraw(alice), claimable);
        assertGt(vault.maxWithdraw(alice), vault.idleAssets());

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AtlasVault.InsufficientLiquidity.selector, 0, 1e18));
        vault.withdraw(1e18, alice, alice);
    }

    // -------------------------------------------------------------------------
    // A5-008 — unpause is timelock-only (pauser cannot toggle)
    // -------------------------------------------------------------------------

    function test_A5_008_pauserCannotUnpause() public {
        vm.prank(pauser);
        vault.pause();
        assertTrue(vault.paused());

        bytes32 admin = vault.DEFAULT_ADMIN_ROLE();
        vm.prank(pauser);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, pauser, admin));
        vault.unpause();

        _timelockCall(address(vault), abi.encodeCall(AtlasVault.unpause, ()));
        assertFalse(vault.paused());
    }

    // -------------------------------------------------------------------------
    // A5-009 — setStrategy does not require the new strategy to report zero NAV
    // -------------------------------------------------------------------------

    function test_A5_009_setStrategyAcceptsPreFundedStrategy() public {
        _timelockCall(address(vault), abi.encodeCall(AtlasVault.emergencyWithdrawFromStrategy, ()));
        _timelockCall(address(vault), abi.encodeCall(AtlasVault.setStrategy, (address(0))));

        _deposit(alice, 50e18);
        uint256 taBefore = vault.totalAssets();

        PreFundedStrategy next = new PreFundedStrategy(address(asset), address(vault));
        asset.mint(address(next), 25e18);
        assertEq(next.totalAssets(), 25e18);

        _timelockCall(address(vault), abi.encodeCall(AtlasVault.setStrategy, (address(next))));
        assertEq(address(vault.strategy()), address(next));
        assertEq(vault.totalAssets(), taBefore + 25e18);
    }

    // -------------------------------------------------------------------------
    // A5-010 — only the proposer holds CANCELLER_ROLE (no independent guardian)
    // -------------------------------------------------------------------------

    function test_A5_010_onlyProposerCanCancelQueuedOp() public {
        bytes memory data = abi.encodeCall(AtlasVault.setDepositCap, (1));
        vm.prank(proposer);
        timelock.schedule(address(vault), 0, data, bytes32(0), bytes32(0), TIMELOCK_DELAY);

        bytes32 id = timelock.hashOperation(address(vault), 0, data, bytes32(0), bytes32(0));
        bytes32 canceller = timelock.CANCELLER_ROLE();

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, canceller)
        );
        timelock.cancel(id);

        vm.prank(proposer);
        timelock.cancel(id);
        assertEq(timelock.getTimestamp(id), 0);
    }

    // -------------------------------------------------------------------------
    // A5-002 companion — handler-style paths that must revert stay revertible
    // -------------------------------------------------------------------------

    function test_A5_002_allocateZeroStillReverts() public {
        vm.prank(harvester);
        vm.expectRevert(AtlasVault.ZeroAmount.selector);
        vault.allocate(0);
    }
}
