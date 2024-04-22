// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/console.sol";
import {Setup, ERC20, IStrategyInterface} from "./utils/Setup.sol";

contract OperationTest is Setup {
    function setUp() public virtual override {
        super.setUp();
    }

    function test_setupStrategyOK() public {
        console.log("address of strategy", address(strategy));
        assertTrue(address(0) != address(strategy));
        assertEq(strategy.asset(), address(asset));
        assertEq(strategy.management(), management);
        assertEq(strategy.performanceFeeRecipient(), performanceFeeRecipient);
        assertEq(strategy.keeper(), keeper);
        // TODO: add additional check on strat params
    }

    function test_operation() public {
        uint256 _amount = 1e18;
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);
        console.log("Assets Deposited", strategy.totalAssets());
        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        uint bal = ybs.balanceOf(address(this));
        console.log('YBS Balance', bal);
        
        // Earn Interest
        skip(1 days);

        // Report profit
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        // Check return Values
        assertGe(profit, 0, "!profit");
        assertEq(loss, 0, "!loss");

        skip(strategy.profitMaxUnlockTime());

        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertGe(
            asset.balanceOf(user),
            balanceBefore + _amount,
            "!final balance"
        );
    }

    function test_profitableReport(
        uint256 _amount,
        uint16 _profitFactor
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);
        _profitFactor = uint16(bound(uint256(_profitFactor), 10, MAX_BPS));

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        // Earn Interest
        skip(1 days);

        // TODO: implement logic to simulate earning interest.
        uint256 toAirdrop = (_amount * _profitFactor) / MAX_BPS;
        airdrop(asset, address(strategy), toAirdrop);

        // Report profit
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        // Check return Values
        assertGe(profit, toAirdrop, "!profit");
        assertEq(loss, 0, "!loss");

        skip(strategy.profitMaxUnlockTime());

        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertGe(
            asset.balanceOf(user),
            balanceBefore + _amount,
            "!final balance"
        );
    }

    function test_profitableReport_withFees(
        uint256 _amount,
        uint16 _profitFactor
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);
        _profitFactor = uint16(bound(uint256(_profitFactor), 10, MAX_BPS));

        // Set protocol fee to 0 and perf fee to 10%
        setFees(0, 1_000);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        // Earn Interest
        skip(1 days);

        // TODO: implement logic to simulate earning interest.
        uint256 toAirdrop = (_amount * _profitFactor) / MAX_BPS;
        airdrop(asset, address(strategy), toAirdrop);

        // Report profit
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        // Check return Values
        assertGe(profit, toAirdrop, "!profit");
        assertEq(loss, 0, "!loss");

        skip(strategy.profitMaxUnlockTime());

        // Get the expected fee
        uint256 expectedShares = (profit * 1_000) / MAX_BPS;

        assertEq(strategy.balanceOf(performanceFeeRecipient), expectedShares);

        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertGe(
            asset.balanceOf(user),
            balanceBefore + _amount,
            "!final balance"
        );

        vm.prank(performanceFeeRecipient);
        strategy.redeem(
            expectedShares,
            performanceFeeRecipient,
            performanceFeeRecipient
        );

        checkStrategyTotals(strategy, 0, 0, 0);

        assertGe(
            asset.balanceOf(performanceFeeRecipient),
            expectedShares,
            "!perf fee out"
        );
    }

    function test_tendTrigger(uint256 _amount) public {
        _amount = bound(_amount, 2, type(uint).max);
        // bound(uint256 x, uint256 min, uint256 max)

        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        (bool trigger, ) = strategy.tendTrigger();
        assertTrue(!trigger);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        (trigger, ) = strategy.tendTrigger();
        assertTrue(!trigger);

        // Skip some time
        skip(1 days);

        (trigger, ) = strategy.tendTrigger();
        assertTrue(!trigger);

        vm.prank(keeper);
        strategy.report();

        (trigger, ) = strategy.tendTrigger();
        assertTrue(!trigger);

        // Unlock Profits
        skip(strategy.profitMaxUnlockTime());

        (trigger, ) = strategy.tendTrigger();
        assertTrue(!trigger);

        vm.prank(user);
        strategy.redeem(_amount, user, user);

        (trigger, ) = strategy.tendTrigger();
        assertTrue(!trigger);
    }

    function test_rewardsClaim(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        depositRewards(1e20);
        ERC20 mkusd = ERC20(rewards.rewardToken());

        // Deposit into YBS
        mintAndDepositIntoStrategy(strategy, user, _amount);
        strategy.stakeFullBalance();

        // Get claimable
        uint claimable = rewards.getClaimable(address(strategy));
        assertEq(claimable, 0, "Should have 0 claimable");

        skip(7 days);

        claimable = rewards.getClaimable(address(strategy));
        assertGt(claimable, 0, "Should have > 0 claimable");

        assertEq(mkusd.balanceOf(address(strategy)), 0, "Should have 0 rewards");

        // Harvest to claim
        vm.prank(keeper);
        strategy.report();
        uint rewardBalance = mkusd.balanceOf(address(strategy));
        assertGt(rewardBalance, 0, "Should have > 0 rewards");
        console.log("Claimed",rewardBalance/1e18);
    }

    function test_stakeTimeBuffer() public {
        uint _amount = 100e18;
        uint currentWeekStart = (block.timestamp / 1 weeks) * 1 weeks;
        uint nextWeekStart = currentWeekStart + 1 weeks;
        uint bufferStart = nextWeekStart - strategy.stakeTimeBuffer();
        uint timeUntil = block.timestamp >= bufferStart ? 0 : bufferStart - block.timestamp;

        // If in the buffer now, get out of it so we can test
        if(timeUntil == 0) skip(nextWeekStart - block.timestamp);

        // Assert we are out of the buffer: shouldStake is false.
        assertFalse(strategy.shouldStake());
        
        // Simulate a user deposit
        mintAndDepositIntoStrategy(strategy, user, _amount);
        uint bal = asset.balanceOf(address(strategy));
        assertGe(bal, _amount, "unexpected stake");

        vm.prank(user);
        strategy.stakeFullBalance();
        bal = asset.balanceOf(address(strategy));
        assertEq(bal, 0, "Stake didnt work");

        // Now, simulate reaching the buffer, depositing, and ensure auto-stake
        skip((bufferStart + 1 weeks) - block.timestamp);
        mintAndDepositIntoStrategy(strategy, user, _amount);
        assertTrue(strategy.shouldStake());
        bal = asset.balanceOf(address(strategy));
        assertEq(bal, 0, "Should have staked");
    }

    function test_withdrawDoesNotUnstake() public {
        uint _amount = 100e18;
        uint currentWeekStart = (block.timestamp / 1 weeks) * 1 weeks;
        uint nextWeekStart = currentWeekStart + 1 weeks;
        uint bufferStart = nextWeekStart - strategy.stakeTimeBuffer();
        uint timeUntil = block.timestamp >= bufferStart ? 0 : bufferStart - block.timestamp;

        // If in the buffer now, get out of it so we can test
        if(timeUntil == 0) skip(nextWeekStart - block.timestamp);

        // Assert we are out of the buffer: shouldStake is false.
        assertFalse(strategy.shouldStake());
        
        // Simulate a user deposit
        mintAndDepositIntoStrategy(strategy, user, _amount);
        uint bal = asset.balanceOf(address(strategy));
        assertGe(bal, _amount, "unexpected stake");

        vm.prank(user);
        strategy.stakeFullBalance();
        bal = asset.balanceOf(address(strategy));
        assertEq(bal, 0, "Stake didnt work");

        // Now, simulate reaching the buffer, depositing, and ensure auto-stake
        skip((bufferStart + 1 weeks) - block.timestamp);
        mintAndDepositIntoStrategy(strategy, user, _amount);
        assertTrue(strategy.shouldStake());
        bal = asset.balanceOf(address(strategy));
        assertEq(bal, 0, "Should have staked");
    }
}
