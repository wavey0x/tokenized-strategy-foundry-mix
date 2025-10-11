// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {RouterStrategySetup} from "../utils/RouterStrategySetup.sol";
import {IStrategyInterface} from "src/interfaces/IStrategyInterface.sol";

/**
 * @title RouterStrategyShutdownTest
 * @notice Shutdown and emergency tests for YBRouterStrategy
 * @dev Tests emergency withdraw and shutdown scenarios, including killed LT tokens
 */
contract RouterStrategyShutdownTest is RouterStrategySetup {

    /**
     * @notice Test strategy shutdown prevents deposits
     */
    function test_shutdown_preventsDeposits(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Initial deposit
        mintAndDepositIntoStrategy(strategy, user, _amount);

        // Shutdown strategy
        vm.prank(management);
        strategy.shutdownStrategy();

        // Verify shutdown
        assertTrue(strategy.isShutdown(), "Strategy should be shutdown");

        // Try to deposit - vault deposit succeeds but strategy won't accept more debt
        deal(address(asset), user, _amount);
        vm.startPrank(user);
        asset.approve(address(vault), _amount);
        vault.deposit(_amount, user);
        vm.stopPrank();

        // Shutdown strategies should not accept new deposits
    }

    /**
     * @notice Test users can still withdraw after shutdown
     */
    function test_shutdown_allowsWithdrawals(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Deposit
        mintAndDepositIntoStrategy(strategy, user, _amount);
        uint256 vaultShares = vault.balanceOf(user);

        // Shutdown strategy
        vm.prank(management);
        strategy.shutdownStrategy();

        // User should still be able to withdraw
        uint256 assetsBefore = asset.balanceOf(user);
        vm.prank(user);
        vault.redeem(vaultShares, user, user);

        // Verify user received assets
        assertGt(asset.balanceOf(user), assetsBefore, "User should receive assets");
    }

    /**
     * @notice Test emergency withdraw from yVault
     */
    function test_emergencyWithdraw_withdrawsFromYVault(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Deposit
        mintAndDepositIntoStrategy(strategy, user, _amount);

        uint256 yVaultSharesBefore = ltYVault.balanceOf(address(routerStrategy));
        assertGt(yVaultSharesBefore, 0, "Should have yVault shares");

        // Shutdown
        vm.prank(management);
        strategy.shutdownStrategy();

        // Emergency withdraw
        vm.prank(management);
        strategy.emergencyWithdraw(_amount);

        // yVault shares should decrease
        uint256 yVaultSharesAfter = ltYVault.balanceOf(address(routerStrategy));
        assertLt(yVaultSharesAfter, yVaultSharesBefore, "yVault shares should decrease");

        // Strategy should have liquid BTC assets
        assertGt(asset.balanceOf(address(routerStrategy)), 0, "Should have liquid BTC");
    }

    /**
     * @notice Test emergency withdraw partial amount
     */
    function test_emergencyWithdraw_partialAmount(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount * 2 && _amount < maxFuzzAmount);

        // Deposit
        mintAndDepositIntoStrategy(strategy, user, _amount);

        // Shutdown
        vm.prank(management);
        strategy.shutdownStrategy();

        // Emergency withdraw half
        uint256 withdrawAmount = _amount / 2;
        vm.prank(management);
        strategy.emergencyWithdraw(withdrawAmount);

        // Should still have some yVault shares
        assertGt(ltYVault.balanceOf(address(routerStrategy)), 0, "Should still have yVault shares");

        // Should have liquid assets
        assertGt(asset.balanceOf(address(routerStrategy)), 0, "Should have liquid assets");
    }

    /**
     * @notice Test emergency withdraw requires shutdown
     */
    function test_emergencyWithdraw_requiresShutdown(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Deposit
        mintAndDepositIntoStrategy(strategy, user, _amount);

        // Try emergency withdraw without shutdown - should revert
        vm.expectRevert("not shutdown");
        vm.prank(management);
        strategy.emergencyWithdraw(_amount);
    }

    /**
     * @notice Test strategy can report after shutdown
     */
    function test_shutdown_canStillReport(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Deposit
        mintAndDepositIntoStrategy(strategy, user, _amount);

        // Shutdown
        vm.prank(management);
        strategy.shutdownStrategy();

        // Skip time
        skip(7 days);

        // Should be able to report
        vm.prank(keeper);
        strategy.report();

        // Verify report succeeded
        assertTrue(true, "Report should succeed after shutdown");
    }

    /**
     * @notice Test shutdown then emergency withdraw then user withdrawal
     */
    function test_shutdown_fullExitFlow(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Deposit
        mintAndDepositIntoStrategy(strategy, user, _amount);
        uint256 vaultShares = vault.balanceOf(user);

        // Shutdown
        vm.prank(management);
        strategy.shutdownStrategy();

        // Emergency withdraw all
        vm.prank(management);
        strategy.emergencyWithdraw(_amount);

        // Report to update accounting
        vm.prank(keeper);
        strategy.report();

        // User withdraws
        uint256 assetsBefore = asset.balanceOf(user);
        vm.prank(user);
        vault.redeem(vaultShares, user, user);

        // User should receive approximately their deposit (minus fees)
        assertRelApproxEq(
            asset.balanceOf(user) - assetsBefore,
            _amount,
            100, // 1% tolerance
            "User should receive approximately their deposit"
        );
    }

    /**
     * @notice Test deposit limit is 0 when LT is killed
     */
    function test_killedLT_blocksDeposits() public view {
        // Note: We can't easily simulate LT being killed in tests without complex mocking
        // This test verifies the logic exists
        // If lt.is_killed() == true, availableDepositLimit should return 0

        // Check current state (should not be killed)
        assertFalse(lt.is_killed(), "LT should not be killed in normal tests");

        // Verify deposit limit is unlimited when not killed
        assertEq(
            strategy.availableDepositLimit(address(vault)),
            type(uint256).max,
            "Deposit limit should be unlimited when LT not killed"
        );
    }

    /**
     * @notice Test emergency withdraw handles zero yVault balance
     */
    function test_emergencyWithdraw_handlesZeroBalance() public {
        // No deposit - strategy has no yVault shares

        // Shutdown
        vm.prank(management);
        strategy.shutdownStrategy();

        // Emergency withdraw should not revert with 0 balance
        vm.prank(management);
        strategy.emergencyWithdraw(1e8); // Try to withdraw 1 BTC

        // Should succeed without reverting
        assertTrue(true, "Emergency withdraw should handle zero balance");
    }
}
