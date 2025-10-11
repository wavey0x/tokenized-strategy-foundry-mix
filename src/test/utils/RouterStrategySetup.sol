// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {console} from "forge-std/console.sol";
import {Setup, IStrategyInterface, ERC20} from "../utils/Setup.sol";
import {TestHelpers} from "../utils/TestHelpers.sol";
import {Constants} from "../utils/Constants.sol";
import {IStrategy} from "@tokenized-strategy/interfaces/IStrategy.sol";
import {YBVaultFactory} from "../../YBVaultFactory.sol";
import {YBRouterStrategy} from "../../YBRouterStrategy.sol";
import {ILT} from "src/interfaces/yb/ILT.sol";
import {IGaugeController} from "src/interfaces/yb/IGaugeController.sol";
import {IVault} from "@yearn-vaults/interfaces/IVault.sol";
import {IYearnVaultFactory} from "src/interfaces/IYearnVaultFactory.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

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
    ERC4626 public ltYVault;       // yVault for LT tokens
    ILT public lt;

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
        ltYVault = ERC4626(yearnVaultFactory.deploy_new_vault(
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
        // Role bits: ADD_STRATEGY_MANAGER = 1, DEBT_MANAGER = 64, MAX_DEBT_MANAGER = 128, DEPOSIT_LIMIT_MANAGER = 256
        uint256 ADD_STRATEGY_MANAGER = 1;
        uint256 MAX_DEBT_MANAGER = 128;
        uint256 DEBT_MANAGER = 64;
        uint256 DEPOSIT_LIMIT_MANAGER = 256;

        // Set roles and deposit limits for BTC vault
        vault.set_role(management, ADD_STRATEGY_MANAGER | MAX_DEBT_MANAGER | DEBT_MANAGER | DEPOSIT_LIMIT_MANAGER);
        vault.set_deposit_limit(type(uint256).max);

        // Set roles and deposit limits for LT yVault
        IVault(address(ltYVault)).set_role(management, DEPOSIT_LIMIT_MANAGER);
        IVault(address(ltYVault)).set_deposit_limit(type(uint256).max);
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
        uint256 stratTotalAssets = strategy.totalAssets();
        uint256 diff = totalAssets - stratTotalAssets;
        console.log("amount", diff);
        vm.prank(management);
        vault.update_debt(address(_strategy), totalAssets);
    }
}
