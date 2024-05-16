// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.8.18;

import {IStrategy} from "@tokenized-strategy/interfaces/IStrategy.sol";
import {ISwapper} from "./utils/ISwapper.sol";

interface IStrategyInterface is IStrategy {
    struct SwapThresholds {
        uint112 min;
        uint112 max;
    }
    function gov() external view returns (address);
    function rewardToken() external view returns (address);
    function rewardTokenUnderlying() external view returns (address);
    function balanceOfStaked() external view returns (uint256);
    function balanceOfAsset() external view returns (uint256);
    function balanceOfReward() external view returns (uint256);
    function swapThresholds() external view returns (SwapThresholds memory);
    function upgradeSwapper(ISwapper) external; 
    
}
