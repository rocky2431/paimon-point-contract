// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IPointsModule} from "./interfaces/IPointsModule.sol";

/// @title StakingModule
/// @author Paimon Protocol
/// @notice Points module for PPT staking with time-locked boost
/// @dev Uses Synthetix-style rewards with boost based on lock duration
///      Replaces HoldingModule for users who want enhanced points via staking
///      Note: MAX_STAKES_PER_USER (10) is a lifetime limit per address.
///      Once a user creates 10 stakes, they cannot create more even after unstaking.
///      Users needing more stakes should use a new address.
contract StakingModule is
    IPointsModule,
    Initializable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    // =============================================================================
    // Constants & Roles
    // =============================================================================

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    uint256 public constant PRECISION = 1e18;
    uint256 public constant BOOST_BASE = 10000; // 1x = 10000, 2x = 20000
    uint256 public constant MAX_EXTRA_BOOST = 10000; // Max extra 1x (total 2x)
    uint256 public constant MIN_LOCK_DURATION = 7 days;
    uint256 public constant MAX_LOCK_DURATION = 365 days;
    uint256 public constant EARLY_UNLOCK_PENALTY_BPS = 5000; // 50%
    uint256 public constant MAX_STAKES_PER_USER = 10;

    string public constant MODULE_NAME = "PPT Staking";
    string public constant VERSION = "1.3.0";

    uint256 public constant MAX_BATCH_USERS = 100;

    /// @notice Maximum stake amount to prevent uint128 overflow (with 2x boost headroom)
    uint256 public constant MAX_STAKE_AMOUNT = type(uint128).max / 2;

    /// @notice Minimum points rate per second
    uint256 public constant MIN_POINTS_RATE = 1;

    /// @notice Maximum points rate per second (prevents overflow in calculations)
    uint256 public constant MAX_POINTS_RATE = 1e24;

    // =============================================================================
    // Data Structures
    // =============================================================================

    /// @notice Individual stake record
    /// @dev Optimized packing into 2 storage slots:
    ///      slot1 = amount(128) + boostedAmount(128) = 256 bits
    ///      slot2 = pointsEarnedAtStake(128) + lockEndTime(64) + lockDuration(56) + isActive(8) = 256 bits
    struct StakeInfo {
        uint128 amount; // Staked amount
        uint128 boostedAmount; // amount * boost / BOOST_BASE
        uint128 pointsEarnedAtStake; // Points earned at stake time (for penalty calc)
        uint64 lockEndTime; // When lock expires
        uint56 lockDuration; // Lock duration in seconds (max ~2.28e9 years, limited by MAX_LOCK_DURATION)
        bool isActive; // Whether stake is active
    }

    /// @notice Aggregated user state for O(1) getPoints
    struct UserState {
        uint256 totalBoostedAmount; // Sum of all active stakes' boostedAmount
        uint256 pointsPerSharePaid; // Last checkpoint pointsPerShare
        uint256 pointsEarned; // Accumulated points (net of penalties)
        uint256 lastCheckpointBlock; // For flash loan protection
    }

    // =============================================================================
    // State Variables
    // =============================================================================

    /// @notice PPT token contract
    IERC20 public ppt;

    /// @notice Points generated per second per boosted PPT share (1e18 precision)
    uint256 public pointsRatePerSecond;

    /// @notice Last time the global state was updated
    uint256 public lastUpdateTime;

    /// @notice Accumulated points per boosted share (1e18 precision)
    uint256 public pointsPerShareStored;

    /// @notice Total boosted amount staked across all users
    uint256 public totalBoostedStaked;

    /// @notice User state mapping
    mapping(address => UserState) public userStates;

    /// @notice User stakes: user => stakeIndex => StakeInfo
    mapping(address => mapping(uint256 => StakeInfo)) public userStakes;

    /// @notice Number of stakes per user (including inactive)
    mapping(address => uint256) public userStakeCount;

    /// @notice Whether the module is active
    bool public active;

    /// @notice Minimum blocks required before points are credited (flash loan protection)
    uint256 public minHoldingBlocks;

    // =============================================================================
    // Events
    // =============================================================================

    event Staked(
        address indexed user,
        uint256 indexed stakeIndex,
        uint256 amount,
        uint256 lockDuration,
        uint256 boostedAmount,
        uint256 lockEndTime
    );

    /// @notice Emitted when a user unstakes
    /// @param user The user address
    /// @param stakeIndex The stake index
    /// @param amount The staked amount returned
    /// @param actualPenalty The penalty actually applied (may be capped)
    /// @param theoreticalPenalty The calculated penalty before capping
    /// @param isEarlyUnlock Whether this was an early unlock
    /// @param penaltyWasCapped Whether the penalty was capped at earned points
    event Unstaked(
        address indexed user,
        uint256 indexed stakeIndex,
        uint256 amount,
        uint256 actualPenalty,
        uint256 theoreticalPenalty,
        bool isEarlyUnlock,
        bool penaltyWasCapped
    );

    event GlobalCheckpointed(uint256 pointsPerShare, uint256 timestamp, uint256 totalBoostedStaked);

    event UserCheckpointed(
        address indexed user, uint256 pointsEarned, uint256 totalBoostedAmount, uint256 timestamp, bool pointsCredited
    );

    /// @notice Emitted when flash loan protection prevents points from being credited
    /// @param user The user address
    /// @param blocksRemaining Blocks remaining before points can be credited
    event FlashLoanProtectionTriggered(address indexed user, uint256 blocksRemaining);

    /// @notice Emitted when a zero address is skipped in batch checkpoint
    /// @param position Position in the batch array
    event ZeroAddressSkipped(uint256 indexed position);

    event PointsRateUpdated(uint256 oldRate, uint256 newRate);
    event ModuleActiveStatusUpdated(bool active);
    event StakingModuleUpgraded(address indexed newImplementation, uint256 timestamp);
    event MinHoldingBlocksUpdated(uint256 oldBlocks, uint256 newBlocks);
    event PptUpdated(address indexed oldPpt, address indexed newPpt);

    // =============================================================================
    // Errors
    // =============================================================================

    error ZeroAddress();
    error ZeroAmount();
    error InvalidLockDuration(uint256 duration, uint256 min, uint256 max);
    error MaxStakesReached(uint256 current, uint256 max);
    error StakeNotFound(uint256 stakeIndex);
    error StakeNotActive(uint256 stakeIndex);
    error BatchTooLarge(uint256 size, uint256 max);

    /// @notice Amount exceeds maximum allowed to prevent overflow
    error AmountTooLarge(uint256 amount, uint256 max);

    /// @notice Points rate is outside valid range
    error InvalidPointsRate(uint256 rate, uint256 min, uint256 max);

    /// @notice Address is not a contract
    error NotAContract(address addr);

    /// @notice Address does not implement ERC20 interface
    error InvalidERC20(address addr);

    /// @notice Points overflow detected (should never happen under normal operation)
    error PointsOverflow(uint256 points);

    /// @notice Hold duration exceeds lock duration
    error InvalidHoldDuration(uint256 holdDuration, uint256 lockDuration);

    // =============================================================================
    // Constructor & Initializer
    // =============================================================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the contract
    /// @param _ppt PPT token address (must be a valid ERC20 contract)
    /// @param admin Admin address
    /// @param keeper Keeper address (for checkpoints)
    /// @param upgrader Upgrader address (typically timelock)
    /// @param _pointsRatePerSecond Initial points rate per second per boosted PPT
    function initialize(address _ppt, address admin, address keeper, address upgrader, uint256 _pointsRatePerSecond)
        external
        initializer
    {
        if (_ppt == address(0) || admin == address(0) || keeper == address(0) || upgrader == address(0)) {
            revert ZeroAddress();
        }
        if (_ppt.code.length == 0) {
            revert NotAContract(_ppt);
        }
        // Validate ERC20 interface
        _validateERC20(_ppt);
        if (_pointsRatePerSecond < MIN_POINTS_RATE || _pointsRatePerSecond > MAX_POINTS_RATE) {
            revert InvalidPointsRate(_pointsRatePerSecond, MIN_POINTS_RATE, MAX_POINTS_RATE);
        }

        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        ppt = IERC20(_ppt);
        pointsRatePerSecond = _pointsRatePerSecond;
        lastUpdateTime = block.timestamp;
        active = true;
        minHoldingBlocks = 1;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);
        _grantRole(KEEPER_ROLE, keeper);
        _grantRole(UPGRADER_ROLE, upgrader);
    }

    /// @notice Validate that an address implements ERC20 interface
    /// @param token Token address to validate
    function _validateERC20(address token) internal view {
        // Check basic ERC20 functions exist by calling view functions
        try IERC20(token).totalSupply() returns (uint256) {
            // Valid - has totalSupply
        } catch {
            revert InvalidERC20(token);
        }
    }

    // =============================================================================
    // UUPS Upgrade
    // =============================================================================

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {
        emit StakingModuleUpgraded(newImplementation, block.timestamp);
    }

    // =============================================================================
    // Core Logic - Boost Calculation
    // =============================================================================

    /// @notice Calculate boost multiplier based on lock duration (lenient version)
    /// @param lockDuration Lock duration in seconds
    /// @return boost Boost multiplier (BOOST_BASE = 1x)
    /// @dev Linear: 7 days = 1.02x, 365 days = 2.0x
    ///      Returns BOOST_BASE for duration < MIN_LOCK_DURATION
    ///      Caps at MAX_LOCK_DURATION for duration > MAX_LOCK_DURATION
    function calculateBoost(uint256 lockDuration) public pure returns (uint256 boost) {
        if (lockDuration < MIN_LOCK_DURATION) {
            return BOOST_BASE;
        }
        if (lockDuration > MAX_LOCK_DURATION) {
            lockDuration = MAX_LOCK_DURATION;
        }

        uint256 extraBoost = (lockDuration * MAX_EXTRA_BOOST) / MAX_LOCK_DURATION;
        return BOOST_BASE + extraBoost;
    }

    /// @notice Calculate boost multiplier with strict validation
    /// @param lockDuration Lock duration in seconds
    /// @return boost Boost multiplier (BOOST_BASE = 1x)
    /// @dev Reverts if duration is outside valid range
    function calculateBoostStrict(uint256 lockDuration) public pure returns (uint256 boost) {
        if (lockDuration < MIN_LOCK_DURATION || lockDuration > MAX_LOCK_DURATION) {
            revert InvalidLockDuration(lockDuration, MIN_LOCK_DURATION, MAX_LOCK_DURATION);
        }

        uint256 extraBoost = (lockDuration * MAX_EXTRA_BOOST) / MAX_LOCK_DURATION;
        return BOOST_BASE + extraBoost;
    }

    /// @notice Calculate boosted amount
    /// @param amount Raw staked amount
    /// @param lockDuration Lock duration in seconds
    /// @return Boosted amount
    function calculateBoostedAmount(uint256 amount, uint256 lockDuration) public pure returns (uint256) {
        uint256 boost = calculateBoost(lockDuration);
        return (amount * boost) / BOOST_BASE;
    }

    // =============================================================================
    // Core Logic - Points Calculation
    // =============================================================================

    /// @notice Calculate current points per share
    /// @return Current accumulated points per boosted share
    function _currentPointsPerShare() internal view returns (uint256) {
        if (!active) return pointsPerShareStored;
        if (totalBoostedStaked == 0) return pointsPerShareStored;

        uint256 timeDelta = block.timestamp - lastUpdateTime;
        uint256 newPoints = timeDelta * pointsRatePerSecond;

        return pointsPerShareStored + (newPoints * PRECISION) / totalBoostedStaked;
    }

    /// @notice Update global state
    function _updateGlobal() internal {
        pointsPerShareStored = _currentPointsPerShare();
        lastUpdateTime = block.timestamp;

        emit GlobalCheckpointed(pointsPerShareStored, block.timestamp, totalBoostedStaked);
    }

    /// @notice Update user state
    /// @param user User address to update
    /// @return pointsCredited Whether points were credited (false if flash loan protection triggered)
    /// @dev IMPORTANT: pointsPerSharePaid is only updated when points are successfully credited.
    ///      This ensures flash loan protection doesn't cause permanent point loss.
    function _updateUser(address user) internal returns (bool pointsCredited) {
        UserState storage state = userStates[user];
        uint256 cachedPointsPerShare = pointsPerShareStored;
        uint256 lastCheckpointBlock = state.lastCheckpointBlock;

        // Flash loan protection
        bool passedHoldingPeriod = lastCheckpointBlock == 0 || block.number >= lastCheckpointBlock + minHoldingBlocks;

        // Calculate new earned points using boosted amount
        if (state.totalBoostedAmount > 0 && passedHoldingPeriod) {
            uint256 pointsDelta = cachedPointsPerShare - state.pointsPerSharePaid;
            uint256 newEarned = (state.totalBoostedAmount * pointsDelta) / PRECISION;
            state.pointsEarned += newEarned;
            // Only update pointsPerSharePaid when points are actually credited
            state.pointsPerSharePaid = cachedPointsPerShare;
            pointsCredited = true;
        } else if (state.totalBoostedAmount > 0 && !passedHoldingPeriod) {
            // Emit event when flash loan protection triggers
            // NOTE: pointsPerSharePaid is NOT updated here, so points are preserved for later
            uint256 blocksRemaining = (lastCheckpointBlock + minHoldingBlocks) - block.number;
            emit FlashLoanProtectionTriggered(user, blocksRemaining);
            pointsCredited = false;
        }

        // Always update lastCheckpointBlock to track the holding period
        state.lastCheckpointBlock = block.number;

        emit UserCheckpointed(user, state.pointsEarned, state.totalBoostedAmount, block.timestamp, pointsCredited);
    }

    /// @notice Internal calculation of user points (view)
    /// @param user User address
    /// @return Total accumulated points
    function _calculatePoints(address user) internal view returns (uint256) {
        UserState storage state = userStates[user];

        if (!active) return state.pointsEarned;
        if (state.totalBoostedAmount == 0) return state.pointsEarned;

        uint256 cachedPointsPerShare = _currentPointsPerShare();
        uint256 pointsDelta = cachedPointsPerShare - state.pointsPerSharePaid;
        uint256 pendingPoints = (state.totalBoostedAmount * pointsDelta) / PRECISION;

        return state.pointsEarned + pendingPoints;
    }

    // =============================================================================
    // User Functions - Stake/Unstake
    // =============================================================================

    /// @notice Stake PPT tokens with lock duration
    /// @param amount Amount of PPT to stake
    /// @param lockDuration Lock duration in seconds (7-365 days)
    /// @return stakeIndex Index of the created stake
    function stake(uint256 amount, uint256 lockDuration)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 stakeIndex)
    {
        if (amount == 0) revert ZeroAmount();
        if (amount > MAX_STAKE_AMOUNT) revert AmountTooLarge(amount, MAX_STAKE_AMOUNT);
        if (lockDuration < MIN_LOCK_DURATION || lockDuration > MAX_LOCK_DURATION) {
            revert InvalidLockDuration(lockDuration, MIN_LOCK_DURATION, MAX_LOCK_DURATION);
        }

        address user = msg.sender;
        uint256 currentCount = userStakeCount[user];
        if (currentCount >= MAX_STAKES_PER_USER) {
            revert MaxStakesReached(currentCount, MAX_STAKES_PER_USER);
        }

        // Update global and user state first
        _updateGlobal();
        _updateUser(user);

        // Transfer PPT from user
        ppt.safeTransferFrom(user, address(this), amount);

        // Calculate boosted amount (safe due to MAX_STAKE_AMOUNT check)
        uint256 boostedAmount = calculateBoostedAmount(amount, lockDuration);

        // Validate points don't overflow uint128 (defensive check)
        uint256 currentUserPoints = userStates[user].pointsEarned;
        if (currentUserPoints > type(uint128).max) {
            revert PointsOverflow(currentUserPoints);
        }

        uint64 lockEndTime = uint64(block.timestamp + lockDuration);

        // Create stake record (all casts are now safe due to validation)
        stakeIndex = currentCount;
        userStakes[user][stakeIndex] = StakeInfo({
            amount: uint128(amount),
            boostedAmount: uint128(boostedAmount),
            pointsEarnedAtStake: uint128(currentUserPoints),
            lockEndTime: lockEndTime,
            lockDuration: uint56(lockDuration),
            isActive: true
        });

        // Update aggregated state
        userStates[user].totalBoostedAmount += boostedAmount;
        totalBoostedStaked += boostedAmount;
        userStakeCount[user] = currentCount + 1;

        emit Staked(user, stakeIndex, amount, lockDuration, boostedAmount, lockEndTime);
    }

    /// @notice Unstake PPT tokens
    /// @param stakeIndex Index of the stake to unstake
    /// @dev If unlocking early, penalty is applied to points earned since stake
    function unstake(uint256 stakeIndex) external nonReentrant whenNotPaused {
        address user = msg.sender;

        if (stakeIndex >= userStakeCount[user]) {
            revert StakeNotFound(stakeIndex);
        }

        StakeInfo storage stakeInfo = userStakes[user][stakeIndex];
        if (!stakeInfo.isActive) {
            revert StakeNotActive(stakeIndex);
        }

        // Update global and user state first
        _updateGlobal();
        _updateUser(user);

        uint256 amount = stakeInfo.amount;
        uint256 boostedAmount = stakeInfo.boostedAmount;
        bool isEarlyUnlock = block.timestamp < stakeInfo.lockEndTime;
        uint256 theoreticalPenalty = 0;
        uint256 actualPenalty = 0;
        bool penaltyWasCapped = false;

        // Calculate and apply penalty for early unlock
        if (isEarlyUnlock) {
            theoreticalPenalty = _calculateEarlyUnlockPenalty(user, stakeInfo);
            if (theoreticalPenalty > 0) {
                if (theoreticalPenalty <= userStates[user].pointsEarned) {
                    actualPenalty = theoreticalPenalty;
                    userStates[user].pointsEarned -= theoreticalPenalty;
                } else {
                    // Cap penalty at earned points
                    actualPenalty = userStates[user].pointsEarned;
                    userStates[user].pointsEarned = 0;
                    penaltyWasCapped = true;
                }
            }
        }

        // Update aggregated state
        userStates[user].totalBoostedAmount -= boostedAmount;
        totalBoostedStaked -= boostedAmount;

        // Mark stake as inactive
        stakeInfo.isActive = false;

        // Transfer PPT back to user
        ppt.safeTransfer(user, amount);

        emit Unstaked(user, stakeIndex, amount, actualPenalty, theoreticalPenalty, isEarlyUnlock, penaltyWasCapped);
    }

    /// @notice Calculate early unlock penalty
    /// @param user User address
    /// @param stakeInfo Stake information
    /// @return penalty Points penalty amount
    /// @dev penalty = earnedSinceStake * (remainingTime / lockDuration) * 50%
    function _calculateEarlyUnlockPenalty(address user, StakeInfo storage stakeInfo)
        internal
        view
        returns (uint256 penalty)
    {
        uint256 currentPoints = userStates[user].pointsEarned;
        uint256 pointsAtStake = stakeInfo.pointsEarnedAtStake;

        // Points earned since this stake
        uint256 earnedSinceStake = currentPoints > pointsAtStake ? currentPoints - pointsAtStake : 0;
        if (earnedSinceStake == 0) return 0;

        // Calculate remaining time ratio
        uint256 remainingTime = stakeInfo.lockEndTime > block.timestamp ? stakeInfo.lockEndTime - block.timestamp : 0;
        if (remainingTime == 0) return 0;

        uint256 lockDuration = stakeInfo.lockDuration;

        // penalty = earnedSinceStake * (remainingTime / lockDuration) * PENALTY_BPS / 10000
        penalty = (earnedSinceStake * remainingTime * EARLY_UNLOCK_PENALTY_BPS) / (lockDuration * 10000);
    }

    // =============================================================================
    // View Functions - IPointsModule Implementation
    // =============================================================================

    /// @notice Get points for a user (real-time calculation)
    /// @param user User address
    /// @return Total accumulated points
    function getPoints(address user) external view override returns (uint256) {
        return _calculatePoints(user);
    }

    /// @notice Get module name
    function moduleName() external pure override returns (string memory) {
        return MODULE_NAME;
    }

    /// @notice Check if module is active
    function isActive() external view override returns (bool) {
        return active;
    }

    // =============================================================================
    // View Functions - Additional
    // =============================================================================

    /// @notice Get current points per share
    function currentPointsPerShare() external view returns (uint256) {
        return _currentPointsPerShare();
    }

    /// @notice Get user's aggregated state
    /// @param user User address
    /// @return totalBoostedAmount Total boosted staked amount
    /// @return earnedPoints Total earned points
    /// @return activeStakeCount Number of active stakes
    function getUserState(address user)
        external
        view
        returns (uint256 totalBoostedAmount, uint256 earnedPoints, uint256 activeStakeCount)
    {
        totalBoostedAmount = userStates[user].totalBoostedAmount;
        earnedPoints = _calculatePoints(user);

        // Count active stakes
        uint256 count = userStakeCount[user];
        for (uint256 i = 0; i < count;) {
            if (userStakes[user][i].isActive) {
                ++activeStakeCount;
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Get user's stake details
    /// @param user User address
    /// @param stakeIndex Stake index
    /// @return info Stake information
    function getStakeInfo(address user, uint256 stakeIndex) external view returns (StakeInfo memory info) {
        if (stakeIndex >= userStakeCount[user]) {
            revert StakeNotFound(stakeIndex);
        }
        return userStakes[user][stakeIndex];
    }

    /// @notice Get all stakes for a user
    /// @param user User address
    /// @return stakes Array of stake information
    function getAllStakes(address user) external view returns (StakeInfo[] memory stakes) {
        uint256 count = userStakeCount[user];
        stakes = new StakeInfo[](count);
        for (uint256 i = 0; i < count;) {
            stakes[i] = userStakes[user][i];
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Estimate points for a staking scenario
    /// @param amount Amount to stake (must be > 0)
    /// @param lockDuration Lock duration (must be valid range)
    /// @param holdDuration How long to hold the stake
    /// @return Estimated points
    /// @dev Reverts on invalid inputs for consistency
    function estimatePoints(uint256 amount, uint256 lockDuration, uint256 holdDuration)
        external
        view
        returns (uint256)
    {
        if (amount == 0) revert ZeroAmount();
        if (lockDuration < MIN_LOCK_DURATION || lockDuration > MAX_LOCK_DURATION) {
            revert InvalidLockDuration(lockDuration, MIN_LOCK_DURATION, MAX_LOCK_DURATION);
        }

        uint256 boostedAmount = calculateBoostedAmount(amount, lockDuration);

        if (totalBoostedStaked == 0) {
            // Would be only staker - gets all points
            return holdDuration * pointsRatePerSecond;
        }

        uint256 totalWithNew = totalBoostedStaked + boostedAmount;
        uint256 pointsGenerated = holdDuration * pointsRatePerSecond;
        return (boostedAmount * pointsGenerated) / totalWithNew;
    }

    /// @notice Calculate potential early unlock penalty
    /// @param user User address
    /// @param stakeIndex Stake index
    /// @return penalty Potential penalty amount
    function calculatePotentialPenalty(address user, uint256 stakeIndex) external view returns (uint256 penalty) {
        if (stakeIndex >= userStakeCount[user]) {
            revert StakeNotFound(stakeIndex);
        }

        StakeInfo storage stakeInfo = userStakes[user][stakeIndex];
        if (!stakeInfo.isActive) {
            revert StakeNotActive(stakeIndex);
        }

        // No penalty if lock has expired
        if (block.timestamp >= stakeInfo.lockEndTime) return 0;

        // Need to calculate current points first
        uint256 currentPoints = _calculatePoints(user);
        uint256 pointsAtStake = stakeInfo.pointsEarnedAtStake;

        uint256 earnedSinceStake = currentPoints > pointsAtStake ? currentPoints - pointsAtStake : 0;
        if (earnedSinceStake == 0) return 0;

        uint256 remainingTime = stakeInfo.lockEndTime - block.timestamp;
        uint256 lockDuration = stakeInfo.lockDuration;

        penalty = (earnedSinceStake * remainingTime * EARLY_UNLOCK_PENALTY_BPS) / (lockDuration * 10000);
    }

    // =============================================================================
    // Checkpoint Functions
    // =============================================================================

    /// @notice Checkpoint global state (keeper function)
    function checkpointGlobal() external onlyRole(KEEPER_ROLE) {
        _updateGlobal();
    }

    /// @notice Checkpoint multiple users (keeper function)
    /// @param users Array of user addresses to checkpoint
    /// @dev Emits ZeroAddressSkipped for any zero addresses in the array
    function checkpointUsers(address[] calldata users) external onlyRole(KEEPER_ROLE) {
        uint256 len = users.length;
        if (len > MAX_BATCH_USERS) revert BatchTooLarge(len, MAX_BATCH_USERS);

        _updateGlobal();

        for (uint256 i = 0; i < len;) {
            if (users[i] != address(0)) {
                _updateUser(users[i]);
            } else {
                emit ZeroAddressSkipped(i);
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Checkpoint a single user (anyone can call)
    /// @param user User address to checkpoint
    /// @return pointsCredited Whether points were credited
    function checkpoint(address user) external returns (bool pointsCredited) {
        _updateGlobal();
        return _updateUser(user);
    }

    /// @notice Checkpoint caller
    /// @return pointsCredited Whether points were credited
    function checkpointSelf() external returns (bool pointsCredited) {
        _updateGlobal();
        return _updateUser(msg.sender);
    }

    // =============================================================================
    // Admin Functions
    // =============================================================================

    /// @notice Set points rate per second
    /// @param newRate New rate (1e18 precision)
    function setPointsRate(uint256 newRate) external onlyRole(ADMIN_ROLE) {
        if (newRate < MIN_POINTS_RATE || newRate > MAX_POINTS_RATE) {
            revert InvalidPointsRate(newRate, MIN_POINTS_RATE, MAX_POINTS_RATE);
        }

        _updateGlobal();

        uint256 oldRate = pointsRatePerSecond;
        pointsRatePerSecond = newRate;

        emit PointsRateUpdated(oldRate, newRate);
    }

    /// @notice Set module active status
    /// @param _active Whether the module is active
    function setActive(bool _active) external onlyRole(ADMIN_ROLE) {
        if (_active && !active) {
            lastUpdateTime = block.timestamp;
        } else if (!_active && active) {
            _updateGlobal();
        }
        active = _active;
        emit ModuleActiveStatusUpdated(_active);
    }

    /// @notice Update PPT address (emergency only)
    /// @param _ppt New PPT address (must be valid ERC20)
    function setPpt(address _ppt) external onlyRole(ADMIN_ROLE) {
        if (_ppt == address(0)) revert ZeroAddress();
        if (_ppt.code.length == 0) revert NotAContract(_ppt);
        _validateERC20(_ppt);

        _updateGlobal();
        address oldPpt = address(ppt);
        ppt = IERC20(_ppt);
        emit PptUpdated(oldPpt, _ppt);
    }

    /// @notice Set minimum holding blocks for flash loan protection
    /// @param blocks Minimum blocks
    function setMinHoldingBlocks(uint256 blocks) external onlyRole(ADMIN_ROLE) {
        uint256 oldBlocks = minHoldingBlocks;
        minHoldingBlocks = blocks;
        emit MinHoldingBlocksUpdated(oldBlocks, blocks);
    }

    /// @notice Pause contract operations
    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    /// @notice Unpause contract operations
    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    /// @notice Get contract version
    /// @return Version string
    function version() external pure returns (string memory) {
        return VERSION;
    }

    // =============================================================================
    // Storage Gap - Reserved for future upgrades
    // =============================================================================

    /// @dev Reserved storage space to allow for layout changes in future upgrades
    uint256[50] private __gap;
}
