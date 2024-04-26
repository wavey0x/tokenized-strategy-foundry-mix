// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.18;

interface ICommonReportTrigger {
    function isCurrentBaseFeeAcceptable() external view returns (bool);
    function setAcceptableBaseFee(uint256 _acceptable) external;
}