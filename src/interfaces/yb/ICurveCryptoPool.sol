// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

/**
 * @title ICurveCryptoPool
 * @notice Interface for Curve Crypto Pool (TwoCrypto-NG)
 * @dev Used for LP price and balance queries
 */
interface ICurveCryptoPool {
    /// @notice Get LP token price
    /// @return LP price in USD (1e18)
    function lp_price() external view returns (uint256);

    /// @notice Get virtual price (for reference)
    /// @return Virtual price (1e18)
    function get_virtual_price() external view returns (uint256);

    /// @notice Get price oracle (TWAP)
    /// @return Oracle price (1e18)
    function price_oracle() external view returns (uint256);

    /// @notice Get mid fee
    /// @return Fee in basis points
    function mid_fee() external view returns (uint256);

    /// @notice Get coin address by index
    /// @param i Coin index (0 or 1)
    /// @return Coin address
    function coins(uint256 i) external view returns (address);

    /// @notice Get coin balance by index
    /// @param i Coin index (0 or 1)
    /// @return Balance
    function balances(uint256 i) external view returns (uint256);

    /// @notice Get total supply of LP token
    /// @return Total supply
    function totalSupply() external view returns (uint256);
}