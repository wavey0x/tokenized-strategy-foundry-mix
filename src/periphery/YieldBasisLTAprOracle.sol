// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {AprOracleBase} from "@periphery/AprOracle/AprOracleBase.sol";
import {ILT} from "../interfaces/yb/ILT.sol";
import {ILiquidityGauge} from "../interfaces/yb/ILiquidityGauge.sol";
import {ICurveCryptoPool} from "../interfaces/yb/ICurveCryptoPool.sol";

/**
 * @title YieldBasisLTAprOracle
 * @author Yearn Finance
 * @notice APR oracle for YieldBasisLTStrategy (unstaked LT token strategy)
 * @dev Calculates APR from Curve trading fees after dynamic admin fee
 *
 * This oracle calculates the expected APR for holders of unstaked LT tokens.
 * The yield comes from trading fees in the underlying Curve pool, net of the
 * dynamic admin fee that increases as more LT is staked in the gauge.
 *
 * Dynamic Admin Fee Formula:
 * f_a = 1 - (1 - f_min) × √(1 - s/T)
 *
 * Where:
 * - f_a = admin fee rate (goes to veYB holders)
 * - f_min = minimum admin fee (10%)
 * - s = total staked LT in gauge
 * - T = total LT supply
 *
 * User Fee Rate:
 * f_user = (1 - f_a) × pool_fee
 *
 * The APR is calculated by:
 * 1. Get recent trading volume from Curve pool
 * 2. Calculate fees generated: volume × pool_fee
 * 3. Calculate admin fee based on staking ratio
 * 4. Calculate net fees to LT holders: fees × (1 - f_a)
 * 5. Annualize: (net_fees / tvl) × periods_per_year
 */
