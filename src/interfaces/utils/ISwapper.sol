pragma solidity 0.8.18;

import {ERC20} from "@tokenized-strategy/BaseStrategy.sol";

interface ISwapper {
    function tokenIn() external view returns (ERC20);
    function tokenOut() external view returns (ERC20);
    function tokenOutPool1() external view returns (address);
    function pool1() external view returns (address);
    function pool2() external view returns (address);
    function pool1InTokenIdx() external view returns (uint);
    function pool1OutTokenIdx() external view returns (uint);
    function pool2InTokenIdx() external view returns (uint);
    function pool2OutTokenIdx() external view returns (uint);
    function swap(uint _amount) external returns (uint);
}