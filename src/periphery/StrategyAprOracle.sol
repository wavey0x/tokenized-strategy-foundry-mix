// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {AprOracleBase} from "@periphery/AprOracle/AprOracleBase.sol";
import {IYBSUtilities} from "../interfaces/ybs/IYBSUtilities.sol";
import {IVault} from "@yearn-vaults/interfaces/IVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title YBS Strategy APR Oracle
/// @notice Calculates APR from YBS staking rewards plus additional donations
contract StrategyAprOracle is AprOracleBase {
    IYBSUtilities public constant YBS_UTILS =
        IYBSUtilities(0xb70E1CBFf4DFf345b3Aa832CC1C03cA26766AD55);
    address public immutable YYB;
    address public immutable VAULT;

    /// @notice Address authorized to auto-fund each epoch
    address public funder;
    /// @notice Amount to transfer when auto-funding
    uint256 public fundAmount;
    /// @notice Total donation amount per epoch
    mapping(uint256 => uint256) public amountPerEpoch;
    /// @notice Whether auto-funding occurred for an epoch
    mapping(uint256 => bool) public epochAutoFunded;

    constructor(address _vault, address _funder, uint256 _fundAmount)
        AprOracleBase("YBS Staker Apr Oracle", msg.sender)
    {
        VAULT = _vault;
        YYB = IVault(_vault).asset();
        funder = _funder;
        fundAmount = _fundAmount;
    }

    /// @notice Returns expected APR including YBS rewards and donations
    /// @param _strategy The strategy address
    /// @param _delta Unused (YBS APR doesn't change with debt)
    /// @return apr Annual percentage rate (1e18 = 100%)
    function aprAfterDebtChange(
        address _strategy,
        int256 _delta
    ) external view virtual override returns (uint256 apr) {
        apr = YBS_UTILS.getUserActiveApr(
            _strategy,
            _getStakeTokenPrice(),
            _getRewardTokenPrice()
        );

        uint256 totalAssets = IVault(VAULT).totalAssets();
        if (totalAssets > 0) {
            // APR = (weeklyAmount / totalAssets) * 52 weeks
            uint256 additionalApr = amountPerEpoch[getEpoch()] * 52 * 1e18 / totalAssets;
            apr += additionalApr;
        }
    }

    /// @notice Donate rewards for current epoch
    /// @param _amount Amount of YYB to donate
    function notifyRewards(uint256 _amount) external {
        _notifyRewards(msg.sender, _amount);
    }

    /// @notice Auto-fund current epoch (once per epoch)
    function notifyRewardsFromFunder() external {
        uint256 epoch = getEpoch();
        require(!epochAutoFunded[epoch], "already funded");
        _notifyRewards(funder, fundAmount);
        epochAutoFunded[epoch] = true;
    }

    /// @notice Update funding parameters
    /// @param _funder New funder address
    /// @param _fundAmount New fund amount
    function setFundingParams(address _funder, uint256 _fundAmount) external {
        require(msg.sender == funder, "!funder");
        funder = _funder;
        fundAmount = _fundAmount;
    }

    function _notifyRewards(address _from, uint256 _amount) internal {
        address _strategy = strategy();
        require(_strategy != address(0), "no strategy");
        IERC20(YYB).transferFrom(_from, _strategy, _amount);
        amountPerEpoch[getEpoch()] += _amount;
    }

    /// @notice Get current epoch (week-aligned timestamp)
    function getEpoch() public view returns (uint256) {
        return block.timestamp / 7 days * 7 days;
    }

    /// @notice Get strategy from vault's default queue
    function strategy() public view virtual returns (address) {
        return IVault(VAULT).default_queue(0);
    }

    function _getStakeTokenPrice() internal view virtual returns (uint256) {
        return 1e18;
    }

    function _getRewardTokenPrice() internal view virtual returns (uint256) {
        return 1e18;
    }
}
