// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {ERC20} from "@tokenized-strategy/BaseStrategy.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// Import interfaces for Yield Basis protocol
import {ILT} from "./interfaces/yb/ILT.sol";
import {ICurveCryptoPool} from "./interfaces/yb/ICurveCryptoPool.sol";
import {IAuction} from "./interfaces/IAuction.sol";
import {RewardsSwapper} from "./RewardsSwapper.sol";
import {BaseHealthCheck} from "@periphery/Bases/HealthCheck/BaseHealthCheck.sol";

/**
 * @title YieldBasisLTStrategy
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
contract YieldBasisLTStrategy is BaseHealthCheck {
    using SafeERC20 for ERC20;

    // ===== IMMUTABLE STATE =====

    /// @notice Yield Basis LT contract (e.g., yb-WBTC)
    ILT public immutable ltToken;

    /// @notice Curve Cryptopool for LP pricing
    ICurveCryptoPool public immutable cryptopool;

    /// @notice Stablecoin used for debt (crvUSD)
    ERC20 public immutable stablecoin;

    // ===== SWAP TYPE =====

    enum SwapType {
        NULL,      // No swap configured (token accumulates)
        SWAP,      // Direct swap via router
        AUCTION    // Yearn Auction system
    }

    /// @notice Reward token configuration (packed into single storage slot)
    struct RewardTokenConfig {
        SwapType swapType;           // uint8 - 1 byte
        uint120 minAmountToSell;     // 15 bytes (supports up to ~1.3e36)
        uint120 maxAmountToSell;     // 15 bytes
        // Total: 31 bytes = 1 storage slot
    }

    // ===== CONFIGURATION =====

    /// @notice Maximum slippage for deposits (in basis points, e.g., 50 = 0.5%)
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

    event SlippageUpdated(uint256 depositSlippage, uint256 withdrawSlippage);
    event RewardsSwapperUpdated(address swapper);
    event AuctionUpdated(address auction);
    event RewardTokenConfigured(address indexed token, SwapType swapType, uint256 minAmountToSell, uint256 maxAmountToSell);
    event EmergencyRecoveryCompleted(bool emergencyRecoveryCompleted);

    // ===== CONSTRUCTOR =====

    /**
     * @notice Initialize the strategy
     * @param _asset Underlying asset (e.g., WBTC, cbBTC)
     * @param _name Strategy name
     * @param _ltToken LT contract address
     * @param _cryptopool Curve cryptopool address
     */
    constructor(
        address _asset,
        string memory _name,
        address _ltToken,
        address _cryptopool
    ) BaseHealthCheck(_asset, _name) {
        ltToken = ILT(_ltToken);
        cryptopool = ICurveCryptoPool(_cryptopool);
        stablecoin = ERC20(ltToken.STABLECOIN());
        require(ltToken.ASSET_TOKEN() == _asset, "Asset mismatch");

        maxDepositSlippage = 50; // 0.5%
        maxWithdrawSlippage = 50; // 0.5%

        asset.safeApprove(_ltToken, type(uint256).max);
        // Add stablecoin as reward token since emergency_withdraw can return crvUSD
        _addRewardToken(address(stablecoin), 1e18, 100_000e18, SwapType.AUCTION);
    }

    // ===== REQUIRED OVERRIDES =====

    /**
     * @notice Deploy assets into LT token
     * @param _amount Amount of asset to deploy
     * @dev Called automatically after deposits
     *
     * Process:
     * 1. Calculate debt needed (≈ asset value in USD)
     * 2. Calculate minimum shares with slippage tolerance
     * 3. Call LT.deposit() which:
     *    - Flash-borrows crvUSD
     *    - Adds liquidity to Curve pool
     *    - Mints LP tokens
     *    - Borrows against LP in YB CDP
     *    - Repays flash loan
     *    - Mints ybBTC shares to us
     */
    function _deployFunds(uint256 _amount) internal override {
        if (TokenizedStrategy.isShutdown()) return;

        // 1) Calculate deposit parameters
        uint256 debtNeeded = _calculateDebtForDeposit(_amount);
        uint256 pricePerShare = ltToken.pricePerShare(); // we use pps which is non-manipulatable (uses oracle pricing)
        uint256 expectedShares = (_amount * PRECISION) / pricePerShare;
        uint256 minShares =
            (expectedShares * (MAX_BPS - maxDepositSlippage)) / MAX_BPS;

        // 2) Deposit to LT token contract
        ltToken.deposit(_amount, debtNeeded, minShares, address(this));
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
            || (isKilled && emergencyRecoveryCompleted)
            , "LT is killed and emergency withdraw has not been completed"
        );

        uint256 ltBalance = ltToken.balanceOf(address(this));
        if (ltBalance == 0) return;
    
        // Calculate shares needed to get _amount of assets
        uint256 sharesToBurn = _calculateSharesToWithdraw(_amount, ltBalance);
        if (sharesToBurn == 0) return;

        // Cap at our balance
        sharesToBurn = sharesToBurn > ltBalance ? ltBalance : sharesToBurn;

        // Calculate minimum assets with slippage tolerance
        uint256 expectedAssets = ltToken.preview_withdraw(sharesToBurn);
        uint256 minAssets =
            (expectedAssets * (MAX_BPS - maxWithdrawSlippage)) / MAX_BPS;

        // Withdraw from LT token contract
        ltToken.withdraw(sharesToBurn, minAssets, address(this));
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
            !isKilled || (isKilled && emergencyRecoveryCompleted),
            "LT is killed and emergency withdraw has not been completed"
        );

        // Calculate current balances
        uint256 ltBalance = ltToken.balanceOf(address(this));
        uint256 looseAssets = asset.balanceOf(address(this));

        // Normal operation: fees accrue automatically via LT price appreciation
        // No explicit harvest needed - yield is built into pricePerShare()
        // Convert LT tokens to asset value using pricePerShare
        // pricePerShare already accounts for accumulated trading fees
        uint256 ltValueInAsset =
            (ltBalance * ltToken.pricePerShare()) / PRECISION;

        _totalAssets = ltValueInAsset + looseAssets;
    }

    // ===== OPTIONAL OVERRIDES =====

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
     * @notice Emergency withdraw when killed
     * @param _amount Amount to withdraw
     */
    function _emergencyWithdraw(uint256 _amount) internal override {
        uint256 ltBalance = ltToken.balanceOf(address(this));
        if (ltBalance == 0) return;

        // Calculate shares needed based on requested amount
        uint256 sharesToBurn = _calculateSharesToWithdraw(_amount, ltBalance);
        if (sharesToBurn == 0) return;

        sharesToBurn = sharesToBurn > ltBalance ? ltBalance : sharesToBurn; // clamp to our balance

        if (ltToken.is_killed()) {
            ltToken.emergency_withdraw(sharesToBurn, address(this), address(this));
        } else if (sharesToBurn > 0) {
            uint256 expectedAssets = ltToken.pricePerShare() * sharesToBurn / PRECISION;
            uint256 minAssets =
                (expectedAssets * (MAX_BPS - maxWithdrawSlippage)) / MAX_BPS;
            ltToken.withdraw(sharesToBurn, minAssets, address(this));
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
        require(_depositSlippage <= 500, "Deposit slippage too high"); // Max 5%
        require(_withdrawSlippage <= 500, "Withdraw slippage too high"); // Max 5%

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
    function setRewardsSwapper(address _swapper) external onlyManagement {
        require(_swapper != address(0), "Zero address");
        address oldSwapper = address(rewardsSwapper);
        rewardsSwapper = RewardsSwapper(_swapper);

        // Revoke all approvals from old swapper
        address[] memory allTokens = allRewardTokens;
        if (oldSwapper != address(0)) {
            for (uint256 i = 0; i < allTokens.length; i++) {
                ERC20(allTokens[i]).forceApprove(oldSwapper, 0);
            }
        }

        // Grant approvals to trusted new swapper
        for (uint256 i = 0; i < allTokens.length; i++) {
            ERC20(allTokens[i]).forceApprove(_swapper, type(uint256).max);
        }

        emit RewardsSwapperUpdated(_swapper);
    }

    /**
     * @notice Set emergency recovery completed only when crvUSD is fully sold to asset
     * @dev In extreme cases, LT.emergency_withdraw() must be used to recover assets.
     *      Because this type of withdraw can break the position into BTC + crvUSD, and we do not have full control over it being called on our behalf,
     *      we must explicitly mark "completed" once the crvUSD is fully sold back to asset. Otherwise the strategy will avoid syncing totalAssets to avoid reporting an artificial loss.
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
     */
    function addRewardToken(
        address _token,
        uint256 _minAmountToSell,
        uint256 _maxAmountToSell,
        SwapType _swapType
    ) external onlyManagement {
        _addRewardToken(_token, _minAmountToSell, _maxAmountToSell, _swapType);
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
                allRewardTokens[i] = _allRewardTokens[_length - 1];
                allRewardTokens.pop();
                found = true;
                break;
            }
        }
        require(found, "Not a valid reward token");
        // Revoke approval from swapper
        if (address(rewardsSwapper) != address(0)) {
            ERC20(_token).forceApprove(address(rewardsSwapper), 0);
        }

        delete rewardTokenConfigs[_token];
        emit RewardTokenConfigured(_token, SwapType.NULL, 0, 0);
    }

    /**
     * @notice Update reward token configuration
     * @param _token The reward token address
     * @param _swapType The swap type (SWAP or AUCTION)
     * @param _minAmountToSell Minimum amount to sell
     * @param _maxAmountToSell Maximum amount to sell
     */
    function updateRewardTokenConfig(
        address _token,
        SwapType _swapType,
        uint256 _minAmountToSell,
        uint256 _maxAmountToSell
    ) external onlyManagement {
        RewardTokenConfig memory config = rewardTokenConfigs[_token];

        // Make sure token exists and new swap type is valid
        require(config.swapType != SwapType.NULL, "Not added");
        require(_swapType != SwapType.NULL, "Invalid swap type");
        require(_minAmountToSell <= type(uint120).max, "Min amount too large");
        // Clamp to max uint120
        _maxAmountToSell = _maxAmountToSell > type(uint120).max ? type(uint120).max : _maxAmountToSell;

        // Update all fields
        config.swapType = _swapType;
        config.minAmountToSell = uint120(_minAmountToSell);
        config.maxAmountToSell = uint120(_maxAmountToSell);

        rewardTokenConfigs[_token] = config;
        emit RewardTokenConfigured(_token, _swapType, _minAmountToSell, _maxAmountToSell);
    }

    // ===== INTERNAL HELPERS =====

    /**
     * @notice Calculate debt needed for deposit
     * @param _assetAmount Amount of asset to deposit
     * @return debtAmount Amount of crvUSD debt to take
     * @dev Debt should approximately equal asset value in USD
     *
     * For balanced liquidity add to Curve, we need equal USD values.
     * We approximate this by using the pool's current balance ratio.
     */
    function _calculateDebtForDeposit(uint256 _assetAmount)
        internal
        view
        returns (uint256 debtAmount)
    {
        // Get pool balances to estimate LP mint
        uint256 crvUsdBalance = cryptopool.balances(0); // crvUSD
        uint256 btcBalance = cryptopool.balances(1); // BTC

        // For balanced liquidity add, we need equal USD values
        // So debt should equal asset USD value

        // Simple approximation: debt = assetAmount * (crvUsdBalance / btcBalance)
        // This gives us the ratio of stables to BTC in the pool
        if (btcBalance > 0) {
            debtAmount = (_assetAmount * crvUsdBalance) / btcBalance;
        } else {
            // Fallback: assume 1:1 if pool empty (shouldn't happen)
            debtAmount = _assetAmount;
        }
    }

    /**
     * @notice Calculate shares to withdraw for desired asset amount
     * @param _assetAmount Desired asset amount
     * @param _ltBalance Current LT balance
     * @return shares Shares to burn
     */
    function _calculateSharesToWithdraw(
        uint256 _assetAmount,
        uint256 _ltBalance
    ) internal view returns (uint256 shares) {
        // Use pricePerShare to estimate
        uint256 pricePerShare = ltToken.pricePerShare();

        if (pricePerShare == 0) return 0;

        // shares = assetAmount / pricePerShare
        shares = (_assetAmount * PRECISION) / pricePerShare;

        // Cap at our balance
        if (shares > _ltBalance) {
            shares = _ltBalance;
        }
    }

    /**
     * @notice Add a reward token internally
     * @param _token Token address
     * @param _minAmountToSell Minimum amount to sell
     * @param _maxAmountToSell Maximum amount to sell
     * @param _swapType Swap type
     */
    function _addRewardToken(address _token, uint256 _minAmountToSell, uint256 _maxAmountToSell, SwapType _swapType) internal {
        require(
            _token != address(asset) && _token != address(ltToken),
            "!allowed"
        );

        // Make sure we haven't already set a swap type for this asset
        require(rewardTokenConfigs[_token].swapType == SwapType.NULL, "!exists");

        // Shouldn't add an asset but set to null
        require(_swapType != SwapType.NULL, "!null");

        // Validate amounts fit in uint120
        require(_minAmountToSell <= type(uint120).max, "Min amount too large");
        require(_maxAmountToSell <= type(uint120).max, "Max amount too large");

        allRewardTokens.push(_token);

        // Store config in single slot
        rewardTokenConfigs[_token] = RewardTokenConfig({
            swapType: _swapType,
            minAmountToSell: uint120(_minAmountToSell),
            maxAmountToSell: uint120(_maxAmountToSell)
        });

        // If swapper is set, approve it for this token
        if (address(rewardsSwapper) != address(0)) {
            ERC20(_token).forceApprove(
                address(rewardsSwapper),
                type(uint256).max
            );
        }
        emit RewardTokenConfigured(_token, _swapType, _minAmountToSell, _maxAmountToSell);
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
            _kickAuction(_token);
        }
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
}