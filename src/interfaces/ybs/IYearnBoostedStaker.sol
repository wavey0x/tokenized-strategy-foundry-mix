// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.18;

interface IYearnBoostedStaker {
    // Enums
    enum ApprovalStatus {
        None,
        StakeOnly,
        UnstakeOnly,
        StakeAndUnstake
    }

    // Structs
    struct AccountData {
        uint112 realizedStake;
        uint112 pendingStake;
        uint16 lastUpdateWeek;
        uint8 updateWeeksBitmap;
    }

    // Events
    event Staked(address indexed account, uint indexed week, uint amount, uint newUserWeight, uint weightAdded);
    event Unstaked(address indexed account, uint indexed week, uint amount, uint newUserWeight, uint weightRemoved);
    event ApprovedCallerSet(address indexed account, address indexed caller, ApprovalStatus status);
    event WeightedStakerSet(address indexed staker, bool approved);
    event OwnershipTransferred(address indexed newOwner);

    // Public and external functions
    function MAX_STAKE_GROWTH_WEEKS() external view returns (uint);
    function START_TIME() external returns (uint);
    function getWeek() external returns (uint);
    function stake(uint _amount) external returns (uint);
    function stakeFor(address _account, uint _amount) external returns (uint);
    function stakeAsWeighted(address _account, uint _amount, uint _idx) external returns (uint);
    function unstake(uint _amount, address _receiver) external returns (uint);
    function unstakeFor(address _account, uint _amount, address _receiver) external returns (uint);
    function checkpointAccount(address _account) external returns (AccountData memory acctData, uint weight);
    function checkpointAccountWithLimit(address _account, uint _week) external returns (AccountData memory acctData, uint weight);
    function getAccountWeight(address account) external view returns (uint);
    function getAccountWeightAt(address _account, uint _week) external view returns (uint);
    function checkpointGlobal() external returns (uint);
    function getGlobalWeight() external view returns (uint);
    function getGlobalWeightAt(uint week) external view returns (uint);
    function getAccountWeightRatio(address _account) external view returns (uint);
    function getAccountWeightRatioAt(address _account, uint _week) external view returns (uint);
    function balanceOf(address _account) external view returns (uint);
    function setApprovedCaller(address _caller, ApprovalStatus _status) external;
    function setWeightedStaker(address _staker, bool _approved) external;
    function transferOwnership(address _pendingOwner) external;
    function acceptOwnership() external;
    function sweep(address _token) external;
}