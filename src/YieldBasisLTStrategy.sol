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
        AUCTION,   // Yearn Auction system
        TF         // Trade Factory (not used in this strategy, for compatibility)
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

    /// @notice Mapping for token address => swap type
    mapping(address => SwapType) public swapType;

    /// @notice Whether emergency withdraw has been completed and crvUSD fully sold to asset
    bool public emergencyRecoveryCompleted;

    /// @notice Mapping for token address => minimum amount to sell
    mapping(address => uint256) public minAmountToSellMapping;

    /// @notice All reward tokens managed by this strategy
    address[] internal allRewardTokens;

    // ===== CONSTANTS =====

    uint256 internal constant PRECISION = 1e18;

    // ===== EVENTS =====

    event SlippageUpdated(uint256 depositSlippage, uint256 withdrawSlippage);
    event RewardsSwapperUpdated(address swapper);
    event AuctionUpdated(address auction);
    event RewardTokenAdded(address indexed token, uint256 minAmountToSell, SwapType swapType);
    event RewardTokenRemoved(address indexed token);
    event SwapTypeUpdated(address indexed token, SwapType swapType);
    event MinAmountToSellUpdated(address indexed token, uint256 minAmount);
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

        // Verify asset matches
        require(ltToken.ASSET_TOKEN() == _asset, "Asset mismatch");

        // Default configuration
        maxDepositSlippage = 50; // 0.5%
        maxWithdrawSlippage = 50; // 0.5%

        // Approve LT contract to spend asset
        asset.safeApprove(_ltToken, type(uint256).max);

        // Add stablecoin as reward token since emergency_withdraw can return crvUSD
        _addRewardToken(address(stablecoin), 1e18, SwapType.AUCTION);
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
     *
     * Process:
     * 1. Calculate shares needed to get _amount of assets
     * 2. Calculate minimum assets with slippage tolerance
     * 3. Call LT.withdraw() which:
     *    - Withdraws from AMM (reduces debt)
     *    - Removes Curve LP symmetrically
     *    - Repays crvUSD debt
     *    - Returns asset tokens to us
     */
    function _freeFunds(uint256 _amount) internal override {
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

        // Sell any stablecoin balance (from emergency_withdraw)
        uint256 stablecoinBalance = stablecoin.balanceOf(address(this));
        if (stablecoinBalance > minAmountToSellMapping[address(stablecoin)]) {
            _swapRewardForAsset(address(stablecoin), stablecoinBalance);
        }

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

        // Clamp to our balance
        sharesToBurn = sharesToBurn > ltBalance ? ltBalance : sharesToBurn;

        // Step 2: Withdraw from LT. Emergency withdraw must be used when AMM is killed.
        if (ltToken.is_killed()) {
            ltToken.emergency_withdraw(sharesToBurn, address(this), address(this));
        } else if (sharesToBurn > 0) {
            uint256 expectedAssets = ltToken.pricePerShare() * sharesToBurn / PRECISION;
            uint256 minAssets =
                (expectedAssets * (MAX_BPS - maxWithdrawSlippage)) / MAX_BPS;
            // Normal withdraw
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

        // Revoke approvals from old swapper for all reward tokens
        address[] memory allTokens = allRewardTokens;
        if (address(rewardsSwapper) != address(0)) {
            for (uint256 i = 0; i < allTokens.length; i++) {
                ERC20(allTokens[i]).forceApprove(address(rewardsSwapper), 0);
            }
        }

        // Set new swapper
        rewardsSwapper = RewardsSwapper(_swapper);

        // Grant unlimited approvals to new swapper for all reward tokens
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
        require(swapType[_token] == SwapType.AUCTION, "!auction");
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
     * @notice Add a new reward token to manage
     * @param _token The reward token address
     * @param _minAmountToSell Minimum amount to sell
     * @param _swapType The swap type for this token
     */
    function addRewardToken(
        address _token,
        uint256 _minAmountToSell,
        SwapType _swapType
    ) external onlyManagement {
        _addRewardToken(_token, _minAmountToSell, _swapType);
    }

    /**
     * @notice Remove a reward token from management
     * @param _token The reward token address to remove
     */
    function removeRewardToken(address _token) external onlyManagement {
        address[] memory _allRewardTokens = allRewardTokens;
        uint256 _length = _allRewardTokens.length;

        for (uint256 i; i < _length; ++i) {
            if (_allRewardTokens[i] == _token) {
                allRewardTokens[i] = _allRewardTokens[_length - 1];
                allRewardTokens.pop();
                break;
            }
        }

        // Revoke approval from swapper
        if (address(rewardsSwapper) != address(0)) {
            ERC20(_token).forceApprove(address(rewardsSwapper), 0);
        }

        delete swapType[_token];
        delete minAmountToSellMapping[_token];

        emit RewardTokenRemoved(_token);
    }

    /**
     * @notice Set the swap type for a specific reward token
     * @param _token The reward token address
     * @param _swapType The new swap type
     */
    function setSwapType(
        address _token,
        SwapType _swapType
    ) external onlyManagement {
        // Make sure we already have this token configured
        require(
            _swapType != SwapType.NULL && swapType[_token] != SwapType.NULL,
            "!null"
        );

        swapType[_token] = _swapType;
        emit SwapTypeUpdated(_token, _swapType);
    }

    /**
     * @notice Set the minimum amount to sell for a specific token
     * @param _token The token address
     * @param _amount Minimum amount to sell
     */
    function setMinAmountToSellMapping(
        address _token,
        uint256 _amount
    ) external onlyManagement {
        minAmountToSellMapping[_token] = _amount;
        emit MinAmountToSellUpdated(_token, _amount);
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
     * @param _swapType Swap type
     */
    function _addRewardToken(address _token, uint256 _minAmountToSell, SwapType _swapType) internal {
        require(
            _token != address(asset) && _token != address(ltToken),
            "!allowed"
        );

        // Make sure we haven't already set a swap type for this asset
        require(swapType[_token] == SwapType.NULL, "!exists");

        // Shouldn't add an asset but set to null
        require(_swapType != SwapType.NULL, "!null");

        allRewardTokens.push(_token);
        swapType[_token] = _swapType;

        // If swapper is set, approve it for this token
        if (address(rewardsSwapper) != address(0)) {
            ERC20(_token).forceApprove(
                address(rewardsSwapper),
                type(uint256).max
            );
        }

        minAmountToSellMapping[_token] = _minAmountToSell;

        emit RewardTokenAdded(_token, _minAmountToSell, _swapType);
    }

    /**
     * @notice Swap reward tokens for asset
     * @param _token Reward token address
     * @param _amount Amount of reward token to sell
     * @return assetReceived Amount of asset received
     * @dev Routes based on swapType mapping: NULL (no swap), SWAP (router), or AUCTION
     */
    function _swapRewardForAsset(address _token, uint256 _amount)
        internal
        returns (uint256 assetReceived)
    {
        if (_amount == 0 || swapType[_token] == SwapType.NULL) {
            return 0;
        }

        if (swapType[_token] == SwapType.SWAP) {
            // Use RewardsSwapper for DEX swaps
            require(address(rewardsSwapper) != address(0), "Swapper not set");

            // Execute swap through RewardsSwapper (minOut = 0 uses route default)
            assetReceived = rewardsSwapper.swap(_token, _amount, 0);
        } else if (swapType[_token] == SwapType.AUCTION) {
            // Transfer to auction (settles asynchronously)
            ERC20(_token).safeTransfer(auction, _amount);
            return 0;
        }

        return assetReceived;
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

        uint256 _balance = ERC20(_from).balanceOf(address(this));
        require(
            _balance > minAmountToSellMapping[_from],
            "Not enough to sell"
        );

        ERC20(_from).safeTransfer(auction, _balance);
        return IAuction(auction).kick(_from);
    }
}