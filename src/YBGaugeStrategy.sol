// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {ERC20} from "@tokenized-strategy/BaseStrategy.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// Import interfaces for Yield Basis protocol
import {ILT} from "./interfaces/yb/ILT.sol";
import {ILiquidityGauge} from "./interfaces/yb/ILiquidityGauge.sol";
import {IGaugeController} from "./interfaces/yb/IGaugeController.sol";
import {IAuction} from "./interfaces/IAuction.sol";
import {RewardsSwapper} from "./RewardsSwapper.sol";
import {BaseHealthCheck} from "@periphery/Bases/HealthCheck/BaseHealthCheck.sol";

/**
 * @title YBGaugeStrategy
 * @author Yearn Finance
 * @notice Yearn V3 strategy that stakes LT tokens in Yield Basis gauge for YB emissions
 * @dev Simplified staker strategy - takes LT as asset, stakes in gauge, earns YB rewards
 *
 * This strategy is designed to be used with an LT Vault (not a BTC Vault).
 * Users deposit LT → strategy stakes in Gauge → earns YB → sells for LT.
 *
 * Key features:
 * - Direct LT → Gauge staking (no BTC conversion)
 * - Earns YB governance token emissions
 * - Sells YB rewards for more LT
 */
contract YBGaugeStrategy is BaseHealthCheck {
    using SafeERC20 for ERC20;

    // ===== IMMUTABLE STATE =====

    /// @notice Yearn Vault that owns this strategy
    address public immutable vault;

    /// @notice Liquidity Gauge for staking LT
    ILiquidityGauge public immutable gauge;

    /// @notice YB governance token
    ERC20 public immutable ybToken;

    /// @notice Gauge Controller (for emissions preview)
    IGaugeController public immutable gaugeController;

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

    /// @notice RewardsSwapper contract for direct DEX swaps
    RewardsSwapper public rewardsSwapper;

    /// @notice Auction contract for reward token sales
    address public auction;

    /// @notice Mapping of token address to reward configuration (packed in 1 slot)
    mapping(address => RewardTokenConfig) public rewardTokenConfigs;

    /// @notice All reward tokens managed by this strategy
    address[] internal allRewardTokens;

    // ===== EVENTS =====

    event RewardsSwapperUpdated(address swapper);
    event AuctionUpdated(address auction);
    event RewardTokenConfigured(
        address indexed token,
        SwapType swapType,
        uint256 minAmountToSell,
        uint256 maxAmountToSell,
        bool shouldClaim
    );

    // ===== CONSTRUCTOR =====

    /**
     * @notice Initialize the strategy
     * @param _ltToken LT token address (this is the asset!)
     * @param _name Strategy name
     * @param _gauge LiquidityGauge contract address
     * @param _vault Yearn Vault that will own this strategy
     */
    constructor(
        address _ltToken,
        string memory _name,
        address _gauge,
        address _vault
    ) BaseHealthCheck(_ltToken, _name) {
        vault = _vault;
        gauge = ILiquidityGauge(_gauge);

        // Get YB and GC from gauge
        ybToken = ERC20(gauge.YB());
        gaugeController = IGaugeController(gauge.GC());

        // Verify gauge accepts this LT token
        require(gauge.LP_TOKEN() == _ltToken, "Gauge LP mismatch");

        // Approve gauge to spend LT
        asset.safeApprove(_gauge, type(uint256).max);

        // Add YB as reward token
        _addRewardToken(address(ybToken), SwapType.AUCTION, 1e18, 100_000e18, true);
    }

    // ===== REQUIRED OVERRIDES =====

    /**
     * @notice Deploy LT into gauge
     * @param _amount Amount of LT to stake
     */
    function _deployFunds(uint256 _amount) internal override {
        if (TokenizedStrategy.isShutdown()) return;
        if (_amount == 0) return;

        // Direct stake: LT → Gauge
        gauge.deposit(_amount, address(this));
    }

    /**
     * @notice Unstake LT from gauge
     * @param _amount Amount of LT to withdraw
     */
    function _freeFunds(uint256 _amount) internal override {
        uint256 gaugeShares = gauge.balanceOf(address(this));
        if (gaugeShares == 0) return;

        // Calculate gauge shares needed for _amount of LT
        uint256 sharesToRedeem = gauge.convertToShares(_amount);

        // Clamp to our balance
        sharesToRedeem = sharesToRedeem > gaugeShares ? gaugeShares : sharesToRedeem;

        if (sharesToRedeem == 0) return;

        // Unstake from gauge (get LT back)
        gauge.redeem(sharesToRedeem, address(this), address(this));
    }

    /**
     * @notice Harvest YB rewards and report total assets
     * @return _totalAssets Total LT held by strategy
     *
     * Process:
     * 1. Claim YB rewards from gauge
     * 2. Sell YB for LT
     * 3. Calculate total: gauge shares (in LT terms) + loose LT
     */
    function _harvestAndReport()
        internal
        override
        returns (uint256 _totalAssets)
    {
        // Harvest and sell rewards
        if (!TokenizedStrategy.isShutdown()) {
            _harvestRewards();
        }

        // Convert gauge shares to LT equivalent
        uint256 gaugeShares = gauge.balanceOf(address(this));
        uint256 ltInGauge = gauge.convertToAssets(gaugeShares);

        _totalAssets = ltInGauge + asset.balanceOf(address(this));
    }

    // ===== OPTIONAL OVERRIDES =====

    /**
     * @notice Restrict deposits to vault only
     * @param _owner Address attempting to deposit
     * @return Maximum amount that can be deposited (0 if not vault)
     */
    function availableDepositLimit(address _owner)
        public
        view
        override
        returns (uint256)
    {
        // Only the vault can deposit
        if (_owner != vault) return 0;
        return type(uint256).max;
    }

    /**
     * @notice Emergency withdraw from gauge
     * @param _amount Amount to withdraw
     */
    function _emergencyWithdraw(uint256 _amount) internal override {
        uint256 gaugeShares = gauge.balanceOf(address(this));
        if (gaugeShares == 0) return;

        uint256 sharesToRedeem = gauge.convertToShares(_amount);
        sharesToRedeem = sharesToRedeem > gaugeShares ? gaugeShares : sharesToRedeem;

        if (sharesToRedeem > 0) {
            gauge.redeem(sharesToRedeem, address(this), address(this));
        }
    }

    // ===== HARVEST FUNCTIONS =====

    /**
     * @notice Harvest rewards and sell for LT
     * @dev Internal function called during _harvestAndReport
     */
    function _harvestRewards() internal {
        for (uint256 i = 0; i < allRewardTokens.length; i++) {
            address token = allRewardTokens[i];
            RewardTokenConfig memory config = rewardTokenConfigs[token];

            // Claim if configured
            if (config.shouldClaim) {
                gauge.claim(token, address(this));
            }

            uint256 amount = ERC20(token).balanceOf(address(this));

            // Sell if above minimum
            if (config.swapType != SwapType.NULL && amount > config.minAmountToSell) {
                _swapRewardForAsset(token, amount);
            }
        }
    }

    /**
     * @notice Swap reward tokens for LT
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
        require(_from != address(asset), "cannot kick");
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
     * @param _swapType The swap type for this token
     * @param _minAmountToSell Minimum amount to sell
     * @param _maxAmountToSell Maximum amount to sell
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

    function _addRewardToken(
        address _token,
        SwapType _swapType,
        uint256 _minAmountToSell,
        uint256 _maxAmountToSell,
        bool _shouldClaim
    ) internal {
        require(_token != address(asset) && _token != address(gauge), "!allowed");
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
}
