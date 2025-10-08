// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {ERC20} from "@tokenized-strategy/BaseStrategy.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// Import interfaces for Yield Basis protocol
import {ILT} from "./interfaces/yb/ILT.sol";
import {ILiquidityGauge} from "./interfaces/yb/ILiquidityGauge.sol";
import {IGaugeController} from "./interfaces/yb/IGaugeController.sol";
import {ICurveCryptoPool} from "./interfaces/yb/ICurveCryptoPool.sol";
import {IAuction} from "./interfaces/IAuction.sol";
import {RewardsSwapper} from "./RewardsSwapper.sol";
import {BaseHealthCheck} from "@periphery/Bases/HealthCheck/BaseHealthCheck.sol";

/**
 * @title YieldBasisGaugeStrategy
 * @author Yearn Finance
 * @notice Yearn V3 strategy that stakes Yield Basis LT tokens for YB emissions
 * @dev Staked strategy - earns YB tokens but foregoes trading fees
 *
 * This strategy provides exposure to YB governance token emissions by staking ybBTC.
 * Users deposit BTC → strategy deposits to LT → stakes in Gauge → earns YB → sells for BTC.
 */
contract YieldBasisGaugeStrategy is BaseHealthCheck {
    using SafeERC20 for ERC20;

    // ===== IMMUTABLE STATE =====

    /// @notice Yield Basis LT contract (e.g., yb-WBTC)
    ILT public immutable ltToken;

    /// @notice Liquidity Gauge for staking LT
    ILiquidityGauge public immutable gauge;

    /// @notice YB governance token
    ERC20 public immutable ybToken;

    /// @notice Gauge Controller (for emissions preview)
    IGaugeController public immutable gaugeController;

    /// @notice Curve Cryptopool for LP pricing
    ICurveCryptoPool public immutable cryptopool;

    /// @notice Stablecoin used for debt (crvUSD)
    ERC20 public immutable stablecoin;

    // ===== SWAP TYPE =====

    enum SwapType {
        NULL,      // No swap configured (token accumulates)
        SWAP,      // Direct swap via router
        AUCTION,   // Yearn Auction system
        TF         // Trade Factory (not used in this strategy, for compatibility)
    }

    /// @notice Reward token configuration (packed into single storage slot)
    struct RewardTokenConfig {
        SwapType swapType;           // uint8 - 1 byte
        uint120 minAmountToSell;     // 15 bytes (supports up to ~1.3e36)
        uint120 maxAmountToSell;     // 15 bytes
        bool shouldClaim;            // 1 byte
    }

    // ===== CONFIGURATION =====

    /// @notice Maximum slippage for deposits (in basis points)
    uint256 public maxDepositSlippage;

    /// @notice Maximum slippage for withdrawals (in basis points)
    uint256 public maxWithdrawSlippage;

    /// @notice RewardsSwapper contract for direct DEX swaps
    RewardsSwapper public rewardsSwapper;

    /// @notice Auction contract for reward token sales
    address public auction;

    /// @notice Whether emergency withdraw has been completed and crvUSD fully sold to asset
    bool public emergencyRecoveryCompleted;

    /// @notice Mapping of token address to reward configuration (packed in 1 slot)
    mapping(address => RewardTokenConfig) public rewardTokenConfigs;

    /// @notice All reward tokens managed by this strategy
    address[] internal allRewardTokens;

    // ===== CONSTANTS =====

    uint256 internal constant PRECISION = 1e18;

    // ===== EVENTS =====

    event SlippageUpdated(
        uint256 depositSlippage,
        uint256 withdrawSlippage
    );
    event RewardsSwapperUpdated(address swapper);
    event AuctionUpdated(address auction);
    event RewardTokenConfigured(
        address indexed token,
        SwapType swapType,
        uint256 minAmountToSell,
        uint256 maxAmountToSell,
        bool shouldClaim
    );
    event EmergencyRecoveryCompleted(bool emergencyRecoveryCompleted);

    // ===== CONSTRUCTOR =====

    /**
     * @notice Initialize the strategy
     * @param _asset Underlying asset (e.g., WBTC, cbBTC)
     * @param _name Strategy name
     * @param _ltToken LT contract address
     * @param _gauge LiquidityGauge contract address
     * @param _cryptopool Curve cryptopool address
     */
    constructor(
        address _asset,
        string memory _name,
        address _ltToken,
        address _gauge,
        address _cryptopool
    ) BaseHealthCheck(_asset, _name) {
        ltToken = ILT(_ltToken);
        gauge = ILiquidityGauge(_gauge);
        cryptopool = ICurveCryptoPool(_cryptopool);
        stablecoin = ERC20(ltToken.STABLECOIN());

        // Get YB and GC from gauge
        ybToken = ERC20(gauge.YB());
        gaugeController = IGaugeController(gauge.GC());

        // Verify asset matches
        require(ltToken.ASSET_TOKEN() == _asset, "Asset mismatch");
        require(gauge.LP_TOKEN() == _ltToken, "Gauge LP mismatch");

        // Default configuration
        maxDepositSlippage = 50; // 0.5%
        maxWithdrawSlippage = 50; // 0.5%

        // Approvals
        asset.safeApprove(_ltToken, type(uint256).max);
        ERC20(_ltToken).safeApprove(_gauge, type(uint256).max);

        // Add reward tokens. Include stablecoin since LP value can be returned as both BTC+crvUSD when AMM is killed.
        _addRewardToken(address(ybToken), SwapType.AUCTION, 1e18, 100_000e18, true);
        _addRewardToken(address(stablecoin), SwapType.AUCTION, 1e18, 100_000e18, false);
    }

    // ===== REQUIRED OVERRIDES =====

    /**
     * @notice Deploy assets into LT token and stake in gauge
     * @param _amount Amount of asset to deploy
     */
    function _deployFunds(uint256 _amount) internal override {
        if (TokenizedStrategy.isShutdown()) return;

        // Step 1: Calculate deposit parameters
        uint256 debtNeeded = _calculateDebtForDeposit(_amount);
        uint256 pricePerShare = ltToken.pricePerShare();
        uint256 expectedShares = (_amount * PRECISION) / pricePerShare;
        uint256 minShares =
            (expectedShares * (MAX_BPS - maxDepositSlippage)) / MAX_BPS;

        // Step 2: Deposit to LT token
        uint256 ltReceived =
            ltToken.deposit(_amount, debtNeeded, minShares, address(this));

        // Step 3: Stake LT in gauge
        if (ltReceived > 0) {
            gauge.deposit(ltReceived, address(this));
        }
    }

    /**
     * @notice Unstake from gauge and withdraw from LT
     * @param _amount Amount of asset to withdraw
     *
     * Two-step process:
     * 1. Unstake from gauge (get ybBTC back)
     * 2. Withdraw from LT (get asset back)
     */
    function _freeFunds(uint256 _amount) internal override {
        bool isKilled = ltToken.is_killed();
        require(
            !isKilled
            || (isKilled && emergencyRecoveryCompleted)
            , "LT is killed and emergency withdraw has not been completed"
        );

        // Step 1: Calculate gauge shares needed
        uint256 sharesToRedeem =
            _calculateGaugeSharesToWithdraw(_amount);
        if (sharesToRedeem == 0) return;

        // Clamp to our balance
        uint256 gaugeShares = gauge.balanceOf(address(this));
        sharesToRedeem =
            sharesToRedeem > gaugeShares ? gaugeShares : sharesToRedeem;

        // Step 2: Redeem from gauge (get LT back)
        uint256 ltReceived =
            gauge.redeem(sharesToRedeem, address(this), address(this));

        // Step 3: Withdraw from LT to asset
        if (ltReceived > 0) {
            uint256 expectedAssets = ltToken.pricePerShare() * ltReceived / PRECISION;
            uint256 minAssets =
                (expectedAssets * (MAX_BPS - maxWithdrawSlippage)) / MAX_BPS;

            ltToken.withdraw(ltReceived, minAssets, address(this));
        }
    }

    /**
     * @notice Harvest YB rewards and report total assets
     * @return _totalAssets Total assets held by strategy
     *
     * Process:
     * 1. Claim YB rewards from gauge
     * 2. Sell YB for asset
     * 3. Calculate total: gaugeShares → LT → asset value + loose assets
     */
    function _harvestAndReport()
        internal
        override
        returns (uint256 _totalAssets)
    {
        
        // if LT is killed then we block reports to explicitly ensure the position has been unwound
        bool isKilled = ltToken.is_killed();
        require(
            !isKilled || 
            (isKilled && emergencyRecoveryCompleted)
            , "LT is killed and emergency withdraw has not been completed"
        );

        _harvestRewards();
        // Convert gauge shares -> LT -> asset value
        uint256 gaugeShares = gauge.balanceOf(address(this));
        uint256 ltEquivalent = gauge.convertToAssets(gaugeShares);
        uint256 assetValue =
            (ltEquivalent * ltToken.pricePerShare()) / PRECISION;

        _totalAssets = assetValue + asset.balanceOf(address(this));
    }


    // ===== OPTIONAL OVERRIDES =====

    /**
     * @notice Emergency withdraw when killed
     * @param _amount Amount to withdraw
     */
    function _emergencyWithdraw(uint256 _amount) internal override {
        // Step 1: Unstake from gauge
        uint256 gaugeShares = gauge.balanceOf(address(this));
        uint256 requestedShares = _calculateGaugeSharesToWithdraw(_amount);
        requestedShares = requestedShares > gaugeShares ? gaugeShares : requestedShares;

        if (requestedShares > 0) gauge.redeem(requestedShares, address(this), address(this));
        uint256 ltBalance = ltToken.balanceOf(address(this));

        if (ltBalance == 0) return;

        // Step 2: Withdraw from LT. Emergency withdraw must be  used when AMM is killed.
        if (ltToken.is_killed()) {
            ltToken.emergency_withdraw(ltBalance, address(this), address(this));
        } else if (ltBalance > 0) {
            uint256 expectedAssets = ltToken.pricePerShare() * ltBalance / PRECISION;
            uint256 minAssets =
                (expectedAssets * (MAX_BPS - maxWithdrawSlippage)) / MAX_BPS;
            // Normal withdraw
            ltToken.withdraw(ltBalance, minAssets, address(this));
        }
    }

    // ===== HARVEST FUNCTIONS =====

    /**
     * @notice Harvest rewards and sell for asset
     * @dev Internal function called during _harvestAndReport
     */
    function _harvestRewards() internal {
        for (uint256 i = 0; i < allRewardTokens.length; i++) {
            address token = allRewardTokens[i];
            RewardTokenConfig memory config = rewardTokenConfigs[token];
            if (config.shouldClaim) gauge.claim(token, address(this));
            uint256 amount = ERC20(token).balanceOf(address(this));

            if (config.swapType != SwapType.NULL && amount > config.minAmountToSell) {
                _swapRewardForAsset(token, amount);
            }
        }
    }

    /**
     * @notice Swap reward tokens for asset
     * @param _token Reward token address
     * @param _amount Amount of reward token to sell
     * @dev Routes based on swapType: SWAP (router) or AUCTION
     */
    function _swapRewardForAsset(address _token, uint256 _amount)
        internal
    {
        RewardTokenConfig memory config = rewardTokenConfigs[_token];
        if (config.swapType == SwapType.SWAP) {
            require(address(rewardsSwapper) != address(0), "Swapper not set");
            rewardsSwapper.swap(_token, _amount, 0); // min out = 0
        }
        if (config.swapType == SwapType.AUCTION) {
            address _auction = auction;
            require(_auction != address(0), "Auction not set");
            ERC20(_token).safeTransfer(auction, _amount);
        }
    }

    // ===== MANAGEMENT FUNCTIONS =====

    /**
     * @notice Claim rewards from gauge
     */
    function claimRewards() external onlyManagement {
        for (uint256 i = 0; i < allRewardTokens.length; i++) {
            address token = allRewardTokens[i];
            gauge.claim(token, address(this));
        }
    }

    /**
     * @notice Set slippage tolerances for LT deposits and withdrawals
     */
    function setSlippage(
        uint256 _depositSlippage,
        uint256 _withdrawSlippage
    ) external onlyManagement {
        // No max slippage on withdraw in order to safely exit in emergency
        require(_depositSlippage <= 500, "Deposit slippage too high");
        require(_withdrawSlippage <= 500, "Withdraw slippage too high");

        maxDepositSlippage = _depositSlippage;
        maxWithdrawSlippage = _withdrawSlippage;

        emit SlippageUpdated(_depositSlippage, _withdrawSlippage);
    }

    /**
     * @notice Set auction contract
     * @param _auction Auction contract address
     */
    function setAuction(address _auction) external onlyManagement {
        if (_auction != address(0)) {
            require(IAuction(_auction).want() == address(asset), "wrong want");
            require(
                IAuction(_auction).receiver() == address(this),
                "wrong receiver"
            );
        }
        auction = _auction;

        emit AuctionUpdated(_auction);
    }

    /**
     * @notice Set RewardsSwapper contract
     * @param _swapper RewardsSwapper contract address
     * @dev Revokes approvals from old swapper and grants to new one
     */
    function setRewardsSwapper(address _swapper) external onlyManagement() {
        require(_swapper != address(0), "Zero address");
        address oldSwapper = address(rewardsSwapper);
        rewardsSwapper = RewardsSwapper(_swapper);

        // Revoke approvals from old swapper for all reward tokens
        address[] memory allTokens = allRewardTokens;
        if (oldSwapper != address(0)) {
            for (uint256 i = 0; i < allTokens.length; i++) {
                ERC20(allTokens[i]).forceApprove(oldSwapper, 0);
            }
        }

        // Grant approvals to trusted new swapper for all reward tokens
        for (uint256 i = 0; i < allTokens.length; i++) {
            ERC20(allTokens[i]).forceApprove(_swapper, type(uint256).max);
        }

        emit RewardsSwapperUpdated(_swapper);
    }

    function availableWithdrawLimit(address /*_owner*/) public view override returns (uint256) {
        if (ltToken.is_killed() && !emergencyRecoveryCompleted) {
            return 0;
        } 
        return type(uint256).max;
    }

    function availableDepositLimit(address /*_owner*/) public view override returns (uint256) {
        if (ltToken.is_killed()) {
            return 0;
        }
        return type(uint256).max;
    }

    /**
     * @notice Set emergency recovery completed only when crvUSD is fully sold to asset
     * @dev In extreme cases, LT.emergency_withdraw() must to recover assets. 
     *      Because this type of withdraw can break the position into BTC + crvUSD, and we do not have full control over it being called on our behalf,
     *      we must explicitly mark "completed" once the crvUSD is fully sold to back to asset. Otherwise the strategy will avoid syncing totalAssets to avoid reporting an artificial loss.
     */
    function setEmergencyRecoveryCompleted(bool _emergencyRecoveryCompleted) external onlyManagement {
        emergencyRecoveryCompleted = _emergencyRecoveryCompleted;
        emit EmergencyRecoveryCompleted(_emergencyRecoveryCompleted);
    }

    /**
     * @notice Kick an auction for a specific reward token
     * @param _token The reward token to auction
     * @return auctionId The ID of the kicked auction
     */
    function kickAuction(
        address _token
    ) external onlyKeepers returns (uint256) {
        require(rewardTokenConfigs[_token].swapType == SwapType.AUCTION, "!auction");
        return _kickAuction(_token);
    }

    /**
     * @dev Kick an auction for a given token
     * @param _from The token being sold
     */
    function _kickAuction(address _from) internal returns (uint256) {
        require(
            _from != address(asset) && _from != address(ltToken),
            "cannot kick"
        );
        require(auction != address(0), "Auction not set");

        RewardTokenConfig memory config = rewardTokenConfigs[_from];
        uint256 _amountToSell = ERC20(_from).balanceOf(address(this));
        _amountToSell = _amountToSell > config.maxAmountToSell ? config.maxAmountToSell : _amountToSell;

        require(
            _amountToSell > config.minAmountToSell,
            "Not enough to sell"
        );

        ERC20(_from).safeTransfer(auction, _amountToSell);
        return IAuction(auction).kick(_from);
    }

    /**
     * @notice Get all reward tokens managed by this strategy
     * @return Array of reward token addresses
     */
    function getAllRewardTokens() external view returns (address[] memory) {
        return allRewardTokens;
    }

    /**
     * @notice Get reward token configuration
     * @param _token The reward token address
     * @return config The packed reward token configuration
     */
    function getRewardTokenConfig(address _token) external view returns (RewardTokenConfig memory) {
        return rewardTokenConfigs[_token];
    }

    /**
     * @notice Add a new reward token to manage
     * @param _token The reward token address
     * @param _minAmountToSell Minimum amount to sell
     * @param _maxAmountToSell Maximum amount to sell
     * @param _swapType The swap type for this token
     * @param _shouldClaim Whether reward is claimable from gauge
     */
    function addRewardToken(
        address _token,
        SwapType _swapType,
        uint256 _minAmountToSell,
        uint256 _maxAmountToSell,
        bool _shouldClaim
    ) external onlyManagement {
        _addRewardToken(_token, _swapType, _minAmountToSell, _maxAmountToSell, _shouldClaim);
    }

    function _addRewardToken(address _token, SwapType _swapType, uint256 _minAmountToSell, uint256 _maxAmountToSell, bool _shouldClaim) internal {
        require(
            _token != address(asset) && _token != address(ltToken) && _token != address(gauge),
            "!allowed"
        );
        require(rewardTokenConfigs[_token].swapType == SwapType.NULL, "Already added");
        require(_swapType != SwapType.NULL, "!null");
        require(_minAmountToSell <= type(uint120).max, "Min amount too large");
        // Clamp to max uint120
        _maxAmountToSell = _maxAmountToSell > type(uint120).max ? type(uint120).max : _maxAmountToSell;

        allRewardTokens.push(_token);

        rewardTokenConfigs[_token] = RewardTokenConfig({
            swapType: _swapType,
            minAmountToSell: uint120(_minAmountToSell),
            maxAmountToSell: uint120(_maxAmountToSell),
            shouldClaim: _shouldClaim
        });

        // If swapper is set, approve it for this token
        if (address(rewardsSwapper) != address(0)) {
            ERC20(_token).forceApprove(
                address(rewardsSwapper),
                type(uint256).max
            );
        }
        emit RewardTokenConfigured(_token, _swapType, _minAmountToSell, _maxAmountToSell, _shouldClaim);
    }

    /**
     * @notice Remove a reward token from management
     * @param _token The reward token address to remove
     */
    function removeRewardToken(address _token) external onlyManagement {
        address[] memory _allRewardTokens = allRewardTokens;
        uint256 _length = _allRewardTokens.length;
        bool found = false;
        for (uint256 i; i < _length; ++i) {
            if (_allRewardTokens[i] == _token) {
                found = true;
                allRewardTokens[i] = _allRewardTokens[_length - 1];
                allRewardTokens.pop();
                break;
            }
        }
        require(found, "Not a valid reward token");

        // Revoke approval from swapper
        if (address(rewardsSwapper) != address(0)) {
            ERC20(_token).forceApprove(address(rewardsSwapper), 0);
        }

        // Clear config values
        delete rewardTokenConfigs[_token];
        emit RewardTokenConfigured(_token, SwapType.NULL, 0, 0, false);
    }

    /**
     * @notice Update reward token configuration
     * @param _token The reward token address
     * @param _swapType The swap type (SWAP or AUCTION)
     * @param _minAmountToSell Minimum amount to sell
     * @param _maxAmountToSell Maximum amount to sell
     * @param _shouldClaim Whether reward is claimable from gauge
     */
    function updateRewardTokenConfig(
        address _token,
        SwapType _swapType,
        uint256 _minAmountToSell,
        uint256 _maxAmountToSell,
        bool _shouldClaim
    ) external onlyManagement {
        RewardTokenConfig memory config = rewardTokenConfigs[_token];
        require(config.swapType != SwapType.NULL, "Token not configured");
        require(_swapType != SwapType.NULL, "Invalid swap type");
        require(_minAmountToSell <= type(uint120).max, "Min amount too large");
        // Clamp to max uint120
        _maxAmountToSell = _maxAmountToSell > type(uint120).max ? type(uint120).max : _maxAmountToSell;

        rewardTokenConfigs[_token] = RewardTokenConfig({
            swapType: _swapType,
            minAmountToSell: uint120(_minAmountToSell),
            maxAmountToSell: uint120(_maxAmountToSell),
            shouldClaim: _shouldClaim
        });
        emit RewardTokenConfigured(_token, _swapType, _minAmountToSell, _maxAmountToSell, _shouldClaim);
    }

    // ===== INTERNAL HELPERS =====

    /**
     * @notice Calculate debt needed for LT deposit
     */
    function _calculateDebtForDeposit(uint256 _assetAmount)
        internal
        view
        returns (uint256 debtAmount)
    {
        uint256 balance0 = cryptopool.balances(0); // crvUSD
        uint256 balance1 = cryptopool.balances(1); // BTC

        if (balance1 > 0) {
            debtAmount = (_assetAmount * balance0) / balance1;
        } else {
            debtAmount = _assetAmount;
        }
    }

    /**
     * @notice Calculate gauge shares to withdraw
     */
    function _calculateGaugeSharesToWithdraw(
        uint256 _assetAmount
    ) internal view returns (uint256 shares) {
        // We know the amount of assets, thus need to make two conversions:
        // 1) asset (BTC) -> LT shares (ybBTC)
        // 2) LT shares -> gauge shares

        // Step 1: Convert asset to LT
        uint256 pricePerShare = ltToken.pricePerShare(); // pps uses non-manipulatable oracle pricing but is not precise
        if (pricePerShare == 0) return 0;
        uint256 ltNeeded = (_assetAmount * PRECISION) / pricePerShare;

        // Step 2: Convert LT to gauge shares
        shares = gauge.convertToShares(ltNeeded);
    }
}