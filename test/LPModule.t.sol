// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "./Base.t.sol";
import {LPModule} from "../src/LPModule.sol";

contract LPModuleTest is BaseTest {
    function setUp() public override {
        super.setUp();
    }

    // ============================================
    // Initialization Tests
    // ============================================

    function test_initialization() public view {
        assertEq(lpModule.VERSION(), "1.3.0");
        assertEq(lpModule.MODULE_NAME(), "LP Providing");
        assertEq(lpModule.basePointsRatePerSecond(), LP_BASE_RATE);
        assertTrue(lpModule.isActive());
        assertEq(lpModule.getPoolCount(), 2);
    }

    function test_moduleName() public view {
        assertEq(lpModule.moduleName(), "LP Providing");
    }

    // ============================================
    // Pool Management Tests
    // ============================================

    function test_addPool() public {
        MockERC20 newLpToken = new MockERC20("LP3", "LP3", 18);

        vm.prank(admin);
        lpModule.addPool(address(newLpToken), 150, "LP Pool 3");

        assertEq(lpModule.getPoolCount(), 3);

        (address lpToken, uint256 multiplier, bool poolActive, string memory name,,) = lpModule.getPool(2);

        assertEq(lpToken, address(newLpToken));
        assertEq(multiplier, 150);
        assertTrue(poolActive);
        assertEq(name, "LP Pool 3");
    }

    function test_revert_addPool_zeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(LPModule.ZeroAddress.selector);
        lpModule.addPool(address(0), 100, "Invalid");
    }

    function test_revert_addPool_alreadyExists() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(LPModule.PoolAlreadyExists.selector, address(lpToken1)));
        lpModule.addPool(address(lpToken1), 100, "Duplicate");
    }

    function test_revert_addPool_invalidMultiplier() public {
        MockERC20 newLp = new MockERC20("LP", "LP", 18);

        vm.prank(admin);
        vm.expectRevert(LPModule.InvalidMultiplier.selector);
        lpModule.addPool(address(newLp), 0, "Zero Multiplier");

        vm.prank(admin);
        vm.expectRevert(LPModule.InvalidMultiplier.selector);
        lpModule.addPool(address(newLp), 1001, "Too High Multiplier");
    }

    function test_revert_addPool_maxPoolsReached() public {
        // Add pools until max (20)
        for (uint256 i = 2; i < 20; i++) {
            MockERC20 newLp = new MockERC20(string(abi.encodePacked("LP", i)), "LP", 18);
            vm.prank(admin);
            lpModule.addPool(address(newLp), 100, "Pool");
        }

        // Try to add one more
        MockERC20 extraLp = new MockERC20("Extra", "EX", 18);
        vm.prank(admin);
        vm.expectRevert(LPModule.MaxPoolsReached.selector);
        lpModule.addPool(address(extraLp), 100, "Extra");
    }

    function test_updatePool() public {
        vm.prank(admin);
        lpModule.updatePool(0, 200, false);

        (, uint256 multiplier, bool poolActive,,,) = lpModule.getPool(0);

        assertEq(multiplier, 200);
        assertFalse(poolActive);
    }

    function test_updatePoolName() public {
        vm.prank(admin);
        lpModule.updatePoolName(0, "New Name");

        (,,, string memory name,,) = lpModule.getPool(0);

        assertEq(name, "New Name");
    }

    // ============================================
    // Checkpoint Tests
    // ============================================

    function test_checkpointAllPools() public {
        vm.prank(keeper);
        lpModule.checkpointAllPools();
        // Should not revert
    }

    function test_checkpointUsers() public {
        lpToken1.mint(user1, 1000 * 1e18);
        lpToken2.mint(user2, 500 * 1e18);

        address[] memory users = new address[](2);
        users[0] = user1;
        users[1] = user2;

        vm.prank(keeper);
        lpModule.checkpointUsers(users);

        // Verify state
        (uint256 balance, uint256 lastCheckpointBalance,, uint256 lastCheckpointTime,) =
            lpModule.getUserPoolState(user1, 0);

        assertEq(balance, 1000 * 1e18);
        assertEq(lastCheckpointBalance, 1000 * 1e18);
        assertGt(lastCheckpointTime, 0);
    }

    function test_checkpointSelf() public {
        lpToken1.mint(user1, 1000 * 1e18);

        vm.prank(user1);
        lpModule.checkpointSelf();

        (, uint256 lastCheckpointBalance,,,) = lpModule.getUserPoolState(user1, 0);

        assertEq(lastCheckpointBalance, 1000 * 1e18);
    }

    function test_checkpointUserPool() public {
        lpToken1.mint(user1, 1000 * 1e18);

        vm.prank(user2);
        lpModule.checkpointUserPool(user1, 0);

        (, uint256 lastCheckpointBalance,,,) = lpModule.getUserPoolState(user1, 0);

        assertEq(lastCheckpointBalance, 1000 * 1e18);
    }

    function test_revert_checkpointUsers_batchTooLarge() public {
        address[] memory users = new address[](26);
        for (uint256 i = 0; i < 26; i++) {
            users[i] = address(uint160(i + 1));
        }

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(LPModule.BatchTooLarge.selector, 26, 25));
        lpModule.checkpointUsers(users);
    }

    // ============================================
    // Points Calculation Tests
    // ============================================

    function test_getPoints_singlePool() public {
        lpToken1.mint(user1, 1000 * 1e18);

        vm.prank(keeper);
        lpModule.checkpointUsers(toArray(user1));

        _advanceTime(1 days);

        uint256 points = lpModule.getPoints(user1);
        // Expected: balance * timeDelta * rate * multiplier / (supply * MULTIPLIER_BASE)
        assertGt(points, 0);
    }

    function test_getPoints_multiplePoolsWithMultipliers() public {
        lpToken1.mint(user1, 1000 * 1e18); // 1x multiplier
        lpToken2.mint(user1, 1000 * 1e18); // 2x multiplier

        vm.prank(keeper);
        lpModule.checkpointUsers(toArray(user1));

        _advanceTime(1 days);

        uint256 totalPoints = lpModule.getPoints(user1);

        // Get individual pool points
        (string[] memory names, uint256[] memory points,,) = lpModule.getUserPoolBreakdown(user1);

        assertEq(names.length, 2);
        assertGt(points[0], 0);
        assertGt(points[1], 0);
        // Pool 2 should have 2x points due to multiplier
        assertApproxEqRel(points[1], points[0] * 2, 0.01e18);
    }

    function test_getPoints_inactivePool() public {
        lpToken1.mint(user1, 1000 * 1e18);

        vm.prank(keeper);
        lpModule.checkpointUsers(toArray(user1));

        // Deactivate pool 0
        vm.prank(admin);
        lpModule.updatePool(0, 100, false);

        _advanceTime(1 days);

        // Points for inactive pool should be from before deactivation
        (, uint256[] memory points,,) = lpModule.getUserPoolBreakdown(user1);

        // Pool 0 is inactive, should have 0 new points after deactivation
        // But might have points from before (depends on timing)
    }

    function test_estimatePoolPoints() public {
        lpToken1.mint(user1, 1000 * 1e18);

        uint256 estimated = lpModule.estimatePoolPoints(0, 500 * 1e18, 1 days);
        assertGt(estimated, 0);
    }

    // ============================================
    // View Functions Tests
    // ============================================

    function test_getPoolCount() public view {
        assertEq(lpModule.getPoolCount(), 2);
    }

    function test_getPool() public view {
        (
            address lpToken,
            uint256 multiplier,
            bool poolActive,
            string memory name,
            uint256 totalSupply,
            uint256 pointsPerLp
        ) = lpModule.getPool(0);

        assertEq(lpToken, address(lpToken1));
        assertEq(multiplier, 100);
        assertTrue(poolActive);
        assertEq(name, "LP Pool 1");
        assertEq(totalSupply, 0); // No LP minted yet
        assertEq(pointsPerLp, 0);
    }

    function test_getUserPoolBreakdown() public {
        lpToken1.mint(user1, 1000 * 1e18);
        lpToken2.mint(user1, 500 * 1e18);

        vm.prank(keeper);
        lpModule.checkpointUsers(toArray(user1));

        _advanceTime(1 hours);

        (string[] memory names, uint256[] memory points, uint256[] memory balances, uint256[] memory multipliers) =
            lpModule.getUserPoolBreakdown(user1);

        assertEq(names.length, 2);
        assertEq(names[0], "LP Pool 1");
        assertEq(names[1], "LP Pool 2");
        assertEq(balances[0], 1000 * 1e18);
        assertEq(balances[1], 500 * 1e18);
        assertEq(multipliers[0], 100);
        assertEq(multipliers[1], 200);
    }

    function test_getUserPoolState() public {
        lpToken1.mint(user1, 1000 * 1e18);

        vm.prank(keeper);
        lpModule.checkpointUsers(toArray(user1));

        _advanceTime(1 hours);

        (
            uint256 balance,
            uint256 lastCheckpointBalance,
            uint256 earnedPoints,
            uint256 lastCheckpointTime,
            uint256 lastCheckpointBlock
        ) = lpModule.getUserPoolState(user1, 0);

        assertEq(balance, 1000 * 1e18);
        assertEq(lastCheckpointBalance, 1000 * 1e18);
        assertGt(earnedPoints, 0);
        assertGt(lastCheckpointTime, 0);
        assertGt(lastCheckpointBlock, 0);
    }

    // ============================================
    // Admin Functions Tests
    // ============================================

    function test_setBaseRate() public {
        uint256 newRate = 2 * LP_BASE_RATE;

        vm.prank(admin);
        lpModule.setBaseRate(newRate);

        assertEq(lpModule.basePointsRatePerSecond(), newRate);
    }

    function test_setActive() public {
        vm.prank(admin);
        lpModule.setActive(false);

        assertFalse(lpModule.isActive());

        // Points should not accumulate when module is inactive
        lpToken1.mint(user1, 1000 * 1e18);
        vm.prank(keeper);
        lpModule.checkpointUsers(toArray(user1));
        _advanceTime(1 days);

        uint256 points = lpModule.getPoints(user1);
        assertEq(points, 0);
    }

    function test_pause_unpause() public {
        vm.prank(admin);
        lpModule.pause();

        vm.prank(admin);
        lpModule.unpause();
    }

    // ============================================
    // Edge Cases
    // ============================================

    function test_zeroLpSupply() public {
        // No LP minted, supply is 0
        (,,,, uint256 totalSupply,) = lpModule.getPool(0);

        assertEq(totalSupply, 0);
    }

    function test_checkpointPools_specificPools() public {
        uint256[] memory poolIds = new uint256[](1);
        poolIds[0] = 0;

        vm.prank(keeper);
        lpModule.checkpointPools(poolIds);
    }

    function test_checkpointPools_invalidPoolId() public {
        uint256[] memory poolIds = new uint256[](1);
        poolIds[0] = 999; // Invalid

        vm.prank(keeper);
        lpModule.checkpointPools(poolIds);
        // Should emit CheckpointPoolSkipped event but not revert
    }

    // ============================================
    // Fuzz Tests
    // ============================================

    function testFuzz_pointsCalculation(uint256 balance, uint256 timeElapsed) public {
        balance = bound(balance, 1e18, 1_000_000 * 1e18);
        timeElapsed = bound(timeElapsed, 1 hours, 365 days);

        lpToken1.mint(user1, balance);
        vm.prank(keeper);
        lpModule.checkpointUsers(toArray(user1));

        _advanceTime(timeElapsed);

        uint256 points = lpModule.getPoints(user1);
        assertGt(points, 0);
    }

    function testFuzz_multiplierEffect(uint256 multiplier) public {
        multiplier = bound(multiplier, 1, 1000);

        // Update pool multiplier
        vm.prank(admin);
        lpModule.updatePool(0, multiplier, true);

        lpToken1.mint(user1, 1000 * 1e18);
        vm.prank(keeper);
        lpModule.checkpointUsers(toArray(user1));

        _advanceTime(1 days);

        uint256 points = lpModule.getPoints(user1);
        assertGt(points, 0);
    }

    // ============================================
    // Helper Functions
    // ============================================

    function toArray(address a) internal pure returns (address[] memory) {
        address[] memory arr = new address[](1);
        arr[0] = a;
        return arr;
    }
}

import {MockERC20} from "./mocks/MockERC20.sol";
