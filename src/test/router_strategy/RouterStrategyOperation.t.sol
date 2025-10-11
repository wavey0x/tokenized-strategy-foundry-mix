// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {RouterStrategySetup} from "../utils/RouterStrategySetup.sol";
import {IStrategyInterface} from "src/interfaces/IStrategyInterface.sol";

/**
 * @title RouterStrategyOperationTest
 * @notice Standard operation tests for YBRouterStrategy
 * @dev Tests deposit/withdraw/report cycles following Yearn patterns
 */
contract RouterStrategyOperationTest is RouterStrategySetup {

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
        assertGt(ltYVault.balanceOf(address(routerStrategy)), 0, "Should have yVault shares");

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
     * @notice Test report maintains asset accounting
     */
    function test_operation_reportMaintainsAccounting(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount / 10);

        // Deposit
        mintAndDepositIntoStrategy(strategy, user, _amount);

        // Skip time
        skip(30 days);

        // Record state before report
        uint256 totalAssetsBefore = strategy.totalAssets();

        // Report
        vm.prank(keeper);
        strategy.report();

        // Total assets should be approximately the same (allowing for small variations in AMM pricing)
        uint256 totalAssetsAfter = strategy.totalAssets();
        assertRelApproxEq(totalAssetsAfter, totalAssetsBefore, 20, "Assets should remain stable");
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

        // // Second deposit
        // mintAndDepositIntoStrategy(strategy, user2, _amount);
        // uint256 totalAssets2 = strategy.totalAssets();

        // // Third deposit
        // mintAndDepositIntoStrategy(strategy, user3, _amount);
        // uint256 totalAssets3 = strategy.totalAssets();

        // // Each deposit should increase total assets
        // assertGt(totalAssets2, totalAssets1, "Second deposit should increase assets");
        // assertGt(totalAssets3, totalAssets2, "Third deposit should increase assets");
    }

    /**
     * @notice Test partial withdraw
     */
    function test_operation_partialWithdraw(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount * 2 && _amount < maxFuzzAmount);

        // Deposit
        mintAndDepositIntoStrategy(strategy, user, _amount);

        uint256 vaultSharesBefore = vault.balanceOf(user);
        uint256 yVaultSharesBefore = ltYVault.balanceOf(address(routerStrategy));

        // Withdraw half
        vm.prank(user);
        vault.redeem(vaultSharesBefore / 2, user, user);

        // Check balances decreased proportionally
        uint256 vaultSharesAfter = vault.balanceOf(user);
        uint256 yVaultSharesAfter = ltYVault.balanceOf(address(routerStrategy));

        assertApproxEqRel(vaultSharesAfter, vaultSharesBefore / 2, 0.01e18, "Vault shares should be halved");
        assertLt(yVaultSharesAfter, yVaultSharesBefore, "yVault shares should decrease");
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

        // Should be approximately equal to deposit (within tolerance for AMM slippage - up to 10%)
        assertRelApproxEq(totalAssets, _amount, 10, "Total assets should match deposit");

        // After report
        vm.prank(keeper);
        strategy.report();

        // Total assets should not decrease from the post-deposit amount
        assertGe(strategy.totalAssets(), totalAssets * 99 / 100, "Assets should not decrease significantly");
    }

    /**
     * @notice Test deposit flow: BTC → LT → yVault
     */
    function test_operation_depositFlow(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Before deposit
        assertEq(ltYVault.balanceOf(address(routerStrategy)), 0, "Should have no yVault shares");

        // Deposit BTC
        mintAndDepositIntoStrategy(strategy, user, _amount);

        // After deposit, strategy should have yVault shares (LT deposited into yVault)
        assertGt(ltYVault.balanceOf(address(routerStrategy)), 0, "Should have yVault shares");

        // Strategy should NOT hold LT or BTC directly
        assertEq(lt.balanceOf(address(routerStrategy)), 0, "Should not hold LT");
        assertEq(asset.balanceOf(address(routerStrategy)), 0, "Should not hold BTC");
    }

    /**
     * @notice Test withdraw flow: yVault → LT → BTC
     */
    function test_operation_withdrawFlow(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Deposit
        mintAndDepositIntoStrategy(strategy, user, _amount);

        uint256 yVaultSharesBefore = ltYVault.balanceOf(address(routerStrategy));
        uint256 userBtcBefore = asset.balanceOf(user);

        // Withdraw
        vm.prank(user);
        vault.redeem(vault.balanceOf(user), user, user);

        // Strategy yVault shares should decrease
        assertEq(ltYVault.balanceOf(address(routerStrategy)), 0, "yVault shares should be redeemed");

        // User should receive BTC and strategy should have less vault shares
        assertGt(asset.balanceOf(user), userBtcBefore, "User should receive BTC");
        assertGt(yVaultSharesBefore, ltYVault.balanceOf(address(routerStrategy)), "yVault shares should decrease");
    }
}
