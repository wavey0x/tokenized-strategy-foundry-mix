// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IVaultV2 is IERC20 {
    struct StrategyParams {
        uint256 performanceFee;
        uint256 activation;
        uint256 debtRatio;
        uint256 minDebtPerHarvest;
        uint256 maxDebtPerHarvest;
        uint256 lastReport;
        uint256 totalDebt;
        uint256 totalGain;
        uint256 totalLoss;
    }

    function deposit(uint amount, address recipient) external returns (uint);
    function withdraw(uint shares, address recipient) external returns (uint);
    function strategies(address) external returns (StrategyParams memory);
    function asset() external view returns (address);
}
