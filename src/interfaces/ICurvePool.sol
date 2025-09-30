// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

/**
 * @title ICurvePool
 * @notice Interface for Curve pool swaps
 */
interface ICurvePool {
    /**
     * @notice Perform an exchange between two tokens
     * @param i Index value for the coin to send
     * @param j Index value of the coin to receive
     * @param dx Amount of i being exchanged
     * @param min_dy Minimum amount of j to receive
     * @return Actual amount of coin j received
     */
    function exchange(
        int128 i,
        int128 j,
        uint256 dx,
        uint256 min_dy
    ) external returns (uint256);

    /**
     * @notice Get the amount received when exchanging
     * @param i Index value for the coin to send
     * @param j Index value of the coin to receive
     * @param dx Amount of i being exchanged
     * @return Amount of j that would be received
     */
    function get_dy(
        int128 i,
        int128 j,
        uint256 dx
    ) external view returns (uint256);

    /**
     * @notice Get coin at index
     * @param arg0 Coin index
     * @return Coin address
     */
    function coins(uint256 arg0) external view returns (address);
}
