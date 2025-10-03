// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {YieldBasisLTStrategy} from "./YieldBasisLTStrategy.sol";
import {YieldBasisGaugeStrategy} from "./YieldBasisGaugeStrategy.sol";
import {RewardsSwapper} from "./RewardsSwapper.sol";
import {ILT} from "./interfaces/yb/ILT.sol";
import {ILiquidityGauge} from "./interfaces/yb/ILiquidityGauge.sol";

/**
 * @title YieldBasisStrategyFactory
 * @author Yearn Finance
 * @notice Factory for deploying paired Yield Basis strategies
 * @dev Deploys both LT (fee-earning) and Gauge (emission-earning) strategies together
 *
 * This factory ensures consistent deployment and configuration of the two complementary
 * Yield Basis strategies:
 * 1. YieldBasisLTStrategy - Holds LT tokens, earns trading fees
 * 2. YieldBasisGaugeStrategy - Stakes LT in gauge, earns YB emissions
 */
contract YieldBasisStrategyFactory {
    // ===== STRUCTS =====

    struct StrategyPair {
        address ltStrategy;
        address gaugeStrategy;
        address asset;
        address ltToken;
        address gauge;
        uint256 deployedAt;
    }

    // ===== STATE =====

    /// @notice Mapping from asset + ltToken to deployed strategy pair
    mapping(address => mapping(address => StrategyPair)) public strategies;

    /// @notice Array of all deployed strategy pairs
    StrategyPair[] public allStrategies;

    /// @notice Default swap router for YB token swaps
    address public defaultSwapRouter;

    /// @notice Factory owner
    address public owner;

    // ===== EVENTS =====

    event StrategyPairDeployed(
        address indexed asset,
        address indexed ltToken,
        address ltStrategy,
        address gaugeStrategy,
        uint256 timestamp
    );

    event LTStrategyDeployed(
        address indexed asset,
        address indexed ltToken,
        address ltStrategy,
        uint256 timestamp
    );

    event GaugeStrategyDeployed(
        address indexed asset,
        address indexed ltToken,
        address gaugeStrategy,
        uint256 timestamp
    );

    event SwapRouterUpdated(address newRouter);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    // ===== CONSTRUCTOR =====

    /**
     * @notice Initialize the factory
     * @param _swapRouter Default swap router for YB swaps
     */
    constructor(address _swapRouter) {
        defaultSwapRouter = _swapRouter;
        owner = msg.sender;
    }

    // ===== DEPLOYMENT FUNCTIONS =====

    /**
     * @notice Deploy both LT and Gauge strategies together
     * @param _asset Underlying asset (WBTC, cbBTC, etc.)
     * @param _ltToken Yield Basis LT contract
     * @param _gauge Liquidity Gauge contract
     * @param _cryptopool Curve cryptopool address
     * @param _ltName Name for LT strategy
     * @param _gaugeName Name for Gauge strategy
     * @return ltStrategy Address of deployed LT strategy
     * @return gaugeStrategy Address of deployed Gauge strategy
     *
     * This is the primary deployment method. It ensures both strategies are
     * deployed together and properly configured.
     */
    function deployStrategies(
        address _asset,
        address _ltToken,
        address _gauge,
        address _cryptopool,
        string memory _ltName,
        string memory _gaugeName
    ) external returns (address ltStrategy, address gaugeStrategy) {
        return deployStrategies(
            _asset,
            _ltToken,
            _gauge,
            _cryptopool,
            _ltName,
            _gaugeName,
            defaultSwapRouter
        );
    }

    /**
     * @notice Deploy both strategies with custom swap router
     * @param _asset Underlying asset (WBTC, cbBTC, etc.)
     * @param _ltToken Yield Basis LT contract
     * @param _gauge Liquidity Gauge contract
     * @param _cryptopool Curve cryptopool address
     * @param _ltName Name for LT strategy
     * @param _gaugeName Name for Gauge strategy
     * @param _swapRouter Custom swap router for this deployment
     * @return ltStrategy Address of deployed LT strategy
     * @return gaugeStrategy Address of deployed Gauge strategy
     */
    function deployStrategies(
        address _asset,
        address _ltToken,
        address _gauge,
        address _cryptopool,
        string memory _ltName,
        string memory _gaugeName,
        address _swapRouter
    ) public returns (address ltStrategy, address gaugeStrategy) {
        // Verify not already deployed
        require(
            strategies[_asset][_ltToken].ltStrategy == address(0),
            "Strategies already deployed"
        );

        // Verify contracts match
        require(ILT(_ltToken).ASSET_TOKEN() == _asset, "LT asset mismatch");
        require(
            ILiquidityGauge(_gauge).LP_TOKEN() == _ltToken,
            "Gauge LP mismatch"
        );

        // Deploy LT strategy
        YieldBasisLTStrategy ltStrat = new YieldBasisLTStrategy(
            _asset,
            _ltName,
            _ltToken,
            _cryptopool
        );

        YieldBasisGaugeStrategy gaugeStrat = new YieldBasisGaugeStrategy(
            _asset,
            _gaugeName,
            _ltToken,
            _gauge,
            _cryptopool
        );

        ltStrategy = address(ltStrat);
        gaugeStrategy = address(gaugeStrat);

        // Deploy default RewardsSwapper (permissionless)
        // Note: msg.sender (factory caller) becomes the initial management of the swapper
        // They can transfer it later if needed
        RewardsSwapper swapper = new RewardsSwapper(
            _asset,         // All rewards swap to asset
            msg.sender      // Factory caller can configure routes initially
        );

        // Set the swapper on the gauge strategy
        gaugeStrat.setRewardsSwapper(address(swapper));

        // Store deployment
        StrategyPair memory pair = StrategyPair({
            ltStrategy: ltStrategy,
            gaugeStrategy: gaugeStrategy,
            asset: _asset,
            ltToken: _ltToken,
            gauge: _gauge,
            deployedAt: block.timestamp
        });

        strategies[_asset][_ltToken] = pair;
        allStrategies.push(pair);

        emit StrategyPairDeployed(
            _asset,
            _ltToken,
            ltStrategy,
            gaugeStrategy,
            block.timestamp
        );
    }

    /**
     * @notice Deploy only LT strategy
     * @param _asset Underlying asset
     * @param _ltToken Yield Basis LT contract
     * @param _cryptopool Curve cryptopool address
     * @param _name Strategy name
     * @return ltStrategy Address of deployed strategy
     *
     * Use this if you only want the fee-earning strategy without YB emissions.
     */
    function deployLTStrategy(
        address _asset,
        address _ltToken,
        address _cryptopool,
        string memory _name
    ) external returns (address ltStrategy) {
        // Verify asset matches
        require(ILT(_ltToken).ASSET_TOKEN() == _asset, "Asset mismatch");

        // Deploy strategy
        YieldBasisLTStrategy strat = new YieldBasisLTStrategy(
            _asset,
            _name,
            _ltToken,
            _cryptopool
        );

        ltStrategy = address(strat);

        emit LTStrategyDeployed(_asset, _ltToken, ltStrategy, block.timestamp);
    }

    /**
     * @notice Deploy only Gauge strategy
     * @param _asset Underlying asset
     * @param _ltToken Yield Basis LT contract
     * @param _gauge Liquidity Gauge contract
     * @param _cryptopool Curve cryptopool address
     * @param _name Strategy name
     * @return gaugeStrategy Address of deployed strategy
     *
     * Use this if you only want the YB emission-earning strategy.
     */
    function deployGaugeStrategy(
        address _asset,
        address _ltToken,
        address _gauge,
        address _cryptopool,
        string memory _name
    ) external returns (address gaugeStrategy) {
        return deployGaugeStrategy(
            _asset,
            _ltToken,
            _gauge,
            _cryptopool,
            _name,
            defaultSwapRouter
        );
    }

    /**
     * @notice Deploy only Gauge strategy with custom swap router
     * @param _asset Underlying asset
     * @param _ltToken Yield Basis LT contract
     * @param _gauge Liquidity Gauge contract
     * @param _cryptopool Curve cryptopool address
     * @param _name Strategy name
     * @param _swapRouter Custom swap router
     * @return gaugeStrategy Address of deployed strategy
     */
    function deployGaugeStrategy(
        address _asset,
        address _ltToken,
        address _gauge,
        address _cryptopool,
        string memory _name,
        address _swapRouter
    ) public returns (address gaugeStrategy) {
        // Verify contracts match
        require(ILT(_ltToken).ASSET_TOKEN() == _asset, "LT asset mismatch");
        require(
            ILiquidityGauge(_gauge).LP_TOKEN() == _ltToken,
            "Gauge LP mismatch"
        );

        // Deploy strategy
        YieldBasisGaugeStrategy strat = new YieldBasisGaugeStrategy(
            _asset,
            _name,
            _ltToken,
            _gauge,
            _cryptopool
        );

        gaugeStrategy = address(strat);

        // Deploy default RewardsSwapper (permissionless)
        // Note: msg.sender (factory caller) becomes the initial management of the swapper
        RewardsSwapper swapper = new RewardsSwapper(
            _asset,         // All rewards swap to asset
            msg.sender      // Factory caller can configure routes initially
        );

        // Set the swapper on the gauge strategy
        strat.setRewardsSwapper(address(swapper));

        emit GaugeStrategyDeployed(
            _asset,
            _ltToken,
            gaugeStrategy,
            block.timestamp
        );
    }

    // ===== VIEW FUNCTIONS =====

    /**
     * @notice Get deployed strategy pair for asset and LT token
     * @param _asset Asset address
     * @param _ltToken LT token address
     * @return pair StrategyPair struct
     */
    function getStrategyPair(address _asset, address _ltToken)
        external
        view
        returns (StrategyPair memory pair)
    {
        return strategies[_asset][_ltToken];
    }

    /**
     * @notice Get total number of deployed strategy pairs
     * @return count Number of pairs
     */
    function strategyCount() external view returns (uint256) {
        return allStrategies.length;
    }

    /**
     * @notice Get strategy pair by index
     * @param _index Index in allStrategies array
     * @return pair StrategyPair struct
     */
    function getStrategyByIndex(uint256 _index)
        external
        view
        returns (StrategyPair memory pair)
    {
        require(_index < allStrategies.length, "Index out of bounds");
        return allStrategies[_index];
    }

    /**
     * @notice Check if strategies exist for asset and LT token
     * @param _asset Asset address
     * @param _ltToken LT token address
     * @return exists True if strategies deployed
     */
    function strategiesExist(address _asset, address _ltToken)
        external
        view
        returns (bool)
    {
        return strategies[_asset][_ltToken].ltStrategy != address(0);
    }

    // ===== MANAGEMENT FUNCTIONS =====

    /**
     * @notice Update default swap router
     * @param _newRouter New swap router address
     */
    function setDefaultSwapRouter(address _newRouter) external onlyOwner {
        require(_newRouter != address(0), "Zero address");
        defaultSwapRouter = _newRouter;
        emit SwapRouterUpdated(_newRouter);
    }

    /**
     * @notice Transfer factory ownership
     * @param _newOwner New owner address
     */
    function transferOwnership(address _newOwner) external onlyOwner {
        require(_newOwner != address(0), "Zero address");
        address oldOwner = owner;
        owner = _newOwner;
        emit OwnershipTransferred(oldOwner, _newOwner);
    }

    // ===== MODIFIERS =====

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }
}