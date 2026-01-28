// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IPointsModule} from "./interfaces/IPointsModule.sol";

/// @title LPModule v2.0 - 信用卡积分模式
/// @author Paimon Protocol
/// @notice LP 提供奖励的积分模块
/// @dev 使用"信用卡积分"模式：积分 = lpBalance × multiplier × baseRate × duration / MULTIPLIER_BASE
///      每个用户的积分只与自己的 LP 持有相关，后入者不会被稀释
///      支持多个具有不同倍数的 LP 池
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
    uint256 public constant MAX_MULTIPLIER = 1000; // 10x max multiplier
    string public constant MODULE_NAME = "LP Providing";
    string public constant VERSION = "2.0.0";

    /// @notice Max batch size for user checkpoints
    uint256 public constant MAX_BATCH_USERS = 25;

    /// @notice Max total operations per batch (users * pools)
    uint256 public constant MAX_OPERATIONS_PER_BATCH = 200;

    /// @notice Max number of pools allowed
    uint256 public constant MAX_POOLS = 20;

    // =============================================================================
    // Data Structures
    // =============================================================================

    /// @notice Pool configuration
    struct PoolConfig {
        address lpToken; // LP Token address
        uint256 multiplier; // Points multiplier (100 = 1x, 200 = 2x)
        bool isActive; // Whether pool is active
        string name; // Pool display name
    }

    /// @notice User state per pool (v2 - Credit Card Mode)
    /// @dev 不再需要 pointsPerLpPaid，改用时间累计模式
    struct UserPoolState {
        uint256 accruedPoints; // 已累计的积分
        uint256 lastBalance; // 上次检查点时的 LP 余额
        uint256 lastAccrualTime; // 上次积分累计时间
        uint256 lastCheckpointBlock; // 用于闪电贷保护
    }

    // =============================================================================
    // State Variables
    // =============================================================================

    /// @notice Base points rate per LP token per second
    uint256 public basePointsRatePerSecond;

    /// @notice Pool configuration array
    PoolConfig[] public pools;

    /// @notice Mapping: lpToken => poolId + 1 (0 means not found)
    mapping(address => uint256) public poolIndex;

    /// @notice Mapping: user => poolId => UserPoolState
    mapping(address => mapping(uint256 => UserPoolState)) public userPoolStates;

    /// @notice Whether module is active
    bool public active;

    /// @notice Minimum blocks balance must be held for points to count (flash loan protection)
    uint256 public minHoldingBlocks;

    // =============================================================================
    // Events
    // =============================================================================

    event PoolAdded(uint256 indexed poolId, address indexed lpToken, uint256 multiplier, string name);
    event PoolUpdated(uint256 indexed poolId, uint256 multiplier, bool isActive);
    event PoolRemoved(uint256 indexed poolId, address indexed lpToken);
    event UserPoolCheckpointed(
        address indexed user, uint256 indexed poolId, uint256 accruedPoints, uint256 balance, uint256 timestamp
    );
    event BaseRateUpdated(uint256 oldRate, uint256 newRate);
    event ModuleActiveStatusUpdated(bool active);
    event LPModuleUpgraded(address indexed newImplementation, uint256 timestamp);
    event CheckpointPoolSkipped(uint256 indexed poolId, string reason);
    event PoolNameUpdated(uint256 indexed poolId, string oldName, string newName);
    event LPTokenQueryFailed(uint256 indexed poolId, address indexed lpToken);
    event MinHoldingBlocksUpdated(uint256 oldBlocks, uint256 newBlocks);
    event FlashLoanProtectionTriggered(address indexed user, uint256 indexed poolId, uint256 blocksRemaining);
    event ZeroAddressSkipped(address indexed user);

    // =============================================================================
    // Errors
    // =============================================================================

    error ZeroAddress();
    error PoolAlreadyExists(address lpToken);
    error PoolNotFound(uint256 poolId);
    error MaxPoolsReached();
    error InvalidMultiplier();
    error BatchTooLarge(uint256 size, uint256 max);
    error TooManyOperations(uint256 operations, uint256 max);

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
    /// @param _baseRate Base points rate per LP per second
    function initialize(address admin, address keeper, address upgrader, uint256 _baseRate) external initializer {
        if (admin == address(0) || keeper == address(0) || upgrader == address(0)) revert ZeroAddress();

        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        basePointsRatePerSecond = _baseRate;
        active = true;
        minHoldingBlocks = 1; // Default: 1 block for flash loan protection

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
    // Core Logic - Credit Card Points Calculation
    // =============================================================================

    /// @notice 计算用户在特定池从上次累计到现在的积分
    /// @dev 信用卡模式：积分 = lpBalance × multiplier × baseRate × duration / MULTIPLIER_BASE
    function _calculatePoolPointsSinceLastAccrual(address user, uint256 poolId) internal view returns (uint256) {
        PoolConfig storage pool = pools[poolId];
        UserPoolState storage userState = userPoolStates[user][poolId];

        if (!pool.isActive || !active) return 0;
        if (userState.lastBalance == 0) return 0;

        uint256 duration = block.timestamp - userState.lastAccrualTime;
        if (duration == 0) return 0;

        uint256 effectiveRate = (basePointsRatePerSecond * pool.multiplier) / MULTIPLIER_BASE;
        return userState.lastBalance * effectiveRate * duration;
    }

    /// @notice 计算用户在特定池的总积分（已累计 + 待累计）
    function _calculateUserPoolPoints(address user, uint256 poolId) internal view returns (uint256) {
        UserPoolState storage userState = userPoolStates[user][poolId];
        return userState.accruedPoints + _calculatePoolPointsSinceLastAccrual(user, poolId);
    }

    /// @notice 累计用户在特定池的积分
    function _accrueUserPoolPoints(address user, uint256 poolId) internal {
        UserPoolState storage userState = userPoolStates[user][poolId];

        uint256 newPoints = _calculatePoolPointsSinceLastAccrual(user, poolId);
        if (newPoints > 0) {
            userState.accruedPoints += newPoints;
        }
        userState.lastAccrualTime = block.timestamp;
    }

    /// @notice 更新用户在池中的状态
    /// @dev 包含闪电贷保护
    function _updateUserPool(address user, uint256 poolId) internal {
        PoolConfig storage pool = pools[poolId];
        UserPoolState storage userState = userPoolStates[user][poolId];

        // 闪电贷保护检查
        bool passedHoldingPeriod =
            userState.lastCheckpointBlock == 0 || block.number >= userState.lastCheckpointBlock + minHoldingBlocks;

        if (!passedHoldingPeriod) {
            uint256 blocksRemaining = (userState.lastCheckpointBlock + minHoldingBlocks) - block.number;
            emit FlashLoanProtectionTriggered(user, poolId, blocksRemaining);
            // 不累计积分，但仍然更新余额
        } else {
            // 累计积分
            _accrueUserPoolPoints(user, poolId);
        }

        // 获取当前余额
        uint256 currentBalance;
        try IERC20(pool.lpToken).balanceOf(user) returns (uint256 balance) {
            currentBalance = balance;
        } catch {
            currentBalance = userState.lastBalance;
            emit LPTokenQueryFailed(poolId, pool.lpToken);
        }

        // 更新状态
        userState.lastBalance = currentBalance;
        userState.lastAccrualTime = block.timestamp;
        userState.lastCheckpointBlock = block.number;

        emit UserPoolCheckpointed(user, poolId, userState.accruedPoints, currentBalance, block.timestamp);
    }

    // =============================================================================
    // View Functions - IPointsModule Implementation
    // =============================================================================

    /// @notice 获取用户在所有池中的总积分
    function getPoints(address user) external view override returns (uint256 total) {
        uint256 len = pools.length;
        for (uint256 i = 0; i < len;) {
            total += _calculateUserPoolPoints(user, i);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice 获取模块名称
    function moduleName() external pure override returns (string memory) {
        return MODULE_NAME;
    }

    /// @notice 检查模块是否激活
    function isActive() external view override returns (bool) {
        return active;
    }

    // =============================================================================
    // View Functions - Additional
    // =============================================================================

    /// @notice 获取池的数量
    function getPoolCount() external view returns (uint256) {
        return pools.length;
    }

    /// @notice 获取池信息
    function getPool(uint256 poolId)
        external
        view
        returns (address lpToken, uint256 multiplier, bool poolActive, string memory name, uint256 totalSupply)
    {
        if (poolId >= pools.length) revert PoolNotFound(poolId);

        PoolConfig storage pool = pools[poolId];
        lpToken = pool.lpToken;
        multiplier = pool.multiplier;
        poolActive = pool.isActive;
        name = pool.name;

        // Skip totalSupply call for removed pools (lpToken == address(0))
        if (lpToken != address(0)) {
            try IERC20(pool.lpToken).totalSupply() returns (uint256 supply) {
                totalSupply = supply;
            } catch {
                totalSupply = 0;
            }
        }
    }

    /// @notice 获取用户按池分类的积分明细
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

        for (uint256 i = 0; i < len;) {
            names[i] = pools[i].name;
            points[i] = _calculateUserPoolPoints(user, i);
            multipliers[i] = pools[i].multiplier;

            try IERC20(pools[i].lpToken).balanceOf(user) returns (uint256 balance) {
                balances[i] = balance;
            } catch {
                balances[i] = 0;
            }

            unchecked {
                ++i;
            }
        }
    }

    /// @notice 获取特定池的用户状态
    function getUserPoolState(address user, uint256 poolId)
        external
        view
        returns (
            uint256 balance,
            uint256 lastCheckpointBalance,
            uint256 earnedPoints,
            uint256 lastAccrualTime,
            uint256 lastCheckpointBlock
        )
    {
        if (poolId >= pools.length) revert PoolNotFound(poolId);

        UserPoolState storage userState = userPoolStates[user][poolId];

        try IERC20(pools[poolId].lpToken).balanceOf(user) returns (uint256 bal) {
            balance = bal;
        } catch {
            balance = 0;
        }

        lastCheckpointBalance = userState.lastBalance;
        earnedPoints = _calculateUserPoolPoints(user, poolId);
        lastAccrualTime = userState.lastAccrualTime;
        lastCheckpointBlock = userState.lastCheckpointBlock;
    }

    /// @notice 估算 LP 金额在特定时长内的积分（信用卡模式 - 固定积分率）
    function estimatePoolPoints(uint256 poolId, uint256 lpAmount, uint256 durationSeconds)
        external
        view
        returns (uint256)
    {
        if (poolId >= pools.length) return 0;
        PoolConfig storage pool = pools[poolId];
        if (!pool.isActive) return 0;

        uint256 effectiveRate = (basePointsRatePerSecond * pool.multiplier) / MULTIPLIER_BASE;
        return lpAmount * effectiveRate * durationSeconds;
    }

    // =============================================================================
    // Pool Management - Admin
    // =============================================================================

    /// @notice 添加新的 LP 池
    function addPool(address lpToken, uint256 multiplier, string calldata name) external onlyRole(ADMIN_ROLE) {
        if (lpToken == address(0)) revert ZeroAddress();
        if (poolIndex[lpToken] != 0) revert PoolAlreadyExists(lpToken);
        if (pools.length >= MAX_POOLS) revert MaxPoolsReached();
        if (multiplier == 0 || multiplier > MAX_MULTIPLIER) revert InvalidMultiplier();

        uint256 poolId = pools.length;
        pools.push(PoolConfig({lpToken: lpToken, multiplier: multiplier, isActive: true, name: name}));

        poolIndex[lpToken] = poolId + 1; // +1 to distinguish from "not found"

        emit PoolAdded(poolId, lpToken, multiplier, name);
    }

    /// @notice 更新池配置
    function updatePool(uint256 poolId, uint256 multiplier, bool poolActive) external onlyRole(ADMIN_ROLE) {
        if (poolId >= pools.length) revert PoolNotFound(poolId);
        if (multiplier == 0 || multiplier > MAX_MULTIPLIER) revert InvalidMultiplier();

        pools[poolId].multiplier = multiplier;
        pools[poolId].isActive = poolActive;

        emit PoolUpdated(poolId, multiplier, poolActive);
    }

    /// @notice 更新池名称
    function updatePoolName(uint256 poolId, string calldata name) external onlyRole(ADMIN_ROLE) {
        if (poolId >= pools.length) revert PoolNotFound(poolId);
        string memory oldName = pools[poolId].name;
        pools[poolId].name = name;
        emit PoolNameUpdated(poolId, oldName, name);
    }

    /// @notice 移除池（标记为非激活并清除映射）
    function removePool(uint256 poolId) external onlyRole(ADMIN_ROLE) {
        if (poolId >= pools.length) revert PoolNotFound(poolId);

        PoolConfig storage pool = pools[poolId];
        address lpToken = pool.lpToken;

        poolIndex[lpToken] = 0;
        pool.isActive = false;
        pool.lpToken = address(0);
        pool.multiplier = 0;

        emit PoolRemoved(poolId, lpToken);
    }

    // =============================================================================
    // Checkpoint Functions
    // =============================================================================

    /// @notice 检查点用户在所有池中的状态
    function _checkpointUser(address user) internal {
        uint256 len = pools.length;
        for (uint256 i = 0; i < len;) {
            if (pools[i].isActive) {
                _updateUserPool(user, i);
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @notice 检查点用户在所有池中的状态 (keeper 函数)
    function checkpointUsers(address[] calldata users) external onlyRole(KEEPER_ROLE) {
        uint256 userLen = users.length;
        if (userLen > MAX_BATCH_USERS) revert BatchTooLarge(userLen, MAX_BATCH_USERS);

        uint256 poolLen = pools.length;
        uint256 totalOps = userLen * poolLen;
        if (totalOps > MAX_OPERATIONS_PER_BATCH) {
            revert TooManyOperations(totalOps, MAX_OPERATIONS_PER_BATCH);
        }

        for (uint256 u = 0; u < userLen;) {
            if (users[u] != address(0)) {
                _checkpointUser(users[u]);
            } else {
                emit ZeroAddressSkipped(users[u]);
            }
            unchecked {
                ++u;
            }
        }
    }

    /// @notice 检查点用户在所有池中的状态（任何人都可以调用）
    function checkpoint(address user) external {
        _checkpointUser(user);
    }

    /// @notice 检查点调用者在所有池中的状态
    function checkpointSelf() external {
        _checkpointUser(msg.sender);
    }

    /// @notice 检查点用户在特定池中的状态
    function checkpointUserPool(address user, uint256 poolId) external {
        if (poolId >= pools.length) revert PoolNotFound(poolId);
        _updateUserPool(user, poolId);
    }

    // =============================================================================
    // Admin Functions
    // =============================================================================

    /// @notice 设置基础积分率
    function setBaseRate(uint256 newRate) external onlyRole(ADMIN_ROLE) {
        uint256 oldRate = basePointsRatePerSecond;
        basePointsRatePerSecond = newRate;
        emit BaseRateUpdated(oldRate, newRate);
    }

    /// @notice 设置模块激活状态
    function setActive(bool _active) external onlyRole(ADMIN_ROLE) {
        active = _active;
        emit ModuleActiveStatusUpdated(_active);
    }

    /// @notice 设置闪电贷保护的最小持有区块数
    function setMinHoldingBlocks(uint256 blocks) external onlyRole(ADMIN_ROLE) {
        uint256 oldBlocks = minHoldingBlocks;
        minHoldingBlocks = blocks;
        emit MinHoldingBlocksUpdated(oldBlocks, blocks);
    }

    /// @notice 暂停合约操作
    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    /// @notice 恢复合约操作
    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    /// @notice 获取合约版本
    function version() external pure returns (string memory) {
        return VERSION;
    }

    // =============================================================================
    // Storage Gap - Reserved for future upgrades
    // =============================================================================

    /// @dev Reserved storage space to allow future layout changes
    uint256[50] private __gap;
}
