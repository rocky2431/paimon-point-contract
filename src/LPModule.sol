// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IPointsModule} from "./interfaces/IPointsModule.sol";

/// @title LPModule
/// @author Paimon Protocol
/// @notice Points module for LP providing rewards
/// @dev Supports multiple LP pools with different multipliers
contract LPModule is
    IPointsModule,
    Initializable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    // =============================================================================
    // Constants & Roles
    // =============================================================================

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    uint256 public constant PRECISION = 1e18;
    uint256 public constant MULTIPLIER_BASE = 100; // 100 = 1x, 200 = 2x
    uint256 public constant MAX_MULTIPLIER = 1000; // 10x maximum multiplier
    string public constant MODULE_NAME = "LP Providing";

    // =============================================================================
    // Data Structures
    // =============================================================================

    /// @notice Pool configuration
    struct PoolConfig {
        address lpToken;        // LP Token address
        uint256 multiplier;     // Points multiplier (100 = 1x, 200 = 2x)
        bool isActive;          // Whether pool is active
        string name;            // Pool name for display
    }

    /// @notice Pool state for points calculation
    struct PoolState {
        uint256 lastUpdateTime;     // Last update timestamp
        uint256 pointsPerLpStored;  // Accumulated points per LP token
    }

    /// @notice User state per pool
    struct UserPoolState {
        uint256 pointsPerLpPaid;    // User's last recorded points per LP
        uint256 pointsEarned;       // User's accumulated points
        uint256 lastBalance;        // User's last recorded LP balance
        uint256 lastCheckpoint;     // Last checkpoint timestamp
    }

    // =============================================================================
    // State Variables
    // =============================================================================

    /// @notice Base points rate per second per LP token
    uint256 public basePointsRatePerSecond;

    /// @notice Array of pool configurations
    PoolConfig[] public pools;

    /// @notice Mapping: lpToken => poolId + 1 (0 means not exists)
    mapping(address => uint256) public poolIndex;

    /// @notice Mapping: poolId => PoolState
    mapping(uint256 => PoolState) public poolStates;

    /// @notice Mapping: user => poolId => UserPoolState
    mapping(address => mapping(uint256 => UserPoolState)) public userPoolStates;

    /// @notice Whether the module is active
    bool public active;

    /// @notice Maximum number of pools allowed
    uint256 public constant MAX_POOLS = 20;

    // =============================================================================
    // Events
    // =============================================================================

    event PoolAdded(
        uint256 indexed poolId,
        address indexed lpToken,
        uint256 multiplier,
        string name
    );
    event PoolUpdated(
        uint256 indexed poolId,
        uint256 multiplier,
        bool isActive
    );
    event PoolRemoved(uint256 indexed poolId, address indexed lpToken);
    event GlobalPoolCheckpointed(
        uint256 indexed poolId,
        uint256 pointsPerLp,
        uint256 timestamp
    );
    event UserPoolCheckpointed(
        address indexed user,
        uint256 indexed poolId,
        uint256 pointsEarned,
        uint256 balance
    );
    event BaseRateUpdated(uint256 oldRate, uint256 newRate);
    event ModuleActiveStatusUpdated(bool active);
    event LPModuleUpgraded(address indexed newImplementation, uint256 timestamp);
    event CheckpointPoolSkipped(uint256 indexed poolId, string reason);

    // =============================================================================
    // Errors
    // =============================================================================

    error ZeroAddress();
    error PoolAlreadyExists(address lpToken);
    error PoolNotFound(uint256 poolId);
    error PoolNotFoundByToken(address lpToken);
    error MaxPoolsReached();
    error InvalidMultiplier();

    // =============================================================================
    // Constructor & Initializer
    // =============================================================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the contract
    /// @param admin Admin address
    /// @param keeper Keeper address
    /// @param upgrader Upgrader address
    /// @param _baseRate Base points rate per second per LP
    function initialize(
        address admin,
        address keeper,
        address upgrader,
        uint256 _baseRate
    ) external initializer {
        if (admin == address(0) || keeper == address(0) || upgrader == address(0)) revert ZeroAddress();

        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        basePointsRatePerSecond = _baseRate;
        active = true;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);
        _grantRole(KEEPER_ROLE, keeper);
        _grantRole(UPGRADER_ROLE, upgrader);
    }

    // =============================================================================
    // UUPS Upgrade
    // =============================================================================

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {
        emit LPModuleUpgraded(newImplementation, block.timestamp);
    }

    // =============================================================================
    // Core Logic - Internal
    // =============================================================================

    /// @notice Calculate current points per LP for a pool
    function _getPoolPointsPerLp(uint256 poolId) internal view returns (uint256) {
        PoolConfig storage pool = pools[poolId];
        PoolState storage state = poolStates[poolId];

        if (!pool.isActive || !active) return state.pointsPerLpStored;

        uint256 totalLp = IERC20(pool.lpToken).totalSupply();
        if (totalLp == 0) return state.pointsPerLpStored;

        uint256 timeDelta = block.timestamp - state.lastUpdateTime;
        uint256 effectiveRate = (basePointsRatePerSecond * pool.multiplier) / MULTIPLIER_BASE;
        uint256 newPoints = timeDelta * effectiveRate;

        return state.pointsPerLpStored + (newPoints * PRECISION) / totalLp;
    }

    /// @notice Update global state for a pool
    function _updatePoolGlobal(uint256 poolId) internal {
        PoolState storage state = poolStates[poolId];

        state.pointsPerLpStored = _getPoolPointsPerLp(poolId);
        state.lastUpdateTime = block.timestamp;

        emit GlobalPoolCheckpointed(poolId, state.pointsPerLpStored, block.timestamp);
    }

    /// @notice Update user state for a pool
    function _updateUserPool(address user, uint256 poolId) internal {
        PoolConfig storage pool = pools[poolId];
        UserPoolState storage userState = userPoolStates[user][poolId];
        PoolState storage poolState = poolStates[poolId];

        uint256 cachedPointsPerLp = poolState.pointsPerLpStored;
        uint256 lastBalance = userState.lastBalance;

        // Calculate new earned points
        if (lastBalance > 0) {
            uint256 pointsDelta = cachedPointsPerLp - userState.pointsPerLpPaid;
            uint256 newEarned = (lastBalance * pointsDelta) / PRECISION;
            userState.pointsEarned += newEarned;
        }

        // Update user state
        uint256 currentBalance = IERC20(pool.lpToken).balanceOf(user);
        userState.pointsPerLpPaid = cachedPointsPerLp;
        userState.lastBalance = currentBalance;
        userState.lastCheckpoint = block.timestamp;

        emit UserPoolCheckpointed(user, poolId, userState.pointsEarned, currentBalance);
    }

    /// @notice Calculate user points for a specific pool (real-time)
    function _getUserPoolPoints(address user, uint256 poolId) internal view returns (uint256) {
        PoolConfig storage pool = pools[poolId];
        UserPoolState storage userState = userPoolStates[user][poolId];

        if (!pool.isActive || !active) return userState.pointsEarned;

        uint256 cachedPointsPerLp = _getPoolPointsPerLp(poolId);
        uint256 lastBalance = userState.lastBalance;

        uint256 earned = userState.pointsEarned;
        if (lastBalance > 0) {
            uint256 pointsDelta = cachedPointsPerLp - userState.pointsPerLpPaid;
            earned += (lastBalance * pointsDelta) / PRECISION;
        }

        return earned;
    }

    // =============================================================================
    // View Functions - IPointsModule Implementation
    // =============================================================================

    /// @notice Get total points for a user across all pools
    function getPoints(address user) external view override returns (uint256 total) {
        uint256 len = pools.length;
        for (uint256 i = 0; i < len; i++) {
            total += _getUserPoolPoints(user, i);
        }
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

    /// @notice Get number of pools
    function getPoolCount() external view returns (uint256) {
        return pools.length;
    }

    /// @notice Get pool info
    function getPool(uint256 poolId)
        external
        view
        returns (
            address lpToken,
            uint256 multiplier,
            bool poolActive,
            string memory name,
            uint256 totalSupply,
            uint256 pointsPerLp
        )
    {
        PoolConfig storage pool = pools[poolId];
        lpToken = pool.lpToken;
        multiplier = pool.multiplier;
        poolActive = pool.isActive;
        name = pool.name;
        totalSupply = IERC20(pool.lpToken).totalSupply();
        pointsPerLp = _getPoolPointsPerLp(poolId);
    }

    /// @notice Get user's points breakdown by pool
    function getUserPoolBreakdown(address user)
        external
        view
        returns (
            string[] memory names,
            uint256[] memory points,
            uint256[] memory balances,
            uint256[] memory multipliers
        )
    {
        uint256 len = pools.length;
        names = new string[](len);
        points = new uint256[](len);
        balances = new uint256[](len);
        multipliers = new uint256[](len);

        for (uint256 i = 0; i < len; i++) {
            names[i] = pools[i].name;
            points[i] = _getUserPoolPoints(user, i);
            balances[i] = IERC20(pools[i].lpToken).balanceOf(user);
            multipliers[i] = pools[i].multiplier;
        }
    }

    /// @notice Get user state for a specific pool
    function getUserPoolState(address user, uint256 poolId)
        external
        view
        returns (
            uint256 balance,
            uint256 lastCheckpointBalance,
            uint256 earnedPoints,
            uint256 lastCheckpointTime
        )
    {
        UserPoolState storage userState = userPoolStates[user][poolId];
        balance = IERC20(pools[poolId].lpToken).balanceOf(user);
        lastCheckpointBalance = userState.lastBalance;
        earnedPoints = _getUserPoolPoints(user, poolId);
        lastCheckpointTime = userState.lastCheckpoint;
    }

    /// @notice Estimate points for LP amount over duration
    function estimatePoolPoints(
        uint256 poolId,
        uint256 lpAmount,
        uint256 durationSeconds
    ) external view returns (uint256) {
        if (poolId >= pools.length) return 0;
        PoolConfig storage pool = pools[poolId];
        if (!pool.isActive) return 0;

        uint256 totalSupply = IERC20(pool.lpToken).totalSupply();
        if (totalSupply == 0) return 0;

        uint256 effectiveRate = (basePointsRatePerSecond * pool.multiplier) / MULTIPLIER_BASE;
        uint256 pointsGenerated = durationSeconds * effectiveRate;
        return (lpAmount * pointsGenerated) / totalSupply;
    }

    // =============================================================================
    // Pool Management - Admin
    // =============================================================================

    /// @notice Add a new LP pool
    /// @param lpToken LP token address
    /// @param multiplier Points multiplier (100 = 1x)
    /// @param name Pool name
    function addPool(
        address lpToken,
        uint256 multiplier,
        string calldata name
    ) external onlyRole(ADMIN_ROLE) {
        if (lpToken == address(0)) revert ZeroAddress();
        if (poolIndex[lpToken] != 0) revert PoolAlreadyExists(lpToken);
        if (pools.length >= MAX_POOLS) revert MaxPoolsReached();
        if (multiplier == 0 || multiplier > MAX_MULTIPLIER) revert InvalidMultiplier();

        uint256 poolId = pools.length;
        pools.push(PoolConfig({
            lpToken: lpToken,
            multiplier: multiplier,
            isActive: true,
            name: name
        }));

        poolIndex[lpToken] = poolId + 1; // +1 to distinguish from "not found"
        poolStates[poolId].lastUpdateTime = block.timestamp;

        emit PoolAdded(poolId, lpToken, multiplier, name);
    }

    /// @notice Update pool configuration
    /// @param poolId Pool ID
    /// @param multiplier New multiplier
    /// @param poolActive Whether pool is active
    function updatePool(
        uint256 poolId,
        uint256 multiplier,
        bool poolActive
    ) external onlyRole(ADMIN_ROLE) {
        if (poolId >= pools.length) revert PoolNotFound(poolId);
        if (multiplier == 0 || multiplier > MAX_MULTIPLIER) revert InvalidMultiplier();

        // Checkpoint first with old settings
        _updatePoolGlobal(poolId);

        pools[poolId].multiplier = multiplier;
        pools[poolId].isActive = poolActive;

        emit PoolUpdated(poolId, multiplier, poolActive);
    }

    /// @notice Update pool name
    function updatePoolName(uint256 poolId, string calldata name) external onlyRole(ADMIN_ROLE) {
        if (poolId >= pools.length) revert PoolNotFound(poolId);
        pools[poolId].name = name;
    }

    // =============================================================================
    // Checkpoint Functions
    // =============================================================================

    /// @notice Internal: checkpoint all pools global state
    function _checkpointAllPoolsInternal() internal {
        uint256 len = pools.length;
        for (uint256 i = 0; i < len; i++) {
            _updatePoolGlobal(i);
        }
    }

    /// @notice Internal: checkpoint a user across all pools
    function _checkpointUser(address user) internal {
        uint256 len = pools.length;
        for (uint256 i = 0; i < len; i++) {
            _updatePoolGlobal(i);
            _updateUserPool(user, i);
        }
    }

    /// @notice Checkpoint all pools (keeper function)
    function checkpointAllPools() external onlyRole(KEEPER_ROLE) {
        _checkpointAllPoolsInternal();
    }

    /// @notice Checkpoint specific pools
    function checkpointPools(uint256[] calldata poolIds) external onlyRole(KEEPER_ROLE) {
        uint256 len = poolIds.length;
        for (uint256 i = 0; i < len; i++) {
            if (poolIds[i] < pools.length) {
                _updatePoolGlobal(poolIds[i]);
            } else {
                emit CheckpointPoolSkipped(poolIds[i], "PoolNotFound");
            }
        }
    }

    /// @notice Checkpoint users across all pools (keeper function)
    function checkpointUsers(address[] calldata users) external onlyRole(KEEPER_ROLE) {
        _checkpointAllPoolsInternal();

        uint256 poolLen = pools.length;
        uint256 userLen = users.length;
        for (uint256 u = 0; u < userLen; u++) {
            for (uint256 p = 0; p < poolLen; p++) {
                _updateUserPool(users[u], p);
            }
        }
    }

    /// @notice Checkpoint a user for all pools (anyone can call)
    function checkpoint(address user) external {
        _checkpointUser(user);
    }

    /// @notice Checkpoint caller for all pools
    function checkpointSelf() external {
        _checkpointUser(msg.sender);
    }

    /// @notice Checkpoint user for specific pool
    function checkpointUserPool(address user, uint256 poolId) external {
        if (poolId >= pools.length) revert PoolNotFound(poolId);
        _updatePoolGlobal(poolId);
        _updateUserPool(user, poolId);
    }

    // =============================================================================
    // Admin Functions
    // =============================================================================

    /// @notice Internal: reset all pool timestamps to now
    function _resetAllPoolTimestamps() internal {
        uint256 len = pools.length;
        for (uint256 i = 0; i < len; i++) {
            poolStates[i].lastUpdateTime = block.timestamp;
        }
    }

    /// @notice Set base points rate
    function setBaseRate(uint256 newRate) external onlyRole(ADMIN_ROLE) {
        _checkpointAllPoolsInternal();

        uint256 oldRate = basePointsRatePerSecond;
        basePointsRatePerSecond = newRate;

        emit BaseRateUpdated(oldRate, newRate);
    }

    /// @notice Set module active status
    function setActive(bool _active) external onlyRole(ADMIN_ROLE) {
        if (_active && !active) {
            _resetAllPoolTimestamps();
        } else if (!_active && active) {
            _checkpointAllPoolsInternal();
        }
        active = _active;
        emit ModuleActiveStatusUpdated(_active);
    }

    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }
}
