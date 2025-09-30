// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title ILiquidityGauge
 * @notice Interface for Yield Basis LiquidityGauge contract (ERC4626)
 * @dev Based on LiquidityGauge.vy (Vyper 0.4.3)
 */
interface ILiquidityGauge is IERC20 {
    // ===== VIEW FUNCTIONS =====

    /// @notice Get the LP token being staked (LT token)
    /// @return LP token address
    function LP_TOKEN() external view returns (address);

    /// @notice Get the YB governance token address
    /// @return YB token address
    function YB() external view returns (address);

    /// @notice Get the gauge controller address
    /// @return GaugeController address
    function GC() external view returns (address);

    /// @notice Preview claimable rewards for a user
    /// @param reward Reward token address
    /// @param user User address
    /// @return Amount of rewards claimable
    function preview_claim(address reward, address user)
        external
        view
        returns (uint256);

    /// @notice Get gauge adjustment factor (sqrt of staked/total supply)
    /// @return Adjustment factor (1e18 = 100%)
    function get_adjustment() external view returns (uint256);

    // ERC4626 standard functions
    function asset() external view returns (address);

    function totalAssets() external view returns (uint256);

    function convertToShares(uint256 assets) external view returns (uint256);

    function convertToAssets(uint256 shares) external view returns (uint256);

    function maxDeposit(address) external view returns (uint256);

    function previewDeposit(uint256 assets) external view returns (uint256);

    function maxMint(address) external view returns (uint256);

    function previewMint(uint256 shares) external view returns (uint256);

    function maxWithdraw(address owner) external view returns (uint256);

    function previewWithdraw(uint256 assets) external view returns (uint256);

    function maxRedeem(address owner) external view returns (uint256);

    function previewRedeem(uint256 shares) external view returns (uint256);

    // ===== STATE-CHANGING FUNCTIONS =====

    /// @notice Deposit LP tokens to earn rewards
    /// @param assets Amount of LP tokens to deposit
    /// @param receiver Address to receive gauge shares
    /// @return shares Amount of gauge shares minted
    function deposit(uint256 assets, address receiver)
        external
        returns (uint256 shares);

    /// @notice Mint gauge shares by depositing LP tokens
    /// @param shares Amount of gauge shares to mint
    /// @param receiver Address to receive gauge shares
    /// @return assets Amount of LP tokens deposited
    function mint(uint256 shares, address receiver)
        external
        returns (uint256 assets);

    /// @notice Withdraw LP tokens by burning gauge shares
    /// @param assets Amount of LP tokens to withdraw
    /// @param receiver Address to receive LP tokens
    /// @param owner Owner of the gauge shares
    /// @return shares Amount of gauge shares burned
    function withdraw(uint256 assets, address receiver, address owner)
        external
        returns (uint256 shares);

    /// @notice Redeem gauge shares for LP tokens
    /// @param shares Amount of gauge shares to redeem
    /// @param receiver Address to receive LP tokens
    /// @param owner Owner of the gauge shares
    /// @return assets Amount of LP tokens received
    function redeem(uint256 shares, address receiver, address owner)
        external
        returns (uint256 assets);

    /// @notice Claim accumulated rewards
    /// @param reward Reward token to claim (YB by default)
    /// @param user User to claim for (msg.sender by default)
    /// @return Amount of rewards claimed
    function claim(address reward, address user) external returns (uint256);
}