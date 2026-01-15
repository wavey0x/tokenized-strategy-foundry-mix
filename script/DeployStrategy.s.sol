// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import "forge-std/Script.sol";
import {StrategyYBSStaker} from "../src/Strategy.sol";
import {IYBSRegistry} from "../src/interfaces/ybs/IYBSRegistry.sol";
import {IYearnBoostedStaker} from "../src/interfaces/ybs/IYearnBoostedStaker.sol";
import {IRewardsDistributor} from "../src/interfaces/ybs/IRewardsDistributor.sol";
import {ISwapper} from "../src/interfaces/utils/ISwapper.sol";

contract DeployStrategy is Script {
    // Token addresses
    address constant YYB = 0x22222222aEA0076fCA927a3f44dc0B4FdF9479D6;

    // Protocol addresses
    address constant YBS_REGISTRY = 0x262be1d31d0754399d8d5dc63B99c22146E9f738;
    address constant ALLOCATOR_VAULT = 0x1F6f16945e395593d8050d6Cc33e4328a515B648;
    address constant SWAPPER = 0x6996b52f7fa5E1D867110f32dC9AA9c4986F1D52;

    // Swap thresholds
    uint256 constant SWAP_THRESHOLD_MIN = 10e18;
    uint256 constant SWAP_THRESHOLD_MAX = 10_000e18;

    function run() external {
        require(SWAPPER != address(0), "Set SWAPPER address first");

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deployer:", deployer);
        console.log("Asset (YYB):", YYB);

        vm.startBroadcast(deployerPrivateKey);

        // Get YBS deployment for YYB
        IYBSRegistry registry = IYBSRegistry(YBS_REGISTRY);
        (address ybsAddress, address rewardsAddress, ) = registry.deployments(YYB);

        require(ybsAddress != address(0), "YBS not deployed for YYB");
        console.log("YBS:", ybsAddress);
        console.log("Rewards Distributor:", rewardsAddress);

        IYearnBoostedStaker ybs = IYearnBoostedStaker(ybsAddress);
        IRewardsDistributor rewardsDistributor = IRewardsDistributor(rewardsAddress);

        // Deploy Strategy
        StrategyYBSStaker strategy = new StrategyYBSStaker(
            YYB,                                // asset
            "YBS YYB Staker",                   // name
            ALLOCATOR_VAULT,                    // allocatorVault
            ybs,                                // ybs
            rewardsDistributor,                 // rewardsDistributor
            ISwapper(SWAPPER),                  // swapper
            SWAP_THRESHOLD_MIN,                 // swapThresholdMin
            SWAP_THRESHOLD_MAX                  // swapThresholdMax
        );

        vm.stopBroadcast();

        console.log("Strategy deployed at:", address(strategy));
        console.log("");
        console.log("Next steps:");
        console.log("1. Set keeper: strategy.setKeeper(keeperAddress)");
        console.log("2. Set performance fee recipient: strategy.setPerformanceFeeRecipient(recipientAddress)");
        console.log("3. Transfer management: strategy.setPendingManagement(newManagement)");
        console.log("4. Accept management from new address: strategy.acceptManagement()");
    }
}
