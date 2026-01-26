// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "./Base.t.sol";
import {ActivityModule} from "../src/ActivityModule.sol";

contract ActivityModuleTest is BaseTest {
    function setUp() public override {
        super.setUp();
    }

    // ============================================
    // Initialization Tests
    // ============================================

    function test_initialization() public view {
        assertEq(activityModule.VERSION(), "1.3.0");
        assertEq(activityModule.MODULE_NAME(), "Trading & Activity");
        assertTrue(activityModule.isActive());
        assertEq(activityModule.merkleRoot(), bytes32(0));
        assertEq(activityModule.currentEpoch(), 0);
    }

    function test_moduleName() public view {
        assertEq(activityModule.moduleName(), "Trading & Activity");
    }

    function test_isActive() public view {
        assertTrue(activityModule.isActive());
    }

    // ============================================
    // Merkle Root Management Tests
    // ============================================

    function test_updateMerkleRoot() public {
        bytes32 newRoot = keccak256("test root");

        // Queue the root
        vm.prank(keeper);
        activityModule.updateMerkleRoot(newRoot, "Week 1");

        // Root should be pending, not active yet
        assertEq(activityModule.pendingRoot(), newRoot);
        assertEq(activityModule.merkleRoot(), bytes32(0)); // Still 0

        // Advance time past ROOT_DELAY
        _advanceTime(24 hours + 1);

        // Activate the root
        activityModule.activateRoot();

        assertEq(activityModule.merkleRoot(), newRoot);
        assertEq(activityModule.currentEpoch(), 1);
        assertEq(activityModule.currentEpochLabel(), "Week 1");
        assertEq(activityModule.getRootHistoryLength(), 1);
    }

    function test_updateMerkleRootWithEpoch() public {
        bytes32 newRoot = keccak256("test root");

        vm.prank(keeper);
        activityModule.updateMerkleRootWithEpoch(newRoot, 5, "Custom Epoch");

        // Advance time past ROOT_DELAY
        _advanceTime(24 hours + 1);
        activityModule.activateRoot();

        assertEq(activityModule.currentEpoch(), 5);
    }

    function test_getRootAt() public {
        bytes32 root1 = keccak256("root1");
        bytes32 root2 = keccak256("root2");

        // Set first root with timelock
        _setActivityMerkleRoot(root1, "Week 1");

        _advanceTime(1 weeks);

        // Set second root with timelock
        _setActivityMerkleRoot(root2, "Week 2");

        (bytes32 storedRoot, uint256 timestamp) = activityModule.getRootAt(0);
        assertEq(storedRoot, root1);
        assertGt(timestamp, 0);
    }

    function test_revert_getRootAt_outOfBounds() public {
        vm.expectRevert(abi.encodeWithSelector(ActivityModule.IndexOutOfBounds.selector, 0, 0));
        activityModule.getRootAt(0);
    }

    // ============================================
    // Claim Tests
    // ============================================

    function test_claim_success() public {
        // Setup Merkle tree with user1 having 1000 points
        address[] memory users = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        users[0] = user1;
        users[1] = user2;
        amounts[0] = 1000 * 1e18;
        amounts[1] = 500 * 1e18;

        (bytes32 root, bytes32[] memory proof) = _generateMerkleProof(user1, amounts[0], users, amounts);

        // Set root with timelock
        _setActivityMerkleRoot(root, "Test");

        // User claims
        vm.prank(user1);
        activityModule.claim(amounts[0], proof);

        assertEq(activityModule.claimedPoints(user1), amounts[0]);
        assertEq(activityModule.getPoints(user1), amounts[0]);
    }

    function test_claim_partialThenFull() public {
        // First root: user1 has 500 points
        address[] memory users1 = new address[](1);
        uint256[] memory amounts1 = new uint256[](1);
        users1[0] = user1;
        amounts1[0] = 500 * 1e18;

        (bytes32 root1, bytes32[] memory proof1) = _generateMerkleProof(user1, amounts1[0], users1, amounts1);

        _setActivityMerkleRoot(root1, "Week 1");

        vm.prank(user1);
        activityModule.claim(amounts1[0], proof1);

        assertEq(activityModule.claimedPoints(user1), 500 * 1e18);

        // Second root: user1 now has 1000 cumulative points
        amounts1[0] = 1000 * 1e18;
        (bytes32 root2, bytes32[] memory proof2) = _generateMerkleProof(user1, amounts1[0], users1, amounts1);

        _setActivityMerkleRoot(root2, "Week 2");

        vm.prank(user1);
        activityModule.claim(amounts1[0], proof2);

        assertEq(activityModule.claimedPoints(user1), 1000 * 1e18);
    }

    function test_revert_claim_noRoot() public {
        vm.prank(user1);
        vm.expectRevert(ActivityModule.MerkleRootNotSet.selector);
        activityModule.claim(1000, new bytes32[](0));
    }

    function test_revert_claim_invalidProof() public {
        // Use 2 users so that empty proof is invalid
        address[] memory users = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        users[0] = user1;
        users[1] = user2;
        amounts[0] = 1000 * 1e18;
        amounts[1] = 500 * 1e18;

        (bytes32 root, ) = _generateMerkleProof(user1, amounts[0], users, amounts);

        _setActivityMerkleRoot(root, "Test");

        // Try to claim with wrong proof (empty)
        vm.prank(user1);
        vm.expectRevert(ActivityModule.InvalidProof.selector);
        activityModule.claim(amounts[0], new bytes32[](0));
    }

    function test_revert_claim_nothingToClaim() public {
        address[] memory users = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        users[0] = user1;
        amounts[0] = 1000 * 1e18;

        (bytes32 root, bytes32[] memory proof) = _generateMerkleProof(user1, amounts[0], users, amounts);

        _setActivityMerkleRoot(root, "Test");

        // First claim
        vm.prank(user1);
        activityModule.claim(amounts[0], proof);

        // Try to claim again with same amount
        vm.prank(user1);
        vm.expectRevert(ActivityModule.NothingToClaim.selector);
        activityModule.claim(amounts[0], proof);
    }

    // ============================================
    // Batch Claim Tests
    // ============================================

    function test_batchClaim() public {
        address[] memory users = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        users[0] = user1;
        users[1] = user2;
        amounts[0] = 1000 * 1e18;
        amounts[1] = 500 * 1e18;

        (bytes32 root, bytes32[] memory proof1) = _generateMerkleProof(user1, amounts[0], users, amounts);
        (, bytes32[] memory proof2) = _generateMerkleProof(user2, amounts[1], users, amounts);

        _setActivityMerkleRoot(root, "Test");

        // Batch claim
        bytes32[][] memory proofs = new bytes32[][](2);
        proofs[0] = proof1;
        proofs[1] = proof2;

        vm.prank(keeper);
        activityModule.batchClaim(users, amounts, proofs);

        assertEq(activityModule.claimedPoints(user1), amounts[0]);
        assertEq(activityModule.claimedPoints(user2), amounts[1]);
    }

    function test_revert_batchClaim_arrayLengthMismatch() public {
        address[] memory users = new address[](2);
        uint256[] memory amounts = new uint256[](1); // Mismatch
        bytes32[][] memory proofs = new bytes32[][](2);

        _setActivityMerkleRoot(keccak256("test"), "Test");

        vm.prank(keeper);
        vm.expectRevert(ActivityModule.ArrayLengthMismatch.selector);
        activityModule.batchClaim(users, amounts, proofs);
    }

    function test_revert_batchClaim_batchTooLarge() public {
        address[] memory users = new address[](101);
        uint256[] memory amounts = new uint256[](101);
        bytes32[][] memory proofs = new bytes32[][](101);

        _setActivityMerkleRoot(keccak256("test"), "Test");

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(ActivityModule.BatchTooLarge.selector, 101, 100));
        activityModule.batchClaim(users, amounts, proofs);
    }

    // ============================================
    // Verify Claim Tests
    // ============================================

    function test_verifyClaim() public {
        address[] memory users = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        users[0] = user1;
        amounts[0] = 1000 * 1e18;

        (bytes32 root, bytes32[] memory proof) = _generateMerkleProof(user1, amounts[0], users, amounts);

        _setActivityMerkleRoot(root, "Test");

        (bool valid, uint256 claimable) = activityModule.verifyClaim(user1, amounts[0], proof);
        assertTrue(valid);
        assertEq(claimable, amounts[0]);
    }

    function test_verifyClaim_alreadyClaimed() public {
        address[] memory users = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        users[0] = user1;
        amounts[0] = 1000 * 1e18;

        (bytes32 root, bytes32[] memory proof) = _generateMerkleProof(user1, amounts[0], users, amounts);

        _setActivityMerkleRoot(root, "Test");

        vm.prank(user1);
        activityModule.claim(amounts[0], proof);

        (bool valid, uint256 claimable) = activityModule.verifyClaim(user1, amounts[0], proof);
        assertTrue(valid);
        assertEq(claimable, 0); // Nothing left to claim
    }

    function test_verifyClaim_noRoot() public view {
        (bool valid, uint256 claimable) = activityModule.verifyClaim(user1, 1000, new bytes32[](0));
        assertFalse(valid);
        assertEq(claimable, 0);
    }

    // ============================================
    // Admin Functions Tests
    // ============================================

    function test_setActive() public {
        vm.prank(admin);
        activityModule.setActive(false);

        assertFalse(activityModule.isActive());
    }

    function test_resetUserClaimed() public {
        // Setup and claim first
        address[] memory users = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        users[0] = user1;
        amounts[0] = 1000 * 1e18;

        (bytes32 root, bytes32[] memory proof) = _generateMerkleProof(user1, amounts[0], users, amounts);

        _setActivityMerkleRoot(root, "Test");

        vm.prank(user1);
        activityModule.claim(amounts[0], proof);

        // Admin resets
        vm.prank(admin);
        activityModule.resetUserClaimed(user1, 500 * 1e18);

        assertEq(activityModule.claimedPoints(user1), 500 * 1e18);
    }

    function test_pause_unpause() public {
        // Setup for claim first (before pausing)
        address[] memory users = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        users[0] = user1;
        amounts[0] = 1000 * 1e18;

        (bytes32 root, bytes32[] memory proof) = _generateMerkleProof(user1, amounts[0], users, amounts);

        _setActivityMerkleRoot(root, "Test");

        // Now pause
        vm.prank(admin);
        activityModule.pause();

        // Should revert when paused
        vm.prank(user1);
        vm.expectRevert();
        activityModule.claim(amounts[0], proof);

        // Unpause
        vm.prank(admin);
        activityModule.unpause();

        // Should work now
        vm.prank(user1);
        activityModule.claim(amounts[0], proof);
    }

    // ============================================
    // View Functions Tests
    // ============================================

    function test_getPoints() public {
        address[] memory users = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        users[0] = user1;
        amounts[0] = 1000 * 1e18;

        (bytes32 root, bytes32[] memory proof) = _generateMerkleProof(user1, amounts[0], users, amounts);

        _setActivityMerkleRoot(root, "Test");

        // Before claim
        assertEq(activityModule.getPoints(user1), 0);

        vm.prank(user1);
        activityModule.claim(amounts[0], proof);

        // After claim
        assertEq(activityModule.getPoints(user1), amounts[0]);
    }

    function test_getUserClaimStatus() public {
        address[] memory users = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        users[0] = user1;
        amounts[0] = 1000 * 1e18;

        (bytes32 root, bytes32[] memory proof) = _generateMerkleProof(user1, amounts[0], users, amounts);

        _setActivityMerkleRoot(root, "Test");

        vm.prank(user1);
        activityModule.claim(amounts[0], proof);

        (uint256 claimed, uint256 lastClaimTime) = activityModule.getUserClaimStatus(user1);
        assertEq(claimed, amounts[0]);
        assertGt(lastClaimTime, 0);
    }

    // ============================================
    // Edge Cases
    // ============================================

    function test_multipleRootUpdates() public {
        for (uint256 i = 0; i < 10; i++) {
            bytes32 newRoot = keccak256(abi.encodePacked("root", i));
            _setActivityMerkleRoot(newRoot, string(abi.encodePacked("Week ", i)));
        }

        assertEq(activityModule.getRootHistoryLength(), 10);
        assertEq(activityModule.currentEpoch(), 10);
    }
}
