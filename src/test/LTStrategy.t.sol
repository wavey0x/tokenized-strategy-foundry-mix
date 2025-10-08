// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {console2} from "forge-std/console2.sol";
import {YieldBasisSetup} from "./utils/YieldBasisSetup.sol";
import {YieldBasisLTStrategy} from "src/YieldBasisLTStrategy.sol";
import {ILT} from "src/interfaces/yb/ILT.sol";
import {IStrategy} from "@tokenized-strategy/interfaces/IStrategy.sol";

/**
 * @title LTStrategyTest
 * @notice Test suite for YieldBasisLTStrategy
 * @dev Inherits shared tests from YieldBasisSetup and adds LT-specific tests
 */
contract LTStrategyTest is YieldBasisSetup {
    YieldBasisLTStrategy public ltStrategy;
    ILT public lt;

    /**
     * @notice Deploy LT strategy (implements abstract deployStrategy from YieldBasisSetup)
     */
    function deployStrategy() internal override returns (address) {
        // Deploy via factory (tests production deployment path)
        address deployed = factory.deployLTStrategy(
            address(asset),
            ltToken,
            cryptopool,
            "YB LT Strategy"
        );

        ltStrategy = YieldBasisLTStrategy(deployed);
        lt = ILT(ltStrategy.ltToken());

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

    // ===== LT-SPECIFIC TESTS =====

    /**
     * @notice Verify LT strategy setup is correct
     */
    function test_ltStrategy_setupOK() public view {
        assertEq(address(ltStrategy.ltToken()), ltToken);
        assertEq(address(ltStrategy.cryptopool()), cryptopool);
        assertEq(address(ltStrategy.stablecoin()), 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E); // crvUSD
        assertEq(ltStrategy.maxDepositSlippage(), 50); // 0.5%
        assertEq(ltStrategy.maxWithdrawSlippage(), 50); // 0.5%
    }

    /**
     * @notice Test that LT tokens are held directly by the strategy
     */
    function test_ltStrategy_holdsLTTokens(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        // Check that strategy holds LT tokens
        uint256 ltBalance = lt.balanceOf(address(ltStrategy));
        assertGt(ltBalance, 0, "Strategy should hold LT tokens");
    }

    /**
     * @notice Test LT pricePerShare accounting
     */
    function test_ltStrategy_pricePerShareAccounting(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        // Get LT balance and pricePerShare
        uint256 ltBalance = lt.balanceOf(address(ltStrategy));
        uint256 pricePerShare = lt.pricePerShare();

        // Calculate expected asset value
        uint256 expectedAssetValue = (ltBalance * pricePerShare) / 1e18;

        // Should be approximately equal to deposited amount (within slippage)
        assertRelApproxEq(expectedAssetValue, _amount, 100); // 1% tolerance
    }

    /**
     * @notice Test direct LT withdraw flow
     */
    function test_ltStrategy_directWithdraw(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        uint256 ltBalanceBefore = lt.balanceOf(address(ltStrategy));
        assertGt(ltBalanceBefore, 0, "Should have LT tokens");

        // Withdraw half
        vm.prank(user);
        strategy.redeem(_amount / 2, user, user);

        uint256 ltBalanceAfter = lt.balanceOf(address(ltStrategy));
        assertLt(ltBalanceAfter, ltBalanceBefore, "LT balance should decrease");
    }

    /**
     * @notice Test slippage protection on deposits
     */
    function test_ltStrategy_depositSlippageProtection() public {
        uint256 _amount = 1e8; // 1 WBTC

        // Set very tight slippage (should still work for normal conditions)
        vm.prank(management);
        ltStrategy.setSlippage(10, 50); // 0.1% deposit, 0.5% withdraw

        // Deposit should succeed with tight slippage
        mintAndDepositIntoStrategy(strategy, user, _amount);

        assertGt(lt.balanceOf(address(ltStrategy)), 0, "Should have deposited");
    }

    /**
     * @notice Test slippage protection on withdrawals
     */
    function test_ltStrategy_withdrawSlippageProtection(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Deposit first
        mintAndDepositIntoStrategy(strategy, user, _amount);

        // Set tight slippage
        vm.prank(management);
        ltStrategy.setSlippage(50, 10); // 0.5% deposit, 0.1% withdraw

        // Withdraw should succeed with tight slippage (under normal conditions)
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertEq(lt.balanceOf(address(ltStrategy)), 0, "Should have withdrawn all LT");
    }

    /**
     * @notice Test management can update slippage
     */
    function test_ltStrategy_setSlippage() public {
        vm.prank(management);
        ltStrategy.setSlippage(100, 200);

        assertEq(ltStrategy.maxDepositSlippage(), 100);
        assertEq(ltStrategy.maxWithdrawSlippage(), 200);
    }

    /**
     * @notice Test slippage cannot be set too high
     */
    function test_ltStrategy_setSlippage_revertsIfTooHigh() public {
        vm.prank(management);
        vm.expectRevert("Deposit slippage too high");
        ltStrategy.setSlippage(501, 50); // >5%

        vm.prank(management);
        vm.expectRevert("Withdraw slippage too high");
        ltStrategy.setSlippage(50, 501); // >5%
    }

    /**
     * @notice Test loose assets are included in totalAssets
     */
    function test_ltStrategy_looseAssetsIncluded(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        // Airdrop some loose assets
        uint256 looseAmount = _amount / 10;
        airdrop(asset, address(ltStrategy), looseAmount);

        // Report should include loose assets
        vm.prank(keeper);
        strategy.report();

        uint256 totalAssets = strategy.totalAssets();
        assertGt(totalAssets, _amount, "Total assets should include loose assets");
    }

    /**
     * @notice Test emergency withdraw from LT strategy
     */
    function test_ltStrategy_emergencyWithdraw(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        uint256 ltBalanceBefore = lt.balanceOf(address(ltStrategy));
        assertGt(ltBalanceBefore, 0, "Should have LT tokens");

        // Shutdown strategy
        vm.prank(management);
        strategy.shutdownStrategy();

        // Emergency withdraw
        vm.prank(management);
        strategy.emergencyWithdraw(_amount);

        // LT tokens should be withdrawn
        uint256 ltBalanceAfter = lt.balanceOf(address(ltStrategy));
        assertLt(ltBalanceAfter, ltBalanceBefore, "LT balance should decrease after emergency withdraw");

        // Assets should be in strategy
        assertGt(asset.balanceOf(address(ltStrategy)), 0, "Should have withdrawn assets");
    }
}
