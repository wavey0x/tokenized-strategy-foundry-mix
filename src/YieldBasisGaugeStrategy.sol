// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {BaseStrategy, ERC20} from "@tokenized-strategy/BaseStrategy.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// Import interfaces for Yield Basis protocol
import {ILT} from "./interfaces/yb/ILT.sol";
import {ILiquidityGauge} from "./interfaces/yb/ILiquidityGauge.sol";
import {IGaugeController} from "./interfaces/yb/IGaugeController.sol";
import {ICurveCryptoPool} from "./interfaces/yb/ICurveCryptoPool.sol";
import {IAuction} from "./interfaces/IAuction.sol";
import {RewardsSwapper} from "./RewardsSwapper.sol";

/**
 * @title YieldBasisGaugeStrategy
 * @author Yearn Finance
 * @notice Yearn V3 strategy that stakes Yield Basis LT tokens for YB emissions
 * @dev Staked strategy - earns YB tokens but foregoes trading fees
 *
 * This strategy provides exposure to YB governance token emissions by staking ybBTC.
 * Users deposit BTC → strategy deposits to LT → stakes in Gauge → earns YB → sells for BTC.
 *
 * Key features:
 * - 2x leverage on Curve BTC/crvUSD LP without impermanent loss
 * - Tracks BTC price 1:1
 * - Earns YB token emissions (based on veYB vote weights)
 * - Auto-harvests and sells YB for BTC (optional)
 * - Foregoes direct trading fees (those go to veYB holders)
 */
