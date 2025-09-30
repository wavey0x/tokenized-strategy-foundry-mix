// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title ILT
 * @notice Interface for Yield Basis LT (Liquidity Token) contract
 * @dev Based on LT.vy (Vyper 0.4.3)
 */
interface ILT is IERC20 {
    // ===== STRUCTS =====

    struct OraclizedValue {
        uint256 p_o; // Oracle price
        uint256 value; // USD value
    }

    struct LiquidityValuesOut {
        int256 admin; // Admin fees (can be negative)
        uint256 total; // Total position value
        uint256 ideal_staked; // Ideal staked amount
        uint256 staked; // Current staked amount
        uint256 staked_tokens; // Staked token balance after reductions
        uint256 supply_tokens; // Total supply after reductions
        int256 token_reduction; // Token reduction amount
    }

    // ===== VIEW FUNCTIONS =====

    /// @notice Returns the price per share of LT tokens in oracle-adjusted terms
    /// @return Price per share (1e18 = 1.0)
    function pricePerShare() external view returns (uint256);

    /// @notice Preview shares received for depositing assets and debt
    /// @param assets Amount of asset tokens to deposit
    /// @param debt Amount of stablecoin debt to take
    /// @return Amount of shares that would be minted
    function preview_deposit(uint256 assets, uint256 debt)
        external
        view
        returns (uint256);

    /// @notice Preview assets received for withdrawing shares
    /// @param tokens Amount of shares to withdraw
    /// @return Amount of assets that would be received
    function preview_withdraw(uint256 tokens) external view returns (uint256);

    /// @notice Check if the market is killed (emergency mode)
    /// @return True if killed, false otherwise
    function is_killed() external view returns (bool);

    /// @notice Get the underlying asset token address
    /// @return Asset token address (e.g., WBTC)
    function ASSET_TOKEN() external view returns (address);

    /// @notice Get the stablecoin token address
    /// @return Stablecoin address (crvUSD)
    function STABLECOIN() external view returns (address);

    /// @notice Get the Curve cryptopool address
    /// @return Cryptopool address
    function CRYPTOPOOL() external view returns (address);

    // ===== STATE-CHANGING FUNCTIONS =====

    /// @notice Deposit assets to receive LT shares
    /// @param assets Amount of assets to deposit
    /// @param debt Amount of debt for AMM to take (≈ assets × price)
    /// @param min_shares Minimum shares to receive (slippage protection)
    /// @param receiver Address to receive shares
    /// @return shares Amount of shares minted
    function deposit(
        uint256 assets,
        uint256 debt,
        uint256 min_shares,
        address receiver
    ) external returns (uint256 shares);

    /// @notice Withdraw assets by burning LT shares
    /// @param shares Amount of shares to burn
    /// @param min_assets Minimum assets to receive (slippage protection)
    /// @param receiver Address to receive assets
    /// @return crypto_received Amount of assets received
    function withdraw(uint256 shares, uint256 min_assets, address receiver)
        external
        returns (uint256 crypto_received);

    /// @notice Emergency withdraw without using AMM math (when killed)
    /// @param shares Amount of shares to withdraw
    /// @param receiver Address to receive assets
    /// @param owner Owner of the shares
    /// @return asset_amount Amount of assets received
    /// @return stables_amount Amount of stables (positive = received, negative = must bring)
    function emergency_withdraw(
        uint256 shares,
        address receiver,
        address owner
    ) external returns (uint256 asset_amount, int256 stables_amount);
}