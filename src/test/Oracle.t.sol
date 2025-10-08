pragma solidity ^0.8.18;

import "forge-std/console2.sol";
import {YieldBasisSetup} from "./utils/YieldBasisSetup.sol";
import {YieldBasisLTStrategy} from "../YieldBasisLTStrategy.sol";
import {IStrategy} from "@tokenized-strategy/interfaces/IStrategy.sol";

import {StrategyAprOracle} from "../periphery/StrategyAprOracle.sol";

contract OracleTest is YieldBasisSetup {
    StrategyAprOracle public oracle;

    function setUp() public override {
        super.setUp();
        oracle = new StrategyAprOracle();
    }

    function deployStrategy() internal override returns (address) {
        // Deploy via factory (tests production deployment path)
        address deployed = factory.deployLTStrategy(
            address(asset),
            ltToken,
            cryptopool,
            "Test Strategy"
        );

        vm.prank(address(factory));
        IStrategy(deployed).setPendingManagement(management);
        vm.prank(management);
        IStrategy(deployed).acceptManagement();

        // Setup keeper
        vm.prank(management);
        IStrategy(deployed).setKeeper(keeper);

        return deployed;
    }

    // TODO: Deploy multiple strategies with different tokens as `asset` to test against the oracle.
}
