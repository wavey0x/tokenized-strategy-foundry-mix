// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/console.sol";
import {Setup, ERC20, IStrategyInterface} from "./utils/Setup.sol";
import {ICurve} from "../interfaces/curve/ICurve.sol";
import {ICurveInt128} from "../interfaces/curve/ICurveInt128.sol";
import {ISwapper} from "../interfaces/utils/ISwapper.sol";
import {Swapper} from "../periphery/Swapper.sol";

interface IERC4626 {
    function asset() external view returns (address);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256);
}

contract SwapperTest is Setup {
    ICurve pool1;
    ICurve pool2;
    ERC20 crvusd;

    function setUp() public virtual override {
        super.setUp();
        pool1 = ICurve(swapper.pool1());
        pool2 = ICurve(swapper.pool2());
        crvusd = ERC20(tokenAddrs["CRVUSD"]);
    }

    function test_setupStrategyOK() public view {
        console.log("address of strategy", address(strategy));
        assertTrue(address(0) != address(strategy));
        assertEq(strategy.asset(), address(asset));
        assertEq(strategy.management(), management);
        assertEq(strategy.performanceFeeRecipient(), performanceFeeRecipient);
        assertEq(strategy.keeper(), keeper);
    }

    function test_correctAddresses() public view {
        ERC20 tokenIn = swapper.tokenIn();
        assertEq(address(tokenIn), pool1.coins(swapper.pool1InTokenIdx()));
        assertEq(address(swapper.tokenOutPool1()), pool1.coins(swapper.pool1OutTokenIdx()));
    }

    function test_swapperOperation() public {
        ERC20 rewardToken = ERC20(rewards.rewardToken());
        uint _amount = 10_000e18;
        deal(address(rewardToken), address(this), _amount);
        // approve
        _amount = IERC4626(address(rewardToken))
            .redeem(_amount, address(this), address(this));
        ERC20(swapper.tokenIn()).approve(address(swapper), type(uint).max);

        uint amt = swapper.swap(_amount);
        uint balance = asset.balanceOf(address(this));
        console.log('Swap end balance', balance);
        assertGe(amt, 0, "No swap gain");
        assertGe(balance, amt, "No swap gain balance");
    }

    function test_swapperUpgrade() public {
        // Deploy new swapper
        ISwapper swapper2 = ISwapper(address(new Swapper(
            management,                    // management
            ERC20(tokenAddrs["CRVUSD"]),   // token in
            ERC20(asset),                 // token out
            ICurve(0xec977F46467a3021785Cff88894886E617abd65b), // pool 1 crvUSD/YB
            ERC20(tokenAddrs["YB"]),  // token out pool 1
            ICurveInt128(0x5Ee9606e5611Fd6CE14BD2BC12db70BD53dC9daA) // pool 2 YB/YYB
        )));
        // Upgrade swapper in strategy
        vm.prank(management);
        strategy.upgradeSwapper(swapper2);
        
        // Test approvals are all correct
        assertEq(
            ERC20(tokenAddrs["CRVUSD"]).allowance(address(strategy), address(swapper)), 
            0, 
            "Allowance should be zeroed"
        );
        assertEq(
            ERC20(tokenAddrs["CRVUSD"]).allowance(address(strategy), address(swapper2)), 
            type(uint).max, 
            "Allowance should be max"
        );

        ERC20(swapper2.tokenIn()).approve(address(swapper2), type(uint).max);

        ERC20 rewardToken = ERC20(rewards.rewardToken());
        uint _amount = 10_000e18;
        deal(address(rewardToken), address(this), _amount);
        // approve
        _amount = IERC4626(address(rewardToken))
            .redeem(_amount, address(this), address(this));
        ERC20(swapper.tokenIn()).approve(address(swapper), type(uint).max);

        uint amt = swapper.swap(_amount);
        uint balance = asset.balanceOf(address(this));
        console.log('Swap end balance', balance);
        assertGe(amt, 0, "No swap gain");
        assertGe(balance, amt, "No swap gain balance");
    }

    function test_SwapperMints() public {
        ERC20 yyb = ERC20(strategy.asset());
        uint256 ts = yyb.totalSupply();
        _skewPool(0);
        deal(address(crvusd), address(this), 10_000e18);
        crvusd.approve(address(swapper), type(uint256).max);
        swapper.swap(10_000e18);
        assertGt(yyb.totalSupply(), ts);
    }

    function test_OracleEMA() public {
        uint256 originalPrice = swapper.priceOracle();
        _skewPool(0);
        skip(1 days);
        assertLt(swapper.priceOracle(), originalPrice); // 1 crvUSD can now buy less
    }

    function _skewPool(uint256 tokenIdxToSell) public {
        address token = pool2.coins(tokenIdxToSell);
        uint256 amount = pool2.balances(tokenIdxToSell);
        deal(token, address(this), amount);
        ERC20(token).approve(address(pool2), type(uint256).max);
        pool2.exchange(
            int128(uint128(tokenIdxToSell)), 
            tokenIdxToSell == 0 ? int128(1) : int128(0), 
            amount, 
            0
        );
    }

}