contract YieldBasisLTAprOracle is AprOracleBase {
    // ===== CONSTANTS =====

    uint256 internal constant PRECISION = 1e18;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant MIN_ADMIN_FEE_BPS = 1_000; // 10% minimum admin fee
    uint256 internal constant SECONDS_PER_YEAR = 365 days;

    // ===== IMMUTABLE STATE =====

    /// @notice Yield Basis LT contract
    ILT public immutable ltToken;

    /// @notice Liquidity Gauge (for staking ratio)
    ILiquidityGauge public immutable gauge;

    /// @notice Curve cryptopool (for fees and volume)
    ICurveCryptoPool public immutable cryptopool;

    // ===== CONFIGURATION =====

    /// @notice Lookback period for volume estimation (default: 7 days)
    uint256 public lookbackPeriod;

    /// @notice Last recorded pool balance for volume estimation
    uint256 public lastBalance0;
    uint256 public lastBalance1;
    uint256 public lastUpdateTimestamp;

    // ===== CONSTRUCTOR =====

    /**
     * @notice Initialize the APR oracle
     * @param _name Oracle name
     * @param _governance Governance address
     * @param _ltToken LT contract address
     * @param _gauge Liquidity Gauge address
     * @param _cryptopool Curve cryptopool address
     */
    constructor(
        string memory _name,
        address _governance,
        address _ltToken,
        address _gauge,
        address _cryptopool
    ) AprOracleBase(_name, _governance) {
        ltToken = ILT(_ltToken);
        gauge = ILiquidityGauge(_gauge);
        cryptopool = ICurveCryptoPool(_cryptopool);

        // Default lookback: 7 days
        lookbackPeriod = 7 days;

        // Initialize balance tracking
        lastBalance0 = cryptopool.balances(0);
        lastBalance1 = cryptopool.balances(1);
        lastUpdateTimestamp = block.timestamp;
    }

    // ===== APR CALCULATION =====

    /**
     * @notice Calculate current APR for LT strategy
     * @param _strategy Strategy address (unused, for interface compatibility)
     * @return apr Current APR in basis points (e.g., 500 = 5%)
     *
     * APR Formula:
     * apr = (estimated_annual_fees / tvl) × 10000
     *
     * Where estimated_annual_fees accounts for:
     * - Trading volume in underlying Curve pool
     * - Pool fee rate
     * - Dynamic admin fee based on staking ratio
     */
    function aprAfterDebtChange(address _strategy, int256)
        external
        view
        override
        returns (uint256 apr)
    {
        _strategy; // Silence unused parameter warning

        // Get current state
        uint256 ltTotalSupply = ltToken.totalSupply();
        if (ltTotalSupply == 0) return 0;

        uint256 ltTVL = _calculateLTValue(ltTotalSupply);
        if (ltTVL == 0) return 0;

        // Calculate dynamic admin fee
        uint256 adminFeeRate = _calculateAdminFee();

        // Estimate annual trading fees
        uint256 annualFees = _estimateAnnualFees();

        // Calculate net fees to LT holders (after admin fee)
        uint256 netFeesToLT = (annualFees * (BPS - adminFeeRate)) / BPS;

        // Calculate APR in basis points
        apr = (netFeesToLT * BPS) / ltTVL;
    }

    // ===== INTERNAL HELPERS =====

    /**
     * @notice Calculate dynamic admin fee based on staking ratio
     * @return adminFee Admin fee rate in basis points
     *
     * Formula: f_a = 1 - (1 - f_min) × √(1 - s/T)
     *
     * Where:
     * - f_min = 0.1 (10%)
     * - s = staked LT
     * - T = total LT
     */
    function _calculateAdminFee() internal view returns (uint256 adminFee) {
        uint256 totalLT = ltToken.totalSupply();
        if (totalLT == 0) return MIN_ADMIN_FEE_BPS;

        uint256 stakedLT = gauge.totalAssets(); // Total LT staked in gauge

        // If no staking, use minimum admin fee
        if (stakedLT == 0) return MIN_ADMIN_FEE_BPS;

        // Calculate staking ratio: s/T
        uint256 stakingRatio = (stakedLT * PRECISION) / totalLT;

        // Cap at 100% (shouldn't happen, but safety check)
        if (stakingRatio >= PRECISION) {
            // At 100% staking, admin fee approaches 100%
            return BPS; // 100%
        }

        // Calculate: 1 - s/T
        uint256 oneMinusStakingRatio = PRECISION - stakingRatio;

        // Calculate: √(1 - s/T)
        uint256 sqrtTerm = _sqrt(oneMinusStakingRatio);

        // Calculate: (1 - f_min) × √(1 - s/T)
        // f_min = 0.1, so (1 - f_min) = 0.9 = 9000 bps
        uint256 term = (9000 * sqrtTerm) / PRECISION;

        // Calculate: f_a = 1 - term = 10000 - term
        if (term >= BPS) return MIN_ADMIN_FEE_BPS;

        adminFee = BPS - term;

        // Ensure minimum
        if (adminFee < MIN_ADMIN_FEE_BPS) {
            adminFee = MIN_ADMIN_FEE_BPS;
        }
    }

    /**
     * @notice Estimate annual trading fees from Curve pool
     * @return annualFees Estimated annual fees in asset terms
     *
     * This uses historical volume to estimate future fees.
     * In production, could be enhanced with:
     * - Oracle-based volume tracking
     * - Multiple lookback periods
     * - Weighted average of recent periods
     */
    function _estimateAnnualFees() internal view returns (uint256 annualFees) {
        // Get current pool state
        uint256 currentBalance0 = cryptopool.balances(0);
        uint256 currentBalance1 = cryptopool.balances(1);

        // Calculate balance changes (proxy for volume)
        uint256 deltaBalance0 =
            currentBalance0 > lastBalance0 ? currentBalance0 - lastBalance0 : 0;
        uint256 deltaBalance1 =
            currentBalance1 > lastBalance1 ? currentBalance1 - lastBalance1 : 0;

        // Estimate volume in last period (sum of balance increases)
        uint256 estimatedVolume = deltaBalance0 + deltaBalance1;

        // Get pool fee rate
        uint256 poolFeeRate = cryptopool.mid_fee(); // In basis points

        // Calculate fees generated in lookback period
        uint256 periodFees = (estimatedVolume * poolFeeRate) / BPS;

        // Annualize
        uint256 timePassed = block.timestamp - lastUpdateTimestamp;
        if (timePassed == 0) return 0;

        annualFees = (periodFees * SECONDS_PER_YEAR) / timePassed;

        // If no historical data, use fallback estimate
        if (annualFees == 0) {
            // Fallback: Assume 0.5% annual turnover of pool
            uint256 poolTVL = currentBalance0 + currentBalance1;
            uint256 assumedAnnualVolume = (poolTVL * 500) / BPS; // 5x yearly
            annualFees = (assumedAnnualVolume * poolFeeRate) / BPS;
        }
    }

    /**
     * @notice Calculate total value of LT tokens
     * @param _ltAmount Amount of LT tokens
     * @return value Value in asset terms
     */
    function _calculateLTValue(uint256 _ltAmount)
        internal
        view
        returns (uint256 value)
    {
        uint256 pricePerShare = ltToken.pricePerShare();
        value = (_ltAmount * pricePerShare) / PRECISION;
    }

    /**
     * @notice Integer square root using Babylonian method
     * @param x Value to find square root of (in 1e18)
     * @return y Square root (in 1e18)
     */
    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        if (x <= 3) return PRECISION;

        uint256 z = (x + PRECISION) / 2;
        y = x;

        while (z < y) {
            y = z;
            z = ((x * PRECISION) / z + z) / 2;
        }

        // Adjust for precision
        y = (y * PRECISION) / _sqrtPrecisionAdjustment(x);
    }

    function _sqrtPrecisionAdjustment(uint256 x)
        internal
        pure
        returns (uint256)
    {
        // Helper to maintain precision in sqrt calculation
        if (x >= PRECISION) return PRECISION;
        return _sqrt(PRECISION * PRECISION / x);
    }

    // ===== MANAGEMENT FUNCTIONS =====

    /**
     * @notice Update lookback period
     * @param _newPeriod New lookback period in seconds
     */
    function setLookbackPeriod(uint256 _newPeriod) external {
        require(_newPeriod > 0 && _newPeriod <= 30 days, "Invalid period");
        lookbackPeriod = _newPeriod;
    }

    /**
     * @notice Update balance tracking (call periodically)
     * @dev Anyone can call this to update the volume tracking
     */
    function updateBalances() external {
        lastBalance0 = cryptopool.balances(0);
        lastBalance1 = cryptopool.balances(1);
        lastUpdateTimestamp = block.timestamp;
    }

    /**
     * @notice Get current staking statistics
     * @return totalLT Total LT supply
     * @return stakedLT LT staked in gauge
     * @return stakingRatio Staking ratio in basis points
     * @return adminFee Current admin fee in basis points
     */
    function getStakingStats()
        external
        view
        returns (
            uint256 totalLT,
            uint256 stakedLT,
            uint256 stakingRatio,
            uint256 adminFee
        )
    {
        totalLT = ltToken.totalSupply();
        stakedLT = gauge.totalAssets();

        if (totalLT > 0) {
            stakingRatio = (stakedLT * BPS) / totalLT;
        }

        adminFee = _calculateAdminFee();
    }
}