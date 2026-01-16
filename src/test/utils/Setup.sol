// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import "forge-std/console.sol";
import {ExtendedTest} from "./ExtendedTest.sol";
import {IBaseHealthCheck} from "@periphery/Bases/HealthCheck/IBaseHealthCheck.sol";
import {StrategyYBSStaker, ERC20} from "../../Strategy.sol";
import {Swapper} from "../../periphery/Swapper.sol";
import {IYBSRegistry, IYBSFactory} from "../../interfaces/ybs/IYBSRegistry.sol";
import {IYearnBoostedStaker} from "../../interfaces/ybs/IYearnBoostedStaker.sol";
import {IRewardsDistributor} from "../../interfaces/ybs/IRewardsDistributor.sol";
import {IYBSUtilities} from "../../interfaces/ybs/IYBSUtilities.sol";
import {ISwapper} from "../../interfaces/utils/ISwapper.sol";
import {IStrategyInterface} from "../../interfaces/IStrategyInterface.sol";
import {ICurve} from "../../interfaces/curve/ICurve.sol";
import {ICurveInt128} from "../../interfaces/curve/ICurveInt128.sol";
import {IVault} from "@yearn-vaults/interfaces/IVault.sol";

// Inherit the events so they can be checked if desired.
import {IEvents} from "@tokenized-strategy/interfaces/IEvents.sol";

interface IFactory {
    function governance() external view returns (address);
    function set_protocol_fee_bps(uint16) external;
    function set_protocol_fee_recipient(address) external;
}

interface ICurveNG {
    function add_liquidity(uint256[] memory _amounts, uint256 _min_mint_amount, address _receiver) external returns (uint256);
}

