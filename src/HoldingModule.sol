// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {IPointsModule, IPPT} from "./interfaces/IPointsModule.sol";

/// @title HoldingModule
/// @author Paimon Protocol
/// @notice PPT 持有奖励积分模块
/// @dev 使用 Synthetix 风格的奖励算法和检查点机制
///      积分基于 PPT 余额随时间累积
contract HoldingModule is
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
    string public constant MODULE_NAME = "PPT Holding";
    string public constant VERSION = "1.3.0";

    /// @notice 用户检查点的最大批处理大小
    uint256 public constant MAX_BATCH_USERS = 100;

    // =============================================================================
    // 状态变量
    // =============================================================================

    /// @notice PPT Vault 合约
    IPPT public ppt;

    /// @notice 每个 PPT 份额每秒生成的积分（1e18 精度）
    uint256 public pointsRatePerSecond;

    /// @notice 全局状态最后更新时间
    uint256 public lastUpdateTime;

    /// @notice 每份额累积积分（1e18 精度）
    uint256 public pointsPerShareStored;

    /// @notice 用户最后记录的每份额积分
    mapping(address => uint256) public userPointsPerSharePaid;

    /// @notice 用户累积获得的积分
    mapping(address => uint256) public userPointsEarned;

    /// @notice 用户最后记录的余额（检查点时）
    mapping(address => uint256) public userLastBalance;

    /// @notice 用户最后检查点时间戳
    mapping(address => uint256) public userLastCheckpoint;

    /// @notice 用户最后检查点区块号（用于闪电贷保护）
    mapping(address => uint256) public userLastCheckpointBlock;

    /// @notice 模块是否激活
    bool public active;

    /// @notice 赚取积分所需的最小余额
    uint256 public minBalanceThreshold;

    /// @notice 是否使用 effectiveSupply (true) 或 totalSupply (false)
    /// @dev 基于 PPT 是否支持 effectiveSupply() 设置
    bool public useEffectiveSupply;

    /// @notice effectiveSupply 模式是否已确定
    bool public supplyModeInitialized;

    /// @notice 余额在计入积分前必须持有的最小区块数（闪电贷保护）
    uint256 public minHoldingBlocks;

    // =============================================================================
    // 事件
    // =============================================================================

    event GlobalCheckpointed(uint256 pointsPerShare, uint256 timestamp, uint256 effectiveSupply);
    event UserCheckpointed(address indexed user, uint256 pointsEarned, uint256 balance, uint256 timestamp);
    event PointsRateUpdated(uint256 oldRate, uint256 newRate);
    event MinBalanceThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);
    event ModuleActiveStatusUpdated(bool active);
    event HoldingModuleUpgraded(address indexed newImplementation, uint256 timestamp);
    event SupplyModeInitialized(bool useEffectiveSupply);
    event PptUpdated(address indexed oldPpt, address indexed newPpt);

    // =============================================================================
    // 错误
    // =============================================================================

    error ZeroAddress();
    error ZeroRate();
    error BatchTooLarge(uint256 size, uint256 max);

    // =============================================================================
    // 附加事件
    // =============================================================================

    event MinHoldingBlocksUpdated(uint256 oldBlocks, uint256 newBlocks);

    // =============================================================================
    // 构造函数和初始化器
    // =============================================================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice 初始化合约
    /// @param _ppt PPT Vault 地址
    /// @param admin 管理员地址
    /// @param keeper Keeper 地址（用于检查点）
    /// @param upgrader 升级者地址（通常为时间锁）
    /// @param _pointsRatePerSecond 每个 PPT 每秒的初始积分速率
    function initialize(address _ppt, address admin, address keeper, address upgrader, uint256 _pointsRatePerSecond)
        external
        initializer
    {
        if (_ppt == address(0) || admin == address(0) || keeper == address(0) || upgrader == address(0)) {
            revert ZeroAddress();
        }

        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        ppt = IPPT(_ppt);
        pointsRatePerSecond = _pointsRatePerSecond;
        lastUpdateTime = block.timestamp;
        active = true;
        minHoldingBlocks = 1; // 默认：1 个区块用于闪电贷保护

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);
        _grantRole(KEEPER_ROLE, keeper);
        _grantRole(UPGRADER_ROLE, upgrader);
    }

    // =============================================================================
    // UUPS 升级
    // =============================================================================

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {
        emit HoldingModuleUpgraded(newImplementation, block.timestamp);
    }

    // =============================================================================
    // 核心逻辑 - 内部函数
    // =============================================================================

    /// @notice 计算当前每份额积分
    /// @return 当前累积的每份额积分
    function _currentPointsPerShare() internal view returns (uint256) {
        if (!active) return pointsPerShareStored;

        uint256 supply = _getEffectiveSupply();
        if (supply == 0) return pointsPerShareStored;

        uint256 timeDelta = block.timestamp - lastUpdateTime;
        uint256 newPoints = timeDelta * pointsRatePerSecond;

        return pointsPerShareStored + (newPoints * PRECISION) / supply;
    }

    /// @notice 获取用于计算的有效供应量
    /// @dev 如果 PPT 支持则使用 effectiveSupply，否则使用 totalSupply
    function _getEffectiveSupply() internal view returns (uint256) {
        if (supplyModeInitialized) {
            return useEffectiveSupply ? ppt.effectiveSupply() : ppt.totalSupply();
        }
        // 初始化前视图调用的回退
        try ppt.effectiveSupply() returns (uint256 supply) {
            return supply;
        } catch {
            return ppt.totalSupply();
        }
    }

    /// @notice 通过检测 PPT 能力初始化供应量模式
    /// @dev 在第一次全局更新期间调用一次
    function _initSupplyMode() internal {
        if (supplyModeInitialized) return;

        try ppt.effectiveSupply() returns (uint256) {
            useEffectiveSupply = true;
        } catch {
            useEffectiveSupply = false;
        }
        supplyModeInitialized = true;
        emit SupplyModeInitialized(useEffectiveSupply);
    }

    /// @notice 更新全局状态
    function _updateGlobal() internal {
        _initSupplyMode();
        uint256 supply = _getEffectiveSupply();
        pointsPerShareStored = _currentPointsPerShare();
        lastUpdateTime = block.timestamp;

        emit GlobalCheckpointed(pointsPerShareStored, block.timestamp, supply);
    }

    /// @notice 更新用户状态
    /// @param user 要更新的用户地址
    function _updateUser(address user) internal {
        uint256 cachedPointsPerShare = pointsPerShareStored;
        uint256 lastBalance = userLastBalance[user];
        uint256 lastCheckpointBlock = userLastCheckpointBlock[user];

        // 闪电贷保护：仅在最小持有区块数已过时才记入积分
        // 这可以防止攻击者借用代币、设置检查点并在同一区块内归还
        bool passedHoldingPeriod = lastCheckpointBlock == 0 || block.number >= lastCheckpointBlock + minHoldingBlocks;

        // 使用最后记录的余额计算新赚取的积分
        // 仅在满足持有期要求时才记入
        if (lastBalance > 0 && lastBalance >= minBalanceThreshold && passedHoldingPeriod) {
            uint256 pointsDelta = cachedPointsPerShare - userPointsPerSharePaid[user];
            uint256 newEarned = (lastBalance * pointsDelta) / PRECISION;
            userPointsEarned[user] += newEarned;
        }

        // 更新用户状态
        uint256 newBalance = ppt.balanceOf(user);
        userPointsPerSharePaid[user] = cachedPointsPerShare;
        userLastBalance[user] = newBalance;
        userLastCheckpoint[user] = block.timestamp;
        userLastCheckpointBlock[user] = block.number;

        emit UserCheckpointed(user, userPointsEarned[user], newBalance, block.timestamp);
    }

    // =============================================================================
    // 视图函数 - IPointsModule 实现
    // =============================================================================

    /// @notice 用户积分的内部计算
    /// @param user 用户地址
    /// @return 累积的总积分
    function _calculatePoints(address user) internal view returns (uint256) {
        if (!active) return userPointsEarned[user];

        uint256 lastBalance = userLastBalance[user];
        uint256 cachedPointsPerShare = _currentPointsPerShare();

        // 从最后检查点计算赚取的积分
        uint256 earned = userPointsEarned[user];

        // 使用最后记录的余额添加从最后检查点到现在的积分
        if (lastBalance > 0 && lastBalance >= minBalanceThreshold) {
            uint256 pointsDelta = cachedPointsPerShare - userPointsPerSharePaid[user];
            earned += (lastBalance * pointsDelta) / PRECISION;
        }

        return earned;
    }

    /// @notice 获取用户积分（实时计算）
    /// @param user 用户地址
    /// @return 累积的总积分
    function getPoints(address user) external view override returns (uint256) {
        return _calculatePoints(user);
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
    // 视图函数 - 附加功能
    // =============================================================================

    /// @notice 获取当前每份额积分
    function currentPointsPerShare() external view returns (uint256) {
        return _currentPointsPerShare();
    }

    /// @notice 获取用户的详细状态
    /// @param user 用户地址
    /// @return balance 当前 PPT 余额
    /// @return lastCheckpointBalance 最后检查点时的余额
    /// @return earnedPoints 总赚取积分
    /// @return lastCheckpointTime 最后检查点时间戳
    function getUserState(address user)
        external
        view
        returns (uint256 balance, uint256 lastCheckpointBalance, uint256 earnedPoints, uint256 lastCheckpointTime)
    {
        balance = ppt.balanceOf(user);
        lastCheckpointBalance = userLastBalance[user];
        earnedPoints = _calculatePoints(user);
        lastCheckpointTime = userLastCheckpoint[user];
    }

    /// @notice 计算在一段时间内将赚取的积分
    /// @param balance PPT 余额
    /// @param durationSeconds 持续时间（秒）
    /// @return 估算的积分
    function estimatePoints(uint256 balance, uint256 durationSeconds) external view returns (uint256) {
        if (balance < minBalanceThreshold) return 0;
        uint256 supply = _getEffectiveSupply();
        if (supply == 0) return 0;

        uint256 pointsGenerated = durationSeconds * pointsRatePerSecond;
        return (balance * pointsGenerated) / supply;
    }

    // =============================================================================
    // 检查点函数
    // =============================================================================

    /// @notice 检查点全局状态（keeper 函数）
    function checkpointGlobal() external onlyRole(KEEPER_ROLE) {
        _updateGlobal();
    }

    /// @notice 检查点多个用户（keeper 函数）
    /// @param users 要检查点的用户地址数组
    function checkpointUsers(address[] calldata users) external onlyRole(KEEPER_ROLE) {
        uint256 len = users.length;
        if (len > MAX_BATCH_USERS) revert BatchTooLarge(len, MAX_BATCH_USERS);

        _updateGlobal();

        for (uint256 i = 0; i < len;) {
            _updateUser(users[i]);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice 检查点单个用户（任何人都可以调用）
    /// @param user 要检查点的用户地址
    function checkpoint(address user) external {
        _updateGlobal();
        _updateUser(user);
    }

    /// @notice 检查点调用者
    function checkpointSelf() external {
        _updateGlobal();
        _updateUser(msg.sender);
    }

    // =============================================================================
    // 管理员函数
    // =============================================================================

    /// @notice 设置每秒积分速率
    /// @param newRate 新速率（1e18 精度）
    function setPointsRate(uint256 newRate) external onlyRole(ADMIN_ROLE) {
        // 首先使用旧速率更新全局状态
        _updateGlobal();

        uint256 oldRate = pointsRatePerSecond;
        pointsRatePerSecond = newRate;

        emit PointsRateUpdated(oldRate, newRate);
    }

    /// @notice 设置最小余额阈值
    /// @param threshold 赚取积分所需的最小余额
    function setMinBalanceThreshold(uint256 threshold) external onlyRole(ADMIN_ROLE) {
        uint256 oldThreshold = minBalanceThreshold;
        minBalanceThreshold = threshold;
        emit MinBalanceThresholdUpdated(oldThreshold, threshold);
    }

    /// @notice 设置模块激活状态
    /// @param _active 模块是否激活
    function setActive(bool _active) external onlyRole(ADMIN_ROLE) {
        if (_active && !active) {
            // 重新激活 - 将 lastUpdateTime 更新为当前时间
            lastUpdateTime = block.timestamp;
        } else if (!_active && active) {
            // 停用 - 完成当前积分
            _updateGlobal();
        }
        active = _active;
        emit ModuleActiveStatusUpdated(_active);
    }

    /// @notice 更新 PPT 地址（仅紧急情况）
    /// @param _ppt 新的 PPT 地址
    function setPpt(address _ppt) external onlyRole(ADMIN_ROLE) {
        if (_ppt == address(0)) revert ZeroAddress();
        if (_ppt == address(ppt)) return; // 无需更改
        _updateGlobal();
        address oldPpt = address(ppt);
        ppt = IPPT(_ppt);
        // 为新 PPT 重置供应量模式检测
        supplyModeInitialized = false;
        emit PptUpdated(oldPpt, _ppt);
    }

    /// @notice 强制设置供应量模式（管理员覆盖）
    /// @param _useEffectiveSupply 是否使用 effectiveSupply
    function setSupplyMode(bool _useEffectiveSupply) external onlyRole(ADMIN_ROLE) {
        useEffectiveSupply = _useEffectiveSupply;
        supplyModeInitialized = true;
        emit SupplyModeInitialized(_useEffectiveSupply);
    }

    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    /// @notice 设置闪电贷保护的最小持有区块数
    /// @param blocks 余额必须持有的最小区块数
    function setMinHoldingBlocks(uint256 blocks) external onlyRole(ADMIN_ROLE) {
        uint256 oldBlocks = minHoldingBlocks;
        minHoldingBlocks = blocks;
        emit MinHoldingBlocksUpdated(oldBlocks, blocks);
    }

    /// @notice 获取合约版本
    /// @return 版本字符串
    function version() external pure returns (string memory) {
        return VERSION;
    }

    // =============================================================================
    // 存储间隙 - 为未来升级保留
    // =============================================================================

    /// @dev 预留存储空间以允许未来升级时的布局更改
    uint256[50] private __gap;
}
