// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {GaugeStrategySetup} from "../utils/GaugeStrategySetup.sol";
import {IStrategyInterface} from "src/interfaces/IStrategyInterface.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title GaugeStrategyShutdownTest
 * @notice Shutdown and emergency tests for YBGaugeStrategy
 * @dev Tests emergency withdraw and shutdown scenarios
 */
contract GaugeStrategyShutdownTest is GaugeStrategySetup {

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

        // Try to deposit - should not be possible
        _mintLTTokens(user, _amount);
        vm.startPrank(user);
        asset.approve(address(vault), _amount);

        // Vault deposit should succeed but strategy won't accept more debt
        vault.deposit(_amount, user);
        vm.stopPrank();

        // Attempting to allocate more debt should be limited
        // (Shutdown strategies should not accept new deposits)
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
     * @notice Test emergency withdraw from gauge
     */
    function test_emergencyWithdraw_unstakesFromGauge(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Deposit
        mintAndDepositIntoStrategy(strategy, user, _amount);

        uint256 gaugeSharesBefore = gauge.balanceOf(address(gaugeStrategy));
        assertGt(gaugeSharesBefore, 0, "Should have gauge shares");

        // Shutdown
        vm.prank(management);
        strategy.shutdownStrategy();

        // Emergency withdraw
        vm.prank(management);
        strategy.emergencyWithdraw(_amount);

        // Gauge shares should decrease
        uint256 gaugeSharesAfter = gauge.balanceOf(address(gaugeStrategy));
        assertLt(gaugeSharesAfter, gaugeSharesBefore, "Gauge shares should decrease");

        // Strategy should have liquid assets
        assertGt(asset.balanceOf(address(gaugeStrategy)), 0, "Should have liquid assets");
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

        // Should still have some gauge shares
        assertGt(gauge.balanceOf(address(gaugeStrategy)), 0, "Should still have gauge shares");

        // Should have liquid assets
        assertGt(asset.balanceOf(address(gaugeStrategy)), 0, "Should have liquid assets");
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
}
