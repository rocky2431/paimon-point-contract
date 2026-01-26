// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "./Base.t.sol";
import {HoldingModule} from "../src/HoldingModule.sol";

contract HoldingModuleTest is BaseTest {
    function setUp() public override {
        super.setUp();
    }

    // ============================================
    // Initialization Tests
    // ============================================

    function test_initialization() public view {
        assertEq(holdingModule.VERSION(), "1.3.0");
        assertEq(holdingModule.MODULE_NAME(), "PPT Holding");
        assertEq(holdingModule.pointsRatePerSecond(), POINTS_RATE_PER_SECOND);
        assertTrue(holdingModule.isActive());
        assertTrue(holdingModule.hasRole(holdingModule.ADMIN_ROLE(), admin));
        assertTrue(holdingModule.hasRole(holdingModule.KEEPER_ROLE(), keeper));
    }

    function test_moduleName() public view {
        assertEq(holdingModule.moduleName(), "PPT Holding");
    }

    function test_isActive() public view {
        assertTrue(holdingModule.isActive());
    }

    // ============================================
    // Checkpoint Tests
    // ============================================

    function test_checkpointGlobal() public {
        uint256 initialTime = holdingModule.lastUpdateTime();

        _advanceTime(1 hours);

        vm.prank(keeper);
        holdingModule.checkpointGlobal();

        assertGt(holdingModule.lastUpdateTime(), initialTime);
    }

    function test_checkpointUsers() public {
        // Setup
        ppt.mint(user1, 1000 * 1e18);
        ppt.mint(user2, 500 * 1e18);

        address[] memory users = new address[](2);
        users[0] = user1;
        users[1] = user2;

        vm.prank(keeper);
        holdingModule.checkpointUsers(users);

        assertEq(holdingModule.userLastBalance(user1), 1000 * 1e18);
        assertEq(holdingModule.userLastBalance(user2), 500 * 1e18);
        assertEq(holdingModule.userLastCheckpoint(user1), block.timestamp);
    }

    function test_checkpointSelf() public {
        ppt.mint(user1, 1000 * 1e18);

        vm.prank(user1);
        holdingModule.checkpointSelf();

        assertEq(holdingModule.userLastBalance(user1), 1000 * 1e18);
    }

    function test_checkpoint_anyone() public {
        ppt.mint(user1, 1000 * 1e18);

        // Anyone can checkpoint any user
        vm.prank(user2);
        holdingModule.checkpoint(user1);

        assertEq(holdingModule.userLastBalance(user1), 1000 * 1e18);
    }

    function test_revert_checkpointUsers_batchTooLarge() public {
        address[] memory users = new address[](101);
        for (uint256 i = 0; i < 101; i++) {
            users[i] = address(uint160(i + 1));
        }

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(HoldingModule.BatchTooLarge.selector, 101, 100));
        holdingModule.checkpointUsers(users);
    }

    // ============================================
    // Points Calculation Tests
    // ============================================

    function test_getPoints_noCheckpoint() public view {
        // Without checkpoint, user has 0 points
        uint256 points = holdingModule.getPoints(user1);
        assertEq(points, 0);
    }

    function test_getPoints_afterCheckpoint() public {
        ppt.mint(user1, 1000 * 1e18);

        vm.prank(keeper);
        holdingModule.checkpointUsers(toArray(user1));

        _advanceTime(1 days);

        uint256 points = holdingModule.getPoints(user1);
        // Expected: balance * timeDelta * rate / supply
        // = 1000e18 * 86400 * 1e15 / 1000e18 = 86400 * 1e15
        assertEq(points, 86400 * 1e15);
    }

    function test_getPoints_multipleUsers() public {
        // User1 and User2 hold equal amounts
        ppt.mint(user1, 500 * 1e18);
        ppt.mint(user2, 500 * 1e18);

        vm.prank(keeper);
        address[] memory users = new address[](2);
        users[0] = user1;
        users[1] = user2;
        holdingModule.checkpointUsers(users);

        _advanceTime(1 days);

        uint256 points1 = holdingModule.getPoints(user1);
        uint256 points2 = holdingModule.getPoints(user2);

        // Both should have equal points
        assertEq(points1, points2);
    }

    function test_getPoints_proportional() public {
        // User1 holds 2x User2's amount
        ppt.mint(user1, 2000 * 1e18);
        ppt.mint(user2, 1000 * 1e18);

        vm.prank(keeper);
        address[] memory users = new address[](2);
        users[0] = user1;
        users[1] = user2;
        holdingModule.checkpointUsers(users);

        _advanceTime(1 days);

        uint256 points1 = holdingModule.getPoints(user1);
        uint256 points2 = holdingModule.getPoints(user2);

        // User1 should have ~2x points (based on last checkpoint balance)
        assertApproxEqRel(points1, points2 * 2, 0.01e18); // 1% tolerance
    }

    function test_getPoints_afterBalanceChange() public {
        // Initial checkpoint
        ppt.mint(user1, 1000 * 1e18);
        vm.prank(keeper);
        holdingModule.checkpointUsers(toArray(user1));

        _advanceTime(1 days);

        // Points before new mint
        uint256 pointsBeforeMint = holdingModule.getPoints(user1);
        assertGt(pointsBeforeMint, 0);

        // User receives more PPT but doesn't checkpoint yet
        // Note: This increases effectiveSupply, changing the rate for ALL users going forward
        ppt.mint(user1, 1000 * 1e18);

        // Points should still be calculated based on LAST checkpoint balance
        // BUT the pointsPerShare has changed due to supply increase
        // The change affects the delta calculation from lastUpdateTime to now
        uint256 pointsAfterMint = holdingModule.getPoints(user1);
        // Points may be different due to supply change affecting rate
        // The key behavior is that new balance won't be used until next checkpoint

        // After new checkpoint, new balance is recorded for FUTURE points
        vm.prank(user1);
        holdingModule.checkpointSelf();

        _advanceTime(1 days);

        uint256 newPoints = holdingModule.getPoints(user1);
        // Now should include points from both periods with new balance
        assertGt(newPoints, pointsAfterMint);
    }

    function test_getPoints_belowMinThreshold() public {
        vm.prank(admin);
        holdingModule.setMinBalanceThreshold(100 * 1e18);

        // User has balance below threshold
        ppt.mint(user1, 50 * 1e18);
        vm.prank(keeper);
        holdingModule.checkpointUsers(toArray(user1));

        _advanceTime(1 days);

        // Should not earn points
        uint256 points = holdingModule.getPoints(user1);
        assertEq(points, 0);
    }

    // ============================================
    // State View Functions Tests
    // ============================================

    function test_getUserState() public {
        ppt.mint(user1, 1000 * 1e18);
        vm.prank(keeper);
        holdingModule.checkpointUsers(toArray(user1));

        _advanceTime(1 hours);

        (
            uint256 balance,
            uint256 lastCheckpointBalance,
            uint256 earnedPoints,
            uint256 lastCheckpointTime
        ) = holdingModule.getUserState(user1);

        assertEq(balance, 1000 * 1e18);
        assertEq(lastCheckpointBalance, 1000 * 1e18);
        assertGt(earnedPoints, 0);
        assertGt(lastCheckpointTime, 0);
    }

    function test_currentPointsPerShare() public {
        ppt.mint(user1, 1000 * 1e18);

        uint256 initial = holdingModule.currentPointsPerShare();

        _advanceTime(1 hours);

        uint256 after1Hour = holdingModule.currentPointsPerShare();
        assertGt(after1Hour, initial);
    }

    function test_estimatePoints() public {
        ppt.mint(user1, 1000 * 1e18);

        uint256 balance = 500 * 1e18;
        uint256 duration = 1 days;

        uint256 estimated = holdingModule.estimatePoints(balance, duration);
        // = balance * duration * rate / supply
        // = 500e18 * 86400 * 1e15 / 1000e18 = 43200 * 1e15
        assertEq(estimated, 43200 * 1e15);
    }

    // ============================================
    // Admin Functions Tests
    // ============================================

    function test_setPointsRate() public {
        uint256 newRate = 2 * POINTS_RATE_PER_SECOND;

        vm.prank(admin);
        holdingModule.setPointsRate(newRate);

        assertEq(holdingModule.pointsRatePerSecond(), newRate);
    }

    function test_setMinBalanceThreshold() public {
        uint256 threshold = 100 * 1e18;

        vm.prank(admin);
        holdingModule.setMinBalanceThreshold(threshold);

        assertEq(holdingModule.minBalanceThreshold(), threshold);
    }

    function test_setActive() public {
        vm.prank(admin);
        holdingModule.setActive(false);

        assertFalse(holdingModule.isActive());

        // Points should not accumulate when inactive
        ppt.mint(user1, 1000 * 1e18);
        vm.prank(keeper);
        holdingModule.checkpointUsers(toArray(user1));
        _advanceTime(1 days);

        uint256 points = holdingModule.getPoints(user1);
        assertEq(points, 0);
    }

    function test_setPpt() public {
        address newPpt = address(0x123);

        vm.prank(admin);
        holdingModule.setPpt(newPpt);

        assertEq(address(holdingModule.ppt()), newPpt);
        assertFalse(holdingModule.supplyModeInitialized());
    }

    function test_setSupplyMode() public {
        vm.prank(admin);
        holdingModule.setSupplyMode(false);

        assertFalse(holdingModule.useEffectiveSupply());
        assertTrue(holdingModule.supplyModeInitialized());
    }

    function test_setMinHoldingBlocks() public {
        uint256 blocks = 10;

        vm.prank(admin);
        holdingModule.setMinHoldingBlocks(blocks);

        assertEq(holdingModule.minHoldingBlocks(), blocks);
    }

    function test_pause_unpause() public {
        vm.prank(admin);
        holdingModule.pause();
        // Note: pause doesn't affect view functions, only state-changing functions if whenNotPaused is used

        vm.prank(admin);
        holdingModule.unpause();
    }

    // ============================================
    // Flash Loan Attack Scenario Test
    // ============================================

    function test_flashLoanProtection_notImplemented() public {
        // This test demonstrates that minHoldingBlocks is NOT actually enforced
        // This is a KNOWN VULNERABILITY (C-01 in audit)

        ppt.mint(user1, 1000 * 1e18);

        // First checkpoint
        vm.prank(user1);
        holdingModule.checkpointSelf();

        // Simulate flash loan: immediately checkpoint again (same block)
        // If protection was implemented, this should fail
        // But currently it succeeds, earning points unfairly

        vm.prank(user1);
        holdingModule.checkpointSelf(); // This should ideally fail with minHoldingBlocks > 0

        // Note: The minHoldingBlocks protection is NOT implemented in the current code
        // This is flagged as Critical vulnerability C-01
    }

    // ============================================
    // Edge Cases
    // ============================================

    function test_zeroSupply() public {
        // No PPT minted, supply is 0
        uint256 pointsPerShare = holdingModule.currentPointsPerShare();
        assertEq(pointsPerShare, 0);
    }

    function test_moduleInactive_noPointsAccumulation() public {
        ppt.mint(user1, 1000 * 1e18);
        vm.prank(keeper);
        holdingModule.checkpointUsers(toArray(user1));

        _advanceTime(1 days);

        uint256 pointsBefore = holdingModule.getPoints(user1);
        assertGt(pointsBefore, 0);

        // Checkpoint to lock in current points before deactivation
        vm.prank(keeper);
        holdingModule.checkpointUsers(toArray(user1));

        // Deactivate module - this calls _updateGlobal() to finalize points
        vm.prank(admin);
        holdingModule.setActive(false);

        // Get points immediately after deactivation
        uint256 pointsAtDeactivation = holdingModule.getPoints(user1);

        _advanceTime(1 days);

        // Points should not increase after deactivation
        uint256 pointsAfter = holdingModule.getPoints(user1);
        assertEq(pointsAfter, pointsAtDeactivation);
    }

    // ============================================
    // Fuzz Tests
    // ============================================

    function testFuzz_pointsCalculation(uint256 balance, uint256 timeElapsed) public {
        balance = bound(balance, 1e18, 1_000_000 * 1e18);
        timeElapsed = bound(timeElapsed, 1 hours, 365 days);

        ppt.mint(user1, balance);
        vm.prank(keeper);
        holdingModule.checkpointUsers(toArray(user1));

        _advanceTime(timeElapsed);

        uint256 points = holdingModule.getPoints(user1);
        assertGt(points, 0);

        // Verify points formula
        uint256 supply = ppt.effectiveSupply();
        uint256 expectedPoints = (balance * timeElapsed * POINTS_RATE_PER_SECOND) / supply;
        assertApproxEqRel(points, expectedPoints, 0.01e18); // 1% tolerance for rounding
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
