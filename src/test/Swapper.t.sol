// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/console.sol";
import {Setup, ERC20, IStrategyInterface} from "./utils/Setup.sol";
import {ICurve} from "../interfaces/curve/ICurve.sol";
import {ICurveInt128} from "../interfaces/curve/ICurveInt128.sol";
import {ISwapper} from "../interfaces/utils/ISwapper.sol";
import {Swapper} from "../periphery/Swapper.sol";
import {IVaultV2} from "../interfaces/utils/IVaultV2.sol";

interface IERC4626 {
    function asset() external view returns (address);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256);
}

contract SwapperTest is Setup {
    ICurve pool1;
    ICurve pool2;
    ERC20 crvusd;
    ERC20 yb;
    ERC20 yyb;

    function setUp() public virtual override {
        super.setUp();
        pool1 = ICurve(swapper.pool1());
        pool2 = ICurve(swapper.pool2());
        yb = ERC20(pool2.coins(0));
        yyb = ERC20(pool2.coins(1));
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
        _ensureNoBalance();
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
        _ensureNoBalance();
    }

    function test_SwapperMints() public {
        uint256 ts = yyb.totalSupply();
        _skewPool(0);
        deal(address(crvusd), address(this), 10_000e18);
        crvusd.approve(address(swapper), type(uint256).max);
        swapper.swap(10_000e18);
        assertGt(yyb.totalSupply(), ts);
        _ensureNoBalance();
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

    function _ensureNoBalance() public {
        assertEq(crvusd.balanceOf(address(swapper)), 0);
        assertEq(yb.balanceOf(address(swapper)), 0);
        assertEq(yyb.balanceOf(address(swapper)), 0);
    }

    function test_OtcSwap() public {
        // Fund swapper with buyToken for OTC
        uint256 otcFunds = 100_000e18;
        deal(address(yyb), address(swapper), otcFunds);

        // Enable OTC and whitelist caller
        vm.prank(swapper.owner());
        swapper.enableOtc(true);
        vm.prank(management);
        swapper.setAllowedSwapper(address(this), true);

        // Calculate expected OTC output
        uint256 sellAmount = 1_000e18;
        uint256 price = swapper.priceOracle();
        uint256 expectedYYB = (sellAmount * price) / 1e18;

        deal(address(crvusd), address(this), sellAmount);
        crvusd.approve(address(swapper), sellAmount);

        uint256 swapperYYBBefore = yyb.balanceOf(address(swapper));
        uint256 userYYBBefore = yyb.balanceOf(address(this));

        uint256 amt = swapper.swap(sellAmount);

        uint256 swapperYYBAfter = yyb.balanceOf(address(swapper));
        uint256 userYYBAfter = yyb.balanceOf(address(this));

        // Verify OTC worked correctly
        assertEq(userYYBAfter - userYYBBefore, expectedYYB, "User should receive exact OTC amount");
        assertEq(swapperYYBBefore - swapperYYBAfter, expectedYYB, "Swapper should send exact OTC amount");
        assertEq(amt, expectedYYB, "Return value should match");
        assertEq(crvusd.balanceOf(address(swapper)), 0, "crvUSD should be deposited to vault");
    }

    function test_AccessControl() public {
        address unauthorized = address(0xBEEF);

        vm.startPrank(unauthorized);
        vm.expectRevert("!owner");
        swapper.setVault(IVaultV2(address(0)));

        vm.expectRevert("!ownerOrManagement");
        swapper.setAllowedSwapper(address(this), true);

        vm.expectRevert("!ownerOrManagement");
        swapper.setOperator(address(this), true);

        vm.expectRevert("!operator");
        swapper.enableOtc(true);

        vm.expectRevert("!ownerOrManagement");
        swapper.sweep(address(crvusd));
        vm.stopPrank();

        // Verify management can call ownerOrManagement functions
        vm.prank(management);
        swapper.setAllowedSwapper(address(this), true);
        assertTrue(swapper.allowedSwapper(address(this)));
    }

}