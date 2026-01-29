// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {PointsHub} from "../src/PointsHub.sol";
import {StakingModule} from "../src/StakingModule.sol";
import {LPModule} from "../src/LPModule.sol";
import {ActivityModule} from "../src/ActivityModule.sol";
import {PenaltyModule} from "../src/PenaltyModule.sol";

import {MockPPT} from "./mocks/MockPPT.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {BaseTest} from "./Base.t.sol";

/// @title SecurityTest
/// @notice Tests for security-critical functionality
contract SecurityTest is BaseTest {
    // ============================================
    // UUPS Upgrade Authorization Tests
    // ============================================

    function test_revert_upgrade_pointsHub_unauthorized() public {
        PointsHub newImpl = new PointsHub();

        vm.prank(user1);
        vm.expectRevert();
        pointsHub.upgradeToAndCall(address(newImpl), "");
    }

    function test_revert_upgrade_stakingModule_unauthorized() public {
        StakingModule newImpl = new StakingModule();

        vm.prank(user1);
        vm.expectRevert();
        stakingModule.upgradeToAndCall(address(newImpl), "");
    }

    function test_revert_upgrade_lpModule_unauthorized() public {
        LPModule newImpl = new LPModule();

        vm.prank(user1);
        vm.expectRevert();
        lpModule.upgradeToAndCall(address(newImpl), "");
    }

    function test_revert_upgrade_activityModule_unauthorized() public {
        ActivityModule newImpl = new ActivityModule();

        vm.prank(user1);
        vm.expectRevert();
        activityModule.upgradeToAndCall(address(newImpl), "");
    }

    function test_revert_upgrade_penaltyModule_unauthorized() public {
        PenaltyModule newImpl = new PenaltyModule();

        vm.prank(user1);
        vm.expectRevert();
        penaltyModule.upgradeToAndCall(address(newImpl), "");
    }

    function test_upgrade_stakingModule_authorized() public {
        StakingModule newImpl = new StakingModule();

        vm.prank(upgrader);
        stakingModule.upgradeToAndCall(address(newImpl), "");

        // Verify upgrade succeeded by checking version is still accessible
        assertEq(stakingModule.VERSION(), "2.3.0");
    }

    // ============================================
    // Flash Loan Protection Tests - LPModule
    // ============================================

    function test_lpModule_flashLoanProtection_defaultEnabled() public {
        // Default minHoldingBlocks should be 1
        assertEq(lpModule.minHoldingBlocks(), 1);
    }

    function test_lpModule_flashLoanProtection_blocksImmediatePoints() public {
        // Setup: User gets LP tokens
        lpToken1.mint(user1, 1000 * 1e18);

        // First checkpoint - records balance but earns no points (no history)
        vm.prank(user1);
        lpModule.checkpointSelf();

        // Advance time but stay in same block
        _advanceTime(1 hours);

        // Second checkpoint in same block - should NOT earn points
        vm.prank(user1);
        lpModule.checkpointSelf();

        uint256 pointsInSameBlock = lpModule.getPoints(user1);

        // Now advance blocks and checkpoint again
        _advanceBlocks(2);
        _advanceTime(1 hours);

        vm.prank(user1);
        lpModule.checkpointSelf();

        uint256 pointsAfterBlocks = lpModule.getPoints(user1);

        // Points should only accumulate after block requirement is met
        assertGt(pointsAfterBlocks, pointsInSameBlock, "Points should increase after holding period");
    }

    function test_lpModule_setMinHoldingBlocks() public {
        uint256 newBlocks = 5;

        vm.prank(admin);
        lpModule.setMinHoldingBlocks(newBlocks);

        assertEq(lpModule.minHoldingBlocks(), newBlocks);
    }

    // ============================================
    // Flash Loan Protection Tests - StakingModule
    // ============================================

    function test_stakingModule_flashLoanProtection_defaultEnabled() public {
        // Default minHoldingBlocks should be 1
        assertEq(stakingModule.minHoldingBlocks(), 1);
    }

    function test_stakingModule_flashLoanProtection_blocksImmediatePoints() public {
        // Setup: User gets PPT tokens and stakes
        ppt.mint(user1, 1000 * 1e18);
        vm.startPrank(user1);
        ppt.approve(address(stakingModule), 1000 * 1e18);
        stakingModule.stakeFlexible(1000 * 1e18);
        vm.stopPrank();

        // In same block, points should be 0 due to flash loan protection
        uint256 pointsInSameBlock = stakingModule.getPoints(user1);
        assertEq(pointsInSameBlock, 0, "Points should be 0 in same block");

        // Advance blocks and time
        _advanceBlocks(2);
        _advanceTime(1 hours);

        uint256 pointsAfterBlocks = stakingModule.getPoints(user1);

        // Points should now accumulate after block requirement is met
        assertGt(pointsAfterBlocks, pointsInSameBlock, "Points should increase after holding period");
    }

    // ============================================
    // Cancel Pending Root Tests
    // ============================================

    function test_activityModule_cancelPendingRoot() public {
        bytes32 newRoot = keccak256("test-root");

        // Queue a root
        vm.prank(keeper);
        activityModule.updateMerkleRoot(newRoot, "Test");

        // Verify pending
        assertEq(activityModule.pendingRoot(), newRoot);

        // Cancel it
        vm.prank(admin);
        activityModule.cancelPendingRoot();

        // Verify cancelled
        assertEq(activityModule.pendingRoot(), bytes32(0));
        assertEq(activityModule.pendingRootEffectiveTime(), 0);
    }

    function test_penaltyModule_cancelPendingRoot() public {
        bytes32 newRoot = keccak256("test-root");

        // Queue a root
        vm.prank(keeper);
        penaltyModule.updatePenaltyRoot(newRoot);

        // Verify pending
        assertEq(penaltyModule.pendingRoot(), newRoot);

        // Cancel it
        vm.prank(admin);
        penaltyModule.cancelPendingRoot();

        // Verify cancelled
        assertEq(penaltyModule.pendingRoot(), bytes32(0));
        assertEq(penaltyModule.pendingRootEffectiveTime(), 0);
    }

    function test_revert_cancelPendingRoot_noPending() public {
        vm.prank(admin);
        vm.expectRevert(ActivityModule.NoPendingRoot.selector);
        activityModule.cancelPendingRoot();
    }

    // ============================================
    // Penalty Cannot Decrease Tests
    // ============================================

    function test_penaltyModule_setUserPenalty_cannotDecrease() public {
        // First set a penalty
        vm.prank(admin);
        penaltyModule.setUserPenalty(user1, 100);

        assertEq(penaltyModule.confirmedPenalty(user1), 100);

        // Try to decrease - should revert
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(PenaltyModule.PenaltyCannotDecrease.selector, 100, 50));
        penaltyModule.setUserPenalty(user1, 50);
    }

    function test_penaltyModule_setUserPenalty_canIncrease() public {
        // First set a penalty
        vm.prank(admin);
        penaltyModule.setUserPenalty(user1, 100);

        // Increase - should work
        vm.prank(admin);
        penaltyModule.setUserPenalty(user1, 200);

        assertEq(penaltyModule.confirmedPenalty(user1), 200);
    }

    // ============================================
    // PointsHub Module Gas Limit Tests
    // ============================================

    function test_pointsHub_moduleGasLimit_configurable() public {
        uint256 newLimit = 500_000;

        vm.prank(admin);
        pointsHub.setModuleGasLimit(newLimit);

        assertEq(pointsHub.moduleGasLimit(), newLimit);
    }

    function test_pointsHub_getTotalPointsWithStatus() public {
        // Setup: User stakes PPT
        ppt.mint(user1, 1000 * 1e18);
        vm.startPrank(user1);
        ppt.approve(address(stakingModule), 1000 * 1e18);
        stakingModule.stakeFlexible(1000 * 1e18);
        vm.stopPrank();

        _advanceTime(1 hours);
        _advanceBlocks(2);

        // Get points with status
        (uint256 total, bool[] memory moduleSuccess) = pointsHub.getTotalPointsWithStatus(user1);

        // All 3 modules should succeed
        assertEq(moduleSuccess.length, 3);
        assertTrue(moduleSuccess[0], "StakingModule should succeed");
        assertTrue(moduleSuccess[1], "LPModule should succeed (inactive is ok)");
        assertTrue(moduleSuccess[2], "ActivityModule should succeed (inactive is ok)");

        // Should have points from StakingModule
        assertGt(total, 0);
    }

    // ============================================
    // Error Path Tests
    // ============================================

    function test_revert_redeem_insufficientRewardTokens() public {
        // Setup: User stakes and earns points
        ppt.mint(user1, 1000 * 1e18);
        vm.startPrank(user1);
        ppt.approve(address(stakingModule), 1000 * 1e18);
        stakingModule.stakeFlexible(1000 * 1e18);
        vm.stopPrank();

        _advanceTime(1 days);
        _advanceBlocks(2);

        // Drain reward tokens from hub
        uint256 hubBalance = rewardToken.balanceOf(address(pointsHub));
        vm.prank(admin);
        pointsHub.withdrawRewardTokens(admin, hubBalance);

        // Enable redeem
        vm.prank(admin);
        pointsHub.setRedeemEnabled(true);

        uint256 claimable = pointsHub.getClaimablePoints(user1);
        assertGt(claimable, 0, "User should have claimable points");

        // Try to redeem - should fail
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(PointsHub.InsufficientRewardTokens.selector, 0, claimable));
        pointsHub.redeem(claimable);
    }

    function test_revert_redeem_exchangeRateNotSet() public {
        // Set exchange rate to 0
        vm.prank(admin);
        pointsHub.setExchangeRate(0);

        // Enable redeem
        vm.prank(admin);
        pointsHub.setRedeemEnabled(true);

        vm.prank(user1);
        vm.expectRevert(PointsHub.ExchangeRateNotSet.selector);
        pointsHub.redeem(100);
    }

    function test_pointsHub_emergencyRemoveModuleByIndex() public {
        uint256 countBefore = pointsHub.getModuleCount();
        address moduleToRemove = pointsHub.getModuleAt(0);

        vm.prank(admin);
        pointsHub.emergencyRemoveModuleByIndex(0);

        assertEq(pointsHub.getModuleCount(), countBefore - 1);
        assertFalse(pointsHub.isModule(moduleToRemove));
    }

    function test_revert_emergencyRemoveModuleByIndex_outOfBounds() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(PointsHub.IndexOutOfBounds.selector, 999, 3));
        pointsHub.emergencyRemoveModuleByIndex(999);
    }

    // ============================================
    // Circular Buffer Tests
    // ============================================

    function test_activityModule_circularBuffer() public {
        // Add many roots to trigger circular buffer behavior
        for (uint256 i = 0; i < 105; i++) {
            bytes32 newRoot = keccak256(abi.encodePacked("root", i));
            vm.prank(keeper);
            activityModule.updateMerkleRoot(newRoot, string(abi.encodePacked("Week ", i)));
            _advanceTime(24 hours + 1);
            activityModule.activateRoot();
        }

        // History should be capped at MAX_ROOT_HISTORY (100)
        assertEq(activityModule.getRootHistoryLength(), 100);

        // Head should have wrapped around
        assertTrue(activityModule.rootHistoryFull());
    }

    // ============================================
    // Helper Functions
    // ============================================

    function toArray(address addr) internal pure returns (address[] memory) {
        address[] memory arr = new address[](1);
        arr[0] = addr;
        return arr;
    }
}
