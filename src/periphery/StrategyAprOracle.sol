// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {AprOracleBase} from "@periphery/AprOracle/AprOracleBase.sol";

contract StrategyAprOracle is AprOracleBase {
    constructor() AprOracleBase("Strategy Apr Oracle Example", msg.sender) {}

    /**
     * @notice Will return the expected Apr of a strategy post a debt change.
     * @dev This should return the annual expected return at the current timestamp
     * represented as 1e18.
     *
     *      ie. 10% == 1e17
     *
     * This will potentially be called during non-view functions so gas
     * efficiency should be taken into account.
     *
     * @return . The expected apr for the strategy represented as 1e18.
     */
    function aprAfterDebtChange(
        address /* _strategy */,
        int256 /* _delta */
    ) external pure override returns (uint256) {
        // TODO: Implement any necessary logic to return the most accurate
        //      APR estimation for the strategy.
        return 1e17;
    }
}
