// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {console} from "forge-std/console.sol";
import {RouterStrategySetup} from "../utils/RouterStrategySetup.sol";
import {YBRouterStrategy} from "src/YBRouterStrategy.sol";
import {IStrategyInterface} from "src/interfaces/IStrategyInterface.sol";

/**
 * @title RouterStrategyBufferTest
 * @notice Test suite for YBRouterStrategy
 * @dev Tests router-specific functionality: LT holding, trading fees, slippage
 */
contract RouterStrategyBufferTest is RouterStrategySetup {

    function test_BufferSkimsAllProfit(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // 1. Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);
        uint256 totalAssets = strategy.totalAssets();
        assertEq(totalAssets, _amount, "Total assets should match deposit");

        // 2. Simulate buffer is created from profit
        uint256 startingTotalAssets = strategy.totalAssets();
        uint256 startingBufferShares = strategy.availableBufferShares();
        uint256 startingBufferAssets = strategy.ltToAsset(startingBufferShares);
        increaseBuffer(_amount); // Helper to take care of airdropping newly minted LT and recording it as buffer

        // 3. Checks
        uint256 endingTotalAssets = strategy.totalAssets();
        uint256 bufferShares = strategy.availableBufferShares();
        uint256 bufferAssets = strategy.ltToAsset(bufferShares);
        assertEq(endingTotalAssets, startingTotalAssets, "Total assets should not increase"); // Buffer was set to 100% of profit
        assertGt(bufferShares, startingBufferShares, "Buffer shares should increase");
        assertGt(bufferAssets, startingBufferAssets, "Buffer assets should increase");
        assertEq(lt.balanceOf(address(strategy)), 0, "Should be no loose LT");
    }

    function test_BufferPaysLossUsingBuffer(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);
        mintAndDepositIntoStrategy(strategy, user, _amount);
        increaseBuffer(_amount);
        uint256 startingBufferShares = strategy.availableBufferShares();
        assertGt(startingBufferShares, 0, "Buffer should be greater than 0");
        assertGt(ltYVault.totalAssets(), 0, "LT vault has 0 assets");
        assertEq(ltYVault.minimum_total_idle(), 0, "LT vault has 0 minimum idle assets");
        assertGt(mockStrategy.totalAssets(), 0, "Mock strategy has 0 assets"); // Auto-deposits should be enabled
        // Scale loss amount to match decimals
        (, uint256 _loss) = createUnrealizedLoss(_amount * 90 / 100);
        assertGt(_loss, 0, "Loss was not created");
        vm.startPrank(management);
        strategy.setDoHealthCheck(false);
        (, _loss) = strategy.report(); // Realize loss
        vm.stopPrank();
        console.log("loss", _loss);
        assertLt(strategy.availableBufferShares(), startingBufferShares, "Buffer should have been used");
    }

    // TODO: 
    // - Test distribute buffer
    // - Test buffer is used to offset a loss
    // - Test BufferUpdated event
    // - Test buffer accounting and full withdrawals still possible

    function increaseBuffer(uint256 _amount) public {
        uint256 originalBufferKeepPct = strategy.bufferKeepPct();
        uint256 profit = simulateProfit(_amount);
        assertGt(profit, 0, "Profit was not created");
        vm.startPrank(management);
        strategy.setBufferKeepPct(MAX_BPS);
        strategy.setDoHealthCheck(false);
        strategy.report();
        strategy.setBufferKeepPct(originalBufferKeepPct); // Set back to original
        vm.stopPrank();
    }

    function createUnrealizedLoss(uint256 _lossAmount) public returns (uint256 _profit, uint256 _loss) {
        _lossAmount = strategy.assetToLt(_lossAmount);
        vm.startPrank(management);
        uint256 vaultTotalAssets = ltYVault.totalAssets();
        if (mockStrategy.totalAssets() < vaultTotalAssets) {
            ltYVault.update_debt(address(mockStrategy), vaultTotalAssets);
        }
        // Create a loss all the way down to the router strategy
        deal(address(ltToken), address(mockStrategy), mockStrategy.totalAssets() - _lossAmount);
        mockStrategy.report();
        (_profit, _loss) = ltYVault.process_report(address(mockStrategy));
        vm.stopPrank();
    }

    function releaseBuffer(uint256 _amount) public {
        vm.prank(management);
        strategy.distributeBuffer(_amount);
    }
}