contract Setup is ExtendedTest, IEvents {

    uint256 mainnetFork;

    // Contract instances that we will use repeatedly.
    ERC20 public asset;
    IStrategyInterface public strategy;
    ISwapper public swapper;

    mapping(string => address) public tokenAddrs;

    // Addresses for different roles we will use repeatedly.
    address public user = address(0x1F6f16945e395593d8050d6Cc33e4328a515B648);
    address public keeper = address(4);
    address public management = address(1);
    address public performanceFeeRecipient = address(3);

    // Address of the real deployed Factory
    address public factory;

    // Integer variables that will be used repeatedly.
    uint256 public decimals;
    uint256 public MAX_BPS = 10_000;

    // Fuzz from $0.01 of 1e6 stable coins up to 1 trillion of a 1e18 coin
    uint256 public maxFuzzAmount = 1e30;
    uint256 public minFuzzAmount = 10_000;

    // Default profit max unlock time is set for 10 days
    uint256 public profitMaxUnlockTime = 10 days;

    IYearnBoostedStaker public ybs;
    IRewardsDistributor public rewards;
    IYBSUtilities public utils;

    function setUp() public virtual {
        mainnetFork = vm.createFork(vm.envString("ETH_RPC_URL"));
        vm.selectFork(mainnetFork);

        _setTokenAddrs();
        asset = ERC20(tokenAddrs["YYB"]);

        // Set asset
        asset = ERC20(tokenAddrs["YYB"]);

        // Set decimals
        decimals = asset.decimals();

        // Deploy strategy and set variables
        strategy = IStrategyInterface(setUpStrategy());

        factory = strategy.FACTORY();

        // label all the used addresses for traces
        vm.label(keeper, "keeper");
        vm.label(factory, "factory");
        vm.label(address(asset), "asset");
        vm.label(management, "management");
        vm.label(address(strategy), "strategy");
        vm.label(performanceFeeRecipient, "performanceFeeRecipient");
        vm.label(address(swapper), "swapper");
        vm.label(address(rewards), "rewards");
        vm.label(address(ybs), "ybs");
        vm.label(swapper.pool1(), "pool1");
        vm.label(swapper.pool2(), "pool2");
    }

    function setUpStrategy() public returns (address) {
        // we save the strategy as a IStrategyInterface to give it the needed interface
        address allocatorVault = 0x1F6f16945e395593d8050d6Cc33e4328a515B648;

        IYBSRegistry registry = IYBSRegistry(0x262be1d31d0754399d8d5dc63B99c22146E9f738);
        (address ybsAddress, address rewardsAddress, address utilsAddress) = registry.deployments(
            address(asset)
        );
        if (ybsAddress == address(0)){
            address owner = IYBSRegistry(0x262be1d31d0754399d8d5dc63B99c22146E9f738).owner();
            vm.prank(owner);
            (ybsAddress, rewardsAddress, utilsAddress) = registry.createNewDeployment(
                address(asset), 
                4, 
                0, 
                tokenAddrs["YVCRVUSD"]
            );
        }


        ybs = IYearnBoostedStaker(ybsAddress);
        rewards = IRewardsDistributor(rewardsAddress);
        utils = IYBSUtilities(utilsAddress);

        _addLiquidity();

        swapper = ISwapper(address(new Swapper(
            management,                    // management
            ERC20(tokenAddrs["CRVUSD"]),   // token in
            ERC20(asset),                 // token out
            ICurve(0xec977F46467a3021785Cff88894886E617abd65b), // pool 1 crvUSD/YB
            ERC20(tokenAddrs["YB"]),  // token out pool 1
            ICurveInt128(0x5Ee9606e5611Fd6CE14BD2BC12db70BD53dC9daA) // pool 2 YB/YYB
        )));

        IStrategyInterface _strategy = IStrategyInterface(
            address(
                new StrategyYBSStaker(
                    address(asset), 
                    "Tokenized Strategy",
                    allocatorVault,
                    ybs,
                    rewards,
                    swapper,
                    1e18,
                    1_000_000e18
                )
            )
        );

        IBaseHealthCheck(address(_strategy)).setProfitLimitRatio(type(uint16).max);

        // set keeper
        _strategy.setKeeper(keeper);
        // set treasury
        _strategy.setPerformanceFeeRecipient(performanceFeeRecipient);
        // set management of the strategy
        _strategy.setPendingManagement(management);

        vm.prank(management);
        _strategy.acceptManagement();

        return address(_strategy);
    }

    function disableHealthCheck(address _strategy) public {
        vm.prank(management);
        IBaseHealthCheck(address(_strategy)).setDoHealthCheck(false);
    }

    function _addLiquidity() internal {
        uint256 amount = 100_000_000e18;
        deal(tokenAddrs["YB"], address(this), amount);
        deal(tokenAddrs["YYB"], address(this), amount);
        ICurveNG pool = ICurveNG(0x5Ee9606e5611Fd6CE14BD2BC12db70BD53dC9daA);
        ERC20(tokenAddrs["YB"]).approve(address(pool), type(uint).max);
        ERC20(tokenAddrs["YYB"]).approve(address(pool), type(uint).max);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = amount;
        amounts[1] = amount;
        pool.add_liquidity(amounts, 0, address(this));
    }

    function depositIntoStrategy(
        IStrategyInterface _strategy,
        address _user,
        uint256 _amount
    ) public {
        vm.prank(_user);
        asset.approve(address(_strategy), _amount);

        vm.prank(_user);
        _strategy.deposit(_amount, _user);
    }

    function mintAndDepositIntoStrategy(
        IStrategyInterface _strategy,
        address _user,
        uint256 _amount
    ) public {
        airdrop(asset, _user, _amount);
        depositIntoStrategy(_strategy, _user, _amount);
    }

    // For checking the amounts in the strategy
    function checkStrategyTotals(
        IStrategyInterface _strategy,
        uint256 _totalAssets,
        uint256 _totalDebt,
        uint256 _totalIdle
    ) public view {
        uint256 _assets = _strategy.totalAssets();
        uint256 _balance = ERC20(_strategy.asset()).balanceOf(
            address(_strategy)
        );
        uint256 _idle = _balance > _assets ? _assets : _balance;
        uint256 _debt = _assets - _idle;
        assertEq(_assets, _totalAssets, "!totalAssets");
        assertEq(_debt, _totalDebt, "!totalDebt");
        assertEq(_idle, _totalIdle, "!totalIdle");
        assertEq(_totalAssets, _totalDebt + _totalIdle, "!Added");
    }

    function airdrop(ERC20 _asset, address _to, uint256 _amount) public {
        uint256 balanceBefore = _asset.balanceOf(_to);
        deal(address(_asset), _to, balanceBefore + _amount);
    }

    /// @notice Mint reward vault tokens by depositing underlying (properly backed shares)
    /// @param _to Recipient of the vault shares
    /// @param _amount Amount of underlying to deposit (receives equivalent shares)
    /// @return shares Amount of vault shares minted
    function mintRewardTokens(address _to, uint256 _amount) public returns (uint256 shares) {
        address rewardVault = rewards.rewardToken();
        address underlying = strategy.rewardTokenUnderlying();

        // Check deposit limit
        uint256 available = IVault(rewardVault).deposit_limit() - IVault(rewardVault).totalAssets();
        if (_amount > available) return 0;

        // Deal underlying to this contract and deposit to vault
        deal(underlying, address(this), _amount);
        ERC20(underlying).approve(rewardVault, _amount);
        shares = IVault(rewardVault).deposit(_amount, _to);
    }

    function setFees(uint16 _protocolFee, uint16 _performanceFee) public {
        address gov = IFactory(factory).governance();

        // Need to make sure there is a protocol fee recipient to set the fee.
        vm.prank(gov);
        IFactory(factory).set_protocol_fee_recipient(gov);

        vm.prank(gov);
        IFactory(factory).set_protocol_fee_bps(_protocolFee);

        vm.prank(management);
        strategy.setPerformanceFee(_performanceFee);
    }

    function depositRewards(uint _amount) public {
        // Deposit some rewards
        deal(tokenAddrs["YVCRVUSD"], address(this), _amount);
        ERC20 reward = ERC20(tokenAddrs["YVCRVUSD"]);
        reward.approve(address(rewards), type(uint).max);
        rewards.depositReward(_amount);
        uint week = rewards.getWeek();
        uint amtAtWeek = rewards.weeklyRewardAmount(week);
        assertGt(amtAtWeek, 0, "Zero rewards");
        assertEq(amtAtWeek, _amount, "Unmatching rewards");
    }

    function _setTokenAddrs() internal {
        tokenAddrs["WBTC"] = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
        tokenAddrs["YFI"] = 0x0bc529c00C6401aEF6D220BE8C6Ea1667F6Ad93e;
        tokenAddrs["WETH"] = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
        tokenAddrs["LINK"] = 0x514910771AF9Ca656af840dff83E8264EcF986CA;
        tokenAddrs["USDT"] = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
        tokenAddrs["DAI"] = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
        tokenAddrs["USDC"] = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
        tokenAddrs["YPRISMA"] = 0xe3668873D944E4A949DA05fc8bDE419eFF543882;
        tokenAddrs["YCRV"] = 0x27B5739e22ad9033bcBf192059122d163b60349D;
        tokenAddrs["CRVUSD"] = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;
        tokenAddrs["MKUSD"] = 0x4591DBfF62656E7859Afe5e45f6f47D3669fBB28;
        tokenAddrs["YVMKUSD"] = 0x04AeBe2e4301CdF5E9c57B01eBdfe4Ac4B48DD13;
        tokenAddrs["CRV"] = 0xD533a949740bb3306d119CC777fa900bA034cd52;
        tokenAddrs["PRISMA"] = 0xdA47862a83dac0c112BA89c6abC2159b95afd71C;
        tokenAddrs["YYB"] = 0x22222222aEA0076fCA927a3f44dc0B4FdF9479D6;
        tokenAddrs["YB"] = 0x01791F726B4103694969820be083196cC7c045fF;
        tokenAddrs["YVCRVUSD"] = 0xBF319dDC2Edc1Eb6FDf9910E39b37Be221C8805F;
    }
}
