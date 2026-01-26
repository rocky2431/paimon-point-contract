// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "./Base.t.sol";
import {PointsHub} from "../src/PointsHub.sol";
import {IPointsModule} from "../src/interfaces/IPointsModule.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract PointsHubTest is BaseTest {
    function setUp() public override {
        super.setUp();
    }

    // ============================================
    // Initialization Tests
    // ============================================

    function test_initialization() public view {
        assertEq(pointsHub.VERSION(), "1.3.0");
        assertTrue(pointsHub.hasRole(pointsHub.ADMIN_ROLE(), admin));
        assertTrue(pointsHub.hasRole(pointsHub.UPGRADER_ROLE(), upgrader));
        assertEq(address(pointsHub.rewardToken()), address(rewardToken));
        assertEq(pointsHub.exchangeRate(), EXCHANGE_RATE);
    }

    function test_revert_initializeTwice() public {
        vm.expectRevert();
        pointsHub.initialize(admin, upgrader);
    }

    function test_revert_initializeWithZeroAddress() public {
        PointsHub impl = new PointsHub();
        bytes memory hubData = abi.encodeWithSelector(
            PointsHub.initialize.selector,
            address(0),
            upgrader
        );
        vm.expectRevert(PointsHub.ZeroAddress.selector);
        new ERC1967Proxy(address(impl), hubData);
    }

    // ============================================
    // Module Registration Tests
    // ============================================

    function test_moduleRegistration() public view {
        assertEq(pointsHub.getModuleCount(), 3);
        assertTrue(pointsHub.isModule(address(holdingModule)));
        assertTrue(pointsHub.isModule(address(lpModule)));
        assertTrue(pointsHub.isModule(address(activityModule)));
    }

    function test_registerModule_onlyAdmin() public {
        address newModule = address(holdingModule); // Just for testing

        vm.prank(user1);
        vm.expectRevert();
        pointsHub.registerModule(newModule);
    }

    function test_removeModule() public {
        vm.prank(admin);
        pointsHub.removeModule(address(holdingModule));

        assertEq(pointsHub.getModuleCount(), 2);
        assertFalse(pointsHub.isModule(address(holdingModule)));
    }

    function test_revert_removeModule_notFound() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(PointsHub.ModuleNotFound.selector, user1));
        pointsHub.removeModule(user1);
    }

    function test_revert_registerModule_alreadyRegistered() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(PointsHub.ModuleAlreadyRegistered.selector, address(holdingModule)));
        pointsHub.registerModule(address(holdingModule));
    }

    // ============================================
    // Points Calculation Tests
    // ============================================

    function test_getTotalPoints_noBalance() public view {
        uint256 points = pointsHub.getTotalPoints(user1);
        assertEq(points, 0);
    }

    function test_getTotalPoints_withHolding() public {
        // Setup: user1 holds PPT
        ppt.mint(user1, 1000 * 1e18);

        // Checkpoint user
        vm.prank(keeper);
        holdingModule.checkpointUsers(toArray(user1));

        // Advance time
        _advanceTime(1 days);

        uint256 points = pointsHub.getTotalPoints(user1);
        // Expected: 1000 PPT * 1 day * pointsRate / effectiveSupply
        // = 1000 * 86400 * 1e15 / 1000 = 86400 * 1e15
        assertGt(points, 0);
    }

    function test_getClaimablePoints() public {
        // Setup: user1 holds PPT
        ppt.mint(user1, 1000 * 1e18);

        vm.prank(keeper);
        holdingModule.checkpointUsers(toArray(user1));

        _advanceTime(1 days);

        uint256 claimable = pointsHub.getClaimablePoints(user1);
        assertGt(claimable, 0);
    }

    function test_getPointsBreakdown() public {
        // Setup
        ppt.mint(user1, 1000 * 1e18);
        vm.prank(keeper);
        holdingModule.checkpointUsers(toArray(user1));
        _advanceTime(1 days);

        (
            string[] memory names,
            uint256[] memory points,
            uint256 penalty,
            uint256 redeemed,
            uint256 claimable
        ) = pointsHub.getPointsBreakdown(user1);

        assertEq(names.length, 3);
        assertEq(names[0], "PPT Holding");
        assertGt(points[0], 0);
        assertEq(penalty, 0);
        assertEq(redeemed, 0);
        assertGt(claimable, 0);
    }

    // ============================================
    // Redemption Tests
    // ============================================

    function test_redeem_success() public {
        // Setup: user1 earns points
        ppt.mint(user1, 1000 * 1e18);
        vm.prank(keeper);
        holdingModule.checkpointUsers(toArray(user1));
        _advanceTime(1 days);

        // Enable redemption
        vm.prank(admin);
        pointsHub.setRedeemEnabled(true);

        uint256 claimable = pointsHub.getClaimablePoints(user1);
        uint256 previewTokens = pointsHub.previewRedeem(claimable);

        uint256 balanceBefore = rewardToken.balanceOf(user1);

        vm.prank(user1);
        pointsHub.redeem(claimable);

        uint256 balanceAfter = rewardToken.balanceOf(user1);
        assertEq(balanceAfter - balanceBefore, previewTokens);
        assertEq(pointsHub.redeemedPoints(user1), claimable);
    }

    function test_redeem_partial() public {
        // Setup
        ppt.mint(user1, 1000 * 1e18);
        vm.prank(keeper);
        holdingModule.checkpointUsers(toArray(user1));
        _advanceTime(1 days);

        vm.prank(admin);
        pointsHub.setRedeemEnabled(true);

        uint256 claimable = pointsHub.getClaimablePoints(user1);
        uint256 halfClaimable = claimable / 2;

        vm.prank(user1);
        pointsHub.redeem(halfClaimable);

        assertEq(pointsHub.redeemedPoints(user1), halfClaimable);
        // Can still claim the rest
        assertGt(pointsHub.getClaimablePoints(user1), 0);
    }

    function test_revert_redeem_notEnabled() public {
        ppt.mint(user1, 1000 * 1e18);
        vm.prank(keeper);
        holdingModule.checkpointUsers(toArray(user1));
        _advanceTime(1 days);

        vm.prank(user1);
        vm.expectRevert(PointsHub.RedeemNotEnabled.selector);
        pointsHub.redeem(100);
    }

    function test_revert_redeem_zeroAmount() public {
        vm.prank(admin);
        pointsHub.setRedeemEnabled(true);

        vm.prank(user1);
        vm.expectRevert(PointsHub.ZeroAmount.selector);
        pointsHub.redeem(0);
    }

    function test_revert_redeem_insufficientPoints() public {
        vm.prank(admin);
        pointsHub.setRedeemEnabled(true);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(PointsHub.InsufficientPoints.selector, 0, 100));
        pointsHub.redeem(100);
    }

    function test_revert_redeem_exceedsMaxPerTx() public {
        ppt.mint(user1, 1000 * 1e18);
        vm.prank(keeper);
        holdingModule.checkpointUsers(toArray(user1));
        _advanceTime(1 days);

        vm.startPrank(admin);
        pointsHub.setRedeemEnabled(true);
        pointsHub.setMaxRedeemPerTx(100);
        vm.stopPrank();

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(PointsHub.ExceedsMaxRedeemPerTx.selector, 200, 100));
        pointsHub.redeem(200);
    }

    function test_redeem_withPenalty() public {
        // Setup points
        ppt.mint(user1, 1000 * 1e18);
        vm.prank(keeper);
        holdingModule.checkpointUsers(toArray(user1));
        _advanceTime(1 days);

        // Setup penalty via admin
        uint256 penalty = 1000;
        vm.prank(admin);
        penaltyModule.setUserPenalty(user1, penalty);

        vm.prank(admin);
        pointsHub.setRedeemEnabled(true);

        uint256 totalPoints = pointsHub.getTotalPoints(user1);
        uint256 claimable = pointsHub.getClaimablePoints(user1);
        assertEq(claimable, totalPoints - penalty);
    }

    // ============================================
    // Admin Functions Tests
    // ============================================

    function test_setExchangeRate() public {
        uint256 newRate = 2 * EXCHANGE_RATE;

        vm.prank(admin);
        pointsHub.setExchangeRate(newRate);

        assertEq(pointsHub.exchangeRate(), newRate);
    }

    function test_withdrawRewardTokens() public {
        uint256 amount = 1000 * 1e18;
        uint256 balanceBefore = rewardToken.balanceOf(admin);

        vm.prank(admin);
        pointsHub.withdrawRewardTokens(admin, amount);

        assertEq(rewardToken.balanceOf(admin), balanceBefore + amount);
    }

    function test_pause_unpause() public {
        vm.prank(admin);
        pointsHub.pause();

        // Setup for redeem
        ppt.mint(user1, 1000 * 1e18);
        vm.prank(keeper);
        holdingModule.checkpointUsers(toArray(user1));
        _advanceTime(1 days);
        vm.prank(admin);
        pointsHub.setRedeemEnabled(true);

        // Should revert when paused
        vm.prank(user1);
        vm.expectRevert();
        pointsHub.redeem(100);

        // Unpause
        vm.prank(admin);
        pointsHub.unpause();

        // Should work now
        uint256 claimable = pointsHub.getClaimablePoints(user1);
        vm.prank(user1);
        pointsHub.redeem(claimable);
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
