// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

/**
 * @title IGaugeController
 * @notice Interface for Yield Basis GaugeController
 * @dev Controls YB emissions to gauges based on veYB votes
 */
interface IGaugeController {
    /// @notice Get the YB governance token address
    /// @return YB token address
    function TOKEN() external view returns (address);

    /// @notice Preview emissions for a gauge at a specific time
    /// @param gauge Gauge address
    /// @param at_time Timestamp to preview emissions for
    /// @return Amount of YB emissions
    function preview_emissions(address gauge, uint256 at_time)
        external
        view
        returns (uint256);

    /// @notice Emit YB tokens to gauges (updates global state)
    /// @return Amount of YB emitted
    /// @dev Cannot declare 'emit()' in Solidity interface due to keyword conflict
    /// Use: abi.encodeWithSignature("emit()") or call directly with low-level call

    /// @notice Get current gauge weight
    /// @param gauge Gauge address
    /// @return Gauge weight
    function gauge_weight(address gauge) external view returns (uint256);

    /// @notice Get adjusted gauge weight (with adjustment factor)
    /// @param gauge Gauge address
    /// @return Adjusted weight
    function adjusted_gauge_weight(address gauge)
        external
        view
        returns (uint256);
}