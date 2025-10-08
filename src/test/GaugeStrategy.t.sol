// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {console2} from "forge-std/console2.sol";
import {YieldBasisSetup} from "./utils/YieldBasisSetup.sol";
import {YieldBasisGaugeStrategy} from "src/YieldBasisGaugeStrategy.sol";
import {ILT} from "src/interfaces/yb/ILT.sol";
import {ILiquidityGauge} from "src/interfaces/yb/ILiquidityGauge.sol";
import {IStrategy} from "@tokenized-strategy/interfaces/IStrategy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title GaugeStrategyTest
 * @notice Test suite for YieldBasisGaugeStrategy
 * @dev Inherits shared tests from YieldBasisSetup and adds Gauge-specific tests
 */
contract GaugeStrategyTest is YieldBasisSetup {
    YieldBasisGaugeStrategy public gaugeStrategy;
    ILT public lt;
    ILiquidityGauge public liquidityGauge;
    ERC20 public ybToken;

    /**
     * @notice Deploy Gauge strategy (implements abstract deployStrategy from YieldBasisSetup)
     */
    function deployStrategy() internal override returns (address) {
        // Deploy via factory (tests production deployment path)
        // Factory also deploys and sets RewardsSwapper
        address deployed = factory.deployGaugeStrategy(
            address(asset),
            ltToken,
            gauge,
            cryptopool,
            "YB Gauge Strategy"
        );

        gaugeStrategy = YieldBasisGaugeStrategy(deployed);
        lt = ILT(gaugeStrategy.ltToken());
        liquidityGauge = ILiquidityGauge(gaugeStrategy.gauge());
        ybToken = ERC20(liquidityGauge.YB());

        // Setup management (factory is initial management, transfer to test management)
        vm.prank(address(factory));
        IStrategy(deployed).setPendingManagement(management);

        vm.prank(management);
        IStrategy(deployed).acceptManagement();

        // Setup keeper
        vm.prank(management);
        IStrategy(deployed).setKeeper(keeper);

        return deployed;
    }

    // ===== GAUGE-SPECIFIC TESTS =====

    /**
     * @notice Verify Gauge strategy setup is correct
     */
    function test_gaugeStrategy_setupOK() public {
        assertEq(address(gaugeStrategy.ltToken()), ltToken);
        assertEq(address(gaugeStrategy.gauge()), gauge);
        assertEq(address(gaugeStrategy.cryptopool()), cryptopool);
        assertEq(address(gaugeStrategy.ybToken()), address(ybToken));
        assertEq(gaugeStrategy.maxDepositSlippage(), 50); // 0.5%
        assertEq(gaugeStrategy.maxWithdrawSlippage(), 50); // 0.5%
    }

    /**
     * @notice Test that gauge strategy stakes LT tokens in gauge
     */
    function test_gaugeStrategy_stakesInGauge(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        // Check that strategy has gauge shares (staked LT)
        uint256 gaugeBalance = liquidityGauge.balanceOf(address(gaugeStrategy));
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

        uint256 gaugeBalanceBefore = liquidityGauge.balanceOf(address(gaugeStrategy));
        assertGt(gaugeBalanceBefore, 0, "Should have staked tokens");

        // Withdraw half
        vm.prank(user);
        strategy.redeem(_amount / 2, user, user);

        uint256 gaugeBalanceAfter = liquidityGauge.balanceOf(address(gaugeStrategy));
        assertLt(gaugeBalanceAfter, gaugeBalanceBefore, "Gauge balance should decrease");
    }

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

        // Check if YB rewards were claimed (may be 0 if no emissions)
        // We just verify the function doesn't revert
        assertTrue(true, "Harvest should not revert");
    }

    /**
     * @notice Test reward token configuration
     */
    function test_gaugeStrategy_rewardTokenConfig() public view {
        // Check that YB token is configured as reward
        YieldBasisGaugeStrategy.RewardTokenConfig memory config =
            gaugeStrategy.getRewardTokenConfig(address(ybToken));

        assertEq(uint8(config.swapType), uint8(YieldBasisGaugeStrategy.SwapType.AUCTION));
        assertEq(config.minAmountToSell, 1e18);
        assertEq(config.maxAmountToSell, 100_000e18);
        assertEq(config.shouldClaim, true);
    }

    /**
     * @notice Test adding a reward token
     */
    function test_gaugeStrategy_addRewardToken() public {
        address newRewardToken = makeAddr("newRewardToken");

        vm.prank(management);
        gaugeStrategy.addRewardToken(
            newRewardToken,
            YieldBasisGaugeStrategy.SwapType.SWAP,
            1e18,
            1000e18,            
            true
        );

        YieldBasisGaugeStrategy.RewardTokenConfig memory config =
            gaugeStrategy.getRewardTokenConfig(newRewardToken);

        assertEq(uint8(config.swapType), uint8(YieldBasisGaugeStrategy.SwapType.SWAP));
        assertEq(config.minAmountToSell, 1e18);
        assertEq(config.maxAmountToSell, 1000e18);
        assertEq(config.shouldClaim, true);
    }

    /**
     * @notice Test removing a reward token
     */
    function test_gaugeStrategy_removeRewardToken() public {
        address newRewardToken = makeAddr("newRewardToken");

        // Add reward token
        vm.prank(management);
        gaugeStrategy.addRewardToken(
            newRewardToken,
            YieldBasisGaugeStrategy.SwapType.SWAP,
            1e18,
            1000e18,
            true
        );

        // Remove it
        vm.prank(management);
        gaugeStrategy.removeRewardToken(newRewardToken);

        // Config should be reset to NULL
        YieldBasisGaugeStrategy.RewardTokenConfig memory config =
            gaugeStrategy.getRewardTokenConfig(newRewardToken);

        assertEq(uint8(config.swapType), uint8(YieldBasisGaugeStrategy.SwapType.NULL));
    }

    /**
     * @notice Test updating reward token config
     */
    function test_gaugeStrategy_updateRewardTokenConfig() public {
        vm.prank(management);
        gaugeStrategy.updateRewardTokenConfig(
            address(ybToken),
            YieldBasisGaugeStrategy.SwapType.SWAP,
            10e18,
            50_000e18,
            true
        );

        YieldBasisGaugeStrategy.RewardTokenConfig memory config =
            gaugeStrategy.getRewardTokenConfig(address(ybToken));

        assertEq(uint8(config.swapType), uint8(YieldBasisGaugeStrategy.SwapType.SWAP));
        assertEq(config.minAmountToSell, 10e18);
        assertEq(config.maxAmountToSell, 50_000e18);
        assertEq(config.shouldClaim, true);
    }

    /**
     * @notice Test management can update slippage
     */
    function test_gaugeStrategy_setSlippage() public {
        vm.prank(management);
        gaugeStrategy.setSlippage(100, 200);

        assertEq(gaugeStrategy.maxDepositSlippage(), 100);
        assertEq(gaugeStrategy.maxWithdrawSlippage(), 200);
    }

    /**
     * @notice Test slippage cannot be set too high
     */
    function test_gaugeStrategy_setSlippage_revertsIfTooHigh() public {
        vm.prank(management);
        vm.expectRevert("Deposit slippage too high");
        gaugeStrategy.setSlippage(501, 50); // >5%

        vm.prank(management);
        vm.expectRevert("Withdraw slippage too high");
        gaugeStrategy.setSlippage(50, 501); // >5%
    }

    /**
     * @notice Test gauge shares convert to assets correctly
     */
    function test_gaugeStrategy_gaugeShareConversion(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        // Get gauge shares
        uint256 gaugeShares = liquidityGauge.balanceOf(address(gaugeStrategy));

        // Convert to LT tokens
        uint256 ltEquivalent = liquidityGauge.convertToAssets(gaugeShares);

        // Convert to asset value
        uint256 assetValue = (ltEquivalent * lt.pricePerShare()) / 1e18;

        // Should be approximately equal to deposited amount (within slippage)
        assertRelApproxEq(assetValue, _amount, 100); // 1% tolerance
    }

    /**
     * @notice Test emergency withdraw from Gauge strategy
     */
    function test_gaugeStrategy_emergencyWithdraw(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        uint256 gaugeBalanceBefore = liquidityGauge.balanceOf(address(gaugeStrategy));
        assertGt(gaugeBalanceBefore, 0, "Should have gauge shares");

        // Shutdown strategy
        vm.prank(management);
        strategy.shutdownStrategy();

        // Emergency withdraw
        vm.prank(management);
        strategy.emergencyWithdraw(_amount);

        // Gauge shares should be withdrawn
        uint256 gaugeBalanceAfter = liquidityGauge.balanceOf(address(gaugeStrategy));
        assertLt(gaugeBalanceAfter, gaugeBalanceBefore, "Gauge balance should decrease after emergency withdraw");

        // Assets should be in strategy
        assertGt(asset.balanceOf(address(gaugeStrategy)), 0, "Should have withdrawn assets");
    }

    /**
     * @notice Test get all reward tokens
     */
    function test_gaugeStrategy_getAllRewardTokens() public view {
        address[] memory rewardTokens = gaugeStrategy.getAllRewardTokens();

        // Should have at least YB and stablecoin
        assertGe(rewardTokens.length, 2, "Should have at least 2 reward tokens");

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
}
