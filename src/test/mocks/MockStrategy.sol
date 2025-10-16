// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {BaseStrategy, ERC20} from "@tokenized-strategy/BaseStrategy.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract MockStrategy is BaseStrategy {
    using SafeERC20 for ERC20;

    constructor(
        address _asset,
        string memory _name
    ) BaseStrategy(_asset, _name) {}


    function _deployFunds(uint256 _amount) internal override {}


    function _freeFunds(uint256 _amount) internal override {}

    function _harvestAndReport()
        internal
        override
        returns (uint256 _totalAssets)
    {
        _totalAssets = asset.balanceOf(address(this));
    }

    function availableWithdrawLimit(
        address /*_owner*/
    ) public view override returns (uint256) {
        return asset.balanceOf(address(this));
    }
}