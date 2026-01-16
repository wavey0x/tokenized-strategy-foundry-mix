// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/console.sol";
import {Setup, ERC20, IStrategyInterface} from "./utils/Setup.sol";
import {StrategyAprOracle} from "../periphery/StrategyAprOracle.sol";

/// @dev Test oracle with overridable strategy() and vault totalAssets for testing
contract TestableAprOracle is StrategyAprOracle {
    address public testStrategy;
    uint256 public testTotalAssets;

    constructor(address _vault, address _funder, uint256 _fundAmount)
        StrategyAprOracle(_vault, address(0), address(0), address(0), _funder, _fundAmount) {}

    function setTestStrategy(address _strategy) external {
        testStrategy = _strategy;
    }

    function setTestTotalAssets(uint256 _totalAssets) external {
        testTotalAssets = _totalAssets;
    }

    function strategy() public view override returns (address) {
        return testStrategy;
    }

    function aprAfterDebtChange(
        address _strategy,
        int256 _delta
    ) external view override returns (uint256 apr) {
        apr = YBS_UTILS.getUserActiveApr(
            _strategy,
            getStakeTokenPrice(),
            getRewardTokenPrice()
        );

        // Fallback to projected APR if active is 0
        if (apr == 0) {
            apr = YBS_UTILS.getUserProjectedApr(
                _strategy,
                getStakeTokenPrice(),
                getRewardTokenPrice()
            );
        }

        uint256 totalAssets = testTotalAssets;
        if (_delta > 0) {
            totalAssets += uint256(_delta);
        } else if (_delta < 0) {
            uint256 decrease = uint256(-_delta);
            totalAssets = totalAssets > decrease ? totalAssets - decrease : 0;
        }

        if (totalAssets > 0) {
            uint256 additionalApr = amountPerEpoch[getEpoch()] * 52 * 1e18 / totalAssets;
            apr += additionalApr;
        }

        // Floor check (will be 0 in tests)
        uint256 unlockingApr = getVaultUnlockingApr();
        apr = unlockingApr > apr ? unlockingApr : apr;
    }

    function getVaultUnlockingApr() public pure override returns (uint256) {
        return 0; // No floor in tests
    }

    // Mock prices for testing (both 1:1 with crvUSD)
    function getStakeTokenPrice() public view override returns (uint256) {
        return 1e18;
    }

    function getRewardTokenPrice() public view override returns (uint256) {
        return 1e18;
    }
}

contract AprOracleTest is Setup {
    TestableAprOracle public oracle;

    function setUp() public virtual override {
        super.setUp();
        oracle = new TestableAprOracle(user, address(this), 1000e18); // user is the allocator vault
        oracle.setTestStrategy(address(strategy));
        oracle.setTestTotalAssets(1_000_000e18); // 1M vault assets
    }

    function test_aprAfterDebtChange() public {
        mintAndDepositIntoStrategy(strategy, user, 100_000e18);

        uint256 apr = oracle.aprAfterDebtChange(address(strategy), 0);
        console.log("Base APR:", apr);
        assertGe(apr, 0, "APR should be >= 0");
    }

    function test_notifyRewards_increasesApr() public {
        mintAndDepositIntoStrategy(strategy, user, 100_000e18);

        uint256 aprBefore = oracle.aprAfterDebtChange(address(strategy), 0);

        // Donate rewards
        uint256 donationAmount = 1000e18;
        deal(oracle.YYB(), address(this), donationAmount);
        ERC20(oracle.YYB()).approve(address(oracle), donationAmount);
        oracle.notifyRewards(donationAmount);

        uint256 aprAfter = oracle.aprAfterDebtChange(address(strategy), 0);
        console.log("APR before donation:", aprBefore);
        console.log("APR after donation:", aprAfter);

        assertGt(aprAfter, aprBefore, "APR should increase after donation");
        assertEq(oracle.amountPerEpoch(oracle.getEpoch()), donationAmount, "Epoch amount mismatch");
    }

    function test_notifyRewardsFromFunder() public {
        mintAndDepositIntoStrategy(strategy, user, 100_000e18);

        uint256 fundAmount = oracle.fundAmount();
        deal(oracle.YYB(), address(this), fundAmount);
        ERC20(oracle.YYB()).approve(address(oracle), fundAmount);

        oracle.notifyRewardsFromFunder();

        assertEq(oracle.amountPerEpoch(oracle.getEpoch()), fundAmount, "Epoch amount mismatch");
        assertTrue(oracle.epochAutoFunded(oracle.getEpoch()), "Epoch should be marked funded");
    }

    function test_notifyRewardsFromFunder_oncePerEpoch() public {
        mintAndDepositIntoStrategy(strategy, user, 100_000e18);

        uint256 fundAmount = oracle.fundAmount();
        deal(oracle.YYB(), address(this), fundAmount * 2);
        ERC20(oracle.YYB()).approve(address(oracle), fundAmount * 2);

        oracle.notifyRewardsFromFunder();

        vm.expectRevert("already funded");
        oracle.notifyRewardsFromFunder();
    }

    function test_setFundingParams() public {
        address newFunder = address(0x123);
        uint256 newAmount = 5000e18;

        oracle.setFundingParams(newFunder, newAmount);

        assertEq(oracle.funder(), newFunder, "Funder not updated");
        assertEq(oracle.fundAmount(), newAmount, "Fund amount not updated");
    }

    function test_setFundingParams_onlyFunder() public {
        vm.prank(address(0xdead));
        vm.expectRevert("!funder");
        oracle.setFundingParams(address(0x123), 1000e18);
    }

    function test_getEpoch() public view {
        uint256 epoch = oracle.getEpoch();
        // Epoch should be aligned to 7 days
        assertEq(epoch % 7 days, 4, "Epoch not aligned to week");
    }
}