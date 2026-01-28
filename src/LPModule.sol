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
/// @notice LP 提供奖励的积分模块
/// @dev 支持多个具有不同倍数的 LP 池
contract LPModule is
    IPointsModule,
    Initializable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    // =============================================================================
    // 常量和角色
    // =============================================================================

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    uint256 public constant PRECISION = 1e18;
    uint256 public constant MULTIPLIER_BASE = 100; // 100 = 1x, 200 = 2x
    uint256 public constant MAX_MULTIPLIER = 1000; // 10x 最大倍数
    string public constant MODULE_NAME = "LP Providing";
    string public constant VERSION = "1.3.0";

    /// @notice 用户检查点的最大批处理大小
    uint256 public constant MAX_BATCH_USERS = 25;

    /// @notice 每批次的最大总操作数（用户数 * 池数）
    uint256 public constant MAX_OPERATIONS_PER_BATCH = 200;

    // =============================================================================
    // 数据结构
    // =============================================================================

    /// @notice 池配置
    struct PoolConfig {
        address lpToken; // LP Token 地址
        uint256 multiplier; // 积分倍数 (100 = 1x, 200 = 2x)
        bool isActive; // 池是否激活
        string name; // 池的显示名称
    }

    /// @notice 用于积分计算的池状态
    struct PoolState {
        uint256 lastUpdateTime; // 最后更新时间戳
        uint256 pointsPerLpStored; // 每个 LP token 的累积积分
    }

    /// @notice 每个池的用户状态
    struct UserPoolState {
        uint256 pointsPerLpPaid; // 用户最后记录的每 LP 积分
        uint256 pointsEarned; // 用户累积的积分
        uint256 lastBalance; // 用户最后记录的 LP 余额
        uint256 lastCheckpoint; // 最后检查点时间戳
        uint256 lastCheckpointBlock; // 最后检查点区块号（用于闪电贷保护）
    }

    // =============================================================================
    // 状态变量
    // =============================================================================

    /// @notice 每个 LP token 每秒的基础积分率
    uint256 public basePointsRatePerSecond;

    /// @notice 池配置数组
    PoolConfig[] public pools;

    /// @notice 映射: lpToken => poolId + 1 (0 表示不存在)
    mapping(address => uint256) public poolIndex;

    /// @notice 映射: poolId => PoolState
    mapping(uint256 => PoolState) public poolStates;

    /// @notice 映射: user => poolId => UserPoolState
    mapping(address => mapping(uint256 => UserPoolState)) public userPoolStates;

    /// @notice 模块是否激活
    bool public active;

    /// @notice 余额必须持有的最小区块数才能计入积分（闪电贷保护）
    uint256 public minHoldingBlocks;

    /// @notice 允许的最大池数量
    uint256 public constant MAX_POOLS = 20;

    // =============================================================================
    // 事件
    // =============================================================================

    event PoolAdded(uint256 indexed poolId, address indexed lpToken, uint256 multiplier, string name);
    event PoolUpdated(uint256 indexed poolId, uint256 multiplier, bool isActive);
    event PoolRemoved(uint256 indexed poolId, address indexed lpToken);
    event GlobalPoolCheckpointed(uint256 indexed poolId, uint256 pointsPerLp, uint256 timestamp);
    event UserPoolCheckpointed(address indexed user, uint256 indexed poolId, uint256 pointsEarned, uint256 balance);
    event BaseRateUpdated(uint256 oldRate, uint256 newRate);
    event ModuleActiveStatusUpdated(bool active);
    event LPModuleUpgraded(address indexed newImplementation, uint256 timestamp);
    event CheckpointPoolSkipped(uint256 indexed poolId, string reason);
    event PoolNameUpdated(uint256 indexed poolId, string oldName, string newName);
    event LPTokenQueryFailed(uint256 indexed poolId, address indexed lpToken);
    event MinHoldingBlocksUpdated(uint256 oldBlocks, uint256 newBlocks);

    // =============================================================================
    // 错误
    // =============================================================================

    error ZeroAddress();
    error PoolAlreadyExists(address lpToken);
    error PoolNotFound(uint256 poolId);
    error PoolNotFoundByToken(address lpToken);
    error MaxPoolsReached();
    error InvalidMultiplier();
    error BatchTooLarge(uint256 size, uint256 max);
    error TooManyOperations(uint256 operations, uint256 max);
    error LPTokenCallFailed(uint256 poolId, address lpToken);

    // =============================================================================
    // 构造函数和初始化器
    // =============================================================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice 初始化合约
    /// @param admin 管理员地址
    /// @param keeper Keeper 地址
    /// @param upgrader 升级者地址
    /// @param _baseRate 每 LP 每秒的基础积分率
    function initialize(address admin, address keeper, address upgrader, uint256 _baseRate) external initializer {
        if (admin == address(0) || keeper == address(0) || upgrader == address(0)) revert ZeroAddress();

        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        basePointsRatePerSecond = _baseRate;
        active = true;
        minHoldingBlocks = 1; // 默认: 1 个区块用于闪电贷保护

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);
        _grantRole(KEEPER_ROLE, keeper);
        _grantRole(UPGRADER_ROLE, upgrader);
    }

    // =============================================================================
    // UUPS 升级
    // =============================================================================

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {
        emit LPModuleUpgraded(newImplementation, block.timestamp);
    }

    // =============================================================================
    // 核心逻辑 - 内部函数
    // =============================================================================

    /// @notice 计算池的当前每 LP 积分
    /// @dev 使用 try-catch 优雅地处理 LP token 调用失败
    function _getPoolPointsPerLp(uint256 poolId) internal view returns (uint256) {
        PoolConfig storage pool = pools[poolId];
        PoolState storage state = poolStates[poolId];

        if (!pool.isActive || !active) return state.pointsPerLpStored;

        uint256 totalLp;
        try IERC20(pool.lpToken).totalSupply() returns (uint256 supply) {
            totalLp = supply;
        } catch {
            // LP token 调用失败，返回存储的值
            return state.pointsPerLpStored;
        }

        if (totalLp == 0) return state.pointsPerLpStored;

        uint256 timeDelta = block.timestamp - state.lastUpdateTime;
        uint256 effectiveRate = (basePointsRatePerSecond * pool.multiplier) / MULTIPLIER_BASE;
        uint256 newPoints = timeDelta * effectiveRate;

        return state.pointsPerLpStored + (newPoints * PRECISION) / totalLp;
    }

    /// @notice 更新池的全局状态
    function _updatePoolGlobal(uint256 poolId) internal {
        PoolState storage state = poolStates[poolId];

        state.pointsPerLpStored = _getPoolPointsPerLp(poolId);
        state.lastUpdateTime = block.timestamp;

        emit GlobalPoolCheckpointed(poolId, state.pointsPerLpStored, block.timestamp);
    }

    /// @notice 更新池的用户状态
    /// @dev 使用 try-catch 优雅地处理 LP token 调用失败
    ///      包含通过 minHoldingBlocks 的闪电贷保护
    function _updateUserPool(address user, uint256 poolId) internal {
        PoolConfig storage pool = pools[poolId];
        UserPoolState storage userState = userPoolStates[user][poolId];
        PoolState storage poolState = poolStates[poolId];

        uint256 cachedPointsPerLp = poolState.pointsPerLpStored;
        uint256 lastBalance = userState.lastBalance;
        uint256 lastCheckpointBlock = userState.lastCheckpointBlock;

        // 闪电贷保护: 只有在最小持有区块数通过后才计入积分
        // 这防止攻击者借入代币、检查点后在同一区块内归还
        bool passedHoldingPeriod = lastCheckpointBlock == 0 || block.number >= lastCheckpointBlock + minHoldingBlocks;

        // 使用最后记录的余额计算新获得的积分
        // 只有在满足持有期要求时才计入
        if (lastBalance > 0 && passedHoldingPeriod) {
            uint256 pointsDelta = cachedPointsPerLp - userState.pointsPerLpPaid;
            uint256 newEarned = (lastBalance * pointsDelta) / PRECISION;
            userState.pointsEarned += newEarned;
        }

        // 使用 try-catch 更新用户状态以处理 LP token 调用
        uint256 currentBalance;
        try IERC20(pool.lpToken).balanceOf(user) returns (uint256 balance) {
            currentBalance = balance;
        } catch {
            // LP token 调用失败，保持最后的余额
            currentBalance = lastBalance;
            emit LPTokenQueryFailed(poolId, pool.lpToken);
        }

        userState.pointsPerLpPaid = cachedPointsPerLp;
        userState.lastBalance = currentBalance;
        userState.lastCheckpoint = block.timestamp;
        userState.lastCheckpointBlock = block.number;

        emit UserPoolCheckpointed(user, poolId, userState.pointsEarned, currentBalance);
    }

    /// @notice 计算特定池的用户积分（实时）
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
    // 视图函数 - IPointsModule 实现
    // =============================================================================

    /// @notice 获取用户在所有池中的总积分
    function getPoints(address user) external view override returns (uint256 total) {
        uint256 len = pools.length;
        for (uint256 i = 0; i < len;) {
            total += _getUserPoolPoints(user, i);
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
    // 视图函数 - 附加函数
    // =============================================================================

    /// @notice 获取池的数量
    function getPoolCount() external view returns (uint256) {
        return pools.length;
    }

    /// @notice 获取池信息
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
        if (poolId >= pools.length) revert PoolNotFound(poolId);

        PoolConfig storage pool = pools[poolId];
        lpToken = pool.lpToken;
        multiplier = pool.multiplier;
        poolActive = pool.isActive;
        name = pool.name;

        // 使用 try-catch 的安全 ERC20 调用
        try IERC20(pool.lpToken).totalSupply() returns (uint256 supply) {
            totalSupply = supply;
        } catch {
            totalSupply = 0;
        }

        pointsPerLp = _getPoolPointsPerLp(poolId);
    }

    /// @notice 获取用户按池分类的积分明细
    /// @dev 对 LP token 调用使用 try-catch 以防止 DoS
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
            points[i] = _getUserPoolPoints(user, i);
            multipliers[i] = pools[i].multiplier;

            // 安全的 ERC20 调用
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
            uint256 lastCheckpointTime,
            uint256 lastCheckpointBlock
        )
    {
        if (poolId >= pools.length) revert PoolNotFound(poolId);

        UserPoolState storage userState = userPoolStates[user][poolId];

        // 安全的 ERC20 调用
        try IERC20(pools[poolId].lpToken).balanceOf(user) returns (uint256 bal) {
            balance = bal;
        } catch {
            balance = 0;
        }

        lastCheckpointBalance = userState.lastBalance;
        earnedPoints = _getUserPoolPoints(user, poolId);
        lastCheckpointTime = userState.lastCheckpoint;
        lastCheckpointBlock = userState.lastCheckpointBlock;
    }

    /// @notice 估算 LP 金额在持续时间内的积分
    function estimatePoolPoints(uint256 poolId, uint256 lpAmount, uint256 durationSeconds)
        external
        view
        returns (uint256)
    {
        if (poolId >= pools.length) return 0;
        PoolConfig storage pool = pools[poolId];
        if (!pool.isActive) return 0;

        uint256 totalSupply;
        try IERC20(pool.lpToken).totalSupply() returns (uint256 supply) {
            totalSupply = supply;
        } catch {
            return 0;
        }

        if (totalSupply == 0) return 0;

        uint256 effectiveRate = (basePointsRatePerSecond * pool.multiplier) / MULTIPLIER_BASE;
        uint256 pointsGenerated = durationSeconds * effectiveRate;
        return (lpAmount * pointsGenerated) / totalSupply;
    }

    // =============================================================================
    // 池管理 - 管理员
    // =============================================================================

    /// @notice 添加新的 LP 池
    /// @param lpToken LP token 地址
    /// @param multiplier 积分倍数 (100 = 1x)
    /// @param name 池名称
    function addPool(address lpToken, uint256 multiplier, string calldata name) external onlyRole(ADMIN_ROLE) {
        if (lpToken == address(0)) revert ZeroAddress();
        if (poolIndex[lpToken] != 0) revert PoolAlreadyExists(lpToken);
        if (pools.length >= MAX_POOLS) revert MaxPoolsReached();
        if (multiplier == 0 || multiplier > MAX_MULTIPLIER) revert InvalidMultiplier();

        uint256 poolId = pools.length;
        pools.push(PoolConfig({lpToken: lpToken, multiplier: multiplier, isActive: true, name: name}));

        poolIndex[lpToken] = poolId + 1; // +1 以区分"未找到"
        poolStates[poolId].lastUpdateTime = block.timestamp;

        emit PoolAdded(poolId, lpToken, multiplier, name);
    }

    /// @notice 更新池配置
    /// @param poolId 池 ID
    /// @param multiplier 新倍数
    /// @param poolActive 池是否激活
    function updatePool(uint256 poolId, uint256 multiplier, bool poolActive) external onlyRole(ADMIN_ROLE) {
        if (poolId >= pools.length) revert PoolNotFound(poolId);
        if (multiplier == 0 || multiplier > MAX_MULTIPLIER) revert InvalidMultiplier();

        // 首先使用旧设置检查点
        _updatePoolGlobal(poolId);

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
    /// @dev 不从数组中删除以保持 poolId 稳定性
    /// @param poolId 要移除的池 ID
    function removePool(uint256 poolId) external onlyRole(ADMIN_ROLE) {
        if (poolId >= pools.length) revert PoolNotFound(poolId);

        PoolConfig storage pool = pools[poolId];
        address lpToken = pool.lpToken;

        // 移除前检查点最终状态
        _updatePoolGlobal(poolId);

        // 清除池索引映射
        poolIndex[lpToken] = 0;

        // 将池标记为非激活并清除 LP token（防止未来操作）
        pool.isActive = false;
        pool.lpToken = address(0);
        pool.multiplier = 0;

        emit PoolRemoved(poolId, lpToken);
    }

    // =============================================================================
    // 检查点函数
    // =============================================================================

    /// @notice 内部函数: 检查点所有池的全局状态
    function _checkpointAllPoolsInternal() internal {
        uint256 len = pools.length;
        for (uint256 i = 0; i < len;) {
            _updatePoolGlobal(i);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice 内部函数: 检查点用户在所有池中的状态
    function _checkpointUser(address user) internal {
        uint256 len = pools.length;
        for (uint256 i = 0; i < len;) {
            _updatePoolGlobal(i);
            _updateUserPool(user, i);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice 检查点所有池 (keeper 函数)
    function checkpointAllPools() external onlyRole(KEEPER_ROLE) {
        _checkpointAllPoolsInternal();
    }

    /// @notice 检查点特定的池
    function checkpointPools(uint256[] calldata poolIds) external onlyRole(KEEPER_ROLE) {
        uint256 len = poolIds.length;
        for (uint256 i = 0; i < len;) {
            if (poolIds[i] < pools.length) {
                _updatePoolGlobal(poolIds[i]);
            } else {
                emit CheckpointPoolSkipped(poolIds[i], "PoolNotFound");
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @notice 检查点用户在所有池中的状态 (keeper 函数)
    /// @dev 限制为 MAX_BATCH_USERS 以防止 gas 限制问题
    function checkpointUsers(address[] calldata users) external onlyRole(KEEPER_ROLE) {
        uint256 userLen = users.length;
        if (userLen > MAX_BATCH_USERS) revert BatchTooLarge(userLen, MAX_BATCH_USERS);

        uint256 poolLen = pools.length;
        uint256 totalOps = userLen * poolLen;
        if (totalOps > MAX_OPERATIONS_PER_BATCH) {
            revert TooManyOperations(totalOps, MAX_OPERATIONS_PER_BATCH);
        }

        _checkpointAllPoolsInternal();

        for (uint256 u = 0; u < userLen;) {
            for (uint256 p = 0; p < poolLen;) {
                _updateUserPool(users[u], p);
                unchecked {
                    ++p;
                }
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
        _updatePoolGlobal(poolId);
        _updateUserPool(user, poolId);
    }

    // =============================================================================
    // 管理员函数
    // =============================================================================

    /// @notice 内部函数: 重置所有池的时间戳为当前时间
    function _resetAllPoolTimestamps() internal {
        uint256 len = pools.length;
        for (uint256 i = 0; i < len;) {
            poolStates[i].lastUpdateTime = block.timestamp;
            unchecked {
                ++i;
            }
        }
    }

    /// @notice 设置基础积分率
    function setBaseRate(uint256 newRate) external onlyRole(ADMIN_ROLE) {
        _checkpointAllPoolsInternal();

        uint256 oldRate = basePointsRatePerSecond;
        basePointsRatePerSecond = newRate;

        emit BaseRateUpdated(oldRate, newRate);
    }

    /// @notice 设置模块激活状态
    function setActive(bool _active) external onlyRole(ADMIN_ROLE) {
        if (_active && !active) {
            _resetAllPoolTimestamps();
        } else if (!_active && active) {
            _checkpointAllPoolsInternal();
        }
        active = _active;
        emit ModuleActiveStatusUpdated(_active);
    }

    /// @notice 设置闪电贷保护的最小持有区块数
    /// @param blocks 余额必须持有的最小区块数
    function setMinHoldingBlocks(uint256 blocks) external onlyRole(ADMIN_ROLE) {
        uint256 oldBlocks = minHoldingBlocks;
        minHoldingBlocks = blocks;
        emit MinHoldingBlocksUpdated(oldBlocks, blocks);
    }

    /// @notice 暂停合约操作
    /// @dev 只能由 ADMIN_ROLE 调用
    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    /// @notice 恢复合约操作
    /// @dev 只能由 ADMIN_ROLE 调用
    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    /// @notice 获取合约版本
    /// @return 版本字符串
    function version() external pure returns (string memory) {
        return VERSION;
    }

    // =============================================================================
    // 存储间隙 - 为未来升级保留
    // =============================================================================

    /// @dev 保留的存储空间，允许未来升级时的布局变更
    uint256[50] private __gap;
}
