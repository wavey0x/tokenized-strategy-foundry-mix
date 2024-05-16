// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

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

    SwapThresholds public swapThresholds;
    ISwapper public swapper;
    bool public bypassClaim;
    bool public bypassMaxStake;
    IYearnBoostedStaker public immutable ybs;
    IRewardsDistributor public immutable rewardsDistributor;
    ERC20 public immutable rewardToken;
    ERC20 public immutable rewardTokenUnderlying;
    ICommonReportTrigger public constant COMMON_REPORT_TRIGGER =
        ICommonReportTrigger(0xD98C652f02E7B987e0C258a43BCa9999DF5078cF);
    
    struct SwapThresholds {
        uint112 min;
        uint112 max;
    }

    constructor(
        address _asset,
        string memory _name,
        IYearnBoostedStaker _ybs,
        IRewardsDistributor _rewardsDistributor,
        ISwapper _swapper,
        uint _swapThresholdMin,
        uint _swapThresholdMax
    ) BaseStrategy(_asset, _name) {
        // Address validation
        require(_ybs.MAX_STAKE_GROWTH_WEEKS() > 0, "Invalid staker");
        require(_rewardsDistributor.staker() == address(_ybs), "Invalid rewards");
        require(_asset == address(_swapper.tokenOut()), "Invalid rewards");
        ERC20 _rewardToken = ERC20(_rewardsDistributor.rewardToken());
        ERC20 _rewardTokenUnderlying = ERC20(IERC4626(address(_rewardToken)).asset());
        require(_rewardTokenUnderlying == _swapper.tokenIn(), "Invalid rewards");
        
        ybs = _ybs;
        rewardsDistributor = _rewardsDistributor;
        swapper = _swapper;
        rewardToken = ERC20(_rewardToken);
        rewardTokenUnderlying = _rewardTokenUnderlying;

        ERC20(_asset).forceApprove(address(_ybs), type(uint).max);
        _rewardTokenUnderlying.forceApprove(address(_swapper), type(uint).max);

        _setSwapThresholds(_swapThresholdMin, _swapThresholdMax);
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

        SwapThresholds memory st = swapThresholds;
        uint256 rewardBalance = balanceOfReward();
        if (rewardBalance > st.min) {
            // Redeem the full balance at once to avoid unnecessary costly withdrawals.
            IERC4626(address(rewardToken)).redeem(rewardBalance, address(this), address(this));
        }
        uint256 toSwap = rewardTokenUnderlying.balanceOf(address(this));
        
        if (toSwap == 0) return;
        if (toSwap > st.min) {
            toSwap = Math.min(toSwap, st.max);
            uint256 profit = swapper.swap(toSwap);
            if(
                profit > 1 && 
                !bypassMaxStake &&
                ybs.approvedWeightedStaker(address(this))
            ) {
                ybs.stakeAsMaxWeighted(address(this), profit);
            }
        }
    }

    function _emergencyWithdraw(uint256 _amount) internal override {
        _amount = Math.min(_amount, balanceOfStaked());
        if (_amount > 1) _freeFunds(_amount);
    }

    function approveRewardClaimer(address _claimer, bool _approved) external onlyManagement {
        rewardsDistributor.approveClaimer(_claimer, _approved);
    }

    function configureClaim(bool _bypass, bool _bypassMaxStake) external onlyManagement {
        bypassClaim = _bypass;
        bypassMaxStake = _bypassMaxStake;
    }

    function setSwapThresholds(uint256 _swapThresholdMin, uint256 _swapThresholdMax) external onlyManagement {
        _setSwapThresholds(_swapThresholdMin, _swapThresholdMax);
    }

    function _setSwapThresholds(uint256 _swapThresholdMin, uint256 _swapThresholdMax) internal {
        require(_swapThresholdMax < type(uint112).max);
        require(_swapThresholdMin < _swapThresholdMax);
        swapThresholds.min = uint112(_swapThresholdMin);
        swapThresholds.max = uint112(_swapThresholdMax);
    }

    function upgradeSwapper(ISwapper _swapper) external onlyManagement {
        require(_swapper.tokenOut() == asset, "Invalid Swapper");
        require(_swapper.tokenIn() == rewardTokenUnderlying);
        rewardTokenUnderlying.forceApprove(address(swapper), 0);
        rewardTokenUnderlying.forceApprove(address(_swapper), type(uint).max);
        swapper = _swapper;
    }

     /**
     * @return . Bool representing if the strategy is ready to report.
     * @return . Bytes with either the calldata or reason why False.
     */
    function reportTrigger(
        address
    ) external view override returns (bool, bytes memory) {
        if (TokenizedStrategy.isShutdown()) return (false, bytes("Shutdown"));

        if (!COMMON_REPORT_TRIGGER.isCurrentBaseFeeAcceptable()) {
            return (false, bytes("Base fee too high"));
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
