// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import "forge-std/Script.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Swapper} from "../src/periphery/Swapper.sol";
import {ICurve} from "../src/interfaces/curve/ICurve.sol";
import {ICurveInt128} from "../src/interfaces/curve/ICurveInt128.sol";

contract DeploySwapper is Script {
    // Token addresses
    address constant YYB = 0x22222222aEA0076fCA927a3f44dc0B4FdF9479D6;
    address constant YB = 0x01791F726B4103694969820be083196cC7c045fF;
    address constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;

    // Curve pool addresses
    address constant POOL_CRVUSD_YB = 0xec977F46467a3021785Cff88894886E617abd65b;
    address constant POOL_YB_YYB = 0x5Ee9606e5611Fd6CE14BD2BC12db70BD53dC9daA;

    // Management address
    address constant MANAGEMENT = 0x16388463d60FFE0661Cf7F1f31a7D658aC790ff7;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deployer:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        Swapper swapper = new Swapper(
            MANAGEMENT,                         // management
            ERC20(CRVUSD),                      // tokenIn
            ERC20(YYB),                         // tokenOut
            ICurve(POOL_CRVUSD_YB),             // pool1 (crvUSD -> YB)
            ERC20(YB),                          // tokenOutPool1
            ICurveInt128(POOL_YB_YYB)           // pool2 (YB -> YYB)
        );

        vm.stopBroadcast();

        console.log("Swapper deployed at:", address(swapper));
    }
}
