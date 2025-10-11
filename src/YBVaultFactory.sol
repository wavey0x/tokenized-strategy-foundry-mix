// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {YBRouterStrategy} from "./YBRouterStrategy.sol";
import {YBGaugeStrategy} from "./YBGaugeStrategy.sol";
import {RewardsSwapper} from "./RewardsSwapper.sol";
import {ILT} from "./interfaces/yb/ILT.sol";
import {ILiquidityGauge} from "./interfaces/yb/ILiquidityGauge.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IStrategy} from "@tokenized-strategy/interfaces/IStrategy.sol";

/**
 * @title YBVaultFactory
 * @author Yearn Finance
 * @notice Factory for deploying Yield Basis strategies
 * @dev Supports two independent strategy types:
 *
 * NEW ARCHITECTURE:
 *
 * BTC Vault (user-facing)
 * └─ Router Strategy: BTC → LT → LT Vault deposit
 *
 * LT Vault (internal)
 * └─ Gauge Strategy: LT → Gauge staking → YB rewards
 *
 * These strategies are deployed independently and work with different assets.
 */
contract YBVaultFactory {
    // ===== STRUCTS =====

    struct RouterDeployment {
        address strategy;
        address btcVault;       // BTC vault that owns this strategy
        address ltVault;        // LT vault this strategy deposits into
        address asset;          // BTC asset
        address ltToken;        // LT token
        uint256 deployedAt;
    }

    struct GaugeDeployment {
        address strategy;
        address ltVault;        // LT vault that owns this strategy
        address ltToken;        // LT token (same as vault asset)
        address gauge;          // Gauge contract
        uint256 deployedAt;
    }

    // ===== STATE =====

    /// @notice Mapping from BTC vault to deployed router strategy
    mapping(address => RouterDeployment) public routerStrategies;

    /// @notice Mapping from LT vault to deployed gauge strategy
    mapping(address => GaugeDeployment) public gaugeStrategies;

    /// @notice Mapping from LT token to all associated strategies
    mapping(address => address[]) public strategiesByLT;

    /// @notice Array of all deployed router strategies
    RouterDeployment[] public allRouterStrategies;

    /// @notice Array of all deployed gauge strategies
    GaugeDeployment[] public allGaugeStrategies;

    /// @notice Default swap router for YB token swaps
    address public defaultSwapRouter;

    /// @notice Strategy management address
    address public management;

    /// @notice Performance fee recipient address
    address public performanceFeeRecipient;

    /// @notice Keeper address for strategy automation
    address public keeper;

    /// @notice Immutable emergency admin address
    address public immutable emergencyAdmin;

    // ===== EVENTS =====

    event RouterStrategyDeployed(
        address indexed btcVault,
        address indexed ltVault,
        address indexed strategy,
        address asset,
        address ltToken,
        uint256 timestamp
    );

    event GaugeStrategyDeployed(
        address indexed ltVault,
        address indexed strategy,
        address ltToken,
        address gauge,
        uint256 timestamp
    );

    event SwapRouterUpdated(address newRouter);
    event ManagementTransferred(address indexed previousManagement, address indexed newManagement);

    // ===== CONSTRUCTOR =====

    /**
     * @notice Initialize the factory
     * @param _management Management address for deployed strategies
     * @param _performanceFeeRecipient Performance fee recipient address
     * @param _keeper Keeper address for strategy automation
     * @param _emergencyAdmin Emergency admin address (immutable)
     * @param _swapRouter Default swap router for YB swaps
     */
    constructor(
        address _management,
        address _performanceFeeRecipient,
        address _keeper,
        address _emergencyAdmin,
        address _swapRouter
    ) {
        management = _management;
        performanceFeeRecipient = _performanceFeeRecipient;
        keeper = _keeper;
        emergencyAdmin = _emergencyAdmin;
        defaultSwapRouter = _swapRouter;
    }

    // ===== DEPLOYMENT FUNCTIONS =====

    /**
     * @notice Deploy Router strategy (BTC → LT → LT Vault)
     * @param _btcVault BTC vault that will own this strategy (pre-deployed)
     * @param _ltVault LT vault this strategy will deposit into (pre-deployed)
     * @param _ltToken Yield Basis LT contract address
     * @return strategy Address of deployed Router strategy
     *
     * Assumes both vaults are already deployed. Router strategy converts BTC to LT
     * and deposits into the LT vault.
     */
    function deployRouterStrategy(
        address _btcVault,
        address _ltVault,
        address _ltToken
    ) external returns (address strategy) {
        // Get BTC asset from LT contract
        address btcAsset = ILT(_ltToken).ASSET_TOKEN();

        // Validate vaults
        _validateVault(_btcVault, btcAsset);  // BTC vault should have BTC as asset
        _validateVault(_ltVault, _ltToken);   // LT vault should have LT as asset

        // Auto-generate strategy name from LT token symbol
        string memory ltSymbol = ERC20(_ltToken).symbol();
        string memory strategyName = string(abi.encodePacked("YB Router ", ltSymbol));

        // Deploy Router strategy
        strategy = address(new YBRouterStrategy(
            btcAsset,
            strategyName,
            _ltToken,
            _ltVault,
            _btcVault
        ));

        // Configure strategy
        _configureStrategy(strategy);

        // Store deployment
        RouterDeployment memory deployment = RouterDeployment({
            strategy: strategy,
            btcVault: _btcVault,
            ltVault: _ltVault,
            asset: btcAsset,
            ltToken: _ltToken,
            deployedAt: block.timestamp
        });

        routerStrategies[_btcVault] = deployment;
        allRouterStrategies.push(deployment);
        strategiesByLT[_ltToken].push(strategy);

        emit RouterStrategyDeployed(
            _btcVault,
            _ltVault,
            strategy,
            btcAsset,
            _ltToken,
            block.timestamp
        );
    }

    /**
     * @notice Deploy Gauge strategy (LT → Gauge staking)
     * @param _ltVault LT vault that will own this strategy (pre-deployed)
     * @param _gauge Liquidity Gauge contract
     * @return strategy Address of deployed Gauge strategy
     *
     * Assumes LT vault is already deployed. Gauge strategy stakes LT in the gauge
     * and earns YB rewards.
     */
    function deployGaugeStrategy(
        address _ltVault,
        address _gauge
    ) external returns (address strategy) {
        // Get LT token from vault
        address ltToken = ERC4626(_ltVault).asset();

        // Validate vault
        _validateVault(_ltVault, ltToken);

        // Verify gauge accepts this LT token
        require(
            ILiquidityGauge(_gauge).LP_TOKEN() == ltToken,
            "Gauge LP mismatch"
        );

        // Auto-generate strategy name from LT token symbol
        string memory ltSymbol = ERC20(ltToken).symbol();
        string memory strategyName = string(abi.encodePacked("YB Gauge ", ltSymbol));

        // Deploy Gauge strategy (LT is the asset!)
        strategy = address(new YBGaugeStrategy(
            ltToken,
            strategyName,
            _gauge,
            _ltVault
        ));

        // Configure strategy
        _configureStrategy(strategy);

        // Deploy and set RewardsSwapper
        {
            RewardsSwapper swapper = new RewardsSwapper(ltToken, management);
            YBGaugeStrategy(strategy).setRewardsSwapper(address(swapper));
        }

        // Store deployment
        GaugeDeployment memory deployment = GaugeDeployment({
            strategy: strategy,
            ltVault: _ltVault,
            ltToken: ltToken,
            gauge: _gauge,
            deployedAt: block.timestamp
        });

        gaugeStrategies[_ltVault] = deployment;
        allGaugeStrategies.push(deployment);
        strategiesByLT[ltToken].push(strategy);

        emit GaugeStrategyDeployed(
            _ltVault,
            strategy,
            ltToken,
            _gauge,
            block.timestamp
        );
    }

    // ===== VIEW FUNCTIONS =====

    /**
     * @notice Get deployed router strategy for a BTC vault
     * @param _btcVault BTC vault address
     * @return deployment RouterDeployment struct
     */
    function getRouterStrategy(address _btcVault)
        external
        view
        returns (RouterDeployment memory deployment)
    {
        return routerStrategies[_btcVault];
    }

    /**
     * @notice Get deployed gauge strategy for an LT vault
     * @param _ltVault LT vault address
     * @return deployment GaugeDeployment struct
     */
    function getGaugeStrategy(address _ltVault)
        external
        view
        returns (GaugeDeployment memory deployment)
    {
        return gaugeStrategies[_ltVault];
    }

    /**
     * @notice Get all strategies associated with an LT token
     * @param _ltToken LT token address
     * @return strategies Array of strategy addresses
     */
    function getStrategiesByLT(address _ltToken)
        external
        view
        returns (address[] memory strategies)
    {
        return strategiesByLT[_ltToken];
    }

    /**
     * @notice Get total number of deployed router strategies
     * @return count Number of router strategies
     */
    function routerStrategyCount() external view returns (uint256) {
        return allRouterStrategies.length;
    }

    /**
     * @notice Get total number of deployed gauge strategies
     * @return count Number of gauge strategies
     */
    function gaugeStrategyCount() external view returns (uint256) {
        return allGaugeStrategies.length;
    }

    /**
     * @notice Get router strategy by index
     * @param _index Index in allRouterStrategies array
     * @return deployment RouterDeployment struct
     */
    function getRouterStrategyByIndex(uint256 _index)
        external
        view
        returns (RouterDeployment memory deployment)
    {
        require(_index < allRouterStrategies.length, "Index out of bounds");
        return allRouterStrategies[_index];
    }

    /**
     * @notice Get gauge strategy by index
     * @param _index Index in allGaugeStrategies array
     * @return deployment GaugeDeployment struct
     */
    function getGaugeStrategyByIndex(uint256 _index)
        external
        view
        returns (GaugeDeployment memory deployment)
    {
        require(_index < allGaugeStrategies.length, "Index out of bounds");
        return allGaugeStrategies[_index];
    }

    /**
     * @notice Check if router strategy exists for a BTC vault
     * @param _btcVault BTC vault address
     * @return exists True if router strategy deployed
     */
    function routerStrategyExists(address _btcVault)
        external
        view
        returns (bool)
    {
        return routerStrategies[_btcVault].strategy != address(0);
    }

    /**
     * @notice Check if gauge strategy exists for an LT vault
     * @param _ltVault LT vault address
     * @return exists True if gauge strategy deployed
     */
    function gaugeStrategyExists(address _ltVault)
        external
        view
        returns (bool)
    {
        return gaugeStrategies[_ltVault].strategy != address(0);
    }

    // ===== CONVENIENCE FUNCTIONS =====

    /**
     * @notice Deploy both Router and Gauge strategies for a complete stack
     * @param _btcVault BTC vault (pre-deployed)
     * @param _ltVault LT vault (pre-deployed)
     * @param _gauge Gauge contract
     * @return routerStrategy Address of deployed Router strategy
     * @return gaugeStrategy Address of deployed Gauge strategy
     *
     * Convenience function to deploy full stack: BTC Vault → Router → LT Vault → Gauge
     */
    function deployBothStrategies(
        address _btcVault,
        address _ltVault,
        address _gauge
    ) external returns (address routerStrategy, address gaugeStrategy) {
        // Get LT token from LT vault
        address ltToken = ERC4626(_ltVault).asset();

        // Deploy Router strategy
        routerStrategy = this.deployRouterStrategy(_btcVault, _ltVault, ltToken);

        // Deploy Gauge strategy
        gaugeStrategy = this.deployGaugeStrategy(_ltVault, _gauge);
    }

    // ===== MANAGEMENT FUNCTIONS =====

    /**
     * @notice Update default swap router
     * @param _newRouter New swap router address
     */
    function setDefaultSwapRouter(address _newRouter) external onlyManagement {
        require(_newRouter != address(0), "Zero address");
        defaultSwapRouter = _newRouter;
        emit SwapRouterUpdated(_newRouter);
    }

    /**
     * @notice Update factory addresses for future deployments
     * @param _management New management address
     * @param _performanceFeeRecipient New performance fee recipient
     * @param _keeper New keeper address
     */
    function setAddresses(
        address _management,
        address _performanceFeeRecipient,
        address _keeper
    ) external onlyManagement {
        require(_management != address(0), "Zero management address");
        require(_performanceFeeRecipient != address(0), "Zero fee recipient");
        require(_keeper != address(0), "Zero keeper address");
        management = _management;
        performanceFeeRecipient = _performanceFeeRecipient;
        keeper = _keeper;
    }

    /**
     * @notice Transfer factory management
     * @param _newManagement New management address
     */
    function transferManagement(address _newManagement) external onlyManagement {
        require(_newManagement != address(0), "Zero address");
        address oldManagement = management;
        management = _newManagement;
        emit ManagementTransferred(oldManagement, _newManagement);
    }

    // ===== INTERNAL HELPERS =====

    /**
     * @notice Validate that a vault exists and has the expected asset
     * @param _vault Vault address to validate
     * @param _expectedAsset Expected asset for the vault
     */
    function _validateVault(address _vault, address _expectedAsset) internal view {
        require(_vault != address(0), "Vault is zero address");
        require(_vault.code.length > 0, "Vault has no code");

        // Verify vault asset matches expected
        address vaultAsset = ERC4626(_vault).asset();
        require(vaultAsset == _expectedAsset, "Vault asset mismatch");
    }

    /**
     * @notice Configure a newly deployed strategy with factory settings
     * @param _strategy Address of strategy to configure
     */
    function _configureStrategy(address _strategy) internal {
        IStrategy(_strategy).setPerformanceFeeRecipient(performanceFeeRecipient);
        IStrategy(_strategy).setKeeper(keeper);
        IStrategy(_strategy).setPendingManagement(management);
        IStrategy(_strategy).setEmergencyAdmin(emergencyAdmin);
        IStrategy(_strategy).setPerformanceFee(500); // 5% default
        IStrategy(_strategy).setProfitMaxUnlockTime(3 days); // 3 day unlock period
    }

    // ===== MODIFIERS =====

    modifier onlyManagement() {
        require(msg.sender == management, "Not management");
        _;
    }
}
