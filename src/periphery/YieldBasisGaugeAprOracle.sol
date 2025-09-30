// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {AprOracleBase} from "@periphery/AprOracle/AprOracleBase.sol";
import {ILT} from "../interfaces/yb/ILT.sol";
import {ILiquidityGauge} from "../interfaces/yb/ILiquidityGauge.sol";
import {IGaugeController} from "../interfaces/yb/IGaugeController.sol";
import {ICurveCryptoPool} from "../interfaces/yb/ICurveCryptoPool.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title YieldBasisGaugeAprOracle
 * @author Yearn Finance
 * @notice APR oracle for YieldBasisGaugeStrategy (staked gauge strategy)
 * @dev Calculates APR from YB token emissions based on gauge votes
 *
 * This oracle calculates the expected APR for stakers in the Liquidity Gauge.
 * The yield comes from YB token emissions allocated by the GaugeController based
 * on veYB holder votes.
 *
 * APR Calculation:
 * 1. Get weekly YB emissions to this gauge from GaugeController
 * 2. Get current YB token price (in asset terms)
 * 3. Calculate annual emission value: weekly_emissions × 52 × yb_price
 * 4. Get gauge TVL: staked_lt × lt_price_per_share
 * 5. Calculate APR: (annual_value / tvl) × 10000
 *
 * Key Considerations:
 * - YB price needs to be fetched from external oracle or DEX
 * - Emissions can change weekly based on veYB votes
 * - Gauge adjustment factor affects effective emissions
 * - This APR does NOT include trading fees (those go to veYB holders via admin fee)
 */
