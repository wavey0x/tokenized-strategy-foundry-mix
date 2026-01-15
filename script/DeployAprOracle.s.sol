// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import "forge-std/Script.sol";
import {StrategyAprOracle} from "../src/periphery/StrategyAprOracle.sol";

contract DeployAprOracle is Script {
    // Protocol addresses
    address constant ALLOCATOR_VAULT = 0x1F6f16945e395593d8050d6Cc33e4328a515B648;
    address constant YVCRVUSD = 0xBF319dDC2Edc1Eb6FDf9910E39b37Be221C8805F;

    // Curve pool addresses
    address constant POOL_CRVUSD_YB = 0xec977F46467a3021785Cff88894886E617abd65b;
    address constant POOL_YB_YYB = 0x5Ee9606e5611Fd6CE14BD2BC12db70BD53dC9daA;

    // APR Oracle config
    address constant FUNDER = 0x4444AAAACDBa5580282365e25b16309Bd770ce4a;
    uint256 constant FUND_AMOUNT = 5_000e18;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deployer:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        StrategyAprOracle aprOracle = new StrategyAprOracle(
            ALLOCATOR_VAULT,
            POOL_CRVUSD_YB,
            POOL_YB_YYB,
            YVCRVUSD,
            FUNDER,
            FUND_AMOUNT
        );

        vm.stopBroadcast();

        console.log("APR Oracle deployed at:", address(aprOracle));
    }
}
