// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {console} from "forge-std/console.sol";
import {Setup, IStrategyInterface, ERC20} from "../utils/Setup.sol";
import {TestHelpers} from "src/test/utils/TestHelpers.sol";
import {Constants} from "src/test/utils/Constants.sol";
import {IStrategy} from "@tokenized-strategy/interfaces/IStrategy.sol";
import {YBVaultFactory} from "src/YBVaultFactory.sol";
import {YBRouterStrategy} from "src/YBRouterStrategy.sol";
import {ILT} from "src/interfaces/yb/ILT.sol";
import {IGaugeController} from "src/interfaces/yb/IGaugeController.sol";
import {IVault} from "@yearn-vaults-v3/interfaces/IVault.sol";
import {IYearnVaultFactory} from "src/interfaces/IYearnVaultFactory.sol";
import {ICurveCryptoPool} from "src/interfaces/yb/ICurveCryptoPool.sol";
import {Accountant} from "@vault-periphery/accountants/Accountant.sol";
import {MockStrategy} from "src/test/mocks/MockStrategy.sol";

/**
 * @title RouterStrategySetup
 * @notice Base test setup for YBRouterStrategy tests
 * @dev Provides router-specific test infrastructure and helpers
 */
abstract contract RouterStrategySetup is Setup, TestHelpers {
    // ===== CONTRACTS =====
    YBVaultFactory public factory;
    YBRouterStrategy public routerStrategy;
    IVault public vault;           // BTC vault
    IVault public ltYVault;       // yVault for LT tokens
    ILT public lt;
    ICurveCryptoPool public cryptopool;
    Accountant public accountant;
    IStrategyInterface public mockStrategy;

    // ===== MARKET REFERENCES =====
    address public ltToken = Constants.WBTC_LT;
    address public btcToken = Constants.WBTC;

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

        // Deploy and setup strategy
        setUpStrategy();

        // Setup accountant on LT vault in order to create losses
        setupAccountant();

        // Label addresses for traces
        vm.label(management, "management");
        vm.label(keeper, "keeper");
        vm.label(user, "user");
        vm.label(address(strategy), "strategy");
        vm.label(address(asset), "asset");
        vm.label(performanceFeeRecipient, "performanceFeeRecipient");
        vm.label(address(vault), "vault");
        vm.label(address(lt), "ltToken");
        vm.label(address(ltYVault), "ltYVault");
    }

    /**
     * @notice Deploy router strategy and associated contracts
     */
    function setUpStrategy() public override returns (IStrategyInterface) {
        // Set asset to BTC (WBTC)
        asset = ERC20(btcToken);
        decimals = asset.decimals(); // 8 for WBTC
        minFuzzAmount = 10 ** (decimals - 3); // 0.001 BTC
        maxFuzzAmount = 10 * 10 ** decimals; // 10 BTC

        // Set lt reference
        lt = ILT(ltToken);
        cryptopool = ICurveCryptoPool(lt.CRYPTOPOOL());

        // Step 1: Deploy BTC Vault from Yearn Vault Factory
        string memory vaultSymbol = string(abi.encodePacked("yv", ERC20(btcToken).symbol()));
        vault = IVault(yearnVaultFactory.deploy_new_vault(
            btcToken,                  // asset (BTC)
            "Yearn BTC Vault",        // name
            vaultSymbol,              // symbol
            management,               // role_manager
            10 days                   // profit_max_unlock_time
        ));

        // Step 2: Deploy LT yVault from Yearn Vault Factory
        string memory ltVaultSymbol = string(abi.encodePacked("yv", ERC20(ltToken).symbol()));
        ltYVault = IVault(yearnVaultFactory.deploy_new_vault(
            ltToken,                   // asset (LT token)
            "Yearn LT Vault",         // name
            ltVaultSymbol,            // symbol
            management,               // role_manager
            10 days                   // profit_max_unlock_time
        ));

        // Step 3: Deploy Router strategy via factory
        address deployed = factory.deployRouterStrategy(
            address(vault),           // BTC vault that owns this strategy
            address(ltYVault),        // yVault for LT tokens
            ltToken                   // LT token address
        );

        routerStrategy = YBRouterStrategy(deployed);
        strategy = IStrategyInterface(deployed);

        // Step 4: Set up vault roles and attach strategy
        vm.startPrank(management);
        // Role bits: ADD_STRATEGY_MANAGER = 1, ACCOUNTANT_MANAGER = 8, DEBT_MANAGER = 64, MAX_DEBT_MANAGER = 128, DEPOSIT_LIMIT_MANAGER = 256
        uint256 ADD_STRATEGY_MANAGER = 1;
        uint256 ACCOUNTANT_MANAGER = 8;
        uint256 REPORTING_MANAGER = 32;
        uint256 DEBT_MANAGER = 64;
        uint256 MAX_DEBT_MANAGER = 128;
        uint256 DEPOSIT_LIMIT_MANAGER = 256;
        uint256 QUEUE_MANAGER = 16;
        uint256 MINIMUM_IDLE_MANAGER = 1024;
        uint256 ROLES = ADD_STRATEGY_MANAGER | ACCOUNTANT_MANAGER | MAX_DEBT_MANAGER | DEBT_MANAGER | DEPOSIT_LIMIT_MANAGER | REPORTING_MANAGER | QUEUE_MANAGER | MINIMUM_IDLE_MANAGER;

        // Set roles and deposit limits for BTC vault
        vault.set_role(management, ROLES);
        vault.set_deposit_limit(type(uint256).max);

        // Set roles and deposit limits for LT yVault
        IVault(address(ltYVault)).set_role(management, ROLES);
        IVault(address(ltYVault)).set_deposit_limit(type(uint256).max);
        vault.add_strategy(deployed);
        vault.update_max_debt_for_strategy(deployed, type(uint256).max);

        // Accept management and configure loss/profit limits
        strategy.acceptManagement();
        strategy.setLossLimitRatio(10_000 - 1);
        strategy.setProfitLimitRatio(10_000 - 1);

        // Add mock strategy to report losses
        mockStrategy = IStrategyInterface(address(new MockStrategy(address(ltToken), "1.0.0")));
        ltYVault.add_strategy(address(mockStrategy));
        ltYVault.update_max_debt_for_strategy(address(mockStrategy), type(uint256).max);
        ltYVault.set_auto_allocate(true);
        vm.stopPrank();

        return strategy;
    }

    function setupAccountant() public {
        accountant = new Accountant(management, performanceFeeRecipient, uint16(100), uint16(1000), 0, uint16(MAX_BPS), uint16(MAX_BPS), uint16(MAX_BPS));
        vm.startPrank(management);
        accountant.addVault(address(ltYVault));
        accountant.setCustomConfig(
            address(ltYVault), 
            200, // custom mgmt fee: 2% max
            1000, // custom performance fee
            0, // refund ratio
            uint16(MAX_BPS), // custom max fee
            uint16(MAX_BPS), // custom max gain
            uint16(MAX_BPS) // custom max loss
        );
        vm.stopPrank();
    }

    /**
     * @notice Override to use BTC and deposit via vault
     * @param _strategy Strategy to deposit into
     * @param _user User address
     * @param _amount Amount to deposit (in BTC)
     */
    function mintAndDepositIntoStrategy(
        IStrategyInterface _strategy,
        address _user,
        uint256 _amount
    ) public override {
        // Deal BTC to user
        deal(address(asset), _user, _amount);

        // Deposit into vault (not directly to strategy)
        vm.startPrank(_user);
        asset.approve(address(vault), _amount);
        vault.deposit(_amount, _user);
        vm.stopPrank();

        // Allocate debt to strategy so funds flow through
        uint256 totalAssets = vault.totalAssets();
        vm.prank(management);
        vault.update_debt(address(_strategy), totalAssets);
    }

    function simulateProfit(
        uint256 _amount
    ) public returns (uint256 _profit) {
        // Deal BTC to user
        deal(address(asset), address(this), _amount);
        asset.approve(address(lt), _amount);
        // Deposit into LT and airdrop to strategy
        _profit = lt.deposit(
            _amount,
            calculateDebtNeeded(_amount),
            0, //calculateMinShares(_amount),
            address(strategy)
        );
        _profit = strategy.ltToAsset(_profit);
    }

    function calculateDebtNeeded(uint256 _assetAmount) public view returns (uint256 debtAmount) {
        uint256 price = cryptopool.price_oracle();
        debtAmount = (_assetAmount * price) / (10 ** decimals);
    }
}