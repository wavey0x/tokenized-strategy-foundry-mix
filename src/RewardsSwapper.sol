// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ICurvePool} from "./interfaces/ICurvePool.sol";

/**
 * @title RewardsSwapper
 * @author Yearn Finance
 * @notice Handles swapping of reward tokens to asset tokens for strategies
 * @dev Upgradeable by management, supports configurable routes per token
 *
 * This contract centralizes DEX swap logic for reward tokens, allowing:
 * - Management to configure and update swap routes without changing strategy code
 * - Support for different DEX protocols (Uniswap V3, 1inch, etc.)
 * - Per-token route configuration
 * - Slippage protection
 */
contract RewardsSwapper {
    using SafeERC20 for ERC20;

    // ===== STRUCTS =====

    /// @notice Swap route configuration for a token
    struct SwapRoute {
        address pool1;         // First Curve pool (e.g., YB -> ETH)
        int128 i1;             // Index of input token in pool1
        int128 j1;             // Index of output token in pool1
        address pool2;         // Second Curve pool (e.g., ETH -> BTC), zero if single-leg
        int128 i2;             // Index of input token in pool2
        int128 j2;             // Index of output token in pool2
        address intermediate;  // Intermediate token (e.g., ETH), zero if single-leg
        bool isActive;         // Whether this route is active
        uint256 minOutBps;     // Minimum output in basis points (e.g., 9900 = 1% slippage)
    }

    // ===== STATE VARIABLES =====

    /// @notice Asset token that all rewards are swapped to
    address public immutable asset;

    /// @notice Management address (can update routes)
    address public management;

    /// @notice Mapping of reward token => swap route configuration
    mapping(address => SwapRoute) public routes;

    // ===== CONSTANTS =====

    uint256 internal constant MAX_BPS = 10_000;

    // ===== EVENTS =====

    event RouteUpdated(
        address indexed token,
        address router,
        bytes routeData,
        uint256 minOutBps
    );
    event RouteDeactivated(address indexed token);
    event ManagementUpdated(address newManagement);
    event Swapped(
        address indexed token,
        uint256 amountIn,
        uint256 amountOut,
        address router
    );

    // ===== ERRORS =====

    error OnlyManagement();
    error RouteNotActive();
    error InvalidRouter();
    error InvalidMinOut();
    error SlippageTooHigh();
    error SwapFailed();

    // ===== MODIFIERS =====

    modifier onlyManagement() {
        if (msg.sender != management) revert OnlyManagement();
        _;
    }

    // ===== CONSTRUCTOR =====

    /**
     * @notice Initialize the rewards swapper
     * @param _asset Asset token to swap rewards to
     * @param _management Management address
     */
    constructor(address _asset, address _management) {
        require(_asset != address(0), "Invalid asset");
        require(_management != address(0), "Invalid management");

        asset = _asset;
        management = _management;
    }

    // ===== SWAP FUNCTIONS =====

    /**
     * @notice Swap reward token to asset
     * @param token Reward token to swap
     * @param amount Amount of reward token to swap
     * @param minOut Minimum amount of asset to receive (0 = use route default)
     * @return amountOut Amount of asset received
     * @dev Permissionless. Caller must approve this contract to spend tokens first.
     */
    function swap(
        address token,
        uint256 amount,
        uint256 minOut
    ) external returns (uint256 amountOut) {
        SwapRoute memory route = routes[token];
        if (!route.isActive) revert RouteNotActive();
        if (route.pool1 == address(0)) revert InvalidRouter();

        // Transfer tokens from caller
        ERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        // Calculate minimum output if not provided
        if (minOut == 0) {
            minOut = _calculateMinOut(token, amount, route.minOutBps);
        }

        // Track balance before swap
        uint256 assetBefore = ERC20(asset).balanceOf(address(this));

        // Execute Curve swap (single or two-leg)
        _executeSwap(token, amount, minOut, route);

        // Calculate amount received
        uint256 assetAfter = ERC20(asset).balanceOf(address(this));
        amountOut = assetAfter - assetBefore;

        // Verify slippage protection
        if (amountOut < minOut) revert SlippageTooHigh();

        // Transfer asset back to caller
        ERC20(asset).safeTransfer(msg.sender, amountOut);

        emit Swapped(token, amount, amountOut, route.pool1);
    }

    /**
     * @notice Preview swap output (view function)
     * @param token Token to swap
     * @param amount Amount to swap
     * @return expectedOut Expected output amount
     */
    function previewSwap(address token, uint256 amount)
        external
        view
        returns (uint256 expectedOut)
    {
        SwapRoute memory route = routes[token];
        if (!route.isActive) return 0;

        if (route.pool2 == address(0)) {
            // Single-leg swap
            return ICurvePool(route.pool1).get_dy(route.i1, route.j1, amount);
        } else {
            // Two-leg swap
            uint256 intermediateOut = ICurvePool(route.pool1).get_dy(
                route.i1,
                route.j1,
                amount
            );
            return ICurvePool(route.pool2).get_dy(
                route.i2,
                route.j2,
                intermediateOut
            );
        }
    }

    // ===== INTERNAL SWAP LOGIC =====

    /**
     * @notice Execute Curve swap (single or two-leg)
     * @param token Token to swap
     * @param amount Amount to swap
     * @param minOut Minimum output
     * @param route Swap route configuration
     */
    function _executeSwap(
        address token,
        uint256 amount,
        uint256 minOut,
        SwapRoute memory route
    ) internal {
        if (route.pool2 == address(0)) {
            // Single-leg swap: token -> asset
            ERC20(token).safeApprove(route.pool1, amount);
            ICurvePool(route.pool1).exchange(
                route.i1,
                route.j1,
                amount,
                minOut
            );
            ERC20(token).safeApprove(route.pool1, 0);
        } else {
            // Two-leg swap: token -> intermediate -> asset

            // First leg: token -> intermediate
            ERC20(token).safeApprove(route.pool1, amount);
            uint256 intermediateOut = ICurvePool(route.pool1).exchange(
                route.i1,
                route.j1,
                amount,
                0  // No slippage check on intermediate step
            );
            ERC20(token).safeApprove(route.pool1, 0);

            // Second leg: intermediate -> asset
            ERC20(route.intermediate).safeApprove(route.pool2, intermediateOut);
            ICurvePool(route.pool2).exchange(
                route.i2,
                route.j2,
                intermediateOut,
                0  // Final slippage check happens in swap() function
            );
            ERC20(route.intermediate).safeApprove(route.pool2, 0);
        }
    }

    /**
     * @notice Calculate minimum output based on route configuration
     * @param token Token being swapped
     * @param amount Amount being swapped
     * @param minOutBps Minimum output in basis points
     * @return minOut Minimum output amount
     */
    function _calculateMinOut(
        address token,
        uint256 amount,
        uint256 minOutBps
    ) internal view returns (uint256 minOut) {
        SwapRoute memory route = routes[token];

        if (route.pool2 == address(0)) {
            // Single-leg swap: get expected output from pool1
            uint256 expectedOut = ICurvePool(route.pool1).get_dy(
                route.i1,
                route.j1,
                amount
            );
            minOut = (expectedOut * minOutBps) / MAX_BPS;
        } else {
            // Two-leg swap: chain get_dy calls
            uint256 intermediateOut = ICurvePool(route.pool1).get_dy(
                route.i1,
                route.j1,
                amount
            );
            uint256 expectedOut = ICurvePool(route.pool2).get_dy(
                route.i2,
                route.j2,
                intermediateOut
            );
            minOut = (expectedOut * minOutBps) / MAX_BPS;
        }
    }

    // ===== MANAGEMENT FUNCTIONS =====

    /**
     * @notice Set or update swap route for a token (single-leg Curve swap)
     * @param token Reward token address
     * @param pool Curve pool address
     * @param i Index of input token in pool
     * @param j Index of output token in pool
     * @param minOutBps Minimum output in basis points (e.g., 9900 = 1% slippage)
     */
    function setRoute(
        address token,
        address pool,
        int128 i,
        int128 j,
        uint256 minOutBps
    ) external onlyManagement {
        require(token != address(0), "Invalid token");
        require(pool != address(0), "Invalid pool");
        require(minOutBps <= MAX_BPS, "Invalid minOutBps");
        require(minOutBps >= 9000, "Slippage too high"); // Max 10% slippage

        routes[token] = SwapRoute({
            pool1: pool,
            i1: i,
            j1: j,
            pool2: address(0),
            i2: 0,
            j2: 0,
            intermediate: address(0),
            isActive: true,
            minOutBps: minOutBps
        });

        emit RouteUpdated(token, pool, "", minOutBps);
    }

    /**
     * @notice Set or update swap route for a token (two-leg Curve swap)
     * @param token Reward token address
     * @param pool1 First Curve pool address (token -> intermediate)
     * @param i1 Index of input token in pool1
     * @param j1 Index of output token in pool1
     * @param pool2 Second Curve pool address (intermediate -> asset)
     * @param i2 Index of input token in pool2
     * @param j2 Index of output token in pool2
     * @param intermediate Intermediate token address
     * @param minOutBps Minimum output in basis points (e.g., 9900 = 1% slippage)
     */
    function setTwoLegRoute(
        address token,
        address pool1,
        int128 i1,
        int128 j1,
        address pool2,
        int128 i2,
        int128 j2,
        address intermediate,
        uint256 minOutBps
    ) external onlyManagement {
        require(token != address(0), "Invalid token");
        require(pool1 != address(0), "Invalid pool1");
        require(pool2 != address(0), "Invalid pool2");
        require(intermediate != address(0), "Invalid intermediate");
        require(minOutBps <= MAX_BPS, "Invalid minOutBps");
        require(minOutBps >= 9000, "Slippage too high"); // Max 10% slippage

        routes[token] = SwapRoute({
            pool1: pool1,
            i1: i1,
            j1: j1,
            pool2: pool2,
            i2: i2,
            j2: j2,
            intermediate: intermediate,
            isActive: true,
            minOutBps: minOutBps
        });

        emit RouteUpdated(token, pool1, "", minOutBps);
    }

    /**
     * @notice Deactivate route for a token
     * @param token Token to deactivate route for
     */
    function deactivateRoute(address token) external onlyManagement {
        routes[token].isActive = false;
        emit RouteDeactivated(token);
    }

    /**
     * @notice Update management address
     * @param newManagement New management address
     */
    function setManagement(address newManagement) external onlyManagement {
        require(newManagement != address(0), "Invalid management");
        management = newManagement;
        emit ManagementUpdated(newManagement);
    }

    /**
     * @notice Emergency function to recover stuck tokens
     * @param token Token to recover
     * @param amount Amount to recover
     */
    function recoverERC20(
        address token,
        uint256 amount
    ) external onlyManagement {
        ERC20(token).safeTransfer(management, amount);
    }

    // ===== VIEW FUNCTIONS =====

    /**
     * @notice Get route configuration for a token
     * @param token Token address
     * @return route SwapRoute struct
     */
    function getRoute(address token)
        external
        view
        returns (SwapRoute memory route)
    {
        return routes[token];
    }

    /**
     * @notice Check if route is active for a token
     * @param token Token address
     * @return isActive Whether route is active
     */
    function isRouteActive(address token) external view returns (bool) {
        return routes[token].isActive;
    }
}
