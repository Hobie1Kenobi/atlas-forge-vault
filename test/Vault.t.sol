// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { Fixture } from "./helpers/Fixture.sol";
import { AtlasVault } from "../src/AtlasVault.sol";
import { MockYieldStrategy } from "../src/demo/MockYieldStrategy.sol";
import { MockERC20 } from "../src/demo/MockERC20.sol";
import { FeeOnTransferToken } from "./mocks/MaliciousTokens.sol";
import { ShortPayingStrategy } from "./mocks/ShortPayingStrategy.sol";

contract VaultTest is Fixture {
    function test_depositMintWithdrawRedeem() public {
        uint256 shares = _deposit(alice, 1000e18);
        assertGt(shares, 0);
        assertEq(vault.idleAssets(), 1000e18);
        assertEq(vault.totalAssets(), 1000e18);
        assertEq(asset.balanceOf(address(vault)), 1000e18);

        vm.prank(harvester);
        vault.allocate(400e18);
        assertEq(vault.idleAssets(), 600e18);
        assertEq(strategy.totalAssets(), 400e18);
        assertEq(vault.totalAssets(), 1000e18);

        uint256 preview = vault.previewWithdraw(200e18);
        vm.prank(alice);
        uint256 burned = vault.withdraw(200e18, alice, alice);
        assertEq(burned, preview);
        assertEq(asset.balanceOf(alice), 200e18);

        uint256 remainingShares = vault.balanceOf(alice);
        vm.prank(alice);
        uint256 redeemed = vault.redeem(remainingShares, alice, alice);
        assertGt(redeemed, 0);
        assertEq(vault.totalSupply(), 0);
        // Virtual shares capture a dust of value; user cannot extract more than they put in.
        assertLe(asset.balanceOf(alice), 1000e18);
        assertEq(vault.totalAssets(), 1000e18 - asset.balanceOf(alice));
    }

    function test_mintMatchesPreview() public {
        _mintApprove(alice, 2000e18);
        uint256 assetsNeeded = vault.previewMint(1e24);
        vm.prank(alice);
        uint256 paid = vault.mint(1e24, alice);
        assertEq(paid, assetsNeeded);
        assertEq(vault.balanceOf(alice), 1e24);
    }

    function test_depositRoundingFavorsVault() public {
        uint256 deposited = 1000e18;
        uint256 shares = _deposit(alice, deposited);
        uint256 claimable = vault.convertToAssets(shares);
        assertLe(claimable, deposited);
    }

    function test_depositCap() public {
        _timelockCall(address(vault), abi.encodeCall(AtlasVault.setDepositCap, (500e18)));
        _deposit(alice, 500e18);
        _mintApprove(bob, 1);
        vm.prank(bob);
        vm.expectRevert();
        vault.deposit(1, bob);
        assertEq(vault.maxDeposit(bob), 0);
    }

    function test_setDepositCapBelowTotalAssetsReverts() public {
        _deposit(alice, 100e18);
        vm.prank(proposer);
        timelock.schedule(
            address(vault), 0, abi.encodeCall(AtlasVault.setDepositCap, (50e18)), bytes32(0), bytes32(0), TIMELOCK_DELAY
        );
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.expectRevert(abi.encodeWithSelector(AtlasVault.CapTooLow.selector, 50e18, 100e18));
        timelock.execute(address(vault), 0, abi.encodeCall(AtlasVault.setDepositCap, (50e18)), bytes32(0), bytes32(0));
    }

    function test_pauseBlocksDepositMintHarvest_withdrawSucceeds() public {
        uint256 shares = _deposit(alice, 100e18);
        vm.prank(pauser);
        vault.pause();

        _mintApprove(bob, 10e18);
        vm.prank(bob);
        vm.expectRevert();
        vault.deposit(10e18, bob);

        vm.prank(bob);
        vm.expectRevert();
        vault.mint(1e18, bob);

        vm.prank(harvester);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vault.harvest(0);

        vm.prank(alice);
        uint256 out = vault.redeem(shares, alice, alice);
        assertGt(out, 0);
        assertEq(asset.balanceOf(alice), out);
    }

    function test_unpauseIsTimelockOnly() public {
        vm.prank(pauser);
        vault.pause();
        vm.prank(pauser);
        vm.expectRevert();
        vault.unpause();
        _timelockCall(address(vault), abi.encodeCall(AtlasVault.unpause, ()));
        assertFalse(vault.paused());
    }

    function test_auth_onlyTimelockSetStrategyAndCap() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.setStrategy(address(0));

        vm.prank(harvester);
        vm.expectRevert();
        vault.setDepositCap(1);

        vm.prank(pauser);
        vm.expectRevert();
        vault.emergencyWithdrawFromStrategy();
    }

    function test_auth_harvestRole() public {
        bytes32 role = vault.HARVESTER_ROLE();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, role));
        vault.harvest(0);
    }

    function test_harvestGainZeroSlippage() public {
        _deposit(alice, 1000e18);
        vm.prank(harvester);
        vault.allocate(1000e18);

        vm.prank(harvester);
        uint256 gainedZero = vault.harvest(0);
        assertEq(gainedZero, 0);

        strategy.demoAccrue(50e18);
        vm.prank(harvester);
        vm.expectRevert(abi.encodeWithSelector(AtlasVault.SlippageExceeded.selector, 50e18, 51e18));
        vault.harvest(51e18);

        vm.prank(harvester);
        uint256 gained = vault.harvest(50e18);
        assertEq(gained, 50e18);
        assertEq(vault.totalAssets(), 1050e18);
        assertEq(strategy.totalAssets(), 1050e18);
    }

    function test_migration_requiresEmptyStrategy() public {
        _deposit(alice, 100e18);
        vm.prank(harvester);
        vault.allocate(100e18);

        MockYieldStrategy next = new MockYieldStrategy(address(asset), address(vault));
        bytes memory setNext = abi.encodeCall(AtlasVault.setStrategy, (address(next)));
        vm.prank(proposer);
        timelock.schedule(address(vault), 0, setNext, bytes32(0), bytes32(0), TIMELOCK_DELAY);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.expectRevert(abi.encodeWithSelector(AtlasVault.StrategyNotEmpty.selector, 100e18));
        timelock.execute(address(vault), 0, setNext, bytes32(0), bytes32(0));

        _timelockCall(address(vault), abi.encodeCall(AtlasVault.emergencyWithdrawFromStrategy, ()));
        assertEq(strategy.totalAssets(), 0);
        assertEq(vault.idleAssets(), 100e18);
        // Same scheduled op is still Ready because the reverted execute did not consume it.
        timelock.execute(address(vault), 0, setNext, bytes32(0), bytes32(0));
        assertEq(address(vault.strategy()), address(next));
    }

    function test_lossReportPath() public {
        _deposit(alice, 100e18);
        vm.prank(harvester);
        vault.allocate(100e18);
        strategy.demoLose(40e18);

        _timelockCall(address(vault), abi.encodeCall(AtlasVault.emergencyWithdrawFromStrategy, ()));
        assertEq(vault.idleAssets(), 60e18);
        assertEq(strategy.totalAssets(), 0);

        // Remaining 0 after emergency pull — detach via setStrategy(0) is allowed.
        _timelockCall(address(vault), abi.encodeCall(AtlasVault.setStrategy, (address(0))));
        assertEq(address(vault.strategy()), address(0));
        assertEq(vault.totalAssets(), 60e18);
    }

    function test_lossReportWritesOffStuckAssets() public {
        _deposit(alice, 80e18);
        vm.prank(harvester);
        vault.allocate(80e18);

        // Simulate a strategy that still reports assets after a failed recovery by NOT
        // emergency-withdrawing, then writing them off.
        _timelockCall(address(vault), abi.encodeCall(AtlasVault.reportLossAndDetachStrategy, (80e18)));
        assertEq(address(vault.strategy()), address(0));
        assertEq(vault.totalAssets(), 0);
        assertEq(vault.idleAssets(), 0);
        // Tokens still sit in the old strategy; they are no longer attributed to shareholders.
        assertEq(asset.balanceOf(address(strategy)), 80e18);
    }

    function test_lossReportMismatchReverts() public {
        _deposit(alice, 10e18);
        vm.prank(harvester);
        vault.allocate(10e18);
        vm.prank(proposer);
        timelock.schedule(
            address(vault),
            0,
            abi.encodeCall(AtlasVault.reportLossAndDetachStrategy, (1)),
            bytes32(0),
            bytes32(0),
            TIMELOCK_DELAY
        );
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.expectRevert(abi.encodeWithSelector(AtlasVault.LossMismatch.selector, 10e18, 1));
        timelock.execute(
            address(vault), 0, abi.encodeCall(AtlasVault.reportLossAndDetachStrategy, (1)), bytes32(0), bytes32(0)
        );
    }

    function test_initializerDisabledOnImplementation() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        vaultImpl.initialize(IERC20(asset), "x", "y", address(timelock), pauser, harvester);
    }

    function test_cannotReinitializeProxy() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        vault.initialize(IERC20(asset), "x", "y", address(timelock), pauser, harvester);
    }

    function test_feeOnTransferUnderlyingRejected() public {
        FeeOnTransferToken feeTok = new FeeOnTransferToken();
        AtlasVault impl = new AtlasVault();
        bytes memory initData = abi.encodeCall(
            AtlasVault.initialize, (IERC20(feeTok), "FeeVault", "fv", address(timelock), pauser, harvester)
        );
        AtlasVault feeVault = AtlasVault(address(new ERC1967Proxy(address(impl), initData)));

        feeTok.mint(alice, 100e18);
        vm.prank(alice);
        feeTok.approve(address(feeVault), 100e18);
        vm.prank(alice);
        vm.expectRevert();
        feeVault.deposit(100e18, alice);
    }

    function test_rebasingUnsupported_donationDoesNotChangeTotalAssets() public {
        _deposit(alice, 100e18);
        uint256 ta = vault.totalAssets();
        uint256 idle = vault.idleAssets();
        // Positive "rebase" simulated as a naked mint to the vault.
        asset.mint(address(vault), 500e18);
        assertEq(vault.totalAssets(), ta);
        assertEq(vault.idleAssets(), idle);
        assertEq(asset.balanceOf(address(vault)), idle + 500e18);
    }

    function test_withdrawPullsFromStrategyWhenIdleLow() public {
        _deposit(alice, 100e18);
        vm.prank(harvester);
        vault.allocate(100e18);
        assertEq(vault.idleAssets(), 0);

        vm.prank(alice);
        vault.withdraw(40e18, alice, alice);
        assertEq(asset.balanceOf(alice), 40e18);
        assertEq(strategy.totalAssets(), 60e18);
    }

    function test_decimalsOffsetApplied() public view {
        assertEq(vault.decimals(), asset.decimals() + 6);
    }

    function test_strategyAssetMismatchReverts() public {
        MockERC20 other = new MockERC20();
        MockYieldStrategy bad = new MockYieldStrategy(address(other), address(vault));
        _timelockCall(address(vault), abi.encodeCall(AtlasVault.emergencyWithdrawFromStrategy, ()));
        vm.prank(proposer);
        timelock.schedule(
            address(vault),
            0,
            abi.encodeCall(AtlasVault.setStrategy, (address(bad))),
            bytes32(0),
            bytes32(0),
            TIMELOCK_DELAY
        );
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.expectRevert(
            abi.encodeWithSelector(AtlasVault.StrategyAssetMismatch.selector, address(asset), address(other))
        );
        timelock.execute(
            address(vault), 0, abi.encodeCall(AtlasVault.setStrategy, (address(bad))), bytes32(0), bytes32(0)
        );
    }

    function test_creditDonationsSocializesToExistingHolders() public {
        _deposit(alice, 100e18);
        asset.mint(address(vault), 10e18);
        assertEq(vault.totalAssets(), 100e18);
        _timelockCall(address(vault), abi.encodeCall(AtlasVault.creditDonations, ()));
        assertEq(vault.totalAssets(), 110e18);
        assertEq(vault.idleAssets(), 110e18);
        uint256 claimable = vault.convertToAssets(vault.balanceOf(alice));
        assertGe(claimable, 100e18);
        assertLe(claimable, 110e18);
    }

    function test_initializeZeroAddressReverts() public {
        AtlasVault impl = new AtlasVault();
        bytes memory initData = abi.encodeCall(
            AtlasVault.initialize, (IERC20(address(0)), "x", "y", address(timelock), pauser, harvester)
        );
        vm.expectRevert(AtlasVault.ZeroAddress.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_depositCapGetterAndMaxMint() public {
        assertEq(vault.depositCap(), 0);
        assertEq(vault.maxMint(alice), type(uint256).max);
        assertEq(vault.assetsUntilCap(), type(uint256).max);

        _timelockCall(address(vault), abi.encodeCall(AtlasVault.setDepositCap, (1000e18)));
        assertEq(vault.depositCap(), 1000e18);
        assertEq(vault.assetsUntilCap(), 1000e18);
        assertGt(vault.maxMint(alice), 0);
        assertLt(vault.maxMint(alice), type(uint256).max);

        vm.prank(pauser);
        vault.pause();
        assertEq(vault.maxMint(alice), 0);
        assertEq(vault.assetsUntilCap(), 0);
    }

    function test_harvestCreditsTokensSentToVault() public {
        _deposit(alice, 100e18);
        vm.prank(harvester);
        vault.allocate(100e18);
        strategy.demoSetPayoutToVault(true);
        strategy.demoAccrue(7e18);
        vm.prank(harvester);
        uint256 gained = vault.harvest(7e18);
        assertEq(gained, 7e18);
        assertEq(vault.idleAssets(), 7e18);
        assertEq(strategy.totalAssets(), 100e18);
        assertEq(vault.totalAssets(), 107e18);
    }

    function test_allocateAndHarvestRequireStrategy() public {
        _timelockCall(address(vault), abi.encodeCall(AtlasVault.emergencyWithdrawFromStrategy, ()));
        _timelockCall(address(vault), abi.encodeCall(AtlasVault.setStrategy, (address(0))));

        vm.prank(harvester);
        vm.expectRevert(AtlasVault.NoStrategy.selector);
        vault.allocate(1);

        vm.prank(harvester);
        vm.expectRevert(AtlasVault.NoStrategy.selector);
        vault.harvest(0);

        vm.prank(harvester);
        vm.expectRevert(AtlasVault.ZeroAmount.selector);
        vault.allocate(0);
    }

    function test_allocateInsufficientIdle() public {
        _deposit(alice, 10e18);
        vm.prank(harvester);
        vm.expectRevert(abi.encodeWithSelector(AtlasVault.InsufficientIdle.selector, 10e18, 11e18));
        vault.allocate(11e18);
    }

    function test_strategyVaultMismatchReverts() public {
        MockYieldStrategy otherVault = new MockYieldStrategy(address(asset), address(strategy));
        _timelockCall(address(vault), abi.encodeCall(AtlasVault.emergencyWithdrawFromStrategy, ()));
        vm.prank(proposer);
        timelock.schedule(
            address(vault),
            0,
            abi.encodeCall(AtlasVault.setStrategy, (address(otherVault))),
            bytes32(0),
            bytes32(0),
            TIMELOCK_DELAY
        );
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.expectRevert(
            abi.encodeWithSelector(AtlasVault.StrategyVaultMismatch.selector, address(vault), address(strategy))
        );
        timelock.execute(
            address(vault), 0, abi.encodeCall(AtlasVault.setStrategy, (address(otherVault))), bytes32(0), bytes32(0)
        );
    }

    function test_creditDonationsNoopWhenNoGift() public {
        _deposit(alice, 5e18);
        _timelockCall(address(vault), abi.encodeCall(AtlasVault.creditDonations, ()));
        assertEq(vault.idleAssets(), 5e18);
    }

    function test_withdrawInsufficientLiquidityWhenStrategyShort() public {
        ShortPayingStrategy short_ = new ShortPayingStrategy(address(asset), address(vault));
        _timelockCall(address(vault), abi.encodeCall(AtlasVault.emergencyWithdrawFromStrategy, ()));
        _timelockCall(address(vault), abi.encodeCall(AtlasVault.setStrategy, (address(short_))));

        _deposit(alice, 10e18);
        vm.prank(harvester);
        vault.allocate(10e18);
        assertEq(vault.idleAssets(), 0);
        assertEq(vault.totalAssets(), 10e18);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AtlasVault.InsufficientLiquidity.selector, 0, 1e18));
        vault.withdraw(1e18, alice, alice);
    }
}
