// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.18;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BaseStrategy, ERC20} from "@tokenized-strategy/BaseStrategy.sol";
import {CustomStrategyTriggerBase} from "@periphery/ReportTrigger/CustomStrategyTriggerBase.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IYearnBoostedStaker} from "./interfaces/ybs/IYearnBoostedStaker.sol";
import {IRewardsDistributor} from "./interfaces/ybs/IRewardsDistributor.sol";
import {ISwapper} from "./interfaces/utils/ISwapper.sol";
import {ICommonReportTrigger} from "./interfaces/ICommonReportTrigger.sol";

interface IERC4626 {
    function asset() external view returns (address);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256);
}

contract Strategy is BaseStrategy, CustomStrategyTriggerBase {
    using SafeERC20 for ERC20;

    bool public bypassClaim;
    uint256 public swapThreshold = 100e18;
    ISwapper public swapper;
    IYearnBoostedStaker public immutable ybs;
    IRewardsDistributor public immutable rewardsDistributor;
    ERC20 public immutable rewardToken;
    address public immutable rewardTokenUnderlying;
    ICommonReportTrigger public constant COMMON_REPORT_TRIGGER =
        ICommonReportTrigger(0xD98C652f02E7B987e0C258a43BCa9999DF5078cF);
    
    constructor(
        address _asset,
        string memory _name,
        IYearnBoostedStaker _ybs,
        IRewardsDistributor _rewardsDistributor,
        ISwapper _swapper
    ) BaseStrategy(_asset, _name) {
        // Address validation
        require(_ybs.MAX_STAKE_GROWTH_WEEKS() > 0, "Invalid staker");
        require(_rewardsDistributor.staker() == address(_ybs), "Invalid rewards");
        require(address(asset) == address(_swapper.tokenOut()), "Invalid rewards");
        address _rewardToken = _rewardsDistributor.rewardToken();
        address _rewardTokenUnderlying = IERC4626(_rewardToken).asset();
        require(_rewardTokenUnderlying == address(_swapper.tokenIn()), "Invalid rewards");
        
        ybs = _ybs;
        rewardsDistributor = _rewardsDistributor;
        swapper = _swapper;
        rewardToken = ERC20(_rewardToken);
        rewardTokenUnderlying = _rewardTokenUnderlying;

        ERC20(asset).approve(address(ybs), type(uint).max);
        ERC20(_rewardTokenUnderlying).approve(address(_swapper), type(uint).max);
    }

    function _deployFunds(uint256 _amount) internal override {
        ybs.stake(_amount); // < 2 wei will revert
    }
    
    function _freeFunds(uint256 _amount) internal override {
        ybs.unstake(_amount, address(this)); // < 2 wei will revert
    }

    function _harvestAndReport()
        internal
        override
        returns (uint256 _totalAssets)
    {
        if (!TokenizedStrategy.isShutdown()) {
            _claimAndSellRewards();
            uint balance = balanceOfAsset();
            if (balance > 1) { // < 2 wei will revert on deposit
                _deployFunds(balance);
            }
        }
        _totalAssets = balanceOfStaked() + balanceOfAsset();
    }

    function _claimAndSellRewards() internal {
        if (!bypassClaim) rewardsDistributor.claim();
        uint256 rewardBalance = balanceOfReward();
        if (rewardBalance > swapThreshold) {
            rewardBalance = IERC4626(address(rewardToken))
                .redeem(rewardBalance, address(this), address(this));
            swapper.swap(rewardBalance);
        }
    }

    function _emergencyWithdraw(uint256 _amount) internal override {
        _amount = Math.min(_amount, balanceOfStaked());
        if (_amount > 1) _freeFunds(_amount);
    }

    function approveRewardClaimer(address _claimer, bool _approved) external onlyManagement {
        rewardsDistributor.approveClaimer(_claimer, _approved);
    }

    function setBypassClaim(bool _bypass) external onlyManagement {
        bypassClaim = _bypass;
    }

    function setSwapThreshold(uint256 _swapThreshold) external onlyManagement {
        swapThreshold = _swapThreshold;
    }

    function upgradeSwapper(ISwapper _swapper) external onlyManagement {
        require(_swapper.tokenOut() == address(asset), "Invalid Swapper");
        require(_swapper.tokenIn() == rewardTokenUnderlying);
        ERC20(rewardTokenUnderlying).approve(address(swapper), 0);
        ERC20(rewardTokenUnderlying).approve(address(_swapper), type(uint).max);
        swapper = _swapper;
    }

     /**
     * @param _strategy The address of the strategy to check.
     * @return . Bool representing if the strategy is ready to report.
     * @return . Bytes with either the calldata or reason why False.
     */
    function reportTrigger(
        address _strategy
    ) external view override returns (bool, bytes memory) {
        if (TokenizedStrategy.isShutdown()) return (false, bytes("Base fee too high"));

        if (!COMMON_REPORT_TRIGGER.isCurrentBaseFeeAcceptable()) {
            return (false, bytes("Shutdown"));
        }
        if (rewardsDistributor.getClaimable(address(this)) > 0) {
            return (true, abi.encodeWithSelector(TokenizedStrategy.report.selector));
        }

        return (false, bytes("Nothing Claimable"));
    }

    function balanceOfStaked() public view returns (uint256) {
        return ybs.balanceOf(address(this));
    }

    function balanceOfAsset() public view returns (uint256) {
        return ERC20(asset).balanceOf(address(this));
    }

    function balanceOfReward() public view returns (uint256) {
        return rewardToken.balanceOf(address(this));
    }
}
