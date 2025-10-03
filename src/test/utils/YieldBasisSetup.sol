// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IStrategy} from "@tokenized-strategy/interfaces/IStrategy.sol";

import {YieldBasisLTStrategy} from "../../YieldBasisLTStrategy.sol";
import {YieldBasisGaugeStrategy} from "../../YieldBasisGaugeStrategy.sol";
import {YieldBasisStrategyFactory} from "../../YieldBasisStrategyFactory.sol";
import {Constants} from "../Constants.sol";

/**
 * @title YieldBasisSetup
 * @notice Base test setup for Yield Basis strategies with mainnet forking
 */
contract YieldBasisSetup is Test {
    // Strategies
    YieldBasisLTStrategy public ltStrategy;
    YieldBasisGaugeStrategy public gaugeStrategy;
    YieldBasisStrategyFactory public factory;

    // Market references
    ERC20 public asset;
    address public ltToken;
    address public gauge;
    address public cryptopool;

    // Actors
    address public management;
    address public keeper;
    address public user;

    // Test params
    uint256 public minFuzzAmount;
    uint256 public maxFuzzAmount;
    uint256 public constant RELATIVE_APPROX = 1e3; // 0.1%

    function setUp() public virtual {
        // Use existing fork (created via --fork-url in command line)

        // Setup accounts
        management = makeAddr("management");
        keeper = makeAddr("keeper");
        user = makeAddr("user");

        // Deploy factory
        factory = new YieldBasisStrategyFactory(address(0)); // No default router

        // Set market (default to WBTC, override in specific tests)
        setMarket(
            Constants.WBTC,
            Constants.WBTC_LT,
            Constants.WBTC_STAKER,
            Constants.WBTC_POOL
        );
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
        uint256 decimals = asset.decimals();
        minFuzzAmount = 10 ** (decimals - 3); // 0.001 of asset
        maxFuzzAmount = 10 * 10 ** decimals; // 10 of asset
    }

    /**
     * @notice Deploy LT strategy for current market
     * @param _name Strategy name
     * @return Deployed LT strategy
     */
    function deployLTStrategy(string memory _name)
        internal
        returns (YieldBasisLTStrategy)
    {
        address deployed = factory.deployLTStrategy(
            address(asset),
            ltToken,
            cryptopool,
            _name
        );

        YieldBasisLTStrategy strat = YieldBasisLTStrategy(deployed);

        // Set management and keeper
        vm.prank(address(factory));
        IStrategy(address(strat)).setPendingManagement(management);

        vm.prank(management);
        IStrategy(address(strat)).acceptManagement();

        vm.prank(management);
        IStrategy(address(strat)).setKeeper(keeper);

        return strat;
    }

    /**
     * @notice Deploy Gauge strategy for current market
     * @param _name Strategy name
     * @param _swapType Initial swap type
     * @return Deployed Gauge strategy
     */
    function deployGaugeStrategy(
        string memory _name,
        YieldBasisGaugeStrategy.SwapType _swapType
    ) internal returns (YieldBasisGaugeStrategy) {
        address deployed = factory.deployGaugeStrategy(
            address(asset),
            ltToken,
            gauge,
            cryptopool,
            _name,
            address(0) // No router initially
        );

        YieldBasisGaugeStrategy strat = YieldBasisGaugeStrategy(deployed);

        // Set management and keeper
        vm.prank(address(factory));
        IStrategy(address(strat)).setPendingManagement(management);

        vm.prank(management);
        IStrategy(address(strat)).acceptManagement();

        vm.prank(management);
        IStrategy(address(strat)).setKeeper(keeper);

        return strat;
    }

    /**
     * @notice Deal asset tokens to an address
     * @param _to Recipient address
     * @param _amount Amount to deal
     */
    function dealAsset(address _to, uint256 _amount) internal {
        deal(address(asset), _to, _amount);
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
}
