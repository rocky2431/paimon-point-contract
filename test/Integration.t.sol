// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "./Base.t.sol";

contract IntegrationTest is BaseTest {
    function setUp() public override {
        super.setUp();
    }

    // ============================================
    // Full User Journey Tests
    // ============================================

    function test_fullUserJourney() public {
        // Step 1: User stakes PPT and deposits LP tokens
        ppt.mint(user1, 1000 * 1e18);
        lpToken1.mint(user1, 500 * 1e18);

        // Stake PPT
        vm.startPrank(user1);
        ppt.approve(address(stakingModule), 1000 * 1e18);
        stakingModule.stakeFlexible(1000 * 1e18);
        vm.stopPrank();

        // Step 2: Checkpoint LP for user
        vm.prank(user1);
        lpModule.checkpointSelf();

        // Step 3: Advance blocks to pass flash loan protection, then advance time (1 week)
        _advanceBlocks(2);
        _advanceTime(7 days);

        // Step 4: Verify points accumulated
        uint256 stakingPoints = stakingModule.getPoints(user1);
        uint256 lpPoints = lpModule.getPoints(user1);
        uint256 totalPoints = pointsHub.getTotalPoints(user1);

        assertGt(stakingPoints, 0);
        assertGt(lpPoints, 0);
        assertEq(totalPoints, stakingPoints + lpPoints);

        // Step 5: User claims activity points (if any)
        // Setup activity merkle tree
        address[] memory users = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        users[0] = user1;
        amounts[0] = 1000 * 1e18;

        (bytes32 root, bytes32[] memory proof) = _generateMerkleProof(user1, amounts[0], users, amounts);

        // Set root with timelock
        _setActivityMerkleRoot(root, "Week 1");

        vm.prank(user1);
        activityModule.claim(amounts[0], proof);

        // Step 6: Verify total points includes activity
        // Note: Time has advanced due to ROOT_DELAY, so staking/lp points may have increased
        uint256 newStakingPoints = stakingModule.getPoints(user1);
        uint256 newLpPoints = lpModule.getPoints(user1);
        uint256 newTotalPoints = pointsHub.getTotalPoints(user1);
        assertEq(newTotalPoints, newStakingPoints + newLpPoints + amounts[0]);

        // Step 7: Enable redemption and redeem points
        vm.prank(admin);
        pointsHub.setRedeemEnabled(true);

        uint256 claimable = pointsHub.getClaimablePoints(user1);
        uint256 previewTokens = pointsHub.previewRedeem(claimable);

        uint256 balanceBefore = rewardToken.balanceOf(user1);

        vm.prank(user1);
        pointsHub.redeem(claimable);

        uint256 balanceAfter = rewardToken.balanceOf(user1);
        assertEq(balanceAfter - balanceBefore, previewTokens);

        // Step 8: Verify points are marked as redeemed
        assertEq(pointsHub.redeemedPoints(user1), claimable);
        assertEq(pointsHub.getClaimablePoints(user1), 0);
    }

    function test_multipleUsersStaking() public {
        // Setup: 3 users with different staking amounts
        ppt.mint(user1, 3000 * 1e18); // 50%
        ppt.mint(user2, 2000 * 1e18); // 33%
        ppt.mint(user3, 1000 * 1e18); // 17%

        // All users stake
        vm.startPrank(user1);
        ppt.approve(address(stakingModule), 3000 * 1e18);
        stakingModule.stakeFlexible(3000 * 1e18);
        vm.stopPrank();

        vm.startPrank(user2);
        ppt.approve(address(stakingModule), 2000 * 1e18);
        stakingModule.stakeFlexible(2000 * 1e18);
        vm.stopPrank();

        vm.startPrank(user3);
        ppt.approve(address(stakingModule), 1000 * 1e18);
        stakingModule.stakeFlexible(1000 * 1e18);
        vm.stopPrank();

        // Advance time and blocks
        _advanceBlocks(2);
        _advanceTime(1 days);

        // Check proportional points (Credit Card Mode: points = amount × rate × time)
        uint256 points1 = stakingModule.getPoints(user1);
        uint256 points2 = stakingModule.getPoints(user2);
        uint256 points3 = stakingModule.getPoints(user3);

        // User1 should have exactly 3x user3's points (same time, 3x amount)
        assertApproxEqRel(points1, points3 * 3, 0.01e18);
        // User2 should have exactly 2x user3's points
        assertApproxEqRel(points2, points3 * 2, 0.01e18);
    }

    function test_penaltyReducesClaimable() public {
        // Setup: User stakes and earns points
        ppt.mint(user1, 1000 * 1e18);
        vm.startPrank(user1);
        ppt.approve(address(stakingModule), 1000 * 1e18);
        stakingModule.stakeFlexible(1000 * 1e18);
        vm.stopPrank();

        _advanceBlocks(2);
        _advanceTime(1 days);

        uint256 totalPoints = pointsHub.getTotalPoints(user1);

        // Apply penalty
        uint256 penaltyAmount = totalPoints / 4; // 25% penalty
        vm.prank(admin);
        penaltyModule.setUserPenalty(user1, penaltyAmount);

        // Verify claimable is reduced
        uint256 claimable = pointsHub.getClaimablePoints(user1);
        assertEq(claimable, totalPoints - penaltyAmount);
    }

    function test_moduleDeactivation() public {
        // Setup
        ppt.mint(user1, 1000 * 1e18);
        vm.startPrank(user1);
        ppt.approve(address(stakingModule), 1000 * 1e18);
        stakingModule.stakeFlexible(1000 * 1e18);
        vm.stopPrank();

        _advanceBlocks(2);
        _advanceTime(1 days);

        uint256 pointsBefore = stakingModule.getPoints(user1);
        assertGt(pointsBefore, 0);

        // Deactivate staking module
        vm.prank(admin);
        stakingModule.setActive(false);

        // Points immediately after deactivation
        uint256 pointsAtDeactivation = stakingModule.getPoints(user1);

        _advanceTime(1 days);

        // Points should not increase after deactivation
        uint256 pointsAfter = stakingModule.getPoints(user1);
        assertEq(pointsAfter, pointsAtDeactivation);
    }

    function test_partialRedemptions() public {
        // Setup
        ppt.mint(user1, 1000 * 1e18);
        vm.startPrank(user1);
        ppt.approve(address(stakingModule), 1000 * 1e18);
        stakingModule.stakeFlexible(1000 * 1e18);
        vm.stopPrank();

        _advanceBlocks(2);
        _advanceTime(7 days);

        vm.prank(admin);
        pointsHub.setRedeemEnabled(true);

        uint256 totalClaimable = pointsHub.getClaimablePoints(user1);
        uint256 portion = totalClaimable / 4;

        // Redeem in portions
        vm.startPrank(user1);
        pointsHub.redeem(portion);
        assertEq(pointsHub.redeemedPoints(user1), portion);

        pointsHub.redeem(portion);
        assertEq(pointsHub.redeemedPoints(user1), portion * 2);

        pointsHub.redeem(portion);
        assertEq(pointsHub.redeemedPoints(user1), portion * 3);

        // Redeem remaining
        uint256 remaining = pointsHub.getClaimablePoints(user1);
        pointsHub.redeem(remaining);
        vm.stopPrank();

        assertEq(pointsHub.getClaimablePoints(user1), 0);
    }

    function test_pointsBreakdownAllModules() public {
        // Setup all modules
        ppt.mint(user1, 1000 * 1e18);
        lpToken1.mint(user1, 500 * 1e18);
        lpToken2.mint(user1, 300 * 1e18);

        // Stake PPT
        vm.startPrank(user1);
        ppt.approve(address(stakingModule), 1000 * 1e18);
        stakingModule.stakeFlexible(1000 * 1e18);
        vm.stopPrank();

        // Checkpoint LP
        vm.prank(user1);
        lpModule.checkpointSelf();

        _advanceBlocks(2);
        _advanceTime(1 days);

        // Add activity points
        address[] memory users = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        users[0] = user1;
        amounts[0] = 2000 * 1e18;

        (bytes32 root, bytes32[] memory proof) = _generateMerkleProof(user1, amounts[0], users, amounts);

        // Set root with timelock
        _setActivityMerkleRoot(root, "Test");

        vm.prank(user1);
        activityModule.claim(amounts[0], proof);

        // Add penalty
        vm.prank(admin);
        penaltyModule.setUserPenalty(user1, 500 * 1e18);

        // Get breakdown
        (string[] memory names, uint256[] memory points, uint256 penalty, uint256 redeemed, uint256 claimable) =
            pointsHub.getPointsBreakdown(user1);

        assertEq(names.length, 3);
        assertGt(points[0], 0); // StakingModule
        assertGt(points[1], 0); // LPModule
        assertEq(points[2], amounts[0]); // ActivityModule
        assertEq(penalty, 500 * 1e18);
        assertEq(redeemed, 0);

        uint256 expectedClaimable = points[0] + points[1] + points[2] - penalty;
        assertEq(claimable, expectedClaimable);
    }

    function test_exchangeRateChange() public {
        // Setup
        ppt.mint(user1, 1000 * 1e18);
        vm.startPrank(user1);
        ppt.approve(address(stakingModule), 1000 * 1e18);
        stakingModule.stakeFlexible(1000 * 1e18);
        vm.stopPrank();

        _advanceBlocks(2);
        _advanceTime(1 days);

        vm.prank(admin);
        pointsHub.setRedeemEnabled(true);

        uint256 claimable = pointsHub.getClaimablePoints(user1);

        // Preview with current rate
        uint256 previewBefore = pointsHub.previewRedeem(claimable);

        // Double the exchange rate
        vm.prank(admin);
        pointsHub.setExchangeRate(EXCHANGE_RATE * 2);

        // Preview should double
        uint256 previewAfter = pointsHub.previewRedeem(claimable);
        assertEq(previewAfter, previewBefore * 2);
    }

    function test_moduleRemovalDoesNotAffectExistingPoints() public {
        // Setup and earn points
        ppt.mint(user1, 1000 * 1e18);
        vm.startPrank(user1);
        ppt.approve(address(stakingModule), 1000 * 1e18);
        stakingModule.stakeFlexible(1000 * 1e18);
        vm.stopPrank();

        _advanceBlocks(2);
        _advanceTime(1 days);

        uint256 stakingPoints = stakingModule.getPoints(user1);
        uint256 totalBefore = pointsHub.getTotalPoints(user1);

        // Remove staking module from PointsHub
        vm.prank(admin);
        pointsHub.removeModule(address(stakingModule));

        // Total points should now exclude staking module
        uint256 totalAfter = pointsHub.getTotalPoints(user1);
        assertEq(totalAfter, totalBefore - stakingPoints);

        // But StakingModule still tracks points internally
        assertEq(stakingModule.getPoints(user1), stakingPoints);
    }

    // ============================================
    // Edge Cases
    // ============================================

    function test_zeroStakeNoPoints() public {
        // User has PPT but doesn't stake
        ppt.mint(user1, 1000 * 1e18);

        _advanceTime(1 days);

        // No staking = no points
        assertEq(stakingModule.getPoints(user1), 0);
    }

    function test_redeemExactlyClaimable() public {
        ppt.mint(user1, 1000 * 1e18);
        vm.startPrank(user1);
        ppt.approve(address(stakingModule), 1000 * 1e18);
        stakingModule.stakeFlexible(1000 * 1e18);
        vm.stopPrank();

        _advanceBlocks(2);
        _advanceTime(1 days);

        vm.prank(admin);
        pointsHub.setRedeemEnabled(true);

        uint256 claimable = pointsHub.getClaimablePoints(user1);

        vm.prank(user1);
        pointsHub.redeem(claimable);

        assertEq(pointsHub.getClaimablePoints(user1), 0);
    }

    function test_concurrentStakes() public {
        ppt.mint(user1, 1000 * 1e18);
        ppt.mint(user2, 1000 * 1e18);

        // Both users stake at same time
        vm.startPrank(user1);
        ppt.approve(address(stakingModule), 1000 * 1e18);
        stakingModule.stakeFlexible(1000 * 1e18);
        vm.stopPrank();

        vm.startPrank(user2);
        ppt.approve(address(stakingModule), 1000 * 1e18);
        stakingModule.stakeFlexible(1000 * 1e18);
        vm.stopPrank();

        _advanceBlocks(2);
        _advanceTime(1 days);

        // Both should have equal points (Credit Card Mode)
        uint256 points1 = stakingModule.getPoints(user1);
        uint256 points2 = stakingModule.getPoints(user2);

        assertApproxEqRel(points1, points2, 0.01e18);
    }

    function test_lateEntrantNotDiluted() public {
        // User1 stakes first
        ppt.mint(user1, 1000 * 1e18);
        vm.startPrank(user1);
        ppt.approve(address(stakingModule), 1000 * 1e18);
        stakingModule.stakeFlexible(1000 * 1e18);
        vm.stopPrank();

        _advanceBlocks(2);
        _advanceTime(1 days);

        // Record user1's points earned in day 1
        uint256 user1PointsDay1 = stakingModule.getPoints(user1);

        // User2 enters later (day 2)
        ppt.mint(user2, 1000 * 1e18);
        vm.startPrank(user2);
        ppt.approve(address(stakingModule), 1000 * 1e18);
        stakingModule.stakeFlexible(1000 * 1e18);
        vm.stopPrank();

        _advanceBlocks(2);
        _advanceTime(1 days);

        // User2's points from day 2
        uint256 user2Points = stakingModule.getPoints(user2);

        // User1's points from day 2 (day 2 only, not cumulative)
        uint256 user1TotalPoints = stakingModule.getPoints(user1);
        uint256 user1PointsDay2 = user1TotalPoints - user1PointsDay1;

        // Credit Card Mode: User2's full day = User1's day 2 portion
        // Both staked same amount for same duration on day 2
        assertApproxEqRel(user2Points, user1PointsDay2, 0.01e18);
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