contract YieldBasisGaugeStrategy is BaseStrategy {
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

    // ===== CONFIGURATION =====

    /// @notice Maximum slippage for deposits (in basis points)
    uint256 public maxDepositSlippage;

    /// @notice Maximum slippage for withdrawals (in basis points)
    uint256 public maxWithdrawSlippage;

    /// @notice Maximum slippage for reward → asset swaps (in basis points)
    uint256 public maxSwapSlippage;

    /// @notice Whether to automatically harvest and sell rewards
    bool public autoHarvest;

    /// @notice RewardsSwapper contract for DEX swaps
    RewardsSwapper public rewardsSwapper;

    /// @notice Auction contract for reward token sales
    address public auction;

    /// @notice Mapping for token address => swap type
    mapping(address => SwapType) public swapType;

    /// @notice Mapping for token address => minimum amount to sell
    mapping(address => uint256) public minAmountToSellMapping;

    /// @notice All reward tokens managed by this strategy
    address[] internal allRewardTokens;

    // ===== CONSTANTS =====

    uint256 internal constant MAX_BPS = 10_000;
    uint256 internal constant PRECISION = 1e18;

    // ===== EVENTS =====

    event SlippageUpdated(
        uint256 depositSlippage,
        uint256 withdrawSlippage,
        uint256 swapSlippage
    );
    event AutoHarvestUpdated(bool enabled);
    event RewardsSwapperUpdated(address swapper);
    event AuctionUpdated(address auction);
    event RewardTokenAdded(address indexed token, SwapType swapType);
    event RewardTokenRemoved(address indexed token);
    event SwapTypeUpdated(address indexed token, SwapType swapType);
    event MinAmountToSellUpdated(address indexed token, uint256 minAmount);

    // ===== CONSTRUCTOR =====

    /**
     * @notice Initialize the strategy
     * @param _asset Underlying asset (e.g., WBTC, cbBTC)
     * @param _name Strategy name
     * @param _ltToken LT contract address
     * @param _gauge LiquidityGauge contract address
     * @param _cryptopool Curve cryptopool address
     * @param _swapType Initial swap type for YB tokens
     */
    constructor(
        address _asset,
        string memory _name,
        address _ltToken,
        address _gauge,
        address _cryptopool,
        SwapType _swapType
    ) BaseStrategy(_asset, _name) {
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
        maxSwapSlippage = 100; // 1% for reward swaps
        autoHarvest = true;

        // Set up YB as the default reward token
        allRewardTokens.push(address(ybToken));
        swapType[address(ybToken)] = _swapType;
        minAmountToSellMapping[address(ybToken)] = 1e18; // 1 YB token

        // Approvals
        asset.safeApprove(_ltToken, type(uint256).max);
        ERC20(_ltToken).safeApprove(_gauge, type(uint256).max);
    }

    // ===== REQUIRED OVERRIDES =====

    /**
     * @notice Deploy assets into LT token and stake in gauge
     * @param _amount Amount of asset to deploy
     */
    function _deployFunds(uint256 _amount) internal override {
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
        // Step 1: Calculate gauge shares needed
        uint256 gaugeShares = gauge.balanceOf(address(this));
        if (gaugeShares == 0) return;

        uint256 sharesToRedeem =
            _calculateGaugeSharesToWithdraw(_amount, gaugeShares);
        if (sharesToRedeem == 0) return;

        sharesToRedeem =
            sharesToRedeem > gaugeShares ? gaugeShares : sharesToRedeem;

        // Step 2: Redeem from gauge (get LT back)
        uint256 ltReceived =
            gauge.redeem(sharesToRedeem, address(this), address(this));

        // Step 3: Withdraw from LT to asset
        if (ltReceived > 0) {
            uint256 expectedAssets = ltToken.preview_withdraw(ltReceived);
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
     * 1. Claim YB rewards from gauge (if autoHarvest enabled)
     * 2. Sell YB for asset
     * 3. Calculate total: gaugeShares → LT → asset value + loose assets
     */
    function _harvestAndReport()
        internal
        override
        returns (uint256 _totalAssets)
    {
        if (!TokenizedStrategy.isShutdown()) {
            _harvestRewards();
        }

        // Calculate total assets
        uint256 gaugeShares = gauge.balanceOf(address(this));
        uint256 looseAssets = asset.balanceOf(address(this));

        // Convert gauge shares → LT → asset value
        uint256 ltEquivalent = gauge.convertToAssets(gaugeShares);
        uint256 assetValue =
            (ltEquivalent * ltToken.pricePerShare()) / PRECISION;

        _totalAssets = assetValue + looseAssets;
    }

    // ===== OPTIONAL OVERRIDES =====

    /**
     * @notice Return maximum withdrawable assets
     * @return Maximum amount that can be withdrawn
     */
    function availableWithdrawLimit(address)
        public
        view
        override
        returns (uint256)
    {
        // Get gauge shares and convert to LT equivalent
        uint256 gaugeShares = gauge.balanceOf(address(this));
        uint256 ltEquivalent = gauge.convertToAssets(gaugeShares);

        if (ltToken.is_killed()) {
            // Conservative estimate during killed state
            return (ltEquivalent * ltToken.pricePerShare()) / PRECISION;
        }

        // Normal operation
        uint256 looseAssets = asset.balanceOf(address(this));
        uint256 maxFromGauge = ltToken.preview_withdraw(ltEquivalent);

        return maxFromGauge + looseAssets;
    }

    /**
     * @notice Emergency withdraw when killed
     * @param _amount Amount to withdraw
     */
    function _emergencyWithdraw(uint256 _amount) internal override {
        bool isKilled = ltToken.is_killed();

        // Step 1: Unstake from gauge
        uint256 gaugeShares = gauge.balanceOf(address(this));
        if (gaugeShares > 0) {
            uint256 sharesToRedeem =
                _calculateGaugeSharesToWithdraw(_amount, gaugeShares);
            sharesToRedeem =
                sharesToRedeem > gaugeShares ? gaugeShares : sharesToRedeem;

            // In killed state, emergency admin can force redeem
            uint256 ltReceived =
                gauge.redeem(sharesToRedeem, address(this), address(this));

            // Step 2: Emergency withdraw from LT
            if (isKilled && ltReceived > 0) {
                try ltToken.emergency_withdraw(
                    ltReceived, address(this), address(this)
                ) returns (uint256, int256) {
                    // Success
                } catch {
                    // Failed - leave in place
                }
            } else if (ltReceived > 0) {
                // Normal withdraw
                uint256 minAssets = 0; // Accept any amount in emergency
                ltToken.withdraw(ltReceived, minAssets, address(this));
            }
        }
    }

    // ===== HARVEST FUNCTIONS =====

    /**
     * @notice Harvest YB rewards and sell for asset
     * @dev Internal function called during _harvestAndReport
     */
    function _harvestRewards() internal {
        // Sell YB for asset based on configured swap type
        for (uint256 i = 0; i < allRewardTokens.length; i++) {
            address token = allRewardTokens[i];
            gauge.claim(token, address(this));
            uint256 amount = ERC20(token).balanceOf(address(this));
            if (amount < minAmountToSellMapping[token]) {
                continue;
            }
            _swapRewardForAsset(token, amount);
        }
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

            // Approve swapper to spend reward token
            ERC20(_token).safeApprove(address(rewardsSwapper), _amount);

            // Execute swap through RewardsSwapper (minOut = 0 uses route default)
            assetReceived = rewardsSwapper.swap(_token, _amount, 0);
        } else if (swapType[_token] == SwapType.AUCTION) {
            // Transfer to auction (settles asynchronously)
            ERC20(_token).safeTransfer(auction, _amount);
            return 0;
        }

        return assetReceived;
    }

    // ===== MANAGEMENT FUNCTIONS =====

    /**
     * @notice Set slippage tolerances
     */
    function setSlippage(
        uint256 _depositSlippage,
        uint256 _withdrawSlippage,
        uint256 _swapSlippage
    ) external onlyManagement {
        require(_depositSlippage <= 500, "Deposit slippage too high");
        require(_withdrawSlippage <= 500, "Withdraw slippage too high");
        require(_swapSlippage <= 500, "Swap slippage too high");

        maxDepositSlippage = _depositSlippage;
        maxWithdrawSlippage = _withdrawSlippage;
        maxSwapSlippage = _swapSlippage;

        emit SlippageUpdated(_depositSlippage, _withdrawSlippage, _swapSlippage);
    }

    /**
     * @notice Toggle auto-harvest
     */
    function setAutoHarvest(bool _enabled) external onlyManagement {
        autoHarvest = _enabled;
        emit AutoHarvestUpdated(_enabled);
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
        if (address(rewardsSwapper) != address(0)) {
            address[] memory oldTokens = allRewardTokens;
            for (uint256 i = 0; i < oldTokens.length; i++) {
                ERC20(oldTokens[i]).safeApprove(address(rewardsSwapper), 0);
            }
        }

        // Set new swapper
        rewardsSwapper = RewardsSwapper(_swapper);

        // Grant unlimited approvals to new swapper for all reward tokens
        address[] memory tokens = allRewardTokens;
        for (uint256 i = 0; i < tokens.length; i++) {
            ERC20(tokens[i]).safeApprove(_swapper, type(uint256).max);
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
        require(swapType[_token] == SwapType.AUCTION, "!auction");
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

        uint256 _balance = ERC20(_from).balanceOf(address(this));
        require(
            _balance > minAmountToSellMapping[_from],
            "Not enough to sell"
        );

        ERC20(_from).safeTransfer(auction, _balance);
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
     * @notice Add a new reward token to manage
     * @param _token The reward token address
     * @param _swapType The swap type for this token
     */
    function addRewardToken(
        address _token,
        SwapType _swapType
    ) external onlyManagement {
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

        // If swapper is set and this token will use SWAP type, approve it
        if (
            address(rewardsSwapper) != address(0) && _swapType == SwapType.SWAP
        ) {
            ERC20(_token).safeApprove(
                address(rewardsSwapper),
                type(uint256).max
            );
        }

        emit RewardTokenAdded(_token, _swapType);
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
        uint256 _assetAmount,
        uint256 _gaugeShares
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