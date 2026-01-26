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
    uint256 public constant POINTS_RATE_PER_SECOND = 1e15; // 0.001 points per second

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
        assertEq(stakingModule.VERSION(), "1.3.0");
        assertEq(stakingModule.version(), "1.3.0");
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

    function test_initialization_zeroAddress_keeper_reverts() public {
        StakingModule impl = new StakingModule();

        vm.expectRevert(StakingModule.ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl),
            abi.encodeWithSelector(
                StakingModule.initialize.selector,
                address(ppt),
                admin,
                address(0), // zero keeper
                upgrader,
                POINTS_RATE_PER_SECOND
            )
        );
    }

    function test_initialization_zeroAddress_upgrader_reverts() public {
        StakingModule impl = new StakingModule();

        vm.expectRevert(StakingModule.ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl),
            abi.encodeWithSelector(
                StakingModule.initialize.selector,
                address(ppt),
                admin,
                keeper,
                address(0), // zero upgrader
                POINTS_RATE_PER_SECOND
            )
        );
    }

    function test_initialization_notAContract_reverts() public {
        StakingModule impl = new StakingModule();
        address notContract = makeAddr("notContract");

        vm.expectRevert(abi.encodeWithSelector(StakingModule.NotAContract.selector, notContract));
        new ERC1967Proxy(
            address(impl),
            abi.encodeWithSelector(
                StakingModule.initialize.selector,
                notContract, // not a contract
                admin,
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

    function test_initialization_invalidPointsRate_tooHigh_reverts() public {
        StakingModule impl = new StakingModule();
        uint256 minRate = impl.MIN_POINTS_RATE();
        uint256 maxRate = impl.MAX_POINTS_RATE();

        vm.expectRevert(abi.encodeWithSelector(StakingModule.InvalidPointsRate.selector, maxRate + 1, minRate, maxRate));
        new ERC1967Proxy(
            address(impl),
            abi.encodeWithSelector(
                StakingModule.initialize.selector,
                address(ppt),
                admin,
                keeper,
                upgrader,
                maxRate + 1 // too high
            )
        );
    }

    function test_roles() public view {
        assertTrue(stakingModule.hasRole(stakingModule.ADMIN_ROLE(), admin));
        assertTrue(stakingModule.hasRole(stakingModule.KEEPER_ROLE(), keeper));
        assertTrue(stakingModule.hasRole(stakingModule.UPGRADER_ROLE(), upgrader));
    }

    // =============================================================================
    // Boost Calculation Tests
    // =============================================================================

    function test_calculateBoost_minDuration() public view {
        // 7 days should give ~1.02x boost
        uint256 boost = stakingModule.calculateBoost(7 days);
        // 10000 + (7 * 10000 / 365) = 10000 + 191 = 10191
        assertEq(boost, 10191);
    }

    function test_calculateBoost_90days() public view {
        // 90 days should give ~1.25x boost
        uint256 boost = stakingModule.calculateBoost(90 days);
        // 10000 + (90 * 10000 / 365) = 10000 + 2465 = 12465
        assertEq(boost, 12465);
    }

    function test_calculateBoost_maxDuration() public view {
        // 365 days should give 2.0x boost
        uint256 boost = stakingModule.calculateBoost(365 days);
        // 10000 + (365 * 10000 / 365) = 10000 + 10000 = 20000
        assertEq(boost, 20000);
    }

    function test_calculateBoost_beyondMax() public view {
        // Beyond 365 days should still be 2.0x (capped)
        uint256 boost = stakingModule.calculateBoost(500 days);
        assertEq(boost, 20000);
    }

    function test_calculateBoost_belowMin() public view {
        // Below minimum should return base boost
        uint256 boost = stakingModule.calculateBoost(1 days);
        assertEq(boost, 10000);
    }

    function test_calculateBoostedAmount() public view {
        uint256 amount = 1000e18;
        uint256 boosted = stakingModule.calculateBoostedAmount(amount, 365 days);
        // 2x boost
        assertEq(boosted, 2000e18);
    }

    // =============================================================================
    // Stake Tests
    // =============================================================================

    function test_stake_basic() public {
        uint256 amount = 1000e18;
        uint256 lockDuration = 30 days;
        _mintAndApprove(user1, amount);

        vm.prank(user1);
        uint256 stakeIndex = stakingModule.stake(amount, lockDuration);

        assertEq(stakeIndex, 0);
        assertEq(ppt.balanceOf(address(stakingModule)), amount);
        assertEq(ppt.balanceOf(user1), 0);

        StakingModule.StakeInfo memory info = stakingModule.getStakeInfo(user1, stakeIndex);
        assertEq(info.amount, amount);
        assertEq(info.lockDuration, lockDuration);
        assertTrue(info.isActive);
        assertEq(info.lockEndTime, block.timestamp + lockDuration);

        uint256 expectedBoosted = stakingModule.calculateBoostedAmount(amount, lockDuration);
        assertEq(info.boostedAmount, expectedBoosted);
    }

    function test_stake_multipleStakes() public {
        _mintAndApprove(user1, 3000e18);

        vm.startPrank(user1);

        // First stake
        uint256 idx1 = stakingModule.stake(1000e18, 30 days);
        assertEq(idx1, 0);

        // Second stake
        ppt.approve(address(stakingModule), 2000e18);
        uint256 idx2 = stakingModule.stake(1000e18, 90 days);
        assertEq(idx2, 1);

        // Third stake
        uint256 idx3 = stakingModule.stake(1000e18, 365 days);
        assertEq(idx3, 2);

        vm.stopPrank();

        assertEq(stakingModule.userStakeCount(user1), 3);

        StakingModule.StakeInfo[] memory stakes = stakingModule.getAllStakes(user1);
        assertEq(stakes.length, 3);
        assertEq(stakes[0].lockDuration, 30 days);
        assertEq(stakes[1].lockDuration, 90 days);
        assertEq(stakes[2].lockDuration, 365 days);
    }

    function test_stake_maxStakesReached_reverts() public {
        uint256 maxStakes = stakingModule.MAX_STAKES_PER_USER();
        _mintAndApprove(user1, (maxStakes + 1) * 100e18);

        vm.startPrank(user1);

        // Create max stakes
        for (uint256 i = 0; i < maxStakes; i++) {
            ppt.approve(address(stakingModule), 100e18);
            stakingModule.stake(100e18, 7 days);
        }

        // Next stake should fail
        ppt.approve(address(stakingModule), 100e18);
        vm.expectRevert(abi.encodeWithSelector(StakingModule.MaxStakesReached.selector, maxStakes, maxStakes));
        stakingModule.stake(100e18, 7 days);

        vm.stopPrank();
    }

    function test_stake_zeroAmount_reverts() public {
        vm.prank(user1);
        vm.expectRevert(StakingModule.ZeroAmount.selector);
        stakingModule.stake(0, 30 days);
    }

    function test_stake_invalidLockDuration_reverts() public {
        _mintAndApprove(user1, 1000e18);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(StakingModule.InvalidLockDuration.selector, 1 days, 7 days, 365 days));
        stakingModule.stake(1000e18, 1 days);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(StakingModule.InvalidLockDuration.selector, 400 days, 7 days, 365 days));
        stakingModule.stake(1000e18, 400 days);
    }

    // =============================================================================
    // Unstake Tests
    // =============================================================================

    function test_unstake_afterLockExpired() public {
        uint256 amount = 1000e18;
        uint256 lockDuration = 30 days;
        _mintAndApprove(user1, amount);

        vm.prank(user1);
        uint256 stakeIndex = stakingModule.stake(amount, lockDuration);

        // Advance past lock period
        _advanceTime(lockDuration + 1);
        _advanceBlocks(2);

        vm.prank(user1);
        stakingModule.unstake(stakeIndex);

        assertEq(ppt.balanceOf(user1), amount);
        assertEq(ppt.balanceOf(address(stakingModule)), 0);

        StakingModule.StakeInfo memory info = stakingModule.getStakeInfo(user1, stakeIndex);
        assertFalse(info.isActive);
    }

    function test_unstake_earlyUnlock_withPenalty() public {
        uint256 amount = 1000e18;
        uint256 lockDuration = 30 days;
        _mintAndApprove(user1, amount);

        vm.prank(user1);
        uint256 stakeIndex = stakingModule.stake(amount, lockDuration);

        // Advance halfway through lock period
        _advanceTime(15 days);
        _advanceBlocks(2);

        // Checkpoint to accrue points
        vm.prank(keeper);
        address[] memory users = new address[](1);
        users[0] = user1;
        stakingModule.checkpointUsers(users);

        uint256 pointsBefore = stakingModule.getPoints(user1);
        assertTrue(pointsBefore > 0, "Should have points before unstake");

        // Calculate expected penalty
        uint256 expectedPenalty = stakingModule.calculatePotentialPenalty(user1, stakeIndex);

        vm.prank(user1);
        stakingModule.unstake(stakeIndex);

        uint256 pointsAfter = stakingModule.getPoints(user1);
        assertEq(pointsAfter, pointsBefore - expectedPenalty, "Points should be reduced by penalty");

        // Tokens should still be returned fully
        assertEq(ppt.balanceOf(user1), amount);
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
        uint256 stakeIndex = stakingModule.stake(amount, 7 days);

        // Advance and unstake
        _advanceTime(8 days);
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
        stakingModule.stake(amount, 365 days); // 2x boost

        // Advance 1 day
        _advanceTime(1 days);
        _advanceBlocks(2);

        uint256 points = stakingModule.getPoints(user1);

        // Expected: 1 day * rate = 86400 * 1e15 = 86.4e18 points
        // With 2x boost and being the only staker, should get full points
        uint256 expected = 1 days * POINTS_RATE_PER_SECOND;
        assertEq(points, expected);
    }

    function test_points_proportionalToBoost() public {
        uint256 amount = 1000e18;
        _mintAndApprove(user1, amount);
        _mintAndApprove(user2, amount);

        // User1 stakes with max boost (2x)
        vm.prank(user1);
        stakingModule.stake(amount, 365 days);

        // User2 stakes with min boost (~1.02x)
        vm.prank(user2);
        stakingModule.stake(amount, 7 days);

        // Advance time
        _advanceTime(1 days);
        _advanceBlocks(2);

        uint256 points1 = stakingModule.getPoints(user1);
        uint256 points2 = stakingModule.getPoints(user2);

        // User1 should have ~2x points of User2 (ratio of boosts)
        // User1 boost: 20000, User2 boost: 10191
        // Total boosted: 2000e18 + 1019.1e18 = 3019.1e18
        // User1 share: 2000/3019.1 ≈ 0.6624
        // User2 share: 1019.1/3019.1 ≈ 0.3376
        assertTrue(points1 > points2, "Higher boost should earn more points");

        // Verify ratio approximately equals boost ratio
        uint256 boost1 = stakingModule.calculateBoost(365 days);
        uint256 boost2 = stakingModule.calculateBoost(7 days);
        uint256 expectedRatio = (boost1 * PRECISION) / boost2;
        uint256 actualRatio = (points1 * PRECISION) / points2;

        // Allow 1% tolerance
        assertApproxEqRel(actualRatio, expectedRatio, 0.01e18);
    }

    function test_points_zeroWhenInactive() public {
        uint256 amount = 1000e18;
        _mintAndApprove(user1, amount);

        vm.prank(user1);
        stakingModule.stake(amount, 30 days);

        // Deactivate module
        vm.prank(admin);
        stakingModule.setActive(false);

        // Advance time
        _advanceTime(1 days);

        // Points should not increase
        uint256 pointsBeforeDeactivation = stakingModule.getPoints(user1);

        _advanceTime(1 days);
        uint256 pointsAfter = stakingModule.getPoints(user1);

        assertEq(pointsAfter, pointsBeforeDeactivation);
    }

    // =============================================================================
    // Checkpoint Tests
    // =============================================================================

    function test_checkpointGlobal() public {
        uint256 amount = 1000e18;
        _mintAndApprove(user1, amount);

        vm.prank(user1);
        stakingModule.stake(amount, 30 days);

        _advanceTime(1 days);

        uint256 ppsBeforeCheckpoint = stakingModule.currentPointsPerShare();

        vm.prank(keeper);
        stakingModule.checkpointGlobal();

        uint256 ppsAfter = stakingModule.pointsPerShareStored();
        assertEq(ppsAfter, ppsBeforeCheckpoint);
    }

    function test_checkpointUsers() public {
        uint256 amount = 1000e18;
        _mintAndApprove(user1, amount);
        _mintAndApprove(user2, amount);

        vm.prank(user1);
        stakingModule.stake(amount, 30 days);

        vm.prank(user2);
        stakingModule.stake(amount, 90 days);

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
        stakingModule.stake(amount, 30 days);

        _advanceTime(1 days);
        _advanceBlocks(2);

        vm.prank(user1);
        stakingModule.checkpointSelf();

        assertTrue(stakingModule.getPoints(user1) > 0);
    }

    // =============================================================================
    // Flash Loan Protection Tests
    // =============================================================================

    function test_flashLoanProtection() public {
        uint256 amount = 1000e18;
        _mintAndApprove(user1, amount);

        vm.prank(user1);
        stakingModule.stake(amount, 30 days);

        // Advance time but NOT blocks - this simulates same block
        _advanceTime(1 days);
        // Still block 1, so flash loan protection should prevent points from being credited

        vm.prank(user1);
        stakingModule.checkpointSelf();

        // Flash loan protection triggered - points NOT credited to pointsEarned yet
        // But the pointsPerSharePaid is also NOT updated (v1.2.0 fix), so points are preserved
        (uint256 totalBoosted, uint256 earnedPoints,) = stakingModule.getUserState(user1);
        assertTrue(totalBoosted > 0, "Should have boosted amount");
        // Note: earnedPoints from getUserState calls _calculatePoints which shows pending points
        // But the stored pointsEarned in the struct should still be 0
        (,, uint256 storedPointsEarned,) = stakingModule.userStates(user1);
        assertEq(storedPointsEarned, 0, "Stored pointsEarned should be 0 during flash loan protection");

        // Now advance blocks to pass holding period
        _advanceBlocks(2);

        vm.prank(user1);
        stakingModule.checkpointSelf();

        // Now should have points - the previously blocked points are now credited
        // (no permanent loss due to v1.2.0 fix)
        (,, storedPointsEarned,) = stakingModule.userStates(user1);
        assertTrue(storedPointsEarned > 0, "Should have points after blocks advance");

        // Verify the points match what we expected from 1 day (allow tiny rounding error)
        uint256 expectedPoints = 1 days * POINTS_RATE_PER_SECOND;
        assertApproxEqRel(storedPointsEarned, expectedPoints, 0.0001e18, "Should have all points from 1 day");
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
        stakingModule.stake(1000e18, 30 days);

        // Unpause
        vm.prank(admin);
        stakingModule.unpause();

        // Should work now
        vm.prank(user1);
        stakingModule.stake(1000e18, 30 days);
    }

    // =============================================================================
    // Integration with PointsHub Tests
    // =============================================================================

    function test_pointsHub_integration() public {
        uint256 amount = 1000e18;
        _mintAndApprove(user1, amount);

        vm.prank(user1);
        stakingModule.stake(amount, 365 days);

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
        stakingModule.stake(amount, 365 days);

        (uint256 totalBoosted, uint256 earnedPoints, uint256 activeCount) = stakingModule.getUserState(user1);

        uint256 expectedBoosted = stakingModule.calculateBoostedAmount(amount, 365 days);
        assertEq(totalBoosted, expectedBoosted);
        assertEq(earnedPoints, 0); // No time passed
        assertEq(activeCount, 1);
    }

    function test_getAllStakes() public {
        _mintAndApprove(user1, 2000e18);

        vm.startPrank(user1);
        stakingModule.stake(1000e18, 30 days);
        ppt.approve(address(stakingModule), 1000e18);
        stakingModule.stake(1000e18, 90 days);
        vm.stopPrank();

        StakingModule.StakeInfo[] memory stakes = stakingModule.getAllStakes(user1);
        assertEq(stakes.length, 2);
        assertTrue(stakes[0].isActive);
        assertTrue(stakes[1].isActive);
    }

    function test_estimatePoints() public view {
        uint256 amount = 1000e18;
        uint256 lockDuration = 365 days;
        uint256 holdDuration = 1 days;

        uint256 estimated = stakingModule.estimatePoints(amount, lockDuration, holdDuration);

        // With no existing stakers, should get all points
        uint256 expected = holdDuration * POINTS_RATE_PER_SECOND;
        assertEq(estimated, expected);
    }

    function test_calculatePotentialPenalty() public {
        uint256 amount = 1000e18;
        uint256 lockDuration = 30 days;
        _mintAndApprove(user1, amount);

        vm.prank(user1);
        uint256 stakeIndex = stakingModule.stake(amount, lockDuration);

        // Advance 15 days (halfway)
        _advanceTime(15 days);
        _advanceBlocks(2);

        // Checkpoint to accrue points
        vm.prank(user1);
        stakingModule.checkpointSelf();

        uint256 penalty = stakingModule.calculatePotentialPenalty(user1, stakeIndex);

        // penalty = earnedSinceStake * (remainingTime / lockDuration) * 50%
        // With 15 days remaining out of 30 days, penalty factor = 0.5 * 0.5 = 0.25
        uint256 earnedPoints = stakingModule.getPoints(user1);
        uint256 expectedPenalty = (earnedPoints * 15 days * 5000) / (30 days * 10000);

        assertEq(penalty, expectedPenalty);
    }

    // =============================================================================
    // Edge Cases Tests
    // =============================================================================

    function test_stake_reusesSlotAfterUnstake() public {
        uint256 maxStakes = stakingModule.MAX_STAKES_PER_USER();
        _mintAndApprove(user1, (maxStakes + 1) * 100e18);

        vm.startPrank(user1);

        // Create max stakes
        for (uint256 i = 0; i < maxStakes; i++) {
            ppt.approve(address(stakingModule), 100e18);
            stakingModule.stake(100e18, 7 days);
        }

        // Advance time to unlock
        vm.stopPrank();
        _advanceTime(8 days);
        _advanceBlocks(2);

        // Unstake one
        vm.prank(user1);
        stakingModule.unstake(0);

        // Can still not stake new because slot is not reused (count stays the same)
        vm.prank(user1);
        ppt.approve(address(stakingModule), 100e18);
        vm.expectRevert();
        stakingModule.stake(100e18, 7 days);
    }

    function test_zeroTotalStaked_noPointsAccrued() public view {
        // With no stakers, points per share should remain 0
        uint256 pps = stakingModule.currentPointsPerShare();
        assertEq(pps, 0);
    }

    function test_penalty_cappedAtEarnedPoints() public {
        uint256 amount = 1000e18;
        _mintAndApprove(user1, amount);

        vm.prank(user1);
        stakingModule.stake(amount, 365 days);

        // Advance just 1 second
        _advanceTime(1);
        _advanceBlocks(2);

        vm.prank(user1);
        stakingModule.checkpointSelf();

        uint256 points = stakingModule.getPoints(user1);

        // Unstake immediately - penalty could theoretically be > points
        vm.prank(user1);
        stakingModule.unstake(0);

        // Points should be 0 or capped
        uint256 pointsAfter = stakingModule.getPoints(user1);
        assertTrue(pointsAfter <= points);
    }

    // =============================================================================
    // Fuzz Tests
    // =============================================================================

    function testFuzz_calculateBoost(uint256 duration) public view {
        uint256 boost = stakingModule.calculateBoost(duration);

        // Boost should always be >= BOOST_BASE
        assertTrue(boost >= BOOST_BASE);

        // Boost should never exceed 2x
        assertTrue(boost <= 2 * BOOST_BASE);
    }

    function testFuzz_stake(uint256 amount, uint256 lockDuration) public {
        // Bound inputs
        amount = bound(amount, 1e18, 1e30);
        lockDuration = bound(lockDuration, 7 days, 365 days);

        _mintAndApprove(user1, amount);

        vm.prank(user1);
        uint256 stakeIndex = stakingModule.stake(amount, lockDuration);

        assertEq(stakeIndex, 0);
        assertEq(ppt.balanceOf(address(stakingModule)), amount);

        StakingModule.StakeInfo memory info = stakingModule.getStakeInfo(user1, stakeIndex);
        assertEq(info.amount, amount);
        assertTrue(info.isActive);
    }

    function testFuzz_pointsAccumulation(uint256 amount, uint256 duration) public {
        // Bound inputs
        amount = bound(amount, 1e18, 1e24);
        duration = bound(duration, 1 hours, 30 days);

        _mintAndApprove(user1, amount);

        vm.prank(user1);
        stakingModule.stake(amount, 30 days);

        _advanceTime(duration);
        _advanceBlocks(2);

        uint256 points = stakingModule.getPoints(user1);

        // Points should be approximately duration * rate
        uint256 expected = duration * POINTS_RATE_PER_SECOND;
        assertApproxEqRel(points, expected, 0.01e18); // 1% tolerance
    }

    // =============================================================================
    // New Error Types Tests (v1.1.0)
    // =============================================================================

    function test_stake_amountTooLarge_reverts() public {
        uint256 maxAmount = stakingModule.MAX_STAKE_AMOUNT();
        uint256 tooLarge = maxAmount + 1;

        ppt.mint(user1, tooLarge);
        vm.prank(user1);
        ppt.approve(address(stakingModule), tooLarge);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(StakingModule.AmountTooLarge.selector, tooLarge, maxAmount));
        stakingModule.stake(tooLarge, 30 days);
    }

    function test_setPointsRate_invalidRate_reverts() public {
        uint256 minRate = stakingModule.MIN_POINTS_RATE();
        uint256 maxRate = stakingModule.MAX_POINTS_RATE();

        // Test rate = 0 (below min)
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(StakingModule.InvalidPointsRate.selector, 0, minRate, maxRate));
        stakingModule.setPointsRate(0);

        // Test rate > max
        uint256 tooHighRate = maxRate + 1;
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(StakingModule.InvalidPointsRate.selector, tooHighRate, minRate, maxRate));
        stakingModule.setPointsRate(tooHighRate);
    }

    function test_setPpt_notAContract_reverts() public {
        address notContract = makeAddr("notContract");

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(StakingModule.NotAContract.selector, notContract));
        stakingModule.setPpt(notContract);
    }

    function test_calculatePotentialPenalty_stakeNotFound_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(StakingModule.StakeNotFound.selector, 0));
        stakingModule.calculatePotentialPenalty(user1, 0);
    }

    function test_calculatePotentialPenalty_stakeNotActive_reverts() public {
        uint256 amount = 1000e18;
        _mintAndApprove(user1, amount);

        vm.prank(user1);
        uint256 stakeIndex = stakingModule.stake(amount, 7 days);

        // Unstake
        _advanceTime(8 days);
        _advanceBlocks(2);

        vm.prank(user1);
        stakingModule.unstake(stakeIndex);

        // Now calculatePotentialPenalty should revert
        vm.expectRevert(abi.encodeWithSelector(StakingModule.StakeNotActive.selector, stakeIndex));
        stakingModule.calculatePotentialPenalty(user1, stakeIndex);
    }

    // =============================================================================
    // New Validation Behavior Tests (v1.1.0)
    // =============================================================================

    function test_estimatePoints_invalidLockDuration_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(StakingModule.InvalidLockDuration.selector, 1 days, 7 days, 365 days));
        stakingModule.estimatePoints(1000e18, 1 days, 30 days);
    }

    function test_checkpointUsers_skipsZeroAddress() public {
        uint256 amount = 1000e18;
        _mintAndApprove(user1, amount);

        vm.prank(user1);
        stakingModule.stake(amount, 30 days);

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
    // KEEPER_ROLE Authorization Tests
    // =============================================================================

    function test_checkpointGlobal_unauthorized_reverts() public {
        vm.prank(user1);
        vm.expectRevert();
        stakingModule.checkpointGlobal();

        vm.prank(admin);
        vm.expectRevert();
        stakingModule.checkpointGlobal();
    }

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
    // checkpoint(address) Function Tests
    // =============================================================================

    function test_checkpoint_anyoneCanCall() public {
        uint256 amount = 1000e18;
        _mintAndApprove(user1, amount);

        vm.prank(user1);
        stakingModule.stake(amount, 30 days);

        _advanceTime(1 days);
        _advanceBlocks(2);

        // Anyone can checkpoint any user
        vm.prank(user2);
        stakingModule.checkpoint(user1);

        assertTrue(stakingModule.getPoints(user1) > 0);
    }

    // =============================================================================
    // Event Emission Tests
    // =============================================================================

    function test_stake_emitsEvent() public {
        uint256 amount = 1000e18;
        uint256 lockDuration = 30 days;
        _mintAndApprove(user1, amount);

        uint256 expectedBoosted = stakingModule.calculateBoostedAmount(amount, lockDuration);
        uint256 expectedLockEndTime = block.timestamp + lockDuration;

        vm.expectEmit(true, true, false, true);
        emit StakingModule.Staked(user1, 0, amount, lockDuration, expectedBoosted, expectedLockEndTime);

        vm.prank(user1);
        stakingModule.stake(amount, lockDuration);
    }

    function test_unstake_emitsEvent_noEarlyUnlock() public {
        uint256 amount = 1000e18;
        uint256 lockDuration = 7 days;
        _mintAndApprove(user1, amount);

        vm.prank(user1);
        uint256 stakeIndex = stakingModule.stake(amount, lockDuration);

        // Advance past lock period
        _advanceTime(lockDuration + 1);
        _advanceBlocks(2);

        vm.expectEmit(true, true, false, true);
        emit StakingModule.Unstaked(user1, stakeIndex, amount, 0, 0, false, false);

        vm.prank(user1);
        stakingModule.unstake(stakeIndex);
    }

    function test_unstake_emitsEvent_earlyUnlock() public {
        uint256 amount = 1000e18;
        uint256 lockDuration = 30 days;
        _mintAndApprove(user1, amount);

        vm.prank(user1);
        uint256 stakeIndex = stakingModule.stake(amount, lockDuration);

        // Advance halfway and checkpoint to accrue points
        _advanceTime(15 days);
        _advanceBlocks(2);

        vm.prank(keeper);
        address[] memory users = new address[](1);
        users[0] = user1;
        stakingModule.checkpointUsers(users);

        // Early unstake - expect isEarlyUnlock = true
        vm.prank(user1);
        stakingModule.unstake(stakeIndex);

        // We just verify it doesn't revert; exact event values depend on points accrued
    }

    function test_flashLoanProtection_emitsEvent() public {
        uint256 amount = 1000e18;
        _mintAndApprove(user1, amount);

        vm.prank(user1);
        stakingModule.stake(amount, 30 days);

        // Advance time but NOT blocks - should trigger flash loan protection
        _advanceTime(1 days);

        vm.expectEmit(true, false, false, true);
        emit StakingModule.FlashLoanProtectionTriggered(user1, 1); // 1 block remaining

        vm.prank(user1);
        stakingModule.checkpointSelf();
    }

    // =============================================================================
    // Penalty Cap Verification Tests
    // =============================================================================

    function test_penalty_cappedAtEarnedPoints_verifyEvent() public {
        uint256 amount = 1000e18;
        _mintAndApprove(user1, amount);

        vm.prank(user1);
        uint256 stakeIndex = stakingModule.stake(amount, 365 days);

        // Advance just 1 second to earn minimal points
        _advanceTime(1);
        _advanceBlocks(2);

        vm.prank(user1);
        stakingModule.checkpointSelf();

        uint256 earnedPoints = stakingModule.getPoints(user1);
        uint256 theoreticalPenalty = stakingModule.calculatePotentialPenalty(user1, stakeIndex);

        // If theoretical penalty > earned points, actual penalty should be capped
        bool expectCapped = theoreticalPenalty > earnedPoints;

        vm.prank(user1);
        stakingModule.unstake(stakeIndex);

        // After unstake with capping, points should be 0
        uint256 pointsAfter = stakingModule.getPoints(user1);
        if (expectCapped) {
            assertEq(pointsAfter, 0, "Points should be 0 when penalty capped");
        } else {
            assertEq(pointsAfter, earnedPoints - theoreticalPenalty, "Points should be reduced by penalty");
        }
    }

    function test_penalty_notCapped_partialDeduction() public {
        uint256 amount = 1000e18;
        _mintAndApprove(user1, amount);

        vm.prank(user1);
        uint256 stakeIndex = stakingModule.stake(amount, 30 days);

        // Advance 25 days - most of lock period, so penalty will be small
        _advanceTime(25 days);
        _advanceBlocks(2);

        vm.prank(user1);
        stakingModule.checkpointSelf();

        uint256 earnedPoints = stakingModule.getPoints(user1);
        uint256 theoreticalPenalty = stakingModule.calculatePotentialPenalty(user1, stakeIndex);

        // With 25/30 days passed, remaining ratio is 5/30 = 1/6
        // Penalty should be small relative to earned points
        assertTrue(theoreticalPenalty < earnedPoints, "Penalty should be less than earned points");

        vm.prank(user1);
        stakingModule.unstake(stakeIndex);

        uint256 pointsAfter = stakingModule.getPoints(user1);
        assertEq(pointsAfter, earnedPoints - theoreticalPenalty, "Points should be reduced by exact penalty");
        assertTrue(pointsAfter > 0, "Should have remaining points");
    }

    // =============================================================================
    // Edge Case Tests (Additional)
    // =============================================================================

    function test_setPointsRate_validBounds() public {
        uint256 minRate = stakingModule.MIN_POINTS_RATE();
        uint256 maxRate = stakingModule.MAX_POINTS_RATE();

        // Test min rate
        vm.prank(admin);
        stakingModule.setPointsRate(minRate);
        assertEq(stakingModule.pointsRatePerSecond(), minRate);

        // Test max rate
        vm.prank(admin);
        stakingModule.setPointsRate(maxRate);
        assertEq(stakingModule.pointsRatePerSecond(), maxRate);
    }

    function test_setPpt_validContract() public {
        MockStakingPPT newPpt = new MockStakingPPT();

        vm.prank(admin);
        stakingModule.setPpt(address(newPpt));

        assertEq(address(stakingModule.ppt()), address(newPpt));
    }

    // =============================================================================
    // Flash Loan Protection - No Point Loss Tests (v1.2.0)
    // =============================================================================

    /// @notice Verify flash loan protection does not cause permanent point loss
    /// @dev This is a regression test for the v1.1.0 bug where pointsPerSharePaid
    ///      was updated even when points weren't credited, causing permanent loss
    function test_flashLoanProtection_noPointLoss() public {
        uint256 amount = 1000e18;
        _mintAndApprove(user1, amount);

        vm.prank(user1);
        stakingModule.stake(amount, 30 days);

        // Record the expected points for 5 days
        uint256 expectedPointsFor5Days = 5 days * POINTS_RATE_PER_SECOND;

        // Advance time 5 days but stay in same block (flash loan scenario)
        _advanceTime(5 days);

        // Checkpoint multiple times in same block - this would lose points in v1.1.0
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(user1);
            stakingModule.checkpointSelf();
        }

        // Verify no points credited yet (stored in struct)
        (,, uint256 storedPointsEarned,) = stakingModule.userStates(user1);
        assertEq(storedPointsEarned, 0, "No points should be credited during flash loan protection");

        // Now advance blocks to pass holding period
        _advanceBlocks(2);

        // Checkpoint to credit points
        vm.prank(user1);
        stakingModule.checkpointSelf();

        // ALL points should now be credited (no loss, allow tiny rounding error)
        (,, storedPointsEarned,) = stakingModule.userStates(user1);
        assertApproxEqRel(
            storedPointsEarned,
            expectedPointsFor5Days,
            0.0001e18,
            "All points from 5 days should be credited without loss"
        );
    }

    /// @notice Test that pointsPerSharePaid is only updated when points are credited
    function test_flashLoanProtection_pointsPerSharePaidPreserved() public {
        uint256 amount = 1000e18;
        _mintAndApprove(user1, amount);

        vm.prank(user1);
        stakingModule.stake(amount, 30 days);

        // Get initial pointsPerSharePaid (should be 0 after stake)
        (, uint256 initialPPS,,) = stakingModule.userStates(user1);
        assertEq(initialPPS, 0, "Initial pointsPerSharePaid should be 0");

        // Advance time but stay in same block
        _advanceTime(1 days);

        // Checkpoint - flash loan protection should trigger
        vm.prank(user1);
        stakingModule.checkpointSelf();

        // pointsPerSharePaid should NOT be updated (v1.2.0 fix)
        (, uint256 ppsAfterProtection,,) = stakingModule.userStates(user1);
        assertEq(ppsAfterProtection, initialPPS, "pointsPerSharePaid should not change during flash loan protection");

        // Advance blocks
        _advanceBlocks(2);

        // Checkpoint again - now points should be credited
        vm.prank(user1);
        stakingModule.checkpointSelf();

        // NOW pointsPerSharePaid should be updated
        (, uint256 ppsAfterCredit,,) = stakingModule.userStates(user1);
        assertTrue(ppsAfterCredit > initialPPS, "pointsPerSharePaid should be updated after points credited");
    }

    /// @notice Test multiple flash loan protection cycles
    function test_flashLoanProtection_multipleProtectionCycles() public {
        uint256 amount = 1000e18;
        _mintAndApprove(user1, amount);

        vm.prank(user1);
        stakingModule.stake(amount, 30 days);

        // First cycle: 1 day with protection
        _advanceTime(1 days);
        vm.prank(user1);
        stakingModule.checkpointSelf(); // Protection triggered

        // Pass holding period and credit points
        _advanceBlocks(2);
        vm.prank(user1);
        stakingModule.checkpointSelf();

        (,, uint256 pointsAfterCycle1,) = stakingModule.userStates(user1);
        uint256 expectedPoints1 = 1 days * POINTS_RATE_PER_SECOND;
        assertApproxEqRel(pointsAfterCycle1, expectedPoints1, 0.0001e18, "Should have 1 day of points after cycle 1");

        // Second cycle: 2 more days with protection (staying in same block)
        _advanceTime(2 days);
        vm.prank(user1);
        stakingModule.checkpointSelf(); // Protection triggered

        // Pass holding period
        _advanceBlocks(2);
        vm.prank(user1);
        stakingModule.checkpointSelf();

        (,, uint256 pointsAfterCycle2,) = stakingModule.userStates(user1);
        uint256 expectedPoints2 = 3 days * POINTS_RATE_PER_SECOND; // Total 3 days
        assertApproxEqRel(pointsAfterCycle2, expectedPoints2, 0.0001e18, "Should have 3 days of points after cycle 2");
    }

    // =============================================================================
    // Additional Edge Case Tests
    // =============================================================================

    function test_estimatePoints_zeroAmount_reverts() public {
        vm.expectRevert(StakingModule.ZeroAmount.selector);
        stakingModule.estimatePoints(0, 30 days, 1 days);
    }

    function test_estimatePoints_withExistingStakers() public {
        uint256 amount = 1000e18;
        _mintAndApprove(user1, amount);

        // User1 stakes first
        vm.prank(user1);
        stakingModule.stake(amount, 365 days);

        // Estimate for user2 with same parameters
        uint256 estimated = stakingModule.estimatePoints(amount, 365 days, 1 days);

        // With existing stakers, new staker gets proportional share
        uint256 newBoosted = stakingModule.calculateBoostedAmount(amount, 365 days);
        uint256 totalBoosted = stakingModule.totalBoostedStaked();
        uint256 totalWithNew = totalBoosted + newBoosted;
        uint256 expectedPoints = (newBoosted * 1 days * POINTS_RATE_PER_SECOND) / totalWithNew;

        assertEq(estimated, expectedPoints, "Should get proportional share with existing stakers");
    }

    // =============================================================================
    // v1.3.0 New Features Tests
    // =============================================================================

    /// @notice Test calculateBoostStrict reverts on invalid duration
    function test_calculateBoostStrict_reverts_belowMin() public {
        vm.expectRevert(abi.encodeWithSelector(StakingModule.InvalidLockDuration.selector, 1 days, 7 days, 365 days));
        stakingModule.calculateBoostStrict(1 days);
    }

    function test_calculateBoostStrict_reverts_aboveMax() public {
        vm.expectRevert(abi.encodeWithSelector(StakingModule.InvalidLockDuration.selector, 400 days, 7 days, 365 days));
        stakingModule.calculateBoostStrict(400 days);
    }

    function test_calculateBoostStrict_validRange() public view {
        uint256 boost7d = stakingModule.calculateBoostStrict(7 days);
        uint256 boost365d = stakingModule.calculateBoostStrict(365 days);

        assertGt(boost7d, BOOST_BASE);
        assertEq(boost365d, 2 * BOOST_BASE);
    }

    /// @notice Test InvalidERC20 error on initialize
    function test_initialization_invalidERC20_reverts() public {
        // Deploy a contract that doesn't implement ERC20
        NonERC20Contract nonErc20 = new NonERC20Contract();
        StakingModule impl = new StakingModule();

        vm.expectRevert(abi.encodeWithSelector(StakingModule.InvalidERC20.selector, address(nonErc20)));
        new ERC1967Proxy(
            address(impl),
            abi.encodeWithSelector(
                StakingModule.initialize.selector,
                address(nonErc20),
                admin,
                keeper,
                upgrader,
                POINTS_RATE_PER_SECOND
            )
        );
    }

    /// @notice Test InvalidERC20 error on setPpt
    function test_setPpt_invalidERC20_reverts() public {
        NonERC20Contract nonErc20 = new NonERC20Contract();

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(StakingModule.InvalidERC20.selector, address(nonErc20)));
        stakingModule.setPpt(address(nonErc20));
    }

    /// @notice Test ZeroAddressSkipped event
    function test_checkpointUsers_emitsZeroAddressSkipped() public {
        uint256 amount = 1000e18;
        _mintAndApprove(user1, amount);

        vm.prank(user1);
        stakingModule.stake(amount, 30 days);

        _advanceTime(1 days);
        _advanceBlocks(2);

        address[] memory users = new address[](3);
        users[0] = user1;
        users[1] = address(0);
        users[2] = user2;

        vm.expectEmit(true, false, false, false);
        emit StakingModule.ZeroAddressSkipped(1);

        vm.prank(keeper);
        stakingModule.checkpointUsers(users);
    }

    /// @notice Test checkpointSelf returns pointsCredited
    function test_checkpointSelf_returnsPointsCredited() public {
        uint256 amount = 1000e18;
        _mintAndApprove(user1, amount);

        vm.prank(user1);
        stakingModule.stake(amount, 30 days);

        // Same block - should return false (flash loan protection)
        _advanceTime(1 days);

        vm.prank(user1);
        bool credited = stakingModule.checkpointSelf();
        assertFalse(credited, "Should return false when flash loan protection triggers");

        // Advance blocks - should return true
        _advanceBlocks(2);

        vm.prank(user1);
        credited = stakingModule.checkpointSelf();
        assertTrue(credited, "Should return true when points credited");
    }

    /// @notice Test checkpoint returns pointsCredited
    function test_checkpoint_returnsPointsCredited() public {
        uint256 amount = 1000e18;
        _mintAndApprove(user1, amount);

        vm.prank(user1);
        stakingModule.stake(amount, 30 days);

        _advanceTime(1 days);
        _advanceBlocks(2);

        vm.prank(user2);
        bool credited = stakingModule.checkpoint(user1);
        assertTrue(credited, "Should return true when points credited");
    }

    /// @notice Test UserCheckpointed event includes pointsCredited
    function test_userCheckpointed_emitsPointsCredited() public {
        uint256 amount = 1000e18;
        _mintAndApprove(user1, amount);

        vm.prank(user1);
        stakingModule.stake(amount, 30 days);

        _advanceTime(1 days);
        _advanceBlocks(2);

        // Expect event with pointsCredited = true
        vm.expectEmit(true, false, false, false);
        emit StakingModule.UserCheckpointed(user1, 0, 0, 0, true);

        vm.prank(user1);
        stakingModule.checkpointSelf();
    }

    /// @notice Test boundary values
    function test_stake_exactlyAtMinLockDuration() public {
        uint256 amount = 1000e18;
        _mintAndApprove(user1, amount);

        vm.prank(user1);
        uint256 stakeIndex = stakingModule.stake(amount, 7 days);

        StakingModule.StakeInfo memory info = stakingModule.getStakeInfo(user1, stakeIndex);
        assertEq(info.lockDuration, 7 days);
    }

    function test_stake_exactlyAtMaxLockDuration() public {
        uint256 amount = 1000e18;
        _mintAndApprove(user1, amount);

        vm.prank(user1);
        uint256 stakeIndex = stakingModule.stake(amount, 365 days);

        StakingModule.StakeInfo memory info = stakingModule.getStakeInfo(user1, stakeIndex);
        assertEq(info.lockDuration, 365 days);
        assertEq(info.boostedAmount, 2 * amount); // 2x boost
    }

    function test_stake_exactlyAtMaxStakeAmount() public {
        uint256 maxAmount = stakingModule.MAX_STAKE_AMOUNT();

        ppt.mint(user1, maxAmount);
        vm.prank(user1);
        ppt.approve(address(stakingModule), maxAmount);

        vm.prank(user1);
        uint256 stakeIndex = stakingModule.stake(maxAmount, 7 days);

        StakingModule.StakeInfo memory info = stakingModule.getStakeInfo(user1, stakeIndex);
        assertEq(info.amount, uint128(maxAmount));
    }

    /// @notice Test empty array in checkpointUsers
    function test_checkpointUsers_emptyArray() public {
        address[] memory users = new address[](0);

        vm.prank(keeper);
        stakingModule.checkpointUsers(users); // Should not revert
    }
}

/// @notice Helper contract that is NOT an ERC20
contract NonERC20Contract {
    // No ERC20 functions
    function foo() external pure returns (uint256) {
        return 42;
    }
}
