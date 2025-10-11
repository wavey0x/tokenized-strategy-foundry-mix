// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {IStrategy} from "@tokenized-strategy/interfaces/IStrategy.sol";

interface IStrategyInterface is IStrategy {
    enum SwapType {
        NULL,
        SWAP,
        AUCTION,
        TF
    }

    struct RewardTokenConfig {
        SwapType swapType;
        uint120 minAmountToSell;
        uint120 maxAmountToSell;
        bool shouldClaim;
    }

    event SlippageUpdated(uint256 depositSlippage, uint256 withdrawSlippage);
    event RewardsSwapperUpdated(address swapper);
    event AuctionUpdated(address auction);
    event RewardTokenConfigured(address indexed token, SwapType swapType, uint256 minAmountToSell, uint256 maxAmountToSell, bool shouldClaim);
    event EmergencyRecoveryCompleted(bool emergencyRecoveryCompleted);

    function ltToken() external view returns (address);
    function cryptopool() external view returns (address);
    function stablecoin() external view returns (address);
    function gauge() external view returns (address);
    function ybToken() external view returns (address);
    function gaugeController() external view returns (address);

    function availableDepositLimit(address _owner) external view returns (uint256);
    function availableWithdrawLimit(address _owner) external view returns (uint256);
    function getAllRewardTokens() external view returns (address[] memory);
    function getRewardTokenConfig(address _token) external view returns (RewardTokenConfig memory);

    function setSlippage(uint256 _depositSlippage, uint256 _withdrawSlippage) external;
    function setAuction(address _auction) external;
    function setRewardsSwapper(address _swapper) external;
    function setEmergencyRecoveryCompleted(bool _emergencyRecoveryCompleted) external;
    function addRewardToken(
        address _token,
        SwapType _swapType,
        uint256 _minAmountToSell,
        uint256 _maxAmountToSell,
        bool _shouldClaim
    ) external;
    function removeRewardToken(address _token) external;
    function updateRewardTokenConfig(
        address _token,
        SwapType _swapType,
        uint256 _minAmountToSell,
        uint256 _maxAmountToSell,
        bool _shouldClaim
    ) external;
    function kickAuction(address _token) external returns (uint256);
    function claimRewards() external;
    function setProfitLimitRatio(uint256 _profitLimitRatio) external;
    function setLossLimitRatio(uint256 _lossLimitRatio) external;
}