contract YieldBasisGaugeAprOracle is AprOracleBase {
    // ===== CONSTANTS =====

    uint256 internal constant PRECISION = 1e18;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant SECONDS_PER_YEAR = 365 days;
    uint256 internal constant SECONDS_PER_WEEK = 7 days;
    uint256 internal constant WEEKS_PER_YEAR = 52;

    // ===== IMMUTABLE STATE =====

    /// @notice Yield Basis LT contract
    ILT public immutable ltToken;

    /// @notice Liquidity Gauge
    ILiquidityGauge public immutable gauge;

    /// @notice Gauge Controller (for emissions)
    IGaugeController public immutable gaugeController;

    /// @notice YB governance token
    ERC20 public immutable ybToken;

    /// @notice Curve cryptopool (for price calculations)
    ICurveCryptoPool public immutable cryptopool;

    // ===== CONFIGURATION =====

    /// @notice YB token price oracle (address of price feed)
    address public ybPriceOracle;

    /// @notice Manually set YB price (fallback if no oracle)
    uint256 public manualYbPrice;

    /// @notice Whether to use manual price
    bool public useManualPrice;

    // ===== EVENTS =====

    event YbPriceOracleUpdated(address newOracle);
    event ManualYbPriceUpdated(uint256 newPrice);
    event UseManualPriceToggled(bool useManual);

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

        // Get gauge controller and YB token from gauge
        gaugeController = IGaugeController(gauge.GC());
        ybToken = ERC20(gauge.YB());

        // Default to manual price mode
        useManualPrice = true;
        manualYbPrice = 0; // Must be set by management
    }

    // ===== APR CALCULATION =====

    /**
     * @notice Calculate current APR for Gauge strategy
     * @param _strategy Strategy address (unused, for interface compatibility)
     * @return apr Current APR in basis points (e.g., 1000 = 10%)
     *
     * APR Formula:
     * apr = (annual_yb_emission_value / gauge_tvl) × 10000
     *
     * Where:
     * - annual_yb_emission_value = weekly_yb × 52 × yb_price
     * - gauge_tvl = staked_lt × lt_price_per_share
     */
    function aprAfterDebtChange(address _strategy, int256)
        external
        view
        override
        returns (uint256 apr)
    {
        _strategy; // Silence unused parameter warning

        // Get gauge TVL
        uint256 gaugeTVL = _calculateGaugeTVL();
        if (gaugeTVL == 0) return 0;

        // Get weekly YB emissions
        uint256 weeklyYbEmissions = _getWeeklyEmissions();
        if (weeklyYbEmissions == 0) return 0;

        // Get YB price in asset terms
        uint256 ybPrice = _getYbPrice();
        if (ybPrice == 0) return 0;

        // Calculate annual emission value
        uint256 annualYbEmissions = weeklyYbEmissions * WEEKS_PER_YEAR;
        uint256 annualEmissionValue = (annualYbEmissions * ybPrice) / PRECISION;

        // Calculate APR in basis points
        apr = (annualEmissionValue * BPS) / gaugeTVL;
    }

    // ===== INTERNAL HELPERS =====

    /**
     * @notice Calculate total value locked in gauge
     * @return tvl TVL in asset terms
     */
    function _calculateGaugeTVL() internal view returns (uint256 tvl) {
        uint256 stakedLT = gauge.totalAssets(); // Total LT staked
        if (stakedLT == 0) return 0;

        uint256 pricePerShare = ltToken.pricePerShare();
        tvl = (stakedLT * pricePerShare) / PRECISION;
    }

    /**
     * @notice Get weekly YB emissions for this gauge
     * @return emissions Weekly YB emissions
     */
    function _getWeeklyEmissions() internal view returns (uint256 emissions) {
        // Preview emissions for next week
        uint256 nextWeek = block.timestamp + SECONDS_PER_WEEK;

        try gaugeController.preview_emissions(address(gauge), nextWeek)
        returns (uint256 amount) {
            emissions = amount;
        } catch {
            // Fallback: return 0 if preview fails
            emissions = 0;
        }
    }

    /**
     * @notice Get YB token price in asset terms
     * @return price YB price (1e18 = 1 asset token)
     *
     * Price sources (in order of preference):
     * 1. External price oracle (if set and not using manual)
     * 2. Manual price (if set)
     * 3. Zero (indicates price unavailable)
     *
     * In production, this should integrate with:
     * - Chainlink price feed
     * - Uniswap V3 TWAP oracle
     * - Custom price aggregator
     */
    function _getYbPrice() internal view returns (uint256 price) {
        if (useManualPrice) {
            return manualYbPrice;
        }

        if (ybPriceOracle != address(0)) {
            // Try to fetch from oracle
            // NOTE: Oracle interface depends on chosen price feed
            // This is a placeholder - implement based on actual oracle
            //
            // Example for Chainlink:
            // IChainlinkOracle oracle = IChainlinkOracle(ybPriceOracle);
            // (uint80 roundId, int256 answer, , uint256 updatedAt, ) = oracle.latestRoundData();
            // if (answer > 0 && block.timestamp - updatedAt < 1 hours) {
            //     return uint256(answer);
            // }
            //
            // For now, return 0 to indicate oracle integration needed
            return 0;
        }

        // No price available
        return 0;
    }

    /**
     * @notice Get detailed emission statistics
     * @return weeklyEmissions Weekly YB emissions
     * @return annualEmissions Annual YB emissions
     * @return ybPrice Current YB price
     * @return gaugeTVL Gauge TVL
     * @return adjustmentFactor Gauge adjustment factor
     */
    function getEmissionStats()
        external
        view
        returns (
            uint256 weeklyEmissions,
            uint256 annualEmissions,
            uint256 ybPrice,
            uint256 gaugeTVL,
            uint256 adjustmentFactor
        )
    {
        weeklyEmissions = _getWeeklyEmissions();
        annualEmissions = weeklyEmissions * WEEKS_PER_YEAR;
        ybPrice = _getYbPrice();
        gaugeTVL = _calculateGaugeTVL();
        adjustmentFactor = gauge.get_adjustment();
    }

    /**
     * @notice Calculate boost for a user
     * @return boost Boost multiplier in 1e18 (1e18 = 1x, 2.5e18 = 2.5x)
     *
     * NOTE: Boost calculation depends on veYB balance and working supply.
     * This is a simplified placeholder - actual implementation should match
     * the gauge's boost calculation logic.
     */
    function getUserBoost(address /* _user */)
        external
        pure
        returns (uint256 boost)
    {
        // Placeholder: return 1x boost
        // In production, calculate based on:
        // - User's veYB balance
        // - User's gauge balance
        // - Total gauge supply
        // - Boost formula: min(balance, 0.4 × balance + 0.6 × supply × veYB/totalVeYB)
        return PRECISION; // 1x boost
    }

    // ===== MANAGEMENT FUNCTIONS =====

    /**
     * @notice Set YB price oracle
     * @param _oracle Oracle address
     */
    function setYbPriceOracle(address _oracle) external {
        ybPriceOracle = _oracle;
        emit YbPriceOracleUpdated(_oracle);
    }

    /**
     * @notice Set manual YB price
     * @param _price YB price in asset terms (1e18 = 1 asset)
     */
    function setManualYbPrice(uint256 _price) external {
        manualYbPrice = _price;
        emit ManualYbPriceUpdated(_price);
    }

    /**
     * @notice Toggle between oracle and manual price
     * @param _useManual True to use manual price
     */
    function setUseManualPrice(bool _useManual) external {
        useManualPrice = _useManual;
        emit UseManualPriceToggled(_useManual);
    }

    /**
     * @notice Get current APR configuration
     * @return ybPrice Current YB price used
     * @return isManual Whether manual price is being used
     * @return oracle Oracle address (if any)
     */
    function getAprConfig()
        external
        view
        returns (uint256 ybPrice, bool isManual, address oracle)
    {
        ybPrice = _getYbPrice();
        isManual = useManualPrice;
        oracle = ybPriceOracle;
    }

    /**
     * @notice Preview APR with custom YB price
     * @param _ybPrice Custom YB price
     * @return apr Projected APR in basis points
     */
    function previewAprWithPrice(uint256 _ybPrice)
        external
        view
        returns (uint256 apr)
    {
        uint256 gaugeTVL = _calculateGaugeTVL();
        if (gaugeTVL == 0) return 0;

        uint256 weeklyYbEmissions = _getWeeklyEmissions();
        if (weeklyYbEmissions == 0) return 0;

        uint256 annualYbEmissions = weeklyYbEmissions * WEEKS_PER_YEAR;
        uint256 annualEmissionValue = (annualYbEmissions * _ybPrice) / PRECISION;

        apr = (annualEmissionValue * BPS) / gaugeTVL;
    }
}