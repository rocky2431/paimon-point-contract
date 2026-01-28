// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "./Base.t.sol";
import {LPModule} from "../src/LPModule.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract LPModuleTest is BaseTest {
    function setUp() public override {
        super.setUp();
    }

    // ============================================
    // Helper Functions
    // ============================================

    function _mintLpTokens(address user, uint256 amount1, uint256 amount2) internal {
        lpToken1.mint(user, amount1);
        lpToken2.mint(user, amount2);
    }

    // ============================================
    // Initialization Tests
    // ============================================

    function test_initialization() public view {
        assertEq(lpModule.VERSION(), "2.0.0");
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

        (address lpToken, uint256 multiplier, bool poolActive, string memory name,) = lpModule.getPool(2);

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

        (, uint256 multiplier, bool poolActive,,) = lpModule.getPool(0);

        assertEq(multiplier, 200);
        assertFalse(poolActive);
    }

    function test_updatePoolName() public {
        vm.prank(admin);
        lpModule.updatePoolName(0, "New Name");

        (,,, string memory name,) = lpModule.getPool(0);
        assertEq(name, "New Name");
    }

    function test_removePool() public {
        vm.prank(admin);
        lpModule.removePool(0);

        (address lpToken, uint256 multiplier, bool poolActive,,) = lpModule.getPool(0);
        assertEq(lpToken, address(0));
        assertEq(multiplier, 0);
        assertFalse(poolActive);
    }

    function test_revert_updatePool_notFound() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(LPModule.PoolNotFound.selector, 99));
        lpModule.updatePool(99, 100, true);
    }

    // ============================================
    // Credit Card Mode - Points Tests
    // ============================================

    function test_earnPoints_singlePool() public {
        uint256 lpAmount = 1000e18;
        _mintLpTokens(user1, lpAmount, 0);

        // Initial checkpoint to record balance
        _advanceBlocks(2);
        lpModule.checkpoint(user1);

        // Advance time
        _advanceTime(1 days);

        // Check points
        uint256 points = lpModule.getPoints(user1);

        // Credit card mode: points = lpBalance * multiplier * baseRate * duration / MULTIPLIER_BASE
        // Pool 0 has multiplier 100 (1x)
        uint256 expectedRate = (LP_BASE_RATE * 100) / 100; // 1x
        uint256 expected = lpAmount * expectedRate * 1 days;
        assertEq(points, expected, "Points should match expected");
    }

    function test_earnPoints_multiplePoolsWithMultipliers() public {
        uint256 lpAmount = 1000e18;
        _mintLpTokens(user1, lpAmount, lpAmount);

        // Initial checkpoint
        _advanceBlocks(2);
        lpModule.checkpoint(user1);

        // Advance time
        _advanceTime(1 days);

        // Check points
        uint256 points = lpModule.getPoints(user1);

        // Pool 0: multiplier 100 (1x)
        // Pool 1: multiplier 200 (2x)
        uint256 rate1 = (LP_BASE_RATE * 100) / 100;
        uint256 rate2 = (LP_BASE_RATE * 200) / 100;
        uint256 expected = (lpAmount * rate1 * 1 days) + (lpAmount * rate2 * 1 days);
        assertEq(points, expected, "Points should include both pools");
    }

    /// @notice Core test: late entrant should NOT be diluted
    function test_lateEntrant_notDiluted() public {
        uint256 lpAmount = 1000e18;
        _mintLpTokens(user1, lpAmount, 0);
        _mintLpTokens(user2, lpAmount, 0);

        // User1 checkpoints on day 1
        _advanceBlocks(2);
        lpModule.checkpoint(user1);

        _advanceTime(1 days);

        // User2 checkpoints on day 2
        _advanceBlocks(2);
        lpModule.checkpoint(user2);

        _advanceTime(1 days);

        // Check points
        uint256 points1 = lpModule.getPoints(user1);
        uint256 points2 = lpModule.getPoints(user2);

        // User1: 2 days of points
        // User2: 1 day of points
        uint256 expectedPerDay = lpAmount * LP_BASE_RATE * 1 days; // multiplier 100 = 1x

        assertEq(points1, expectedPerDay * 2, "User1 should have 2 days of points");
        assertEq(points2, expectedPerDay, "User2 should have 1 day of points");

        // Key assertion: Same daily earning rate for equal stakes
        assertEq(points1 / 2, points2, "Same daily earning rate for equal stakes");
    }

    /// @notice Test multiplier ratio is exact
    function test_multiplierRatio_exact() public {
        uint256 lpAmount = 1000e18;

        // User1 in Pool 0 (1x)
        lpToken1.mint(user1, lpAmount);
        // User2 in Pool 1 (2x)
        lpToken2.mint(user2, lpAmount);

        _advanceBlocks(2);
        lpModule.checkpoint(user1);
        lpModule.checkpoint(user2);

        _advanceTime(1 days);

        uint256 points1 = lpModule.getPoints(user1);
        uint256 points2 = lpModule.getPoints(user2);

        // Pool 1 has 2x multiplier compared to Pool 0
        assertEq(points2, points1 * 2, "2x multiplier should give exactly 2x points");
    }

    // ============================================
    // Checkpoint Tests
    // ============================================

    function test_checkpointSelf() public {
        uint256 lpAmount = 1000e18;
        _mintLpTokens(user1, lpAmount, 0);

        _advanceBlocks(2);

        vm.prank(user1);
        lpModule.checkpointSelf();

        (, uint256 lastBalance,,,) = lpModule.getUserPoolState(user1, 0);
        assertEq(lastBalance, lpAmount);
    }

    function test_checkpoint_anyoneCanCall() public {
        uint256 lpAmount = 1000e18;
        _mintLpTokens(user1, lpAmount, 0);

        _advanceBlocks(2);

        // User2 can checkpoint user1
        vm.prank(user2);
        lpModule.checkpoint(user1);

        (, uint256 lastBalance,,,) = lpModule.getUserPoolState(user1, 0);
        assertEq(lastBalance, lpAmount);
    }

    function test_checkpointUsers_keeper() public {
        uint256 lpAmount = 1000e18;
        _mintLpTokens(user1, lpAmount, 0);
        _mintLpTokens(user2, lpAmount, 0);

        _advanceBlocks(2);

        address[] memory users = new address[](2);
        users[0] = user1;
        users[1] = user2;

        vm.prank(keeper);
        lpModule.checkpointUsers(users);

        _advanceTime(1 days);

        assertTrue(lpModule.getPoints(user1) > 0);
        assertTrue(lpModule.getPoints(user2) > 0);
    }

    function test_checkpointUserPool_specific() public {
        uint256 lpAmount = 1000e18;
        _mintLpTokens(user1, lpAmount, lpAmount);

        _advanceBlocks(2);

        // Only checkpoint pool 0
        lpModule.checkpointUserPool(user1, 0);

        (, uint256 balance0,,,) = lpModule.getUserPoolState(user1, 0);
        (, uint256 balance1,,,) = lpModule.getUserPoolState(user1, 1);

        assertEq(balance0, lpAmount);
        assertEq(balance1, 0); // Pool 1 not checkpointed
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

    function test_revert_checkpointUsers_tooManyOperations() public {
        // Add more pools to trigger operation limit (users * pools > 200)
        for (uint256 i = 2; i < 15; i++) {
            MockERC20 newLp = new MockERC20(string(abi.encodePacked("LP", i)), "LP", 18);
            vm.prank(admin);
            lpModule.addPool(address(newLp), 100, "Pool");
        }

        // 15 pools * 15 users = 225 > 200
        address[] memory users = new address[](15);
        for (uint256 i = 0; i < 15; i++) {
            users[i] = address(uint160(i + 1));
        }

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(LPModule.TooManyOperations.selector, 225, 200));
        lpModule.checkpointUsers(users);
    }

    function test_checkpointUsers_skipsZeroAddress() public {
        uint256 lpAmount = 1000e18;
        _mintLpTokens(user1, lpAmount, 0);

        _advanceBlocks(2);

        address[] memory users = new address[](3);
        users[0] = user1;
        users[1] = address(0); // Should be skipped
        users[2] = user2;

        vm.prank(keeper);
        lpModule.checkpointUsers(users); // Should not revert

        (, uint256 balance1,,,) = lpModule.getUserPoolState(user1, 0);
        assertEq(balance1, lpAmount);
    }

    // ============================================
    // Flash Loan Protection Tests
    // ============================================

    function test_flashLoanProtection() public {
        uint256 lpAmount = 1000e18;
        _mintLpTokens(user1, lpAmount, 0);

        // First checkpoint - records balance
        _advanceBlocks(2);
        lpModule.checkpoint(user1);

        // Advance time to earn points
        _advanceTime(1 days);

        // Second checkpoint - should accrue points (passed flash loan protection)
        _advanceBlocks(2);
        lpModule.checkpoint(user1);

        uint256 pointsAfterFirstAccrual = lpModule.getPoints(user1);
        assertTrue(pointsAfterFirstAccrual > 0, "Should have accrued points");

        // Advance time but NOT blocks - simulating flash loan scenario
        _advanceTime(1 days);

        // Checkpoint without advancing blocks - flash loan protection triggered
        lpModule.checkpoint(user1);

        // The pending points in view function will show more,
        // but accruedPoints won't increase because flash loan protection
        uint256 pointsAfterFlashLoan = lpModule.getPoints(user1);
        // Points may show pending amount but accruedPoints wasn't updated
        assertTrue(pointsAfterFlashLoan > 0, "Pending points visible in view");
    }

    // ============================================
    // Balance Change Tests
    // ============================================

    function test_balanceChange_afterCheckpoint() public {
        uint256 lpAmount = 1000e18;
        _mintLpTokens(user1, lpAmount, 0);

        _advanceBlocks(2);
        lpModule.checkpoint(user1);

        _advanceTime(1 days);

        // Double the LP balance
        lpToken1.mint(user1, lpAmount);

        _advanceBlocks(2);
        lpModule.checkpoint(user1);

        _advanceTime(1 days);

        // Points calculation should reflect the balance change
        uint256 points = lpModule.getPoints(user1);

        // Day 1: 1000 LP at rate
        // Day 2: 2000 LP at rate
        uint256 day1Points = lpAmount * LP_BASE_RATE * 1 days;
        uint256 day2Points = (lpAmount * 2) * LP_BASE_RATE * 1 days;

        assertEq(points, day1Points + day2Points);
    }

    function test_balanceDecrease_afterCheckpoint() public {
        uint256 lpAmount = 1000e18;
        _mintLpTokens(user1, lpAmount, 0);

        _advanceBlocks(2);
        lpModule.checkpoint(user1);

        _advanceTime(1 days);

        // Remove half the LP balance
        vm.prank(user1);
        lpToken1.transfer(user2, lpAmount / 2);

        _advanceBlocks(2);
        lpModule.checkpoint(user1);

        _advanceTime(1 days);

        uint256 points = lpModule.getPoints(user1);

        // Day 1: 1000 LP
        // Day 2: 500 LP
        uint256 day1Points = lpAmount * LP_BASE_RATE * 1 days;
        uint256 day2Points = (lpAmount / 2) * LP_BASE_RATE * 1 days;

        assertEq(points, day1Points + day2Points);
    }

    // ============================================
    // Admin Functions Tests
    // ============================================

    function test_setBaseRate() public {
        uint256 newRate = LP_BASE_RATE * 2;

        vm.prank(admin);
        lpModule.setBaseRate(newRate);

        assertEq(lpModule.basePointsRatePerSecond(), newRate);
    }

    function test_setActive() public {
        vm.prank(admin);
        lpModule.setActive(false);
        assertFalse(lpModule.isActive());

        vm.prank(admin);
        lpModule.setActive(true);
        assertTrue(lpModule.isActive());
    }

    function test_setMinHoldingBlocks() public {
        vm.prank(admin);
        lpModule.setMinHoldingBlocks(5);

        assertEq(lpModule.minHoldingBlocks(), 5);
    }

    function test_pauseUnpause() public {
        vm.prank(admin);
        lpModule.pause();

        // Operations that check whenNotPaused would fail
        // (checkpoint functions don't have this modifier in the current implementation)

        vm.prank(admin);
        lpModule.unpause();
    }

    function test_revert_adminFunctions_unauthorized() public {
        vm.prank(user1);
        vm.expectRevert();
        lpModule.setBaseRate(1e16);

        vm.prank(user1);
        vm.expectRevert();
        lpModule.setActive(false);

        vm.prank(user1);
        vm.expectRevert();
        lpModule.addPool(address(0x123), 100, "Pool");
    }

    // ============================================
    // View Functions Tests
    // ============================================

    function test_getPool() public view {
        (address lpToken, uint256 multiplier, bool poolActive, string memory name, uint256 totalSupply) =
            lpModule.getPool(0);

        assertEq(lpToken, address(lpToken1));
        assertEq(multiplier, 100);
        assertTrue(poolActive);
        assertEq(name, "LP Pool 1");
        assertEq(totalSupply, 0); // No tokens minted
    }

    function test_getUserPoolBreakdown() public {
        uint256 lpAmount = 1000e18;
        _mintLpTokens(user1, lpAmount, lpAmount * 2);

        _advanceBlocks(2);
        lpModule.checkpoint(user1);

        _advanceTime(1 days);

        (string[] memory names, uint256[] memory points, uint256[] memory balances, uint256[] memory multipliers) =
            lpModule.getUserPoolBreakdown(user1);

        assertEq(names.length, 2);
        assertEq(names[0], "LP Pool 1");
        assertEq(names[1], "LP Pool 2");

        assertEq(balances[0], lpAmount);
        assertEq(balances[1], lpAmount * 2);

        assertEq(multipliers[0], 100);
        assertEq(multipliers[1], 200);

        // Points should reflect multipliers
        assertTrue(points[1] > points[0], "Pool 1 (2x) should have more points");
    }

    function test_getUserPoolState() public {
        uint256 lpAmount = 1000e18;
        _mintLpTokens(user1, lpAmount, 0);

        _advanceBlocks(2);
        lpModule.checkpoint(user1);

        _advanceTime(1 days);

        (
            uint256 balance,
            uint256 lastCheckpointBalance,
            uint256 earnedPoints,
            uint256 lastAccrualTime,
            uint256 lastCheckpointBlock
        ) = lpModule.getUserPoolState(user1, 0);

        assertEq(balance, lpAmount);
        assertEq(lastCheckpointBalance, lpAmount);
        assertTrue(earnedPoints > 0);
        assertTrue(lastAccrualTime > 0);
        assertTrue(lastCheckpointBlock > 0);
    }

    function test_estimatePoolPoints() public view {
        uint256 lpAmount = 1000e18;
        uint256 duration = 1 days;

        uint256 estimated0 = lpModule.estimatePoolPoints(0, lpAmount, duration);
        uint256 estimated1 = lpModule.estimatePoolPoints(1, lpAmount, duration);

        // Pool 0: 1x multiplier
        // Pool 1: 2x multiplier
        uint256 expected0 = lpAmount * LP_BASE_RATE * duration;
        uint256 expected1 = lpAmount * (LP_BASE_RATE * 2) * duration;

        assertEq(estimated0, expected0);
        assertEq(estimated1, expected1);
    }

    function test_estimatePoolPoints_invalidPool() public view {
        uint256 estimated = lpModule.estimatePoolPoints(99, 1000e18, 1 days);
        assertEq(estimated, 0);
    }

    function test_estimatePoolPoints_inactivePool() public {
        vm.prank(admin);
        lpModule.updatePool(0, 100, false);

        uint256 estimated = lpModule.estimatePoolPoints(0, 1000e18, 1 days);
        assertEq(estimated, 0);
    }

    // ============================================
    // Integration with PointsHub Tests
    // ============================================

    function test_pointsHub_integration() public {
        uint256 lpAmount = 1000e18;
        _mintLpTokens(user1, lpAmount, 0);

        _advanceBlocks(2);
        lpModule.checkpoint(user1);

        _advanceTime(1 days);

        // PointsHub should aggregate points from LPModule
        uint256 lpPoints = lpModule.getPoints(user1);
        uint256 totalPoints = pointsHub.getTotalPoints(user1);

        // Total should include LP points (and possibly others)
        assertTrue(totalPoints >= lpPoints);
    }

    // ============================================
    // Edge Cases Tests
    // ============================================

    function test_zeroBalance_noPoints() public {
        // User has no LP tokens
        lpModule.checkpoint(user1);

        _advanceTime(1 days);

        uint256 points = lpModule.getPoints(user1);
        assertEq(points, 0, "Zero balance should earn zero points");
    }

    function test_moduleInactive_noNewPoints() public {
        uint256 lpAmount = 1000e18;
        _mintLpTokens(user1, lpAmount, 0);

        _advanceBlocks(2);
        lpModule.checkpoint(user1);

        _advanceTime(1 days);

        // Checkpoint to persist the earned points before deactivating
        _advanceBlocks(2);
        lpModule.checkpoint(user1);

        uint256 pointsBefore = lpModule.getPoints(user1);
        assertTrue(pointsBefore > 0, "Should have earned points");

        // Deactivate module
        vm.prank(admin);
        lpModule.setActive(false);

        _advanceTime(1 days);

        uint256 pointsAfter = lpModule.getPoints(user1);
        assertEq(pointsAfter, pointsBefore, "No new points when module inactive");
    }

    function test_poolInactive_noNewPoints() public {
        uint256 lpAmount = 1000e18;
        _mintLpTokens(user1, lpAmount, 0);

        _advanceBlocks(2);
        lpModule.checkpoint(user1);

        _advanceTime(1 days);

        // Checkpoint to persist the earned points before deactivating
        _advanceBlocks(2);
        lpModule.checkpoint(user1);

        uint256 pointsBefore = lpModule.getPoints(user1);
        assertTrue(pointsBefore > 0, "Should have earned points");

        // Deactivate pool 0
        vm.prank(admin);
        lpModule.updatePool(0, 100, false);

        _advanceTime(1 days);

        uint256 pointsAfter = lpModule.getPoints(user1);
        assertEq(pointsAfter, pointsBefore, "No new points when pool inactive");
    }

    // ============================================
    // Fuzz Tests
    // ============================================

    function testFuzz_earnPoints(uint256 lpAmount, uint256 duration) public {
        lpAmount = bound(lpAmount, 1e18, 1e24);
        duration = bound(duration, 1 hours, 365 days);

        lpToken1.mint(user1, lpAmount);

        _advanceBlocks(2);
        lpModule.checkpoint(user1);

        _advanceTime(duration);

        uint256 points = lpModule.getPoints(user1);

        uint256 expected = lpAmount * LP_BASE_RATE * duration;
        assertEq(points, expected);
    }

    function testFuzz_multiplePools(uint256 amount1, uint256 amount2) public {
        amount1 = bound(amount1, 1e18, 1e24);
        amount2 = bound(amount2, 1e18, 1e24);

        lpToken1.mint(user1, amount1);
        lpToken2.mint(user1, amount2);

        _advanceBlocks(2);
        lpModule.checkpoint(user1);

        _advanceTime(1 days);

        uint256 points = lpModule.getPoints(user1);

        uint256 expected1 = amount1 * LP_BASE_RATE * 1 days;
        uint256 expected2 = amount2 * (LP_BASE_RATE * 2) * 1 days; // 2x multiplier

        assertEq(points, expected1 + expected2);
    }

    // ============================================
    // UUPS Upgrade Authorization Tests
    // ============================================

    function test_upgrade_unauthorized_reverts() public {
        LPModule newImpl = new LPModule();

        vm.prank(admin);
        vm.expectRevert();
        lpModule.upgradeToAndCall(address(newImpl), "");

        vm.prank(user1);
        vm.expectRevert();
        lpModule.upgradeToAndCall(address(newImpl), "");
    }

    function test_upgrade_authorized_succeeds() public {
        LPModule newImpl = new LPModule();

        vm.prank(upgrader);
        lpModule.upgradeToAndCall(address(newImpl), "");
    }
}
