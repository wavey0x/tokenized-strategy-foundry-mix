// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {Setup, IStrategyInterface, ERC20} from "./Setup.sol";
import {IStrategy} from "@tokenized-strategy/interfaces/IStrategy.sol";

import {YieldBasisLTStrategy} from "../../YieldBasisLTStrategy.sol";
import {YieldBasisGaugeStrategy} from "../../YieldBasisGaugeStrategy.sol";
import {YieldBasisStrategyFactory} from "../../YieldBasisStrategyFactory.sol";
import {Constants} from "./Constants.sol";
import {ILT} from "src/interfaces/yb/ILT.sol";
import {IGaugeController} from "src/interfaces/yb/IGaugeController.sol";

/**
 * @title YieldBasisSetup
 * @notice Abstract base test setup for Yield Basis strategies with shared tests
 * @dev Both LT and Gauge strategies inherit from this to run all shared tests
 */
abstract contract YieldBasisSetup is Setup {
    // Factory
    YieldBasisStrategyFactory public factory;

    // Market references
    address public ltToken;
    address public gauge;
    address public cryptopool;

    // Test params (override Setup defaults for BTC decimals)
    uint256 public constant RELATIVE_APPROX = 1e3; // 0.1%

    /**
     * @notice Abstract method that children must implement to deploy their specific strategy
     * @return address of deployed strategy
     */
    function deployStrategy() internal virtual returns (address);

    function setUp() public virtual override {
        // Fork mainnet at specific block
        vm.createSelectFork(vm.envString("ETH_RPC_URL"));

        // Setup accounts
        management = makeAddr("management");
        keeper = makeAddr("keeper");
        user = makeAddr("user");

        // Deploy factory (no default swap router for tests)
        factory = new YieldBasisStrategyFactory(address(0));

        // Set market (default to WBTC, override in specific tests)
        setMarket(
            Constants.WBTC,
            Constants.WBTC_LT,
            Constants.WBTC_STAKER,
            Constants.WBTC_POOL
        );

        // Add debt limit to LTs
        vm.startPrank(ILT(Constants.WBTC_LT).admin());
        deal(Constants.CRVUSD, Constants.YB_FACTORY, 1_000_000_000e18);
        ILT(Constants.WBTC_LT).allocate_stablecoins(300_000_000e18);
        ILT(Constants.CBBTC_LT).allocate_stablecoins(300_000_000e18);
        ILT(Constants.TBTC_LT).allocate_stablecoins(300_000_000e18);
        vm.stopPrank();

        gauge = Constants.WBTC_STAKER;
        IGaugeController gc = IGaugeController(Constants.GAUGE_CONTROLLER);
        if (gc.time_weight(gauge) == 0) {
            vm.prank(gc.owner());
            gc.add_gauge(gauge);
        }

        // Deploy strategy using abstract method
        strategy = IStrategyInterface(setUpStrategy());

        // Label addresses for traces
        vm.label(management, "management");
        vm.label(keeper, "keeper");
        vm.label(user, "user");
        vm.label(address(strategy), "strategy");
        vm.label(address(asset), "asset");
        vm.label(performanceFeeRecipient, "performanceFeeRecipient");
    }

    /**
     * @notice Override Setup's setUpStrategy to use child's deployStrategy
     */
    function setUpStrategy() public override returns (address) {
        return deployStrategy();
    }

    /**
     * @notice Set the market to test against
     * @param _asset Asset token address
     * @param _ltToken LT token address
     * @param _gauge Gauge (staker) address
     * @param _cryptopool Curve pool address
     */
    function setMarket(
        address _asset,
        address _ltToken,
        address _gauge,
        address _cryptopool
    ) internal {
        asset = ERC20(_asset);
        ltToken = _ltToken;
        gauge = _gauge;
        cryptopool = _cryptopool;

        // Set test amounts based on asset decimals
        decimals = asset.decimals();
        minFuzzAmount = 10 ** (decimals - 3); // 0.001 of asset
        maxFuzzAmount = 10 * 10 ** decimals; // 10 of asset
    }

    /**
     * @notice Helper assertion for relative approximation
     */
    function assertRelApproxEq(
        uint256 a,
        uint256 b,
        uint256 maxPercentDelta
    ) internal {
        uint256 delta = a > b ? a - b : b - a;
        uint256 maxRelDelta = b / maxPercentDelta;

        if (delta > maxRelDelta) {
            emit log("Error: a ~= b not satisfied [uint]");
            emit log_named_uint("  Expected", b);
            emit log_named_uint("    Actual", a);
            emit log_named_uint(" Max Delta", maxRelDelta);
            emit log_named_uint("     Delta", delta);
            fail();
        }
    }

    // ===== SHARED TESTS (run on both LT and Gauge strategies) =====

    function test_setupStrategyOK() public virtual {
        assertTrue(address(0) != address(strategy));
        assertEq(strategy.asset(), address(asset));
        assertEq(strategy.management(), management);
        assertEq(strategy.keeper(), keeper);
    }

    function test_operation(uint256 _amount) public virtual {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

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
    ) public virtual {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);
        _profitFactor = uint16(bound(uint256(_profitFactor), 10, MAX_BPS));

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        // Earn Interest
        skip(1 days);

        // Simulate earning interest
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
    ) public virtual {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);
        _profitFactor = uint16(bound(uint256(_profitFactor), 10, MAX_BPS));

        // Set protocol fee to 0 and perf fee to 10%
        setFees(0, 1_000);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        // Earn Interest
        skip(1 days);

        // Simulate earning interest
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

    function test_tendTrigger(uint256 _amount) public virtual {
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
}
