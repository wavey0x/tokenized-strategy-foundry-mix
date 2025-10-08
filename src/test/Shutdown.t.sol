pragma solidity ^0.8.18;

import "forge-std/console2.sol";
import {YieldBasisSetup} from "./utils/YieldBasisSetup.sol";
import {ERC20, IStrategyInterface} from "./utils/Setup.sol";
import {YieldBasisLTStrategy} from "../YieldBasisLTStrategy.sol";
import {IStrategy} from "@tokenized-strategy/interfaces/IStrategy.sol";

contract ShutdownTest is YieldBasisSetup {
    function setUp() public virtual override {
        super.setUp();
    }

    function deployStrategy() internal override returns (address) {
        // Deploy via factory (tests production deployment path)
        address deployed = factory.deployLTStrategy(
            address(asset),
            ltToken,
            cryptopool,
            "Test Strategy"
        );

        vm.prank(address(factory));
        IStrategy(deployed).setPendingManagement(management);
        vm.prank(management);
        IStrategy(deployed).acceptManagement();

        // Setup keeper
        vm.prank(management);
        IStrategy(deployed).setKeeper(keeper);

        return deployed;
    }

    function test_shutdownCanWithdraw(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        // Earn Interest
        skip(1 days);

        // Shutdown the strategy
        vm.prank(emergencyAdmin);
        strategy.shutdownStrategy();

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        // Make sure we can still withdraw the full amount
        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertGe(
            asset.balanceOf(user),
            balanceBefore + _amount,
            "!final balance"
        );
    }

    function test_emergencyWithdraw_maxUint(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        // Earn Interest
        skip(1 days);

        // Shutdown the strategy
        vm.prank(emergencyAdmin);
        strategy.shutdownStrategy();

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        // should be able to pass uint 256 max and not revert.
        vm.prank(emergencyAdmin);
        strategy.emergencyWithdraw(type(uint256).max);

        // Make sure we can still withdraw the full amount
        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertGe(
            asset.balanceOf(user),
            balanceBefore + _amount,
            "!final balance"
        );
    }

    // TODO: Add tests for any emergency function added.
}
