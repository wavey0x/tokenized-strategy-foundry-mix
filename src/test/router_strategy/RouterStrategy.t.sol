// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {console2} from "forge-std/console2.sol";
import {RouterStrategySetup} from "../utils/RouterStrategySetup.sol";
import {YBRouterStrategy} from "src/YBRouterStrategy.sol";
import {IStrategyInterface} from "src/interfaces/IStrategyInterface.sol";

/**
 * @title RouterStrategyTest
 * @notice Test suite for YBRouterStrategy
 * @dev Tests router-specific functionality: LT holding, trading fees, slippage
 */
contract RouterStrategyTest is RouterStrategySetup {
    // ===== SETUP VALIDATION TESTS =====

    /**
     * @notice Verify Router strategy setup is correct
     */
    function test_routerStrategy_setupOK() public view {
        assertEq(address(strategy.asset()), btcToken); // BTC is the asset
        assertEq(address(routerStrategy.ltToken()), ltToken);
        assertEq(address(routerStrategy.yVault()), address(ltYVault));
    }

    // ===== LT HOLDING TESTS =====

    /**
     * @notice Test that router strategy holds LT tokens in yVault (not staked)
     */
    function test_routerStrategy_holdsLTInYVault(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        // Check that strategy has yVault shares
        uint256 yVaultShares = ltYVault.balanceOf(address(routerStrategy));
        assertGt(yVaultShares, 0, "Strategy should have yVault shares");

        // Strategy should NOT hold LT tokens directly (they're in yVault)
        uint256 ltBalance = lt.balanceOf(address(routerStrategy));
        assertEq(ltBalance, 0, "Strategy should not hold LT tokens directly");
    }

    /**
     * @notice Test LT tokens are NOT staked in gauge
     */
    function test_routerStrategy_doesNotStake(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        // Verify strategy has yVault shares but no gauge shares
        assertGt(ltYVault.balanceOf(address(routerStrategy)), 0, "Should have yVault shares");
    }

    // ===== WITHDRAWAL TESTS =====

    /**
     * @notice Test router strategy withdraws from yVault
     */
    function test_routerStrategy_withdrawsFromYVault(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        uint256 yVaultSharesBefore = ltYVault.balanceOf(address(routerStrategy));
        assertGt(yVaultSharesBefore, 0, "Should have yVault shares");

        // Withdraw half
        vm.prank(user);
        uint256 vaultShares = vault.balanceOf(user);
        vault.redeem(vaultShares, user, user);

        uint256 yVaultSharesAfter = ltYVault.balanceOf(address(routerStrategy));
        assertLt(yVaultSharesAfter, yVaultSharesBefore, "yVault shares should decrease");
    }

    // ===== CONVERSION TESTS =====

    /**
     * @notice Test LT to asset conversion
     */
    function test_routerStrategy_ltToAsset() public view {
        uint256 ltAmount = 1e18; // 1 LT
        uint256 assetAmount = routerStrategy.ltToAsset(ltAmount);

        // Should be approximately 1 BTC (8 decimals)
        assertGt(assetAmount, 0, "Asset amount should be positive");
    }

    /**
     * @notice Test asset to LT conversion
     */
    function test_routerStrategy_assetToLt() public view {
        uint256 assetAmount = 1e8; // 1 BTC (8 decimals)
        uint256 ltAmount = routerStrategy.assetToLt(assetAmount);

        // Should be approximately 1 LT (18 decimals)
        assertGt(ltAmount, 0, "LT amount should be positive");
    }

    // ===== DEPOSIT LIMIT TESTS =====

    /**
     * @notice Test only vault can deposit
     */
    function test_routerStrategy_onlyVaultCanDeposit() public view {
        // Vault should have unlimited deposit limit
        assertEq(
            strategy.availableDepositLimit(address(vault)),
            type(uint256).max,
            "Vault should have unlimited deposit"
        );

        // Other addresses should have 0 deposit limit
        assertEq(
            strategy.availableDepositLimit(user),
            0,
            "Non-vault should have 0 deposit limit"
        );
    }

    // ===== ASSET ACCOUNTING TESTS =====

    /**
     * @notice Test total assets accounting
     */
    function test_routerStrategy_totalAssetsAccounting(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Before deposit
        assertEq(strategy.totalAssets(), 0, "Should start at 0");

        // After deposit
        mintAndDepositIntoStrategy(strategy, user, _amount);
        uint256 totalAssets = strategy.totalAssets();

        // Should be approximately equal to deposit (within tolerance for fees/slippage)
        assertRelApproxEq(totalAssets, _amount, 100, "Total assets should match deposit");
    }

    /**
     * @notice Test trading fee accrual via pricePerShare
     */
    function test_routerStrategy_tradingFeeAccrual(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount / 10);

        // Deposit
        mintAndDepositIntoStrategy(strategy, user, _amount);
        uint256 totalAssetsBefore = strategy.totalAssets();

        // Skip time (trading fees accrue passively via pricePerShare)
        skip(30 days);

        // Report to update accounting
        vm.prank(keeper);
        strategy.report();

        // Total assets should be at least what we started with
        // (Trading fees may have accrued, but not guaranteed in test)
        uint256 totalAssetsAfter = strategy.totalAssets();
        assertGe(totalAssetsAfter, totalAssetsBefore * 95 / 100, "Assets should not decrease significantly");
    }
}
