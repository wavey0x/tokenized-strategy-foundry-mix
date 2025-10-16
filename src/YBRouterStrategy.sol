// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {ERC20} from "@tokenized-strategy/BaseStrategy.sol";
import {BaseHealthCheck} from "@periphery/Bases/HealthCheck/BaseHealthCheck.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
// Import interfaces for Yield Basis protocol
import {ILT} from "./interfaces/yb/ILT.sol";
import {ICurveCryptoPool} from "./interfaces/yb/ICurveCryptoPool.sol";
import {IAuction} from "./interfaces/IAuction.sol";
import {RewardsSwapper} from "./utils/RewardsSwapper.sol";


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

    /// @notice Percentage of buffer to keep to offset losses
    uint256 public bufferKeepPct;

    /// @notice Maximum slippage for deposits (in basis points, e.g., 50 = 0.5%)
    uint256 public maxDepositSlippage;

    /// @notice Maximum slippage for withdrawals (in basis points)
    uint256 public maxWithdrawSlippage;

    uint256 public maxInvest;
    uint256 public minInvest;
    bool public dontInvest;
    uint256 public availableBufferShares; // vault shares
    bool public useProfitBuffer;

    // ===== CONSTANTS =====

    uint256 internal constant PRECISION = 1e18;

    // ===== EVENTS =====

    event SlippageUpdated(uint256 depositSlippage, uint256 withdrawSlippage);
    event AuctionUpdated(address auction);
    event AvailableBufferUpdated(uint256 availableBufferBefore, uint256 availableBufferAfter);
    event BufferKeepPctUpdated(uint256 bufferKeepPct);
    event Debug(uint256 _debug);

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

        minInvest = 1e14;
        maxInvest = 50e18;

        maxDepositSlippage = 500; // 5%
        maxWithdrawSlippage = 500; // 5%

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
        if (dontInvest || TokenizedStrategy.isShutdown()) return;
        _amount = _amount > maxInvest ? maxInvest : _amount;
        uint256 ltAmount = assetToLt(_amount);
        if (ltAmount < minInvest) return;
        uint256 debtNeeded = _calculateDebtForDeposit(_amount);
        uint256 minShares =
            (ltAmount * (MAX_BPS - maxDepositSlippage)) / MAX_BPS;
        ltToken.deposit(_amount, debtNeeded, minShares, address(this));
        // Always deposit all LTs to yVault
        _depositLtBalanceToYVault();
    }

    function _depositLtBalanceToYVault() internal {
        uint256 ltBalance = ltToken.balanceOf(address(this));
        if (ltBalance == 0) return;
        yVault.deposit(ltBalance, address(this));
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

        uint256 vaultSharesToRedeem = _convertAssetsToVaultShares(_amount);
        vaultSharesToRedeem = vaultSharesToRedeem > vaultBalance ? vaultBalance : vaultSharesToRedeem;

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

        uint256 currentTotalAssets = TokenizedStrategy.totalAssets();
        _depositLtBalanceToYVault(); // deposit any loose LT balance into yVault
        _totalAssets = estimatedTotalAssets();
        if (_totalAssets > currentTotalAssets) {
            uint256 amountToSkim = (_totalAssets - currentTotalAssets) * bufferKeepPct / MAX_BPS;
            if (amountToSkim > 0) {
                _skimBuffer(amountToSkim);
                _totalAssets -= amountToSkim;
            }
        }
        else {
            emit Debug(currentTotalAssets - _totalAssets);
            uint256 amountDistributed = _distributeBuffer(currentTotalAssets - _totalAssets);
            emit Debug(currentTotalAssets - _totalAssets);
            if (amountDistributed > 0) _totalAssets += amountDistributed;
        }
    }

    /**
     * @notice Estimated total assets held by strategy
     * @dev Uses optimistic price per share
     * @return _totalAssets Estimated total assets
     */
    function estimatedTotalAssets() public view returns (uint256) {
        uint256 vaultShares = yVault.balanceOf(address(this));
        // subtract available buffer shares
        vaultShares = vaultShares > availableBufferShares ? vaultShares - availableBufferShares : 0;
        uint256 ltInVault;
        if (vaultShares > 0) ltInVault = yVault.convertToAssets(vaultShares);
        uint256 assetValue = ltToAsset(ltInVault + ltToken.balanceOf(address(this)));
        return assetValue + asset.balanceOf(address(this));
    }

    // ===== OPTIONAL OVERRIDES =====

    function availableWithdrawLimit(address /*_owner*/) public view override returns (uint256) {
        if (ltToken.is_killed()) {
            return 0;
        }
        return maxInvest + asset.balanceOf(address(this));
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
        // subtract available buffer shares
        vaultBalance = vaultBalance > availableBufferShares ? vaultBalance - availableBufferShares : 0;
        uint256 vaultSharesToRedeem = _convertAssetsToVaultShares(_amount);
        vaultSharesToRedeem = vaultSharesToRedeem > vaultBalance ? vaultBalance : vaultSharesToRedeem;
        if (vaultSharesToRedeem != 0) yVault.redeem(vaultSharesToRedeem, address(this), address(this));

        uint256 ltBalance = ltToken.balanceOf(address(this));
        if (ltBalance == 0) return;
        uint256 minAssets =
            (ltToAsset(ltBalance) * (MAX_BPS - maxWithdrawSlippage)) / MAX_BPS;
        ltToken.withdraw(ltBalance, minAssets, address(this));
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
        maxDepositSlippage = _depositSlippage;
        maxWithdrawSlippage = _withdrawSlippage;
        emit SlippageUpdated(_depositSlippage, _withdrawSlippage);
    }

    function setBufferKeepPct(uint256 _bufferKeepPct) external onlyManagement {
        require(_bufferKeepPct <= MAX_BPS, "!too high");
        bufferKeepPct = _bufferKeepPct;
        emit BufferKeepPctUpdated(_bufferKeepPct);
    }

    // ===== INTERNAL HELPERS =====

    /**
     * @notice Convert LT shares (18 decimals) to asset amount and normalize to asset decimals
     * @param _ltAmount Amount of LT tokens (18 decimals)
     * @return assetAmount Amount in asset decimals
     */
    function ltToAsset(uint256 _ltAmount) public view returns (uint256) {
        return (_ltAmount * ltToken.pricePerShare()) / (10 ** (36 - assetDecimals));
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
     * @param _assetAmount amount of assets (BTC)
     * @return shares Vault shares to redeem
     */
    function _convertAssetsToVaultShares(
        uint256 _assetAmount
    ) internal view returns (uint256 shares) {
        // Convert asset amount to LT amount needed
        uint256 ltNeeded = assetToLt(_assetAmount);
        if (ltNeeded == 0) return 0;
        shares = yVault.convertToShares(ltNeeded);
    }

    function _convertVaultSharesToAssets(uint256 _vaultShares) internal view returns (uint256 _assets) {
        if (_vaultShares == 0) return 0;
        uint256 lts = yVault.convertToAssets(_vaultShares);
        if (lts == 0) return 0;
        _assets = ltToAsset(lts);
    }

    function distributeBuffer(uint256 _bufferAssetsToDistribute) external onlyManagement {
        _distributeBuffer(_bufferAssetsToDistribute);
    }

    // ===== HEALTH CHECK Functions implementing automatic profit/loss smoothing =====

    function _distributeBuffer(uint256 _bufferAssetsToDistribute) internal returns (uint256 _bufferAssetsUsed) {
        if (_bufferAssetsToDistribute == 0) return 0;
        uint256 _bufferSharesToDistribute = _convertAssetsToVaultShares(_bufferAssetsToDistribute);
        uint256 _availableBufferShares = availableBufferShares;
        // clamp to available buffer shares
        _bufferSharesToDistribute = _bufferSharesToDistribute > _availableBufferShares ? _availableBufferShares : _bufferSharesToDistribute;
        if (_bufferSharesToDistribute == 0) return 0;
        availableBufferShares -= _bufferSharesToDistribute;
        emit AvailableBufferUpdated(_availableBufferShares, availableBufferShares);
        return _convertAssetsToVaultShares(_bufferSharesToDistribute);
    }

    function _skimBuffer(uint256 _bufferAssetsToSkim) internal {
        uint256 _bufferSharesToSkim = _convertAssetsToVaultShares(_bufferAssetsToSkim);
        if (_bufferSharesToSkim == 0) return;
        availableBufferShares += _bufferSharesToSkim;
        emit AvailableBufferUpdated(availableBufferShares, availableBufferShares + _bufferSharesToSkim);
    }

    function availableBufferAssets() public view returns (uint256 _bufferAssets) {
        return _convertVaultSharesToAssets(availableBufferShares);
    }
}