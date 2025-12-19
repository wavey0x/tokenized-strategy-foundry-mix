// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import "forge-std/Script.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {StrategyYBSStaker} from "../src/Strategy.sol";
import {Swapper} from "../src/periphery/Swapper.sol";
import {IYBSRegistry} from "../src/interfaces/ybs/IYBSRegistry.sol";
import {IYearnBoostedStaker} from "../src/interfaces/ybs/IYearnBoostedStaker.sol";
import {IRewardsDistributor} from "../src/interfaces/ybs/IRewardsDistributor.sol";
import {ISwapper} from "../src/interfaces/utils/ISwapper.sol";
import {ICurve} from "../src/interfaces/curve/ICurve.sol";
import {ICurveInt128} from "../src/interfaces/curve/ICurveInt128.sol";

contract DeployStrategy is Script {
    // Token addresses
    address constant YYB = 0x22222222aEA0076fCA927a3f44dc0B4FdF9479D6;
    address constant YB = 0x01791F726B4103694969820be083196cC7c045fF;
    address constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;

    // Protocol addresses
    address constant YBS_REGISTRY = 0x262be1d31d0754399d8d5dc63B99c22146E9f738;
    address constant ALLOCATOR_VAULT = 0x1F6f16945e395593d8050d6Cc33e4328a515B648;

    // Curve pool addresses
    address constant POOL_CRVUSD_YB = 0xec977F46467a3021785Cff88894886E617abd65b;
    address constant POOL_YB_YYB = 0x5Ee9606e5611Fd6CE14BD2BC12db70BD53dC9daA;

    // Swap thresholds
    uint256 constant SWAP_THRESHOLD_MIN = 1e18;
    uint256 constant SWAP_THRESHOLD_MAX = 1_000_000e18;

    function run() external {
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

        // Deploy Swapper
        Swapper swapper = new Swapper(
            ERC20(CRVUSD),                      // tokenIn
            ERC20(YYB),                         // tokenOut
            ICurve(POOL_CRVUSD_YB),             // pool1 (crvUSD -> YB)
            ERC20(YB),                          // tokenOutPool1
            ICurveInt128(POOL_YB_YYB)           // pool2 (YB -> YYB)
        );
        console.log("Swapper deployed at:", address(swapper));

        // Deploy Strategy
        StrategyYBSStaker strategy = new StrategyYBSStaker(
            YYB,                                // asset
            "YBS YYB Staker",                   // name
            ALLOCATOR_VAULT,                    // allocatorVault
            ybs,                                // ybs
            rewardsDistributor,                 // rewardsDistributor
            ISwapper(address(swapper)),         // swapper
            SWAP_THRESHOLD_MIN,                 // swapThresholdMin
            SWAP_THRESHOLD_MAX                  // swapThresholdMax
        );
        console.log("Strategy deployed at:", address(strategy));

        vm.stopBroadcast();
    }
}
