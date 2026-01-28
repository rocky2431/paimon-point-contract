// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "./Base.t.sol";
import {PenaltyModule} from "../src/PenaltyModule.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract PenaltyModuleTest is BaseTest {
    function setUp() public override {
        super.setUp();
    }

    // ============================================
    // Initialization Tests
    // ============================================

    function test_initialization() public view {
        assertEq(penaltyModule.VERSION(), "1.3.0");
        assertEq(penaltyModule.penaltyRateBps(), PENALTY_RATE_BPS);
        assertTrue(penaltyModule.hasRole(penaltyModule.ADMIN_ROLE(), admin));
        assertTrue(penaltyModule.hasRole(penaltyModule.KEEPER_ROLE(), keeper));
    }

    function test_revert_initializeWithInvalidRate() public {
        PenaltyModule impl = new PenaltyModule();
        bytes memory penaltyData = abi.encodeWithSelector(
            PenaltyModule.initialize.selector,
            admin,
            keeper,
            upgrader,
            10001 // > BASIS_POINTS
        );
        vm.expectRevert(PenaltyModule.InvalidPenaltyRate.selector);
        new ERC1967Proxy(address(impl), penaltyData);
    }

    // ============================================
    // Penalty Root Management Tests
    // ============================================

    function test_updatePenaltyRoot() public {
        bytes32 newRoot = keccak256("penalty root");

        // Queue the root
        vm.prank(keeper);
        penaltyModule.updatePenaltyRoot(newRoot);

        // Root should be pending, not active yet
        assertEq(penaltyModule.pendingRoot(), newRoot);
        assertEq(penaltyModule.penaltyRoot(), bytes32(0)); // Still 0

        // Advance time past ROOT_DELAY
        _advanceTime(24 hours + 1);

        // Activate the root
        penaltyModule.activateRoot();

        assertEq(penaltyModule.penaltyRoot(), newRoot);
        assertEq(penaltyModule.currentEpoch(), 1);
        assertEq(penaltyModule.getRootHistoryLength(), 1);
    }

    function test_multipleRootUpdates() public {
        for (uint256 i = 0; i < 5; i++) {
            bytes32 newRoot = keccak256(abi.encodePacked("root", i));
            _setPenaltyMerkleRoot(newRoot);
        }

        assertEq(penaltyModule.getRootHistoryLength(), 5);
        assertEq(penaltyModule.currentEpoch(), 5);
    }

    // ============================================
    // Sync Penalty Tests
    // ============================================

    function test_syncPenalty_success() public {
        // Setup Merkle tree with user1 having 100 penalty
        address[] memory users = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        users[0] = user1;
        users[1] = user2;
        amounts[0] = 100 * 1e18;
        amounts[1] = 50 * 1e18;

        (bytes32 root, bytes32[] memory proof) = _generateMerkleProof(user1, amounts[0], users, amounts);

        _setPenaltyMerkleRoot(root);

        // Sync penalty
        vm.prank(user1);
        penaltyModule.syncPenalty(user1, amounts[0], proof);

        assertEq(penaltyModule.confirmedPenalty(user1), amounts[0]);
        assertEq(penaltyModule.getPenalty(user1), amounts[0]);
    }

    function test_syncPenalty_byKeeper() public {
        address[] memory users = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        users[0] = user1;
        amounts[0] = 100 * 1e18;

        (bytes32 root, bytes32[] memory proof) = _generateMerkleProof(user1, amounts[0], users, amounts);

        _setPenaltyMerkleRoot(root);

        // Keeper syncs for user
        vm.prank(keeper);
        penaltyModule.syncPenalty(user1, amounts[0], proof);

        assertEq(penaltyModule.confirmedPenalty(user1), amounts[0]);
    }

    function test_syncPenalty_onlyIncreases() public {
        // First sync: 100 penalty
        address[] memory users = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        users[0] = user1;
        amounts[0] = 100 * 1e18;

        (bytes32 root1, bytes32[] memory proof1) = _generateMerkleProof(user1, amounts[0], users, amounts);

        _setPenaltyMerkleRoot(root1);

        vm.prank(user1);
        penaltyModule.syncPenalty(user1, amounts[0], proof1);

        assertEq(penaltyModule.confirmedPenalty(user1), 100 * 1e18);

        // Second sync with lower amount (should not decrease)
        amounts[0] = 50 * 1e18;
        (bytes32 root2, bytes32[] memory proof2) = _generateMerkleProof(user1, amounts[0], users, amounts);

        _setPenaltyMerkleRoot(root2);

        vm.prank(user1);
        penaltyModule.syncPenalty(user1, amounts[0], proof2);

        // Should remain at 100
        assertEq(penaltyModule.confirmedPenalty(user1), 100 * 1e18);

        // Third sync with higher amount (should increase)
        amounts[0] = 200 * 1e18;
        (bytes32 root3, bytes32[] memory proof3) = _generateMerkleProof(user1, amounts[0], users, amounts);

        _setPenaltyMerkleRoot(root3);

        vm.prank(user1);
        penaltyModule.syncPenalty(user1, amounts[0], proof3);

        // Should now be 200
        assertEq(penaltyModule.confirmedPenalty(user1), 200 * 1e18);
    }

    function test_revert_syncPenalty_noRoot() public {
        vm.prank(user1);
        vm.expectRevert(PenaltyModule.PenaltyRootNotSet.selector);
        penaltyModule.syncPenalty(user1, 100, new bytes32[](0));
    }

    function test_revert_syncPenalty_invalidProof() public {
        // Use 2 users so empty proof is invalid
        address[] memory users = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        users[0] = user1;
        users[1] = user2;
        amounts[0] = 100 * 1e18;
        amounts[1] = 50 * 1e18;

        (bytes32 root,) = _generateMerkleProof(user1, amounts[0], users, amounts);

        _setPenaltyMerkleRoot(root);

        vm.prank(user1);
        vm.expectRevert(PenaltyModule.InvalidProof.selector);
        penaltyModule.syncPenalty(user1, amounts[0], new bytes32[](0));
    }

    // ============================================
    // Batch Sync Tests
    // ============================================

    function test_batchSyncPenalty() public {
        address[] memory users = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        users[0] = user1;
        users[1] = user2;
        amounts[0] = 100 * 1e18;
        amounts[1] = 50 * 1e18;

        (bytes32 root, bytes32[] memory proof1) = _generateMerkleProof(user1, amounts[0], users, amounts);
        (, bytes32[] memory proof2) = _generateMerkleProof(user2, amounts[1], users, amounts);

        _setPenaltyMerkleRoot(root);

        bytes32[][] memory proofs = new bytes32[][](2);
        proofs[0] = proof1;
        proofs[1] = proof2;

        vm.prank(keeper);
        penaltyModule.batchSyncPenalty(users, amounts, proofs);

        assertEq(penaltyModule.confirmedPenalty(user1), amounts[0]);
        assertEq(penaltyModule.confirmedPenalty(user2), amounts[1]);
    }

    function test_revert_batchSyncPenalty_arrayLengthMismatch() public {
        address[] memory users = new address[](2);
        uint256[] memory amounts = new uint256[](1);
        bytes32[][] memory proofs = new bytes32[][](2);

        _setPenaltyMerkleRoot(keccak256("test"));

        vm.prank(keeper);
        vm.expectRevert(PenaltyModule.ArrayLengthMismatch.selector);
        penaltyModule.batchSyncPenalty(users, amounts, proofs);
    }

    function test_revert_batchSyncPenalty_batchTooLarge() public {
        address[] memory users = new address[](101);
        uint256[] memory amounts = new uint256[](101);
        bytes32[][] memory proofs = new bytes32[][](101);

        _setPenaltyMerkleRoot(keccak256("test"));

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(PenaltyModule.BatchTooLarge.selector, 101, 100));
        penaltyModule.batchSyncPenalty(users, amounts, proofs);
    }

    // ============================================
    // Verify Penalty Tests
    // ============================================

    function test_verifyPenalty() public {
        address[] memory users = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        users[0] = user1;
        amounts[0] = 100 * 1e18;

        (bytes32 root, bytes32[] memory proof) = _generateMerkleProof(user1, amounts[0], users, amounts);

        _setPenaltyMerkleRoot(root);

        bool valid = penaltyModule.verifyPenalty(user1, amounts[0], proof);
        assertTrue(valid);
    }

    function test_verifyPenalty_noRoot() public view {
        bool valid = penaltyModule.verifyPenalty(user1, 100, new bytes32[](0));
        assertFalse(valid);
    }

    // ============================================
    // Admin Functions Tests
    // ============================================

    function test_setPenaltyRate() public {
        uint256 newRate = 2000; // 20%

        vm.prank(admin);
        penaltyModule.setPenaltyRate(newRate);

        assertEq(penaltyModule.penaltyRateBps(), newRate);
    }

    function test_revert_setPenaltyRate_invalid() public {
        vm.prank(admin);
        vm.expectRevert(PenaltyModule.InvalidPenaltyRate.selector);
        penaltyModule.setPenaltyRate(10001);
    }

    function test_setUserPenalty() public {
        vm.prank(admin);
        penaltyModule.setUserPenalty(user1, 500 * 1e18);

        assertEq(penaltyModule.confirmedPenalty(user1), 500 * 1e18);
    }

    function test_batchSetPenalties() public {
        address[] memory users = new address[](2);
        uint256[] memory penalties = new uint256[](2);
        users[0] = user1;
        users[1] = user2;
        penalties[0] = 100 * 1e18;
        penalties[1] = 200 * 1e18;

        vm.prank(admin);
        penaltyModule.batchSetPenalties(users, penalties);

        assertEq(penaltyModule.confirmedPenalty(user1), penalties[0]);
        assertEq(penaltyModule.confirmedPenalty(user2), penalties[1]);
    }

    function test_revert_batchSetPenalties_arrayLengthMismatch() public {
        address[] memory users = new address[](2);
        uint256[] memory penalties = new uint256[](1);

        vm.prank(admin);
        vm.expectRevert(PenaltyModule.ArrayLengthMismatch.selector);
        penaltyModule.batchSetPenalties(users, penalties);
    }

    function test_pause_unpause() public {
        // Setup first (before pausing)
        address[] memory users = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        users[0] = user1;
        amounts[0] = 100 * 1e18;

        (bytes32 root, bytes32[] memory proof) = _generateMerkleProof(user1, amounts[0], users, amounts);

        _setPenaltyMerkleRoot(root);

        // Now pause
        vm.prank(admin);
        penaltyModule.pause();

        // Should revert when paused
        vm.prank(user1);
        vm.expectRevert();
        penaltyModule.syncPenalty(user1, amounts[0], proof);

        // Unpause
        vm.prank(admin);
        penaltyModule.unpause();

        // Should work now
        vm.prank(user1);
        penaltyModule.syncPenalty(user1, amounts[0], proof);
    }

    // ============================================
    // Calculate Penalty Tests
    // ============================================

    function test_calculatePenalty() public view {
        uint256 redemptionAmount = 1000 * 1e18;
        uint256 expectedPenalty = (redemptionAmount * PENALTY_RATE_BPS) / 10000;

        uint256 calculated = penaltyModule.calculatePenalty(redemptionAmount);
        assertEq(calculated, expectedPenalty);
    }

    // ============================================
    // Integration with PointsHub Tests
    // ============================================

    function test_penaltyAffectsClaimablePoints() public {
        // Setup: user earns points by staking
        ppt.mint(user1, 1000 * 1e18);
        vm.startPrank(user1);
        ppt.approve(address(stakingModule), 1000 * 1e18);
        stakingModule.stakeFlexible(1000 * 1e18);
        vm.stopPrank();

        _advanceBlocks(2);
        _advanceTime(1 days);

        uint256 totalPoints = pointsHub.getTotalPoints(user1);
        uint256 claimableBefore = pointsHub.getClaimablePoints(user1);
        assertEq(claimableBefore, totalPoints);

        // Admin sets penalty
        uint256 penalty = 1000 * 1e18;
        vm.prank(admin);
        penaltyModule.setUserPenalty(user1, penalty);

        // Claimable should be reduced by penalty
        uint256 claimableAfter = pointsHub.getClaimablePoints(user1);
        if (totalPoints > penalty) {
            assertEq(claimableAfter, totalPoints - penalty);
        } else {
            assertEq(claimableAfter, 0);
        }
    }

    // ============================================
    // Fuzz Tests
    // ============================================

    function testFuzz_calculatePenalty(uint256 amount, uint256 rateBps) public {
        rateBps = bound(rateBps, 0, 10000);
        amount = bound(amount, 0, type(uint128).max);

        vm.prank(admin);
        penaltyModule.setPenaltyRate(rateBps);

        uint256 penalty = penaltyModule.calculatePenalty(amount);
        assertEq(penalty, (amount * rateBps) / 10000);
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
