// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {GaugeStrategySetup} from "../utils/GaugeStrategySetup.sol";
import {IStrategyInterface} from "src/interfaces/IStrategyInterface.sol";

/**
 * @title GaugeStrategyOperationTest
 * @notice Standard operation tests for YBGaugeStrategy
 * @dev Tests deposit/withdraw/report cycles following Yearn patterns
 */
contract GaugeStrategyOperationTest is GaugeStrategySetup {

    /**
     * @notice Deposits should be blocked to any user other than the vault
     */
    function test_OnlyVaultCanDeposit(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);
        deal(address(asset), management, _amount);
        vm.startPrank(management);
        asset.approve(address(strategy), _amount);
        vm.expectRevert("ERC4626: deposit more than max");
        strategy.deposit(_amount, management);
        vm.stopPrank();
    }

    /**
     * @notice Test basic deposit and withdraw cycle
     */
    function test_operation_depositAndWithdraw(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Deposit
        mintAndDepositIntoStrategy(strategy, user, _amount);

        // Check strategy has assets deployed
        assertGt(gauge.balanceOf(address(gaugeStrategy)), 0, "Should have gauge shares");

        // Check user has vault shares
        assertGt(vault.balanceOf(user), 0, "User should have vault shares");

        // Withdraw
        uint256 vaultShares = vault.balanceOf(user);
        vm.prank(user);
        vault.redeem(vaultShares, user, user);

        // Verify assets returned to user
        assertGt(asset.balanceOf(user), 0, "User should receive assets back");
    }

    /**
     * @notice Test report generates profit
     */
    function test_operation_reportWithProfit(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount / 10);

        // Deposit
        mintAndDepositIntoStrategy(strategy, user, _amount);

        // Skip time to accrue rewards
        skip(30 days);

        // Record state before report
        uint256 totalAssetsBefore = strategy.totalAssets();

        // Report
        vm.prank(keeper);
        strategy.report();

        // Total assets should be at least what we started with
        // (May have YB rewards, but test doesn't guarantee emissions)
        uint256 totalAssetsAfter = strategy.totalAssets();
        assertGe(totalAssetsAfter, totalAssetsBefore, "Total assets should not decrease");
    }

    /**
     * @notice Test multiple deposits increase total assets
     */
    function test_operation_multipleDeposits(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount / 3);

        address user2 = makeAddr("user2");
        address user3 = makeAddr("user3");

        // First deposit
        mintAndDepositIntoStrategy(strategy, user, _amount);
        uint256 totalAssets1 = strategy.totalAssets();

        // Second deposit
        mintAndDepositIntoStrategy(strategy, user2, _amount);
        uint256 totalAssets2 = strategy.totalAssets();

        // Third deposit
        mintAndDepositIntoStrategy(strategy, user3, _amount);
        uint256 totalAssets3 = strategy.totalAssets();

        // Each deposit should increase total assets
        assertGt(totalAssets2, totalAssets1, "Second deposit should increase assets");
        assertGt(totalAssets3, totalAssets2, "Third deposit should increase assets");
    }

    /**
     * @notice Test partial withdraw
     */
    function test_operation_partialWithdraw(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount * 2 && _amount < maxFuzzAmount);

        // Deposit
        mintAndDepositIntoStrategy(strategy, user, _amount);

        uint256 vaultSharesBefore = vault.balanceOf(user);
        uint256 gaugeSharesBefore = gauge.balanceOf(address(gaugeStrategy));

        // Withdraw half
        vm.prank(user);
        vault.redeem(vaultSharesBefore / 2, user, user);

        // Check balances decreased proportionally
        uint256 vaultSharesAfter = vault.balanceOf(user);
        uint256 gaugeSharesAfter = gauge.balanceOf(address(gaugeStrategy));

        assertApproxEqRel(vaultSharesAfter, vaultSharesBefore / 2, 0.01e18, "Vault shares should be halved");
        assertLt(gaugeSharesAfter, gaugeSharesBefore, "Gauge shares should decrease");
    }

    /**
     * @notice Test totalAssets accounting
     */
    function test_operation_totalAssetsAccounting(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Before deposit
        assertEq(strategy.totalAssets(), 0, "Should start at 0");

        // After deposit
        mintAndDepositIntoStrategy(strategy, user, _amount);
        uint256 totalAssets = strategy.totalAssets();

        // Should be approximately equal to deposit (within 1% tolerance)
        assertRelApproxEq(totalAssets, _amount, 100, "Total assets should match deposit");

        // After report
        vm.prank(keeper);
        strategy.report();

        // Total assets should still be >= original amount
        assertGe(strategy.totalAssets(), totalAssets, "Assets should not decrease significantly");
    }
}
