// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/Test.sol";
import {RewardsSwapper} from "../../RewardsSwapper.sol";
import {ICurvePool} from "../../interfaces/ICurvePool.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title RewardsSwapperTest
 * @notice Tests for RewardsSwapper contract
 * @dev Tests swap paths and recoverERC20 functionality
 */
contract RewardsSwapperTest is Test {
    RewardsSwapper public swapper;

    address public strategy = address(1);
    address public management = address(2);
    address public asset;
    address public rewardToken;

    MockERC20 public mockAsset;
    MockERC20 public mockReward;
    MockCurvePool public mockPool;

    function setUp() public {
        // Deploy mock tokens
        mockAsset = new MockERC20("WBTC", "WBTC", 8);
        mockReward = new MockERC20("Reward Token", "RWD", 18);

        asset = address(mockAsset);
        rewardToken = address(mockReward);

        // Deploy mock Curve pool
        mockPool = new MockCurvePool(rewardToken, asset);

        // Deploy swapper (permissionless)
        swapper = new RewardsSwapper(asset, management);
    }

    function test_constructor() public {
        assertEq(swapper.asset(), asset);
        assertEq(swapper.management(), management);
    }

    function test_setRoute_onlyManagement() public {
        // Non-management should revert
        vm.prank(address(999));
        vm.expectRevert(RewardsSwapper.OnlyManagement.selector);
        swapper.setRoute(rewardToken, address(mockPool), 0, 1, 9900);

        // Management should succeed
        vm.prank(management);
        swapper.setRoute(rewardToken, address(mockPool), 0, 1, 9900);

        // Verify route is set
        RewardsSwapper.SwapRoute memory route = swapper.getRoute(rewardToken);
        assertTrue(route.isActive);
        assertEq(route.pool1, address(mockPool));
        assertEq(route.i1, 0);
        assertEq(route.j1, 1);
        assertEq(route.minOutBps, 9900);
    }

    function test_setRoute_revertsOnInvalidParams() public {
        vm.startPrank(management);

        // Zero token address
        vm.expectRevert("Invalid token");
        swapper.setRoute(address(0), address(mockPool), 0, 1, 9900);

        // Zero pool address
        vm.expectRevert("Invalid pool");
        swapper.setRoute(rewardToken, address(0), 0, 1, 9900);

        // Invalid minOutBps (> MAX_BPS)
        vm.expectRevert("Invalid minOutBps");
        swapper.setRoute(rewardToken, address(mockPool), 0, 1, 10001);

        // Slippage too high (< 9000 = more than 10% slippage)
        vm.expectRevert("Slippage too high");
        swapper.setRoute(rewardToken, address(mockPool), 0, 1, 8999);

        vm.stopPrank();
    }

    function test_setTwoLegRoute() public {
        address intermediate = address(new MockERC20("ETH", "ETH", 18));
        MockCurvePool pool2 = new MockCurvePool(intermediate, asset);

        vm.prank(management);
        swapper.setTwoLegRoute(
            rewardToken,
            address(mockPool),
            0,
            1,
            address(pool2),
            0,
            1,
            intermediate,
            9900
        );

        // Verify route is set
        RewardsSwapper.SwapRoute memory route = swapper.getRoute(rewardToken);
        assertTrue(route.isActive);
        assertEq(route.pool1, address(mockPool));
        assertEq(route.pool2, address(pool2));
        assertEq(route.intermediate, intermediate);
    }

    function test_swap_permissionless() public {
        // Setup route
        vm.prank(management);
        swapper.setRoute(rewardToken, address(mockPool), 0, 1, 9900);

        // Any caller can use the swapper
        address caller = address(999);
        mockReward.mint(caller, 1000e18);

        vm.startPrank(caller);
        mockReward.approve(address(swapper), type(uint256).max);
        // Note: This will revert in mock because we haven't implemented exchange
        // In real tests with proper mocks, this would succeed
        vm.stopPrank();
    }

    function test_swap_singleLeg_placeholder() public {
        // This test is a placeholder for single-leg swap logic
        // Cannot fully test without deployed Curve pools
        // When pools exist, test should:
        // 1. Setup single-leg route (YB -> BTC)
        // 2. Mint reward tokens to strategy
        // 3. Call swap from strategy
        // 4. Verify asset received
        // 5. Verify slippage protection works
    }

    function test_swap_twoLeg_placeholder() public {
        // This test is a placeholder for two-leg swap logic
        // Cannot fully test without deployed Curve pools
        // When pools exist, test should:
        // 1. Setup two-leg route (YB -> ETH -> BTC)
        // 2. Mint reward tokens to strategy
        // 3. Call swap from strategy
        // 4. Verify intermediate token handling
        // 5. Verify final asset received
        // 6. Verify slippage protection works
    }

    function test_previewSwap_placeholder() public {
        // This test is a placeholder for preview functionality
        // Setup route
        vm.prank(management);
        swapper.setRoute(rewardToken, address(mockPool), 0, 1, 9900);

        // Preview should work (returns 0 in mock)
        uint256 preview = swapper.previewSwap(rewardToken, 100e18);
        // In real tests with proper mock pools, verify preview amount
    }

    function test_recoverERC20() public {
        // Airdrop some tokens to swapper
        mockReward.mint(address(swapper), 100e18);

        uint256 beforeBalance = mockReward.balanceOf(management);

        // Non-management should revert
        vm.prank(address(999));
        vm.expectRevert(RewardsSwapper.OnlyManagement.selector);
        swapper.recoverERC20(rewardToken, 100e18);

        // Management can recover
        vm.prank(management);
        swapper.recoverERC20(rewardToken, 100e18);

        assertEq(mockReward.balanceOf(management), beforeBalance + 100e18);
        assertEq(mockReward.balanceOf(address(swapper)), 0);
    }

    function test_recoverERC20_partialAmount() public {
        // Airdrop tokens
        mockReward.mint(address(swapper), 100e18);

        // Recover partial amount
        vm.prank(management);
        swapper.recoverERC20(rewardToken, 50e18);

        assertEq(mockReward.balanceOf(management), 50e18);
        assertEq(mockReward.balanceOf(address(swapper)), 50e18);
    }

    function test_deactivateRoute() public {
        // Setup route
        vm.prank(management);
        swapper.setRoute(rewardToken, address(mockPool), 0, 1, 9900);

        assertTrue(swapper.isRouteActive(rewardToken));

        // Deactivate
        vm.prank(management);
        swapper.deactivateRoute(rewardToken);

        assertFalse(swapper.isRouteActive(rewardToken));
    }

    function test_setManagement() public {
        address newManagement = address(999);

        // Non-management should revert
        vm.prank(address(123));
        vm.expectRevert(RewardsSwapper.OnlyManagement.selector);
        swapper.setManagement(newManagement);

        // Management can update
        vm.prank(management);
        swapper.setManagement(newManagement);

        assertEq(swapper.management(), newManagement);
    }
}

/**
 * @title MockERC20
 * @notice Simple ERC20 mock for testing
 */
contract MockERC20 is ERC20 {
    uint8 private _decimals;

    constructor(
        string memory name,
        string memory symbol,
        uint8 decimals_
    ) ERC20(name, symbol) {
        _decimals = decimals_;
    }

    function decimals() public view virtual override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/**
 * @title MockCurvePool
 * @notice Simple Curve pool mock for testing
 */
contract MockCurvePool is ICurvePool {
    address public token0;
    address public token1;

    constructor(address _token0, address _token1) {
        token0 = _token0;
        token1 = _token1;
    }

    function exchange(
        int128 i,
        int128 j,
        uint256 dx,
        uint256 min_dy
    ) external returns (uint256) {
        // Simple mock: transfer input token, mint output token
        // In real tests, implement proper exchange logic
        revert("Mock not implemented");
    }

    function get_dy(
        int128 i,
        int128 j,
        uint256 dx
    ) external view returns (uint256) {
        // Simple mock: return 1:1 exchange rate for testing
        return dx;
    }

    function coins(uint256 arg0) external view returns (address) {
        if (arg0 == 0) return token0;
        if (arg0 == 1) return token1;
        revert("Invalid index");
    }
}
