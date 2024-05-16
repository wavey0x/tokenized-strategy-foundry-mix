// SPDX-License-Identifier: GNU AGPLv3
pragma solidity ^0.8.18;

interface IYBSFactory {
    function deploy(address, uint, uint, address) external returns (address);
    function deploy(address, address) external returns (address);
}

interface IYBSRegistry {

    // Events
    event NewDeployment(address indexed yearnBoostedStaker, address indexed rewardDistributor, address indexed utilities);
    event DeployerApproved(address indexed deployer, bool indexed approved);
    event DistributorUpdated(address indexed token, address indexed distributor);
    event UtilitiesUpdated(address indexed token, address indexed utilities);
    event FactoriesUpdated(address indexed ybsFactory, address indexed rewardFactory, address indexed utilsFactory);
    event OwnershipTransferred(address indexed owner);

    // Function signatures
    function approveDeployer(address _deployer, bool _approved) external;
    function deployments(address token) external returns(address yearnBoostedStaker, address rewardDistributor, address utilities);
    
    function createNewDeployment(
        address _token,
        uint _max_stake_growth_weeks,
        uint _start_time,
        address _reward_token
    ) external returns (address ybs, address distributor, address utils);
    
    function updateRewardDistributor(address _token, address _distributor) external;
    
    function updateUtilities(address _token, address _utils) external;
    
    function updateFactories(IYBSFactory _ybsFactory, IYBSFactory _rewardFactory, IYBSFactory _utilsFactory) external;
    
    function transferOwnership(address _pendingOwner) external;
    
    function acceptOwnership() external;
    
    function isApprovedDeployer(address _deployer) external view returns (bool);
}
