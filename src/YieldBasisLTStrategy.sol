// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {BaseStrategy, ERC20} from "@tokenized-strategy/BaseStrategy.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// Import interfaces for Yield Basis protocol
import {ILT} from "./interfaces/yb/ILT.sol";
import {ICurveCryptoPool} from "./interfaces/yb/ICurveCryptoPool.sol";

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
contract YieldBasisLTStrategy is BaseStrategy {
    using SafeERC20 for ERC20;

    // ===== IMMUTABLE STATE =====

    /// @notice Yield Basis LT contract (e.g., yb-WBTC)
    ILT public immutable ltToken;

    /// @notice Curve Cryptopool for LP pricing
    ICurveCryptoPool public immutable cryptopool;

    /// @notice Stablecoin used for debt (crvUSD)
    ERC20 public immutable stablecoin;

    // ===== CONFIGURATION =====

    /// @notice Maximum slippage for deposits (in basis points, e.g., 50 = 0.5%)
    uint256 public maxDepositSlippage;

    /// @notice Maximum slippage for withdrawals (in basis points)
    uint256 public maxWithdrawSlippage;

    // ===== CONSTANTS =====

    uint256 internal constant MAX_BPS = 10_000;
    uint256 internal constant PRECISION = 1e18;

    // ===== EVENTS =====

    event SlippageUpdated(uint256 depositSlippage, uint256 withdrawSlippage);

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
    ) BaseStrategy(_asset, _name) {
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
        view
        override
        returns (uint256 _totalAssets)
    {
        // Calculate current balances
        uint256 ltBalance = ltToken.balanceOf(address(this));
        uint256 looseAssets = asset.balanceOf(address(this));

        // Check if market is killed
        if (ltToken.is_killed()) {
            // In killed state, use emergency accounting
            // Don't try to harvest, just report current convertible value

            // Estimate withdrawable value using pricePerShare
            uint256 ltValue = (ltBalance * ltToken.pricePerShare()) / PRECISION;
            _totalAssets = ltValue + looseAssets;

            return _totalAssets;
        }

        // Normal operation: fees accrue automatically via LT price appreciation
        // No explicit harvest needed - yield is built into pricePerShare()

        // Convert LT tokens to asset value using pricePerShare
        // pricePerShare already accounts for accumulated trading fees
        uint256 ltValueInAsset =
            (ltBalance * ltToken.pricePerShare()) / PRECISION;

        _totalAssets = ltValueInAsset + looseAssets;
    }

    // ===== OPTIONAL OVERRIDES =====

    /**
     * @notice Return maximum withdrawable assets
     * @param _owner Owner address (unused)
     * @return Maximum withdrawable amount
     * @dev Checks LT balance and potential illiquidity
     */
    function availableWithdrawLimit(address _owner)
        public
        view
        override
        returns (uint256)
    {
        _owner; // Silence unused parameter warning

        // Get LT balance
        uint256 ltBalance = ltToken.balanceOf(address(this));

        // Check if killed
        if (ltToken.is_killed()) {
            // During killed state, withdrawals may be limited
            // Return conservative estimate
            return (ltBalance * ltToken.pricePerShare()) / PRECISION;
        }

        // Normal operation
        uint256 looseAssets = asset.balanceOf(address(this));

        // Maximum we can withdraw from LT
        uint256 maxFromLT = ltToken.preview_withdraw(ltBalance);

        return maxFromLT + looseAssets;
    }

    /**
     * @notice Emergency withdraw when market is killed
     * @param _amount Amount to attempt to withdraw
     * @dev Uses emergency_withdraw which may require user to bring stables
     *
     * NOTE: In killed state with negative stables balance, emergency_withdraw
     * may require bringing crvUSD to cover the shortfall. This implementation
     * accepts whatever can be withdrawn without additional stables.
     */
    function _emergencyWithdraw(uint256 _amount) internal override {
        if (!ltToken.is_killed()) {
            // Use normal withdrawal
            _freeFunds(_amount);
            return;
        }

        // Market is killed - use emergency withdrawal
        uint256 ltBalance = ltToken.balanceOf(address(this));
        if (ltBalance == 0) return;

        uint256 sharesToBurn = _calculateSharesToWithdraw(_amount, ltBalance);
        sharesToBurn = sharesToBurn > ltBalance ? ltBalance : sharesToBurn;

        // Emergency withdraw returns (assets, stables)
        // If stables < 0, we need to bring them (complex - may revert)
        try ltToken.emergency_withdraw(
            sharesToBurn, address(this), address(this)
        ) returns (uint256, int256) {
            // Success - withdrew what we could
        } catch {
            // If emergency withdraw fails (e.g., need to bring stables),
            // leave funds in place. Management should handle manually.
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
        uint256 balance0 = cryptopool.balances(0); // crvUSD
        uint256 balance1 = cryptopool.balances(1); // BTC

        // For balanced liquidity add, we need equal USD values
        // So debt (in USD, assuming crvUSD ≈ $1) should equal asset USD value

        // Simple approximation: debt = assetAmount × (balance0 / balance1)
        // This gives us the ratio of stables to BTC in the pool
        if (balance1 > 0) {
            debtAmount = (_assetAmount * balance0) / balance1;
        } else {
            // Fallback: assume 1:1 if pool empty (shouldn't happen)
            debtAmount = _assetAmount;
        }

        // For first deposit, LT will optimize this internally
        // For subsequent deposits, preview_deposit will validate
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
}