// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {AprOracleBase} from "@periphery/AprOracle/AprOracleBase.sol";
import {IYBSUtilities} from "../interfaces/ybs/IYBSUtilities.sol";
import {IVault} from "@yearn-vaults/interfaces/IVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ICurve} from "../interfaces/curve/ICurve.sol";
import {IAprOracleRegistry} from "../interfaces/utils/IAprOracleRegistry.sol";

/// @title YBS Strategy APR Oracle
/// @notice Calculates APR from YBS staking rewards plus additional donations
contract StrategyAprOracle is AprOracleBase {
    IYBSUtilities public constant YBS_UTILS =
        IYBSUtilities(0xb70E1CBFf4DFf345b3Aa832CC1C03cA26766AD55);
    IAprOracleRegistry public constant APR_ORACLE_REGISTRY = 
        IAprOracleRegistry(0x1981AD9F44F2EA9aDd2dC4AD7D075c102C70aF92);
    address public immutable YYB;
    address public immutable VAULT;
    address public immutable POOL_CRVUSD_YB;
    address public immutable POOL_YB_YYB;
    address public immutable REWARD_TOKEN;

    /// @notice Address authorized to auto-fund each epoch
    address public funder;
    /// @notice Amount to transfer when auto-funding
    uint256 public fundAmount;
    /// @notice Total donation amount per epoch
    mapping(uint256 => uint256) public amountPerEpoch;
    /// @notice Whether auto-funding occurred for an epoch
    mapping(uint256 => bool) public epochAutoFunded;

    constructor(
        address _vault,
        address _poolCrvusdYb,
        address _poolYbYyb,
        address _rewardToken,
        address _funder,
        uint256 _fundAmount
    ) AprOracleBase("YBS Staker Apr Oracle", msg.sender) {
        VAULT = _vault;
        YYB = IVault(_vault).asset();
        POOL_CRVUSD_YB = _poolCrvusdYb;
        POOL_YB_YYB = _poolYbYyb;
        REWARD_TOKEN = _rewardToken;
        funder = _funder;
        fundAmount = _fundAmount;
    }

    /// @notice Returns expected APR including YBS rewards and donations
    /// @param _strategy The strategy address
    /// @param _delta Change in debt (positive = increase, negative = decrease)
    /// @return apr Annual percentage rate (1e18 = 100%)
    function aprAfterDebtChange(
        address _strategy,
        int256 _delta
    ) external view virtual override returns (uint256 apr) {
        apr = YBS_UTILS.getUserActiveApr(
            _strategy,
            getStakeTokenPrice(),
            getRewardTokenPrice()
        );

        if (apr == 0) {
            apr = YBS_UTILS.getUserProjectedApr(
                _strategy,
                getStakeTokenPrice(),
                getRewardTokenPrice()
            );
        }

        uint256 totalAssets = IVault(VAULT).totalAssets();
        if (_delta > 0) {
            totalAssets += uint256(_delta);
        } else if (_delta < 0) {
            uint256 decrease = uint256(-_delta);
            totalAssets = totalAssets > decrease ? totalAssets - decrease : 0;
        }

        if (totalAssets > 0) {
            // APR = (weeklyAmount / totalAssets) * 52 weeks
            uint256 additionalApr = amountPerEpoch[getEpoch()] * 52 * 1e18 / totalAssets;
            apr += additionalApr;
        }

        uint256 unlockingApr = getVaultUnlockingApr();
        apr = unlockingApr > apr ? unlockingApr : apr;
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

    /// @notice Get current epoch (YBS-aligned timestamp)
    function getEpoch() public view returns (uint256) {
        return YBS_UTILS.getWeek();
    }

    /// @notice Get strategy from vault's default queue
    function strategy() public view virtual returns (address) {
        return IVault(VAULT).default_queue(0);
    }

    /// @notice YYB price in crvUSD terms
    function getStakeTokenPrice() public view virtual returns (uint256) {
        // YB price in crvUSD (coin[1]/coin[0])
        uint256 ybPriceInCrvusd = ICurve(POOL_CRVUSD_YB).price_oracle();
        // YYB price in YB (coin[1]/coin[0])
        uint256 yybPriceInYb = ICurve(POOL_YB_YYB).price_oracle(0);
        // YYB price in crvUSD
        return ybPriceInCrvusd * yybPriceInYb / 1e18;
    }

    /// @notice yvcrvUSD-2 price in crvUSD terms
    function getRewardTokenPrice() public view virtual returns (uint256) {
        return IVault(REWARD_TOKEN).pricePerShare();
    }

    function getVaultUnlockingApr() public view virtual returns (uint256) {
        return APR_ORACLE_REGISTRY.getCurrentApr(VAULT);
    }
}
