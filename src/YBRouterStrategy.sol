// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {ERC20} from "@tokenized-strategy/BaseStrategy.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
// Import interfaces for Yield Basis protocol
import {ILT} from "./interfaces/yb/ILT.sol";
import {ICurveCryptoPool} from "./interfaces/yb/ICurveCryptoPool.sol";
import {IAuction} from "./interfaces/IAuction.sol";
import {RewardsSwapper} from "./RewardsSwapper.sol";
import {BaseHealthCheck} from "@periphery/Bases/HealthCheck/BaseHealthCheck.sol";

/**
 * @title YBRouterStrategy
 * @author Yearn Finance
 * @notice Yearn V3 strategy that holds Yield Basis LT tokens for trading fee yield
 * @dev Unstaked strategy - earns fees but no YB emissions
 *
 * This strategy provides exposure to Yield Basis's leveraged liquidity without IL.
 * Users deposit BTC → strategy deposits to LT → holds ybBTC → earns trading fees.
 *
 * Key features:
 * - 2x leverage on Curve BTC/crvUSD LP without impermanent loss
 * - Tracks BTC price 1:1
 * - Earns trading fees (net of dynamic admin fee)
 * - No token price exposure (yield is BTC-denominated)
 */
contract YBRouterStrategy is BaseHealthCheck {
    using SafeERC20 for ERC20;

    // ===== IMMUTABLE STATE =====

    /// @notice Yearn Vault that owns this strategy
    address public immutable vault;

    /// @notice Yield Basis LT contract (e.g., yb-WBTC)
    ILT public immutable ltToken;

    ERC4626 public immutable yVault;

    /// @notice Curve Cryptopool for LP pricing
    ICurveCryptoPool public immutable cryptopool;

    /// @notice Stablecoin used for debt (crvUSD)
    ERC20 public immutable stablecoin;

    /// @notice Decimals of the underlying asset token
    uint8 public immutable assetDecimals;
    // ===== CONFIGURATION =====

    /// @notice Maximum slippage for deposits (in basis points, e.g., 50 = 0.5%)
    uint256 public maxDepositSlippage;

    /// @notice Maximum slippage for withdrawals (in basis points)
    uint256 public maxWithdrawSlippage;

    // ===== CONSTANTS =====

    uint256 internal constant PRECISION = 1e18;

    // ===== EVENTS =====

    event SlippageUpdated(uint256 depositSlippage, uint256 withdrawSlippage);
    event AuctionUpdated(address auction);

    // ===== CONSTRUCTOR =====

    /**
     * @notice Initialize the strategy
     * @param _asset Underlying asset (e.g., WBTC, cbBTC)
     * @param _name Strategy name
     * @param _ltToken LT contract address
     * @param _yVault Yearn Vault address
     * @param _vault Yearn Vault that will own this strategy
     */
    constructor(
        address _asset,
        string memory _name,
        address _ltToken,
        address _yVault,
        address _vault
    ) BaseHealthCheck(_asset, _name) {
        vault = _vault;
        ltToken = ILT(_ltToken);
        cryptopool = ICurveCryptoPool(ltToken.CRYPTOPOOL());
        yVault = ERC4626(_yVault);
        require(ltToken.ASSET_TOKEN() == _asset, "Asset mismatch");

        // Validate asset decimals
        assetDecimals = ERC20(_asset).decimals();
        require(assetDecimals <= 18, "Asset decimals must be <= 18");

        maxDepositSlippage = 200; // 1%
        maxWithdrawSlippage = 200; // 1%

        asset.safeApprove(_ltToken, type(uint256).max);
        ERC20(_ltToken).safeApprove(_yVault, type(uint256).max);
    }

    // ===== REQUIRED OVERRIDES =====

    /**
     * @notice Deploy assets into LT
     * @param _amount Amount of asset to deploy
     * @dev Called automatically after deposits
     */
    function _deployFunds(uint256 _amount) internal override {
        if (TokenizedStrategy.isShutdown()) return;
        uint256 debtNeeded = _calculateDebtForDeposit(_amount);
        uint256 minShares =
            (assetToLt(_amount) * (MAX_BPS - maxDepositSlippage)) / MAX_BPS;
        ltToken.deposit(_amount, debtNeeded, minShares, address(this));
        // Always deposit all LTs to yVault
        yVault.deposit(ltToken.balanceOf(address(this)), address(this));
    }

    /**
     * @notice Withdraw assets from LT token
     * @param _amount Amount of asset to withdraw
     * @dev Called during user withdrawals
     */
    function _freeFunds(uint256 _amount) internal override {
        bool isKilled = ltToken.is_killed();
        require(
            !isKilled
            , "LT is Killed"
        );

        uint256 vaultBalance = yVault.balanceOf(address(this));
        if (vaultBalance == 0) return;

        uint256 vaultSharesToRedeem = _convertAmountToVaultShares(_amount, vaultBalance);
        if (vaultSharesToRedeem == 0) return;
        yVault.redeem(vaultSharesToRedeem, address(this), address(this));
        uint256 ltBalance = ltToken.balanceOf(address(this));
        uint256 minAssets =
            (ltToAsset(ltBalance) * (MAX_BPS - maxWithdrawSlippage)) / MAX_BPS;
        ltToken.withdraw(ltBalance, minAssets, address(this));
    }

    /**
     * @notice Report total assets held by strategy
     * @return _totalAssets Total assets in strategy
     * @dev Trading fees accrue as LT token appreciation
     *
     * Key insight: Fees are NOT explicitly harvested. They accrue automatically
     * via pricePerShare() appreciation as trading fees accumulate in the Curve pool.
     *
     * The dynamic admin fee determines how much goes to us vs veYB holders:
     * - More staking → higher admin fee → lower yield for unstaked (us)
     * - Less staking → lower admin fee → higher yield for unstaked (us)
     * - But with fewer unstaked tokens, each gets proportionally more
     */
    function _harvestAndReport()
        internal
        override
        returns (uint256 _totalAssets)
    {
        // if LT is killed then we block reports to explicitly ensure the position has been unwound
        bool isKilled = ltToken.is_killed();
        require(
            !isKilled,
            "LT is Killed"
        );

        // Calculate current balances
        // LT is deposited in yVault, so we need to check vault balance
        uint256 vaultShares = yVault.balanceOf(address(this));
        uint256 ltInVault = yVault.convertToAssets(vaultShares);

        // Convert LT amount to BTC value
        uint256 btcValueInVault = ltToAsset(ltInVault);

        _totalAssets = btcValueInVault + asset.balanceOf(address(this));
    }

    // ===== OPTIONAL OVERRIDES =====

    function availableWithdrawLimit(address /*_owner*/) public view override returns (uint256) {
        if (ltToken.is_killed()) {
            return 0;
        }
        return type(uint256).max;
    }

    function availableDepositLimit(address _owner) public view override returns (uint256) {
        // Only the vault can deposit
        if (_owner != vault) return 0;

        if (ltToken.is_killed()) {
            return 0;
        }
        return type(uint256).max;
    }

    /**
     * @notice Emergency withdraw when killed
     * @param _amount Amount to withdraw
     */
    function _emergencyWithdraw(uint256 _amount) internal override {
        uint256 vaultBalance = yVault.balanceOf(address(this));
        if (vaultBalance == 0) return;

        // Step 1: Calculate vault shares needed
        uint256 vaultSharesToRedeem = _convertAmountToVaultShares(_amount, vaultBalance);
        if (vaultSharesToRedeem == 0) return;

        // Step 2: Redeem from yVault to get LT back
        uint256 ltReceived = yVault.redeem(vaultSharesToRedeem, address(this), address(this));
        if (ltReceived == 0) return;

        // Step 3: Withdraw from LT (use emergency_withdraw if killed, normal withdraw otherwise)
        if (ltToken.is_killed()) {
            ltToken.emergency_withdraw(ltReceived, address(this), address(this));
        } else {
            uint256 expectedAssets = ltToken.preview_withdraw(ltReceived);
            uint256 minAssets =
                (expectedAssets * (MAX_BPS - maxWithdrawSlippage)) / MAX_BPS;
            ltToken.withdraw(ltReceived, minAssets, address(this));
        }
    }

    // ===== MANAGEMENT FUNCTIONS =====

    /**
     * @notice Set slippage tolerances
     * @param _depositSlippage Deposit slippage in bps
     * @param _withdrawSlippage Withdraw slippage in bps
     */
    function setSlippage(
        uint256 _depositSlippage,
        uint256 _withdrawSlippage
    ) external onlyManagement {
        require(_depositSlippage <= 1500, "Deposit slippage too high"); // Max 15%
        require(_withdrawSlippage <= 1500, "Withdraw slippage too high"); // Max 15%

        maxDepositSlippage = _depositSlippage;
        maxWithdrawSlippage = _withdrawSlippage;

        emit SlippageUpdated(_depositSlippage, _withdrawSlippage);
    }

    // ===== INTERNAL HELPERS =====

    /**
     * @notice Convert LT shares (18 decimals) to asset amount and normalize to asset decimals
     * @param _ltAmount Amount of LT tokens (18 decimals)
     * @return assetAmount Amount in asset decimals
     */
    function ltToAsset(uint256 _ltAmount) public view returns (uint256) {
        return (_ltAmount * ltToken.pricePerShare()) / (10 ** (36 - assetDecimals));
        return ltToken.preview_withdraw(_ltAmount);
    }

    /**
     * @notice Convert asset amount (asset decimals) to LT shares and normalize to 18 decimals
     * @param _assetAmount Amount in asset decimals
     * @return ltAmount Amount of LT tokens (18 decimals)
     */
    function assetToLt(uint256 _assetAmount) public view returns (uint256) {
        uint256 pricePerShare = ltToken.pricePerShare();
        if (pricePerShare == 0) return 0;
        return (_assetAmount * (10 ** (36 - assetDecimals))) / pricePerShare;
    }

    /**
     * @notice Calculate debt needed for deposit using Curve pool's price oracle
     * @param _assetAmount Amount of asset to deposit
     * @return debtAmount Amount of crvUSD debt to take
     * @dev Uses Curve pool's TWAP oracle for stable, manipulation-resistant pricing
     *      debt ≈ assetAmount × BTC_price (per YB protocol docs)
     */
    function _calculateDebtForDeposit(uint256 _assetAmount)
        internal
        view
        returns (uint256 debtAmount)
    {
        uint256 price = cryptopool.price_oracle();
        debtAmount = (_assetAmount * price) / (10 ** assetDecimals);
    }

    /**
     * @notice Calculate vault shares to withdraw for desired BTC amount
     * @param _assetAmount Desired BTC amount
     * @param _vaultBalance Current yVault share balance
     * @return vaultSharesToRedeem Vault shares to redeem
     */
    function _convertAmountToVaultShares(
        uint256 _assetAmount,
        uint256 _vaultBalance
    ) internal view returns (uint256 vaultSharesToRedeem) {
        // Convert BTC amount to LT amount needed
        uint256 ltNeeded = assetToLt(_assetAmount);
        if (ltNeeded == 0) return 0;

        // Convert LT amount to vault shares needed
        vaultSharesToRedeem = yVault.convertToShares(ltNeeded);

        // Clamp to our vault balance
        if (vaultSharesToRedeem > _vaultBalance) vaultSharesToRedeem = _vaultBalance;
    }

    /**
     * @notice Calculate shares to withdraw for desired asset amount
     * @param _assetAmount Desired asset amount
     * @param _ltBalance Current LT balance
     * @return sharesToRedeem Shares to redeem
     */
    function _calculateSharesToWithdraw(
        uint256 _assetAmount,
        uint256 _ltBalance
    ) internal view returns (uint256 sharesToRedeem) {
        // Convert asset amount to LT shares
        sharesToRedeem = assetToLt(_assetAmount);
        if (sharesToRedeem == 0) return 0;

        // Clamp to our balance
        if (sharesToRedeem > _ltBalance) sharesToRedeem = _ltBalance;
    }
}