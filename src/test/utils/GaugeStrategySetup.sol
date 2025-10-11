// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {Setup, IStrategyInterface, ERC20} from "../utils/Setup.sol";
import {TestHelpers} from "../utils/TestHelpers.sol";
import {Constants} from "../utils/Constants.sol";
import {IStrategy} from "@tokenized-strategy/interfaces/IStrategy.sol";
import {YBVaultFactory} from "../../YBVaultFactory.sol";
import {YBGaugeStrategy} from "../../YBGaugeStrategy.sol";
import {ILT} from "src/interfaces/yb/ILT.sol";
import {ILiquidityGauge} from "src/interfaces/yb/ILiquidityGauge.sol";
import {IVault} from "@yearn-vaults/interfaces/IVault.sol";
import {IYearnVaultFactory} from "src/interfaces/IYearnVaultFactory.sol";

/**
 * @title GaugeStrategySetup
 * @notice Base test setup for YBGaugeStrategy tests
 * @dev Provides gauge-specific test infrastructure and helpers
 */
abstract contract GaugeStrategySetup is Setup, TestHelpers {
    // ===== CONTRACTS =====
    YBVaultFactory public factory;
    YBGaugeStrategy public gaugeStrategy;
    IVault public vault;
    ILT public lt;
    ILiquidityGauge public gauge;
    ERC20 public ybToken;

    // ===== MARKET REFERENCES =====
    address public ltToken = Constants.WBTC_LT;
    address public gaugeAddress = Constants.WBTC_STAKER;

    /**
     * @notice Setup function - initializes all contracts and configuration
     */
    function setUp() public virtual override {
        // Fork mainnet BEFORE calling super.setUp() (needed for _configureYB)
        vm.createSelectFork(vm.envString("ETH_RPC_URL"));

        // Call base setup (token addrs, YB config, asset setup)
        super.setUp();

        // Setup accounts
        management = makeAddr("management");
        keeper = makeAddr("keeper");
        user = makeAddr("user");
        performanceFeeRecipient = makeAddr("performanceFeeRecipient");

        // Deploy factory
        factory = new YBVaultFactory(
            management,
            performanceFeeRecipient,
            keeper,
            management, // emergencyAdmin
            address(0)  // no default swap router for tests
        );
        
        setUpStrategy();

        // Label addresses for traces
        vm.label(management, "management");
        vm.label(keeper, "keeper");
        vm.label(user, "user");
        vm.label(address(strategy), "strategy");
        vm.label(address(asset), "asset");
        vm.label(performanceFeeRecipient, "performanceFeeRecipient");
        vm.label(address(vault), "vault");
        vm.label(address(lt), "ltToken");
        vm.label(address(gauge), "gauge");
    }

    /**
     * @notice Deploy gauge strategy and associated contracts
     * @return Tuple of (strategy address, strategy address) to satisfy Setup interface
     */
    function setUpStrategy() public override returns (IStrategyInterface) {
        // Set asset to LT token (not BTC!)
        asset = ERC20(ltToken);
        decimals = asset.decimals(); // 18 for LT
        minFuzzAmount = 10 ** (decimals - 3); // 0.001 LT
        maxFuzzAmount = 100 * 10 ** decimals; // 100 LT
        lt = ILT(ltToken);

        // Step 1: Deploy LT Vault from Yearn Vault Factory
        string memory vaultSymbol = string(abi.encodePacked("yv", ERC20(ltToken).symbol()));
        vault = IVault(yearnVaultFactory.deploy_new_vault(
            ltToken,                   // asset (LT token)
            "Yearn LT Vault",          // name
            vaultSymbol,               // symbol
            management,                // role_manager
            10 days                    // profit_max_unlock_time
        ));

        // Step 2: Deploy Gauge strategy via factory
        address deployed = factory.deployGaugeStrategy(
            address(vault),    // LT vault that owns this strategy
            gaugeAddress       // Gauge contract
        );

        gaugeStrategy = YBGaugeStrategy(deployed);
        strategy = IStrategyInterface(deployed);
        gauge = ILiquidityGauge(gaugeStrategy.gauge());
        ybToken = ERC20(gauge.YB());

        // Step 3: Set up vault roles and attach strategy
        vm.startPrank(management);
        // Role bits: ADD_STRATEGY_MANAGER = 1, DEBT_MANAGER = 64, MAX_DEBT_MANAGER = 128, DEPOSIT_LIMIT_MANAGER = 256
        uint256 ADD_STRATEGY_MANAGER = 1;
        uint256 MAX_DEBT_MANAGER = 128;
        uint256 DEBT_MANAGER = 64;
        uint256 DEPOSIT_LIMIT_MANAGER = 256;
        vault.set_role(management, ADD_STRATEGY_MANAGER | MAX_DEBT_MANAGER | DEBT_MANAGER | DEPOSIT_LIMIT_MANAGER);
        vault.set_deposit_limit(type(uint256).max);
        vault.add_strategy(deployed);
        vault.update_max_debt_for_strategy(deployed, type(uint256).max);

        // Accept management and configure loss/profit limits
        strategy.acceptManagement();
        strategy.setLossLimitRatio(10_000 - 1);
        strategy.setProfitLimitRatio(10_000 - 1);
        vm.stopPrank();

        return strategy;
    }

    /**
     * @notice Override to use proper LT minting and deposit via vault
     * @param _strategy Strategy to deposit into
     * @param _user User address
     * @param _amount Amount to deposit
     */
    function mintAndDepositIntoStrategy(
        IStrategyInterface _strategy,
        address _user,
        uint256 _amount
    ) public override {
        // Convert LT-denominated fuzz amount into underlying BTC with a small buffer
        address btc = lt.ASSET_TOKEN();
        uint256 pricePerShare = lt.pricePerShare(); // 18 decimals
        uint256 assetAmount18 = (_amount * pricePerShare) / 1e18;
        uint256 btcAmount = descaleTokenDecimals(ERC20(btc), assetAmount18);
        if (btcAmount == 0) {
            btcAmount = 1;
        }
        btcAmount = (btcAmount * (MAX_BPS + 100)) / MAX_BPS; // +1% buffer to avoid shortfalls

        // Mint LT tokens properly (not via deal)
        uint256 ltAmount = _mintLTTokens(_user, btcAmount);

        // Deposit into vault (not directly to strategy)
        vm.startPrank(_user);
        asset.approve(address(vault), ltAmount);
        vault.deposit(ltAmount, _user);
        vm.stopPrank();

        // Allocate debt to strategy so funds flow through
        uint256 totalAssets = vault.totalAssets();
        vm.prank(management);
        vault.update_debt(address(_strategy), totalAssets);
    }

    /**
     * @notice Helper to mint LT tokens by depositing BTC into LT contract
     * @param _recipient Address to receive LT tokens
     * @param _btcAmount Amount of BTC to deposit (asset decimals, e.g. 8 for WBTC)
     * @return mintedLt Amount of LT tokens credited to the recipient
     */
    function _mintLTTokens(address _recipient, uint256 _btcAmount) internal returns (uint256 mintedLt) {
        require(_btcAmount > 0, "BTC amount must be > 0");

        address btc = lt.ASSET_TOKEN();

        // Provide BTC liquidity to LT and calculate debt using oracle price
        deal(btc, address(this), _btcAmount);
        ERC20(btc).approve(address(lt), _btcAmount);

        uint256 debtNeeded = calculateDebtForLTDeposit(lt, _btcAmount);

        // Calculate expected shares using oracle-based pricing (non-manipulatable)
        // Convert BTC (8 decimals) to LT shares (18 decimals)
        uint256 pricePerShare = lt.pricePerShare();
        require(pricePerShare > 0, "Invalid pricePerShare");

        uint8 assetDecimals = ERC20(btc).decimals();
        uint256 expectedShares = (_btcAmount * (10 ** (36 - assetDecimals))) / pricePerShare;
        uint256 minShares = (expectedShares * 90) / 100; // 10% slippage tolerance for AMM dynamics

        return lt.deposit(_btcAmount, debtNeeded, minShares, _recipient);
    }
}
