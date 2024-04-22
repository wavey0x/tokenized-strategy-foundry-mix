// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.18;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BaseStrategy, ERC20} from "@tokenized-strategy/BaseStrategy.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IYearnBoostedStaker} from "./interfaces/IYearnBoostedStaker.sol";
import {IRewardsDistributor} from "./interfaces/IRewardsDistributor.sol";

// Import interfaces for many popular DeFi projects, or add your own!
//import "../interfaces/<protocol>/<Interface>.sol";

/**
 * The `TokenizedStrategy` variable can be used to retrieve the strategies
 * specific storage data your contract.
 *
 *       i.e. uint256 totalAssets = TokenizedStrategy.totalAssets()
 *
 * This can not be used for write functions. Any TokenizedStrategy
 * variables that need to be updated post deployment will need to
 * come from an external call from the strategies specific `management`.
 */

// NOTE: To implement permissioned functions you can use the onlyManagement, onlyEmergencyAuthorized and onlyKeepers modifiers

contract Strategy is BaseStrategy {
    using SafeERC20 for ERC20;

    uint public stakeTimeBuffer = 1 days;
    IYearnBoostedStaker public immutable ybs;
    IRewardsDistributor public immutable rewardsDistributor;
    

    constructor(
        address _asset,
        string memory _name,
        IYearnBoostedStaker _ybs,
        IRewardsDistributor _rewardsDistributor
    ) BaseStrategy(_asset, _name) {
        ybs = _ybs;
        rewardsDistributor = _rewardsDistributor;
        ERC20(asset).approve(address(ybs), type(uint).max);
    }

    function _deployFunds(uint256 _amount) internal override {
        if(shouldStake()) stakeFullBalance();
    }

    function shouldStake() public view returns (bool) {
        uint nextWeekStart = (block.timestamp / 1 weeks + 1) * 1 weeks;
        return nextWeekStart - block.timestamp <= stakeTimeBuffer;
    }

    function stakeFullBalance() public {
        ybs.deposit(balanceOfAsset());
    }
    
    function _freeFunds(uint256 _amount) internal override {
        uint balance = balanceOfAsset();
        if(_amount >= balance) {
            ybs.withdraw(_amount - balance, address(this));
        }
    }

    function _harvestAndReport()
        internal
        override
        returns (uint256 _totalAssets)
    {
        uint balance = balanceOfAsset();
        if (!TokenizedStrategy.isShutdown()) {
            rewardsDistributor.claim();
            if (balance > 1) { // YBS min deposit size is 2 wei.
                _deployFunds(balance);
                balance = 0;
            }
        }
        _totalAssets = stakedBalance() + balanceOfAsset();
    }

    function _emergencyWithdraw(uint256 _amount) internal override {
        _amount = Math.min(_amount, stakedBalance());
        if (_amount > 1) _freeFunds(_amount);
    }

    function approveRewardClaimer(address _claimer, bool _approved) external onlyManagement {
        rewardsDistributor.approveClaimer(_claimer, true);
    }

    /**
     * @notice Configurable time setting for when user deposits should trigger full strategy balance to be staked.
     * @dev This is intended to save gas for the typical user. Staking at the beginning of the week serves
     *      no advantage over staking at the very end of the week. So our goal is to minimize the number of stake operations.
    */
    function setStakeTimeBuffer(uint _buffer) external onlyManagement {
        require(_buffer <= 1 weeks, "Buffer > 1 week");
        stakeTimeBuffer = _buffer;
    }

    function balanceOfAsset() public view returns (uint256) {
        return ERC20(asset).balanceOf(address(this));
    }

    function stakedBalance() public view returns (uint256) {
        return ybs.balanceOf(address(this));
    }
}
