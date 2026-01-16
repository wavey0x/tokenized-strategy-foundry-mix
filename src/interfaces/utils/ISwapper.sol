// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {ERC20} from "@tokenized-strategy/BaseStrategy.sol";
import {IZap} from "./IZap.sol";
import {IVaultV2} from "./IVaultV2.sol";

interface ISwapper {
    // Immutable state
    function PRECISION() external view returns (uint);
    function tokenIn() external view returns (ERC20);
    function tokenOut() external view returns (ERC20);
    function tokenOutPool1() external view returns (ERC20);
    function pool1() external view returns (address);
    function pool2() external view returns (address);
    function pool1InTokenIdx() external view returns (uint);
    function pool1OutTokenIdx() external view returns (uint);
    function owner() external view returns (address);
    function treasury() external view returns (address);
    function zap() external view returns (IZap);
    function approvedVault() external view returns (IVaultV2);

    // Mutable state
    function otcEnabled() external view returns (bool);
    function vault() external view returns (IVaultV2);
    function management() external view returns (address);
    function allowedSwapper(address) external view returns (bool);
    function operator(address) external view returns (bool);

    // Core functions
    function swap(uint _amount) external returns (uint);
    function priceOracle() external view returns (uint);

    // Management functions
    function sweep(address _token) external;
    function enableOtc(bool _enabled) external;
    function setVault(IVaultV2 _vault) external;
    function setAllowedSwapper(address _caller, bool _isAllowed) external;
    function setOperator(address _caller, bool _isAllowed) external;
    function setManagement(address _management) external;
}
