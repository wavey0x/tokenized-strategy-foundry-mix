// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import "forge-std/console2.sol";
import {Test} from "forge-std/Test.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IStrategyInterface} from "../../interfaces/IStrategyInterface.sol";
import {ILT} from "../../interfaces/yb/ILT.sol";
import {IGaugeController} from "../../interfaces/yb/IGaugeController.sol";
import {Constants} from "../utils/Constants.sol";
import {IYearnVaultFactory} from "../../interfaces/IYearnVaultFactory.sol";

// Inherit the events so they can be checked if desired.
import {IEvents} from "@tokenized-strategy/interfaces/IEvents.sol";

interface IFactory {
    function governance() external view returns (address);

    function set_protocol_fee_bps(uint16) external;

    function set_protocol_fee_recipient(address) external;
}

contract Setup is Test, IEvents {
    // Contract instances that we will use repeatedly.
    ERC20 public asset;
    IStrategyInterface public strategy;

    mapping(string => address) public tokenAddrs;

    // Addresses for different roles we will use repeatedly.
    address public user = address(10);
    address public keeper = address(4);
    address public management = address(1);
    address public performanceFeeRecipient = address(3);
    address public emergencyAdmin = address(5);

    // Integer variables that will be used repeatedly.
    uint256 public decimals;
    uint256 public MAX_BPS = 10_000;

    // Fuzz from $0.01 of 1e6 stable coins up to 1 trillion of a 1e18 coin
    uint256 public maxFuzzAmount = 1e30;
    uint256 public minFuzzAmount = 10_000;

    // Default profit max unlock time is set for 10 days
    uint256 public profitMaxUnlockTime = 10 days;

    // Set Yearn Vault Factory (already deployed on mainnet)
    IYearnVaultFactory public yearnVaultFactory = IYearnVaultFactory(Constants.YEARN_VAULT_FACTORY);

    function setUp() public virtual {
        _setTokenAddrs();
        _configureYB();

        // Set asset - WBTC for YB strategies
        asset = ERC20(tokenAddrs["WBTC"]);

        // Set decimals
        decimals = asset.decimals();
    }

    function setUpStrategy() public virtual returns (IStrategyInterface) {
        // Child contracts must override this
        revert("Must override setUpStrategy");
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
    ) public virtual {
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

    function _setTokenAddrs() internal {
        tokenAddrs["WBTC"] = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
        tokenAddrs["YFI"] = 0x0bc529c00C6401aEF6D220BE8C6Ea1667F6Ad93e;
        tokenAddrs["WETH"] = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
        tokenAddrs["LINK"] = 0x514910771AF9Ca656af840dff83E8264EcF986CA;
        tokenAddrs["USDT"] = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
        tokenAddrs["DAI"] = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
        tokenAddrs["USDC"] = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    }

    /**
     * @notice Configure Yield Basis protocol for testing
     * @dev Allocates stablecoins to LTs and adds gauge to controller
     */
    function _configureYB() internal {
        vm.startPrank(ILT(Constants.WBTC_LT).admin());
        uint256 TOTAL_CRVUSD = 100_000_000_000e18;
        deal(Constants.CRVUSD, Constants.YB_FACTORY, TOTAL_CRVUSD); // 100B crvUSD
        ILT(Constants.WBTC_LT).allocate_stablecoins(TOTAL_CRVUSD / 3);   // 30B per LT
        ILT(Constants.CBBTC_LT).allocate_stablecoins(TOTAL_CRVUSD / 3);
        ILT(Constants.TBTC_LT).allocate_stablecoins(TOTAL_CRVUSD / 3);
        vm.stopPrank();

        IGaugeController gc = IGaugeController(Constants.GAUGE_CONTROLLER);
        address gaugeToAdd = Constants.WBTC_STAKER;
        if (gc.time_weight(gaugeToAdd) == 0) {
            vm.prank(gc.owner());
            gc.add_gauge(gaugeToAdd);
        }
    }
}
