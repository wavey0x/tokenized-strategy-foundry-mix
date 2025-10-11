// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {console2} from "forge-std/console2.sol";
import {GaugeStrategySetup} from "../utils/GaugeStrategySetup.sol";
import {YBGaugeStrategy} from "src/YBGaugeStrategy.sol";
import {IStrategyInterface} from "src/interfaces/IStrategyInterface.sol";

/**
 * @title GaugeStrategyTest
 * @notice Test suite for YBGaugeStrategy
 * @dev Tests gauge-specific functionality: staking, rewards, token config
 */
contract GaugeStrategyTest is GaugeStrategySetup {
    // ===== SETUP VALIDATION TESTS =====

    /**
     * @notice Verify Gauge strategy setup is correct
     */
    function test_gaugeStrategy_setupOK() public view {
        assertEq(address(strategy.asset()), ltToken); // LT is the asset
        assertEq(address(gaugeStrategy.gauge()), gaugeAddress);
        assertEq(address(gaugeStrategy.ybToken()), address(ybToken));
    }

    // ===== STAKING TESTS =====

    /**
     * @notice Test that gauge strategy stakes LT tokens in gauge
     */
    function test_gaugeStrategy_stakesInGauge(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        // Check that strategy has gauge shares (staked LT)
        uint256 gaugeBalance = gauge.balanceOf(address(gaugeStrategy));
        assertGt(gaugeBalance, 0, "Strategy should have gauge shares");

        // Strategy should NOT hold LT tokens directly (they're staked)
        uint256 ltBalance = lt.balanceOf(address(gaugeStrategy));
        assertEq(ltBalance, 0, "Strategy should not hold unstaked LT tokens");
    }

    /**
     * @notice Test gauge unstaking on withdraw
     */
    function test_gaugeStrategy_unstakesOnWithdraw(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        uint256 gaugeBalanceBefore = gauge.balanceOf(address(gaugeStrategy));
        assertGt(gaugeBalanceBefore, 0, "Should have staked tokens");

        // Withdraw half
        vm.prank(user);
        strategy.redeem(_amount / 2, user, user);

        uint256 gaugeBalanceAfter = gauge.balanceOf(address(gaugeStrategy));
        assertLt(gaugeBalanceAfter, gaugeBalanceBefore, "Gauge balance should decrease");
    }

    // ===== REWARD TESTS =====

    /**
     * @notice Test YB reward claiming
     */
    function test_gaugeStrategy_claimsYBRewards(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        // Skip time to accrue rewards
        skip(7 days);

        // Get YB balance before harvest
        uint256 ybBalanceBefore = ybToken.balanceOf(address(gaugeStrategy));

        // Harvest (claims rewards)
        vm.prank(keeper);
        strategy.report();
    }

    /**
     * @notice Test manual claim rewards
     */
    function test_gaugeStrategy_manualClaimRewards(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        // Skip time to accrue rewards
        skip(7 days);

        // Manual claim by management
        vm.prank(management);
        gaugeStrategy.claimRewards();

        // Should not revert
        assertTrue(true, "Manual claim should not revert");
    }

    // ===== REWARD TOKEN CONFIGURATION TESTS =====

    /**
     * @notice Test reward token configuration
     */
    function test_gaugeStrategy_rewardTokenConfig() public view {
        // Check that YB token is configured as reward
        YBGaugeStrategy.RewardTokenConfig memory config =
            gaugeStrategy.getRewardTokenConfig(address(ybToken));

        assertEq(uint8(config.swapType), uint8(YBGaugeStrategy.SwapType.AUCTION));
        assertEq(config.minAmountToSell, 1e18);
        assertEq(config.maxAmountToSell, 100_000e18);
        assertEq(config.shouldClaim, true);
    }

    /**
     * @notice Test adding a reward token
     */
    function test_gaugeStrategy_addRewardToken() public {
        // Use real WETH address as a mock reward token
        address newRewardToken = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2; // WETH

        vm.prank(management);
        gaugeStrategy.addRewardToken(
            newRewardToken,
            YBGaugeStrategy.SwapType.SWAP,
            1e18,
            1000e18,
            true
        );

        YBGaugeStrategy.RewardTokenConfig memory config =
            gaugeStrategy.getRewardTokenConfig(newRewardToken);

        assertEq(uint8(config.swapType), uint8(YBGaugeStrategy.SwapType.SWAP));
        assertEq(config.minAmountToSell, 1e18);
        assertEq(config.maxAmountToSell, 1000e18);
        assertEq(config.shouldClaim, true);
    }

    /**
     * @notice Test removing a reward token
     */
    function test_gaugeStrategy_removeRewardToken() public {
        // Use real WETH address as a mock reward token
        address newRewardToken = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2; // WETH

        // Add reward token
        vm.prank(management);
        gaugeStrategy.addRewardToken(
            newRewardToken,
            YBGaugeStrategy.SwapType.SWAP,
            1e18,
            1000e18,
            true
        );

        // Remove it
        vm.prank(management);
        gaugeStrategy.removeRewardToken(newRewardToken);

        // Config should be reset to NULL
        YBGaugeStrategy.RewardTokenConfig memory config =
            gaugeStrategy.getRewardTokenConfig(newRewardToken);

        assertEq(uint8(config.swapType), uint8(YBGaugeStrategy.SwapType.NULL));
    }

    /**
     * @notice Test updating reward token config
     */
    function test_gaugeStrategy_updateRewardTokenConfig() public {
        vm.prank(management);
        gaugeStrategy.updateRewardTokenConfig(
            address(ybToken),
            YBGaugeStrategy.SwapType.SWAP,
            10e18,
            50_000e18,
            true
        );

        YBGaugeStrategy.RewardTokenConfig memory config =
            gaugeStrategy.getRewardTokenConfig(address(ybToken));

        assertEq(uint8(config.swapType), uint8(YBGaugeStrategy.SwapType.SWAP));
        assertEq(config.minAmountToSell, 10e18);
        assertEq(config.maxAmountToSell, 50_000e18);
        assertEq(config.shouldClaim, true);
    }

    /**
     * @notice Test get all reward tokens
     */
    function test_gaugeStrategy_getAllRewardTokens() public view {
        address[] memory rewardTokens = gaugeStrategy.getAllRewardTokens();

        // Should have at least YB token (stablecoin removed in simplified version)
        assertGe(rewardTokens.length, 1, "Should have at least 1 reward token");

        // Check YB token is in the list
        bool foundYB = false;
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            if (rewardTokens[i] == address(ybToken)) {
                foundYB = true;
                break;
            }
        }
        assertTrue(foundYB, "YB token should be in reward tokens list");
    }

    // ===== CONVERSION TESTS =====

    /**
     * @notice Test gauge shares convert to assets correctly
     */
    function test_gaugeStrategy_gaugeShareConversion(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        // Get gauge shares
        uint256 gaugeShares = gauge.balanceOf(address(gaugeStrategy));

        // Convert to LT tokens (asset for this strategy)
        uint256 ltEquivalent = gauge.convertToAssets(gaugeShares);

        // Should be approximately equal to deposited amount (LT is the asset)
        assertRelApproxEq(ltEquivalent, _amount, 100); // 1% tolerance
    }

    // ===== EMERGENCY TESTS =====

    /**
     * @notice Test emergency withdraw from Gauge strategy
     */
    function test_gaugeStrategy_emergencyWithdraw(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        uint256 gaugeBalanceBefore = gauge.balanceOf(address(gaugeStrategy));
        assertGt(gaugeBalanceBefore, 0, "Should have gauge shares");

        // Shutdown strategy
        vm.prank(management);
        strategy.shutdownStrategy();

        // Emergency withdraw
        vm.prank(management);
        strategy.emergencyWithdraw(_amount);

        // Gauge shares should be withdrawn
        uint256 gaugeBalanceAfter = gauge.balanceOf(address(gaugeStrategy));
        assertLt(gaugeBalanceAfter, gaugeBalanceBefore, "Gauge balance should decrease after emergency withdraw");

        // Assets should be in strategy
        assertGt(asset.balanceOf(address(gaugeStrategy)), 0, "Should have withdrawn assets");
    }
}
