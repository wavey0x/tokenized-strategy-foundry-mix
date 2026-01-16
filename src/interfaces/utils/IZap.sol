// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

interface IZap {
    function zap(
        address _inputToken,
        address _outputToken,
        uint256 _amountIn,
        uint256 _minOut,
        address _recipient
    ) external returns (uint256);
}
