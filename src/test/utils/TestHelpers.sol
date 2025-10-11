// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ILT} from "../../interfaces/yb/ILT.sol";
import {ICurveCryptoPool} from "../../interfaces/yb/ICurveCryptoPool.sol";

/**
 * @title TestHelpers
 * @notice Shared test utility functions for all strategy tests
 * @dev Provides reusable assertion helpers and test utilities
 */
abstract contract TestHelpers is Test {
    // ===== CONSTANTS =====

    uint256 public constant RELATIVE_APPROX = 5e2; // 0.5%

    // ===== ASSERTION HELPERS =====

    /**
     * @notice Helper assertion for relative approximation
     * @param a Actual value
     * @param b Expected value
     * @param maxPercentDelta Maximum percent delta (e.g., 100 = 1%)
     */
    function assertRelApproxEq(
        uint256 a,
        uint256 b,
        uint256 maxPercentDelta
    ) internal {
        uint256 delta = a > b ? a - b : b - a;
        uint256 maxRelDelta = b / maxPercentDelta;

        if (delta > maxRelDelta) {
            emit log("Error: a ~= b not satisfied [uint]");
            emit log_named_uint("  Expected", b);
            emit log_named_uint("    Actual", a);
            emit log_named_uint(" Max Delta", maxRelDelta);
            emit log_named_uint("     Delta", delta);
            fail();
        }
    }

    /**
     * @notice Helper assertion for relative approximation with custom error message
     * @param a Actual value
     * @param b Expected value
     * @param maxPercentDelta Maximum percent delta (e.g., 100 = 1%)
     * @param err Custom error message
     */
    function assertRelApproxEq(
        uint256 a,
        uint256 b,
        uint256 maxPercentDelta,
        string memory err
    ) internal {
        uint256 delta = a > b ? a - b : b - a;
        uint256 maxRelDelta = b / maxPercentDelta;

        if (delta > maxRelDelta) {
            emit log_named_string("Error", err);
            emit log_named_uint("  Expected", b);
            emit log_named_uint("    Actual", a);
            emit log_named_uint(" Max Delta", maxRelDelta);
            emit log_named_uint("     Delta", delta);
            fail();
        }
    }

    // ===== YIELD BASIS HELPERS =====

    /**
     * @notice Calculate debt needed for LT deposit using Curve pool's price oracle
     * @param lt LT token contract
     * @param assetAmount Amount of asset to deposit (e.g., 8 decimals for BTC)
     * @return debt Amount of crvUSD debt to take (18 decimals)
     * @dev Uses Curve pool's TWAP oracle for stable, manipulation-resistant pricing
     *      debt ≈ assetAmount × BTC_price (per YB protocol docs)
     */
    function calculateDebtForLTDeposit(ILT lt, uint256 assetAmount)
        internal
        view
        returns (uint256 debt)
    {
        ICurveCryptoPool pool = ICurveCryptoPool(lt.CRYPTOPOOL());

        // Get oracle price (crvUSD per BTC, in 1e18 format)
        uint256 price = pool.price_oracle();

        // Get asset decimals (8 for WBTC, cbBTC, tBTC)
        address btc = lt.ASSET_TOKEN();
        uint256 assetDecimals = ERC20(btc).decimals();
        debt = (assetAmount * price) / (10 ** assetDecimals);
    }

    function scaleTokenDecimals(ERC20 _token, uint256 _amount)
        internal
        view
        returns (uint256)
    {
        uint256 fromDecimals = _token.decimals();
        if (fromDecimals < 18) {
            return _amount * (10 ** (18 - fromDecimals));
        } else {
            return _amount;
        }
    }

    function descaleTokenDecimals(ERC20 _token, uint256 _amount)
        internal
        view
        returns (uint256)
    {
        uint256 toDecimals = _token.decimals();
        if (toDecimals < 18) {
            uint256 divisor = 10 ** (18 - toDecimals);
            return (_amount + divisor - 1) / divisor;
        } else {
            return _amount;
        }
    }
}
