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
    function setUp() public virtual override {
        super.setUp();
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
        ICurve pool1 = ICurve(swapper.pool1());
        ERC20 tokenIn = swapper.tokenIn();
        assertEq(address(tokenIn), pool1.coins(swapper.pool1InTokenIdx()));
        assertEq(swapper.tokenOutPool1(), pool1.coins(swapper.pool1OutTokenIdx()));
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
            ERC20(tokenAddrs["MKUSD"]),   // token in
            ERC20(asset),                 // token out
            ICurve(0x9D8108DDD8aD1Ee89d527C0C9e928Cb9D2BBa2d3), // pool 1 mkusd/crvusd
            ERC20(tokenAddrs["PRISMA"]),  // token out pool 1
            ICurveInt128(0x69833361991ed76f9e8DBBcdf9ea1520fEbFb4a7) // pool 2 prisma/yprisma
        )));
        // Upgrade swapper in strategy
        vm.prank(management);
        strategy.upgradeSwapper(swapper2);
        
        // Test approvals are all correct
        assertEq(
            ERC20(tokenAddrs["MKUSD"]).allowance(address(strategy), address(swapper)), 
            0, 
            "Allowance should be zeroed"
        );
        assertEq(
            ERC20(tokenAddrs["MKUSD"]).allowance(address(strategy), address(swapper2)), 
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

}
