// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {StakingModule} from "../src/StakingModule.sol";
import {PointsHub} from "../src/PointsHub.sol";
import {MockStakingPPT} from "./mocks/MockStakingPPT.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract StakingModuleTest is Test {
    StakingModule public stakingModule;
    PointsHub public pointsHub;
    MockStakingPPT public ppt;
    MockERC20 public rewardToken;

    address public admin = makeAddr("admin");
    address public keeper = makeAddr("keeper");
    address public upgrader = makeAddr("upgrader");
    address public user1 = makeAddr("user1");
    address public user2 = makeAddr("user2");

    uint256 public constant PRECISION = 1e18;
    uint256 public constant BOOST_BASE = 10000;
    uint256 public constant POINTS_RATE_PER_SECOND = 1e15; // 0.001 points per second per PPT

    function setUp() public {
        // Deploy mocks
        ppt = new MockStakingPPT();
        rewardToken = new MockERC20("Reward Token", "RWD", 18);

        // Deploy and initialize StakingModule
        StakingModule impl = new StakingModule();
        bytes memory initData = abi.encodeWithSelector(
            StakingModule.initialize.selector, address(ppt), admin, keeper, upgrader, POINTS_RATE_PER_SECOND
        );
        stakingModule = StakingModule(address(new ERC1967Proxy(address(impl), initData)));

        // Deploy and initialize PointsHub
        PointsHub hubImpl = new PointsHub();
        bytes memory hubData = abi.encodeWithSelector(PointsHub.initialize.selector, admin, upgrader);
        pointsHub = PointsHub(address(new ERC1967Proxy(address(hubImpl), hubData)));

        // Register module in PointsHub
        vm.prank(admin);
        pointsHub.registerModule(address(stakingModule));

        // Setup reward tokens
        rewardToken.mint(address(pointsHub), 1_000_000 * 1e18);
        vm.prank(admin);
        pointsHub.setRewardToken(address(rewardToken));
    }

    // =============================================================================
    // Helper Functions
    // =============================================================================

    function _mintAndApprove(address user, uint256 amount) internal {
        ppt.mint(user, amount);
        vm.prank(user);
        ppt.approve(address(stakingModule), amount);
    }

    function _advanceTime(uint256 seconds_) internal {
        vm.warp(block.timestamp + seconds_);
    }

    function _advanceBlocks(uint256 blocks_) internal {
        vm.roll(block.number + blocks_);
    }

    // =============================================================================
    // Initialization Tests
    // =============================================================================

    function test_initialization() public view {
        assertEq(address(stakingModule.ppt()), address(ppt));
        assertEq(stakingModule.pointsRatePerSecond(), POINTS_RATE_PER_SECOND);
        assertTrue(stakingModule.active());
        assertEq(stakingModule.minHoldingBlocks(), 1);
        assertEq(stakingModule.moduleName(), "PPT Staking");
        assertEq(stakingModule.VERSION(), "2.3.0");
        assertEq(stakingModule.version(), "2.3.0");
    }

    function test_initialization_zeroAddress_ppt_reverts() public {
        StakingModule impl = new StakingModule();

        vm.expectRevert(StakingModule.ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl),
            abi.encodeWithSelector(
                StakingModule.initialize.selector,
                address(0), // zero PPT
                admin,
                keeper,
                upgrader,
                POINTS_RATE_PER_SECOND
            )
        );
    }

    function test_initialization_zeroAddress_admin_reverts() public {
        StakingModule impl = new StakingModule();

        vm.expectRevert(StakingModule.ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl),
            abi.encodeWithSelector(
                StakingModule.initialize.selector,
                address(ppt),
                address(0), // zero admin
                keeper,
                upgrader,
                POINTS_RATE_PER_SECOND
            )
        );
    }

    function test_initialization_invalidPointsRate_tooLow_reverts() public {
        StakingModule impl = new StakingModule();
        uint256 minRate = impl.MIN_POINTS_RATE();
        uint256 maxRate = impl.MAX_POINTS_RATE();

        vm.expectRevert(abi.encodeWithSelector(StakingModule.InvalidPointsRate.selector, 0, minRate, maxRate));
        new ERC1967Proxy(
            address(impl),
            abi.encodeWithSelector(
                StakingModule.initialize.selector,
                address(ppt),
                admin,
                keeper,
                upgrader,
                0 // too low
            )
        );
    }

    function test_roles() public view {
        assertTrue(stakingModule.hasRole(stakingModule.ADMIN_ROLE(), admin));
        assertTrue(stakingModule.hasRole(stakingModule.KEEPER_ROLE(), keeper));
        assertTrue(stakingModule.hasRole(stakingModule.UPGRADER_ROLE(), upgrader));
    }

    // =============================================================================
    // Boost Calculation Tests (Credit Card Mode)
    // =============================================================================

    function test_calculateBoostFromDays_flexible() public view {
        // 0 days = flexible = 1.0x boost
        uint256 boost = stakingModule.calculateBoostFromDays(0);
        assertEq(boost, BOOST_BASE);
    }

    function test_calculateBoostFromDays_minDuration() public view {
        // 7 days should give ~1.02x boost
        uint256 boost = stakingModule.calculateBoostFromDays(7);
        // 10000 + (7 * 10000 / 365) = 10000 + 191 = 10191
        assertEq(boost, 10191);
    }

    function test_calculateBoostFromDays_90days() public view {
        // 90 days should give ~1.25x boost
        uint256 boost = stakingModule.calculateBoostFromDays(90);
        // 10000 + (90 * 10000 / 365) = 10000 + 2465 = 12465
        assertEq(boost, 12465);
    }

    function test_calculateBoostFromDays_maxDuration() public view {
        // 365 days should give 2.0x boost
        uint256 boost = stakingModule.calculateBoostFromDays(365);
        // 10000 + (365 * 10000 / 365) = 10000 + 10000 = 20000
        assertEq(boost, 20000);
    }

    function test_calculateBoostFromDays_beyondMax() public view {
        // Beyond 365 days should still be 2.0x (capped)
        uint256 boost = stakingModule.calculateBoostFromDays(500);
        assertEq(boost, 20000);
    }

    function test_calculateBoostFromDays_belowMin() public view {
        // Below 7 days should return base boost
        uint256 boost = stakingModule.calculateBoostFromDays(3);
        assertEq(boost, BOOST_BASE);
    }

    // =============================================================================
    // Flexible Stake Tests
    // =============================================================================

    function test_stakeFlexible_basic() public {
        uint256 amount = 1000e18;
        _mintAndApprove(user1, amount);

        vm.prank(user1);
        uint256 stakeIndex = stakingModule.stakeFlexible(amount);

        assertEq(stakeIndex, 0);
        assertEq(ppt.balanceOf(address(stakingModule)), amount);
        assertEq(ppt.balanceOf(user1), 0);

        StakingModule.StakeInfo memory info = stakingModule.getStakeInfo(user1, stakeIndex);
        assertEq(info.amount, amount);
        assertEq(info.lockDurationDays, 0);
        assertEq(info.lockEndTime, 0);
        assertTrue(info.isActive);
        assertTrue(info.stakeType == StakingModule.StakeType.Flexible);
    }

    function test_stakeFlexible_earnPoints() public {
        uint256 amount = 1000e18;
        _mintAndApprove(user1, amount);

        vm.prank(user1);
        stakingModule.stakeFlexible(amount);

        // Advance 1 day
        _advanceTime(1 days);

        uint256 points = stakingModule.getPoints(user1);
        // Credit card mode: points = amount * boost(1.0x) * rate * duration / (BOOST_BASE * RATE_PRECISION)
        // = 1000e18 * 10000 * 1e15 * 86400 / (10000 * 1e18)
        // = 1000e18 * 1e15 * 86400 / 1e18
        // = 1000 * 1e15 * 86400
        // = 86400e18
        assertTrue(points > 0, "Should have earned points");

        // Verify the calculation
        uint256 expected = (amount * BOOST_BASE * POINTS_RATE_PER_SECOND * 1 days) / (BOOST_BASE * PRECISION);
        assertEq(points, expected, "Points should match expected");
    }

    // =============================================================================
    // Locked Stake Tests
    // =============================================================================

    function test_stakeLocked_basic() public {
        uint256 amount = 1000e18;
        uint256 lockDays = 30;
        _mintAndApprove(user1, amount);

        vm.prank(user1);
        uint256 stakeIndex = stakingModule.stakeLocked(amount, lockDays);

        assertEq(stakeIndex, 0);
        assertEq(ppt.balanceOf(address(stakingModule)), amount);

        StakingModule.StakeInfo memory info = stakingModule.getStakeInfo(user1, stakeIndex);
        assertEq(info.amount, amount);
        assertEq(info.lockDurationDays, lockDays);
        assertEq(info.lockEndTime, block.timestamp + lockDays * 1 days);
        assertTrue(info.isActive);
        assertTrue(info.stakeType == StakingModule.StakeType.Locked);
    }

    function test_stakeLocked_multipleStakes() public {
        _mintAndApprove(user1, 3000e18);

        vm.startPrank(user1);

        // First stake - flexible
        uint256 idx1 = stakingModule.stakeFlexible(1000e18);
        assertEq(idx1, 0);

        // Second stake - locked 90 days
        ppt.approve(address(stakingModule), 2000e18);
        uint256 idx2 = stakingModule.stakeLocked(1000e18, 90);
        assertEq(idx2, 1);

        // Third stake - locked 365 days
        uint256 idx3 = stakingModule.stakeLocked(1000e18, 365);
        assertEq(idx3, 2);

        vm.stopPrank();

        assertEq(stakingModule.userStakeCount(user1), 3);

        StakingModule.StakeInfo[] memory stakes = stakingModule.getAllStakes(user1);
        assertEq(stakes.length, 3);
        assertTrue(stakes[0].stakeType == StakingModule.StakeType.Flexible);
        assertEq(stakes[1].lockDurationDays, 90);
        assertEq(stakes[2].lockDurationDays, 365);
    }

    function test_stakeLocked_invalidDuration_reverts() public {
        _mintAndApprove(user1, 1000e18);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(StakingModule.InvalidLockDuration.selector, 1 days, 7 days, 365 days));
        stakingModule.stakeLocked(1000e18, 1);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(StakingModule.InvalidLockDuration.selector, 400 days, 7 days, 365 days));
        stakingModule.stakeLocked(1000e18, 400);
    }

    function test_stake_zeroAmount_reverts() public {
        vm.prank(user1);
        vm.expectRevert(StakingModule.ZeroAmount.selector);
        stakingModule.stakeFlexible(0);
    }

    function test_stake_maxStakesReached_reverts() public {
        uint256 maxStakes = stakingModule.MAX_STAKES_PER_USER();
        _mintAndApprove(user1, (maxStakes + 1) * 100e18);

        vm.startPrank(user1);

        // Create max stakes
        for (uint256 i = 0; i < maxStakes; i++) {
            ppt.approve(address(stakingModule), 100e18);
            stakingModule.stakeFlexible(100e18);
        }

        // Next stake should fail
        ppt.approve(address(stakingModule), 100e18);
        vm.expectRevert(abi.encodeWithSelector(StakingModule.MaxStakesReached.selector, maxStakes, maxStakes));
        stakingModule.stakeFlexible(100e18);

        vm.stopPrank();
    }

    // =============================================================================
    // Credit Card Mode - Fair Points Distribution Tests
    // =============================================================================

    /// @notice Core test: late entrant should NOT be diluted
    function test_lateEntrant_notDiluted() public {
        uint256 amount = 1000e18;
        _mintAndApprove(user1, amount);
        _mintAndApprove(user2, amount);

        // User1 stakes on day 1
        vm.prank(user1);
        stakingModule.stakeFlexible(amount);

        _advanceTime(1 days);

        // User2 stakes on day 2
        vm.prank(user2);
        stakingModule.stakeFlexible(amount);

        _advanceTime(1 days);

        // User2's first day points should equal User1's second day points
        // (since both have same amount and same boost)
        uint256 points1 = stakingModule.getPoints(user1);
        uint256 points2 = stakingModule.getPoints(user2);

        // User1: 2 days of points
        // User2: 1 day of points
        uint256 expectedPerDay = (amount * BOOST_BASE * POINTS_RATE_PER_SECOND * 1 days) / (BOOST_BASE * PRECISION);
        assertEq(points1, expectedPerDay * 2, "User1 should have 2 days of points");
        assertEq(points2, expectedPerDay, "User2 should have 1 day of points");

        // The key assertion: User2's points per day equals User1's points per day
        assertEq(points1 / 2, points2, "Same daily earning rate for equal stakes");
    }

    /// @notice Test boost ratio is exactly as expected
    function test_boostRatio_exact() public {
        uint256 amount = 1000e18;
        _mintAndApprove(user1, amount);
        _mintAndApprove(user2, amount);

        // User1 stakes with max boost (2.0x) - 365 days lock
        vm.prank(user1);
        stakingModule.stakeLocked(amount, 365);

        // User2 stakes flexible (1.0x)
        vm.prank(user2);
        stakingModule.stakeFlexible(amount);

        _advanceTime(1 days);

        uint256 points1 = stakingModule.getPoints(user1);
        uint256 points2 = stakingModule.getPoints(user2);

        // User1 should have exactly 2x points of User2
        assertEq(points1, points2 * 2, "2x boost should give exactly 2x points");
    }

    /// @notice Test lock expiry automatically reduces boost to 1.0x
    function test_lockExpiry_becomesFlexible() public {
        uint256 amount = 1000e18;
        _mintAndApprove(user1, amount);

        vm.prank(user1);
        stakingModule.stakeLocked(amount, 7); // 7 day lock

        // Check boost before expiry
        (uint256 pointsBefore, uint256 boostBefore, bool expiredBefore) = stakingModule.getStakePointsAndBoost(user1, 0);
        assertFalse(expiredBefore);
        assertEq(boostBefore, stakingModule.calculateBoostFromDays(7));

        // Advance past lock period
        _advanceTime(8 days);

        // Check boost after expiry
        (, uint256 boostAfter, bool expiredAfter) = stakingModule.getStakePointsAndBoost(user1, 0);
        assertTrue(expiredAfter);
        assertEq(boostAfter, BOOST_BASE, "Boost should be 1.0x after lock expires");
    }

    // =============================================================================
    // Unstake Tests
    // =============================================================================

    function test_unstake_flexible() public {
        uint256 amount = 1000e18;
        _mintAndApprove(user1, amount);

        vm.prank(user1);
        uint256 stakeIndex = stakingModule.stakeFlexible(amount);

        // Can unstake immediately (no lock)
        _advanceBlocks(2); // Pass flash loan protection

        vm.prank(user1);
        stakingModule.unstake(stakeIndex);

        assertEq(ppt.balanceOf(user1), amount);
        assertEq(ppt.balanceOf(address(stakingModule)), 0);

        StakingModule.StakeInfo memory info = stakingModule.getStakeInfo(user1, stakeIndex);
        assertFalse(info.isActive);
    }

    function test_unstake_lockedAfterExpiry() public {
        uint256 amount = 1000e18;
        uint256 lockDays = 30;
        _mintAndApprove(user1, amount);

        vm.prank(user1);
        uint256 stakeIndex = stakingModule.stakeLocked(amount, lockDays);

        // Advance past lock period
        _advanceTime(lockDays * 1 days + 1);
        _advanceBlocks(2);

        vm.prank(user1);
        stakingModule.unstake(stakeIndex);

        assertEq(ppt.balanceOf(user1), amount);

        StakingModule.StakeInfo memory info = stakingModule.getStakeInfo(user1, stakeIndex);
        assertFalse(info.isActive);
    }

    function test_unstake_earlyUnlock_withPenalty() public {
        uint256 amount = 1000e18;
        uint256 lockDays = 30;
        _mintAndApprove(user1, amount);

        vm.prank(user1);
        uint256 stakeIndex = stakingModule.stakeLocked(amount, lockDays);

        // Advance halfway through lock period
        _advanceTime(15 days);
        _advanceBlocks(2);

        uint256 pointsBefore = stakingModule.getPoints(user1);
        assertTrue(pointsBefore > 0, "Should have points before unstake");

        // Calculate expected penalty
        uint256 expectedPenalty = stakingModule.calculatePotentialPenalty(user1, stakeIndex);
        assertTrue(expectedPenalty > 0, "Should have penalty for early unlock");

        vm.prank(user1);
        stakingModule.unstake(stakeIndex);

        uint256 pointsAfter = stakingModule.getPoints(user1);
        assertEq(pointsAfter, pointsBefore - expectedPenalty, "Points should be reduced by penalty");

        // Tokens should still be returned fully
        assertEq(ppt.balanceOf(user1), amount);
    }

    function test_unstake_flexible_noPenalty() public {
        uint256 amount = 1000e18;
        _mintAndApprove(user1, amount);

        vm.prank(user1);
        uint256 stakeIndex = stakingModule.stakeFlexible(amount);

        _advanceTime(1 days);
        _advanceBlocks(2);

        uint256 pointsBefore = stakingModule.getPoints(user1);
        uint256 expectedPenalty = stakingModule.calculatePotentialPenalty(user1, stakeIndex);
        assertEq(expectedPenalty, 0, "Flexible stakes have no penalty");

        vm.prank(user1);
        stakingModule.unstake(stakeIndex);

        // Points should remain (no penalty)
        uint256 pointsAfter = stakingModule.getPoints(user1);
        // Points are stored in the stake, so after unstake they're still there but inactive
        // Actually, after unstake the stake.accruedPoints is preserved
        assertEq(pointsAfter, pointsBefore, "No penalty for flexible unstake");
    }

    function test_unstake_stakeNotFound_reverts() public {
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(StakingModule.StakeNotFound.selector, 0));
        stakingModule.unstake(0);
    }

    function test_unstake_stakeNotActive_reverts() public {
        uint256 amount = 1000e18;
        _mintAndApprove(user1, amount);

        vm.prank(user1);
        uint256 stakeIndex = stakingModule.stakeFlexible(amount);

        _advanceBlocks(2);

        vm.prank(user1);
        stakingModule.unstake(stakeIndex);

        // Try to unstake again
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(StakingModule.StakeNotActive.selector, stakeIndex));
        stakingModule.unstake(stakeIndex);
    }

    // =============================================================================
    // Points Accumulation Tests
    // =============================================================================

    function test_points_accumulateOverTime() public {
        uint256 amount = 1000e18;
        _mintAndApprove(user1, amount);

        vm.prank(user1);
        stakingModule.stakeLocked(amount, 365); // 2x boost

        // Advance 1 day
        _advanceTime(1 days);

        uint256 points = stakingModule.getPoints(user1);

        // Expected: amount * boost(2.0x) * rate * duration / (BOOST_BASE * RATE_PRECISION)
        uint256 boost = stakingModule.calculateBoostFromDays(365);
        uint256 expected = (amount * boost * POINTS_RATE_PER_SECOND * 1 days) / (BOOST_BASE * PRECISION);
        assertEq(points, expected);
    }

    function test_points_zeroWhenInactive() public {
        uint256 amount = 1000e18;
        _mintAndApprove(user1, amount);

        vm.prank(user1);
        stakingModule.stakeFlexible(amount);

        // Deactivate module
        vm.prank(admin);
        stakingModule.setActive(false);

        uint256 pointsBeforeDeactivation = stakingModule.getPoints(user1);

        // Advance time
        _advanceTime(1 days);

        // Points should not increase
        uint256 pointsAfter = stakingModule.getPoints(user1);
        assertEq(pointsAfter, pointsBeforeDeactivation);
    }

    // =============================================================================
    // Checkpoint Tests
    // =============================================================================

    function test_checkpointUsers() public {
        uint256 amount = 1000e18;
        _mintAndApprove(user1, amount);
        _mintAndApprove(user2, amount);

        vm.prank(user1);
        stakingModule.stakeFlexible(amount);

        vm.prank(user2);
        stakingModule.stakeLocked(amount, 90);

        _advanceTime(1 days);
        _advanceBlocks(2);

        address[] memory users = new address[](2);
        users[0] = user1;
        users[1] = user2;

        vm.prank(keeper);
        stakingModule.checkpointUsers(users);

        // Both users should have earned points
        assertTrue(stakingModule.getPoints(user1) > 0);
        assertTrue(stakingModule.getPoints(user2) > 0);
    }

    function test_checkpointUsers_batchTooLarge_reverts() public {
        address[] memory users = new address[](101);
        for (uint256 i = 0; i < 101; i++) {
            users[i] = address(uint160(i + 1));
        }

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(StakingModule.BatchTooLarge.selector, 101, 100));
        stakingModule.checkpointUsers(users);
    }

    function test_checkpointSelf() public {
        uint256 amount = 1000e18;
        _mintAndApprove(user1, amount);

        vm.prank(user1);
        stakingModule.stakeFlexible(amount);

        _advanceTime(1 days);
        _advanceBlocks(2);

        vm.prank(user1);
        stakingModule.checkpointSelf();

        assertTrue(stakingModule.getPoints(user1) > 0);
    }

    function test_checkpoint_anyoneCanCall() public {
        uint256 amount = 1000e18;
        _mintAndApprove(user1, amount);

        vm.prank(user1);
        stakingModule.stakeFlexible(amount);

        _advanceTime(1 days);
        _advanceBlocks(2);

        // Anyone can checkpoint any user
        vm.prank(user2);
        stakingModule.checkpoint(user1);

        assertTrue(stakingModule.getPoints(user1) > 0);
    }

    // =============================================================================
    // Flash Loan Protection Tests
    // =============================================================================

    function test_flashLoanProtection() public {
        uint256 amount = 1000e18;
        _mintAndApprove(user1, amount);

        vm.prank(user1);
        stakingModule.stakeFlexible(amount);

        // Advance time but NOT blocks - this simulates same block
        _advanceTime(1 days);

        vm.prank(user1);
        stakingModule.checkpointSelf();

        // Flash loan protection triggered
        // Points are calculated in real-time, but checkpoint doesn't persist them
        uint256 points = stakingModule.getPoints(user1);
        assertTrue(points > 0, "getPoints should still show pending points");

        // Now advance blocks to pass holding period
        _advanceBlocks(2);

        vm.prank(user1);
        stakingModule.checkpointSelf();

        // Points should still be there
        uint256 pointsAfter = stakingModule.getPoints(user1);
        assertTrue(pointsAfter > 0, "Should have points after blocks advance");
    }

    // =============================================================================
    // Admin Functions Tests
    // =============================================================================

    function test_setPointsRate() public {
        uint256 newRate = 2e15;

        vm.prank(admin);
        stakingModule.setPointsRate(newRate);

        assertEq(stakingModule.pointsRatePerSecond(), newRate);
    }

    function test_setPointsRate_unauthorized_reverts() public {
        vm.prank(user1);
        vm.expectRevert();
        stakingModule.setPointsRate(2e15);
    }

    function test_setActive() public {
        vm.prank(admin);
        stakingModule.setActive(false);
        assertFalse(stakingModule.isActive());

        vm.prank(admin);
        stakingModule.setActive(true);
        assertTrue(stakingModule.isActive());
    }

    function test_setPpt() public {
        MockStakingPPT newPpt = new MockStakingPPT();

        vm.prank(admin);
        stakingModule.setPpt(address(newPpt));

        assertEq(address(stakingModule.ppt()), address(newPpt));
    }

    function test_setPpt_zeroAddress_reverts() public {
        vm.prank(admin);
        vm.expectRevert(StakingModule.ZeroAddress.selector);
        stakingModule.setPpt(address(0));
    }

    function test_setMinHoldingBlocks() public {
        vm.prank(admin);
        stakingModule.setMinHoldingBlocks(5);

        assertEq(stakingModule.minHoldingBlocks(), 5);
    }

    function test_pauseUnpause() public {
        vm.prank(admin);
        stakingModule.pause();

        // Stake should fail when paused
        _mintAndApprove(user1, 1000e18);
        vm.prank(user1);
        vm.expectRevert();
        stakingModule.stakeFlexible(1000e18);

        // Unpause
        vm.prank(admin);
        stakingModule.unpause();

        // Should work now
        vm.prank(user1);
        stakingModule.stakeFlexible(1000e18);
    }

    // =============================================================================
    // Integration with PointsHub Tests
    // =============================================================================

    function test_pointsHub_integration() public {
        uint256 amount = 1000e18;
        _mintAndApprove(user1, amount);

        vm.prank(user1);
        stakingModule.stakeLocked(amount, 365);

        _advanceTime(1 days);
        _advanceBlocks(2);

        // PointsHub should aggregate points from StakingModule
        uint256 totalPoints = pointsHub.getTotalPoints(user1);
        uint256 stakingPoints = stakingModule.getPoints(user1);

        assertEq(totalPoints, stakingPoints);
    }

    // =============================================================================
    // View Functions Tests
    // =============================================================================

    function test_getUserState() public {
        uint256 amount = 1000e18;
        _mintAndApprove(user1, amount);

        vm.prank(user1);
        stakingModule.stakeFlexible(amount);

        (uint256 totalStaked, uint256 earnedPoints, uint256 activeCount) = stakingModule.getUserState(user1);

        assertEq(totalStaked, amount);
        assertEq(earnedPoints, 0); // No time passed
        assertEq(activeCount, 1);
    }

    function test_getAllStakes() public {
        _mintAndApprove(user1, 2000e18);

        vm.startPrank(user1);
        stakingModule.stakeFlexible(1000e18);
        ppt.approve(address(stakingModule), 1000e18);
        stakingModule.stakeLocked(1000e18, 90);
        vm.stopPrank();

        StakingModule.StakeInfo[] memory stakes = stakingModule.getAllStakes(user1);
        assertEq(stakes.length, 2);
        assertTrue(stakes[0].isActive);
        assertTrue(stakes[1].isActive);
    }

    function test_estimatePoints() public view {
        uint256 amount = 1000e18;
        uint256 lockDays = 365;
        uint256 holdDuration = 1 days;

        uint256 estimated = stakingModule.estimatePoints(amount, lockDays, holdDuration);

        // Credit card mode: fixed rate regardless of other stakers
        uint256 boost = stakingModule.calculateBoostFromDays(lockDays);
        uint256 expected = (amount * boost * POINTS_RATE_PER_SECOND * holdDuration) / (BOOST_BASE * PRECISION);
        assertEq(estimated, expected);
    }

    function test_calculatePotentialPenalty() public {
        uint256 amount = 1000e18;
        uint256 lockDays = 30;
        _mintAndApprove(user1, amount);

        vm.prank(user1);
        uint256 stakeIndex = stakingModule.stakeLocked(amount, lockDays);

        // Advance 15 days (halfway)
        _advanceTime(15 days);
        _advanceBlocks(2);

        uint256 penalty = stakingModule.calculatePotentialPenalty(user1, stakeIndex);

        // penalty = accruedPoints * (remainingTime / lockDuration) * 50%
        uint256 currentPoints = stakingModule.getPoints(user1);
        uint256 expectedPenalty = (currentPoints * 15 days * 5000) / (30 days * 10000);

        assertEq(penalty, expectedPenalty);
    }

    function test_getStakePointsAndBoost() public {
        uint256 amount = 1000e18;
        _mintAndApprove(user1, amount);

        vm.prank(user1);
        stakingModule.stakeLocked(amount, 30);

        _advanceTime(1 days);

        (uint256 points, uint256 boost, bool expired) = stakingModule.getStakePointsAndBoost(user1, 0);

        assertTrue(points > 0);
        assertEq(boost, stakingModule.calculateBoostFromDays(30));
        assertFalse(expired);
    }

    // =============================================================================
    // Edge Cases Tests
    // =============================================================================

    function test_penalty_cappedAtEarnedPoints() public {
        uint256 amount = 1000e18;
        _mintAndApprove(user1, amount);

        vm.prank(user1);
        stakingModule.stakeLocked(amount, 365);

        // Advance just 1 second
        _advanceTime(1);
        _advanceBlocks(2);

        uint256 points = stakingModule.getPoints(user1);

        // Unstake immediately - penalty could theoretically be > points
        vm.prank(user1);
        stakingModule.unstake(0);

        // Points should be 0 or capped (no underflow)
        uint256 pointsAfter = stakingModule.getPoints(user1);
        assertTrue(pointsAfter <= points);
    }

    // =============================================================================
    // Fuzz Tests
    // =============================================================================

    function testFuzz_calculateBoostFromDays(uint256 days_) public view {
        uint256 boost = stakingModule.calculateBoostFromDays(days_);

        // Boost should always be >= BOOST_BASE
        assertTrue(boost >= BOOST_BASE);

        // Boost should never exceed 2x
        assertTrue(boost <= 2 * BOOST_BASE);
    }

    function testFuzz_stakeFlexible(uint256 amount) public {
        // Bound inputs (MIN_STAKE_AMOUNT = 100e18)
        amount = bound(amount, 100e18, 1e30);

        _mintAndApprove(user1, amount);

        vm.prank(user1);
        uint256 stakeIndex = stakingModule.stakeFlexible(amount);

        assertEq(stakeIndex, 0);
        assertEq(ppt.balanceOf(address(stakingModule)), amount);

        StakingModule.StakeInfo memory info = stakingModule.getStakeInfo(user1, stakeIndex);
        assertEq(info.amount, amount);
        assertTrue(info.isActive);
    }

    function testFuzz_stakeLocked(uint256 amount, uint256 lockDays) public {
        // Bound inputs (MIN_STAKE_AMOUNT = 100e18)
        amount = bound(amount, 100e18, 1e24);
        lockDays = bound(lockDays, 7, 365);

        _mintAndApprove(user1, amount);

        vm.prank(user1);
        uint256 stakeIndex = stakingModule.stakeLocked(amount, lockDays);

        assertEq(stakeIndex, 0);

        StakingModule.StakeInfo memory info = stakingModule.getStakeInfo(user1, stakeIndex);
        assertEq(info.amount, amount);
        assertEq(info.lockDurationDays, lockDays);
        assertTrue(info.isActive);
    }

    function testFuzz_pointsAccumulation(uint256 amount, uint256 duration) public {
        // Bound inputs (MIN_STAKE_AMOUNT = 100e18)
        amount = bound(amount, 100e18, 1e24);
        duration = bound(duration, 1 hours, 30 days);

        _mintAndApprove(user1, amount);

        vm.prank(user1);
        stakingModule.stakeFlexible(amount);

        _advanceTime(duration);

        uint256 points = stakingModule.getPoints(user1);

        // Points should be exactly: amount * 1.0x * rate * duration / (BOOST_BASE * RATE_PRECISION)
        uint256 expected = (amount * BOOST_BASE * POINTS_RATE_PER_SECOND * duration) / (BOOST_BASE * PRECISION);
        assertEq(points, expected);
    }

    // =============================================================================
    // UUPS Upgrade Authorization Tests
    // =============================================================================

    function test_upgrade_unauthorized_reverts() public {
        StakingModule newImpl = new StakingModule();

        // Non-upgrader should fail
        vm.prank(admin);
        vm.expectRevert();
        stakingModule.upgradeToAndCall(address(newImpl), "");

        vm.prank(user1);
        vm.expectRevert();
        stakingModule.upgradeToAndCall(address(newImpl), "");
    }

    function test_upgrade_authorized_succeeds() public {
        StakingModule newImpl = new StakingModule();

        // Upgrader should succeed
        vm.prank(upgrader);
        stakingModule.upgradeToAndCall(address(newImpl), "");
    }

    // =============================================================================
    // Event Emission Tests
    // =============================================================================

    function test_stake_emitsEvent() public {
        uint256 amount = 1000e18;
        uint256 lockDays = 30;
        _mintAndApprove(user1, amount);

        uint256 expectedBoost = stakingModule.calculateBoostFromDays(lockDays);
        uint256 expectedLockEndTime = block.timestamp + lockDays * 1 days;

        vm.expectEmit(true, true, false, true);
        emit StakingModule.Staked(
            user1, 0, amount, StakingModule.StakeType.Locked, lockDays, expectedBoost, expectedLockEndTime
        );

        vm.prank(user1);
        stakingModule.stakeLocked(amount, lockDays);
    }

    function test_unstake_emitsEvent_noEarlyUnlock() public {
        uint256 amount = 1000e18;
        _mintAndApprove(user1, amount);

        vm.prank(user1);
        uint256 stakeIndex = stakingModule.stakeFlexible(amount);

        _advanceBlocks(2);

        vm.expectEmit(true, true, false, true);
        emit StakingModule.Unstaked(user1, stakeIndex, amount, 0, 0, false, false);

        vm.prank(user1);
        stakingModule.unstake(stakeIndex);
    }

    // =============================================================================
    // checkpointUsers Authorization Tests
    // =============================================================================

    function test_checkpointUsers_unauthorized_reverts() public {
        address[] memory users = new address[](1);
        users[0] = user1;

        vm.prank(user1);
        vm.expectRevert();
        stakingModule.checkpointUsers(users);

        vm.prank(admin);
        vm.expectRevert();
        stakingModule.checkpointUsers(users);
    }

    // =============================================================================
    // Additional Edge Cases
    // =============================================================================

    function test_estimatePoints_zeroAmount_reverts() public {
        vm.expectRevert(StakingModule.ZeroAmount.selector);
        stakingModule.estimatePoints(0, 30, 1 days);
    }

    function test_checkpointUsers_skipsZeroAddress() public {
        uint256 amount = 1000e18;
        _mintAndApprove(user1, amount);

        vm.prank(user1);
        stakingModule.stakeFlexible(amount);

        _advanceTime(1 days);
        _advanceBlocks(2);

        // Array with zero address
        address[] memory users = new address[](3);
        users[0] = user1;
        users[1] = address(0); // Should be skipped
        users[2] = user2;

        vm.prank(keeper);
        stakingModule.checkpointUsers(users); // Should not revert

        assertTrue(stakingModule.getPoints(user1) > 0);
    }

    function test_stake_exactlyAtMaxStakeAmount() public {
        uint256 maxAmount = stakingModule.MAX_STAKE_AMOUNT();

        ppt.mint(user1, maxAmount);
        vm.prank(user1);
        ppt.approve(address(stakingModule), maxAmount);

        vm.prank(user1);
        uint256 stakeIndex = stakingModule.stakeFlexible(maxAmount);

        StakingModule.StakeInfo memory info = stakingModule.getStakeInfo(user1, stakeIndex);
        assertEq(info.amount, uint128(maxAmount));
    }

    function test_checkpointUsers_emptyArray() public {
        address[] memory users = new address[](0);

        vm.prank(keeper);
        stakingModule.checkpointUsers(users); // Should not revert
    }

    // =============================================================================
    // Boundary Condition Tests (Critical Coverage Gaps)
    // =============================================================================

    function test_stake_amountTooLarge_reverts() public {
        uint256 maxAmount = stakingModule.MAX_STAKE_AMOUNT();
        uint256 tooLarge = maxAmount + 1;

        ppt.mint(user1, tooLarge);
        vm.prank(user1);
        ppt.approve(address(stakingModule), tooLarge);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(StakingModule.AmountTooLarge.selector, tooLarge, maxAmount));
        stakingModule.stakeFlexible(tooLarge);
    }

    function test_stakeLocked_amountTooLarge_reverts() public {
        uint256 maxAmount = stakingModule.MAX_STAKE_AMOUNT();
        uint256 tooLarge = maxAmount + 1;

        ppt.mint(user1, tooLarge);
        vm.prank(user1);
        ppt.approve(address(stakingModule), tooLarge);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(StakingModule.AmountTooLarge.selector, tooLarge, maxAmount));
        stakingModule.stakeLocked(tooLarge, 30);
    }

    function test_setPointsRate_tooHigh_reverts() public {
        uint256 maxRate = stakingModule.MAX_POINTS_RATE();
        uint256 minRate = stakingModule.MIN_POINTS_RATE();
        uint256 tooHighRate = maxRate + 1;

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(StakingModule.InvalidPointsRate.selector, tooHighRate, minRate, maxRate));
        stakingModule.setPointsRate(tooHighRate);
    }

    function test_setPointsRate_tooLow_reverts() public {
        uint256 maxRate = stakingModule.MAX_POINTS_RATE();
        uint256 minRate = stakingModule.MIN_POINTS_RATE();
        uint256 tooLowRate = 0; // MIN_POINTS_RATE is 1

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(StakingModule.InvalidPointsRate.selector, tooLowRate, minRate, maxRate));
        stakingModule.setPointsRate(tooLowRate);
    }

    function test_setPpt_notAContract_reverts() public {
        address notContract = makeAddr("notContract");

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(StakingModule.NotAContract.selector, notContract));
        stakingModule.setPpt(notContract);
    }

    function test_setPpt_invalidERC20_reverts() public {
        NonERC20Contract notERC20 = new NonERC20Contract();

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(StakingModule.InvalidERC20.selector, address(notERC20)));
        stakingModule.setPpt(address(notERC20));
    }
}

/// @notice Helper contract that is NOT an ERC20
contract NonERC20Contract {
    // No ERC20 functions
    function foo() external pure returns (uint256) {
        return 42;
    }
}
