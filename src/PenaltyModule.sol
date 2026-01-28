// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

import {IPenaltyModule} from "./interfaces/IPointsModule.sol";

/// @title PenaltyModule
/// @author Paimon Protocol
/// @notice 用于追踪兑换惩罚的模块
/// @dev 使用 Merkle 树进行链下惩罚计算
///      惩罚基于 RedemptionSettled 事件在链下计算
contract PenaltyModule is
    IPenaltyModule,
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

    uint256 public constant BASIS_POINTS = 10000;
    string public constant VERSION = "1.3.0";

    /// @notice 惩罚同步的最大批处理大小
    uint256 public constant MAX_BATCH_SIZE = 100;

    /// @notice 新惩罚根生效前的时间延迟（防抢跑）
    uint256 public constant ROOT_DELAY = 24 hours;

    /// @notice 历史记录中保留的最大根数量
    uint256 public constant MAX_ROOT_HISTORY = 100;

    // =============================================================================
    // 状态变量
    // =============================================================================

    /// @notice 当前惩罚数据的 Merkle 根
    bytes32 public penaltyRoot;

    /// @notice 每个用户的已确认惩罚金额
    /// @dev 通过 Merkle 证明验证进行更新
    mapping(address => uint256) public confirmedPenalty;

    /// @notice 基点制的惩罚率（例如，1000 = 10%）
    /// @dev 用于链下计算参考，实际计算在链下进行
    uint256 public penaltyRateBps;

    /// @notice 惩罚根的历史记录
    bytes32[] public rootHistory;

    /// @notice 根到时间戳的映射
    mapping(bytes32 => uint256) public rootTimestamp;

    /// @notice 当前纪元编号
    uint256 public currentEpoch;

    /// @notice 待处理的惩罚根（等待延迟期）
    bytes32 public pendingRoot;

    /// @notice 待处理根生效的时间戳
    uint256 public pendingRootEffectiveTime;

    /// @notice 循环缓冲区的头索引（下一个写入位置）
    uint256 public rootHistoryHead;

    /// @notice 根历史数组是否已环绕
    bool public rootHistoryFull;

    // =============================================================================
    // 事件
    // =============================================================================

    event PenaltyRootQueued(bytes32 indexed newRoot, uint256 effectiveTime);

    event PenaltyRootActivated(bytes32 indexed oldRoot, bytes32 indexed newRoot, uint256 epoch, uint256 timestamp);

    event PenaltyRootUpdated(bytes32 indexed oldRoot, bytes32 indexed newRoot, uint256 epoch, uint256 timestamp);
    event PenaltyConfirmed(address indexed user, uint256 previousPenalty, uint256 newPenalty, uint256 epoch);
    event PenaltyRateUpdated(uint256 oldRate, uint256 newRate);
    event PenaltyModuleUpgraded(address indexed newImplementation, uint256 timestamp);
    event BatchSyncSkipped(address indexed user, string reason);
    event PendingRootCancelled(bytes32 indexed cancelledRoot, uint256 epoch, address indexed admin);

    // =============================================================================
    // 错误
    // =============================================================================

    error ZeroAddress();
    error InvalidProof();
    error ProofForPendingRoot(bytes32 currentRoot, bytes32 pendingRoot, uint256 effectiveTime);
    error PenaltyRootNotSet();
    error InvalidPenaltyRate();
    error ArrayLengthMismatch();
    error BatchTooLarge(uint256 size, uint256 max);
    error PendingRootNotReady(uint256 currentTime, uint256 effectiveTime);
    error NoPendingRoot();
    error PenaltyCannotDecrease(uint256 current, uint256 requested);

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
    /// @param _penaltyRateBps 基点制的初始惩罚率
    function initialize(address admin, address keeper, address upgrader, uint256 _penaltyRateBps) external initializer {
        if (admin == address(0) || keeper == address(0) || upgrader == address(0)) revert ZeroAddress();
        if (_penaltyRateBps > BASIS_POINTS) revert InvalidPenaltyRate();

        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        penaltyRateBps = _penaltyRateBps;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);
        _grantRole(KEEPER_ROLE, keeper);
        _grantRole(UPGRADER_ROLE, upgrader);
    }

    // =============================================================================
    // UUPS 升级
    // =============================================================================

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {
        emit PenaltyModuleUpgraded(newImplementation, block.timestamp);
    }

    // =============================================================================
    // 内部辅助函数
    // =============================================================================

    /// @notice 计算用户惩罚的 Merkle 叶子
    /// @param user 用户地址
    /// @param totalPenalty 总累积惩罚
    /// @return Merkle 叶子哈希
    function _computeLeaf(address user, uint256 totalPenalty) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(user, totalPenalty))));
    }

    // =============================================================================
    // 视图函数 - IPenaltyModule 实现
    // =============================================================================

    /// @notice 获取用户的惩罚积分
    /// @param user 用户地址
    /// @return 已确认的惩罚积分
    function getPenalty(address user) external view override returns (uint256) {
        return confirmedPenalty[user];
    }

    // =============================================================================
    // 视图函数 - 额外功能
    // =============================================================================

    /// @notice 验证惩罚证明
    /// @param user 用户地址
    /// @param totalPenalty 总累积惩罚
    /// @param proof Merkle 证明
    /// @return valid 证明是否有效
    function verifyPenalty(address user, uint256 totalPenalty, bytes32[] calldata proof)
        public
        view
        returns (bool valid)
    {
        if (penaltyRoot == bytes32(0)) return false;

        bytes32 leaf = _computeLeaf(user, totalPenalty);
        return MerkleProof.verify(proof, penaltyRoot, leaf);
    }

    /// @notice 获取根历史记录长度
    function getRootHistoryLength() external view returns (uint256) {
        return rootHistory.length;
    }

    /// @notice 计算兑换金额的惩罚（仅供参考）
    /// @param redemptionAmount 基础单位的兑换金额
    /// @return 惩罚金额
    function calculatePenalty(uint256 redemptionAmount) external view returns (uint256) {
        return (redemptionAmount * penaltyRateBps) / BASIS_POINTS;
    }

    // =============================================================================
    // 同步函数
    // =============================================================================

    /// @notice 使用 Merkle 证明同步用户惩罚
    /// @dev 可由 keeper 或用户自己调用
    /// @param user 用户地址
    /// @param totalPenalty 来自 Merkle 树的总累积惩罚
    /// @param proof Merkle 证明
    function syncPenalty(address user, uint256 totalPenalty, bytes32[] calldata proof)
        external
        nonReentrant
        whenNotPaused
    {
        if (penaltyRoot == bytes32(0)) revert PenaltyRootNotSet();

        // 验证证明
        bytes32 leaf = _computeLeaf(user, totalPenalty);
        if (!MerkleProof.verify(proof, penaltyRoot, leaf)) {
            revert InvalidProof();
        }

        // 仅当新惩罚更高时才更新（惩罚只会增加）
        if (totalPenalty > confirmedPenalty[user]) {
            uint256 previousPenalty = confirmedPenalty[user];
            confirmedPenalty[user] = totalPenalty;

            emit PenaltyConfirmed(user, previousPenalty, totalPenalty, currentEpoch);
        }
    }

    /// @notice 批量同步多个用户的惩罚
    /// @param users 用户地址数组
    /// @param totalPenalties 总惩罚数组
    /// @param proofs Merkle 证明数组
    function batchSyncPenalty(address[] calldata users, uint256[] calldata totalPenalties, bytes32[][] calldata proofs)
        external
        onlyRole(KEEPER_ROLE)
        whenNotPaused
    {
        if (penaltyRoot == bytes32(0)) revert PenaltyRootNotSet();

        uint256 len = users.length;
        if (len != totalPenalties.length || len != proofs.length) revert ArrayLengthMismatch();
        if (len > MAX_BATCH_SIZE) revert BatchTooLarge(len, MAX_BATCH_SIZE);

        for (uint256 i = 0; i < len;) {
            address user = users[i];
            uint256 totalPenalty = totalPenalties[i];
            bytes32[] calldata proof = proofs[i];

            // 验证证明
            bytes32 leaf = _computeLeaf(user, totalPenalty);
            if (!MerkleProof.verify(proof, penaltyRoot, leaf)) {
                emit BatchSyncSkipped(user, "InvalidProof");
                unchecked {
                    ++i;
                }
                continue;
            }

            // 仅当更高时才更新
            if (totalPenalty > confirmedPenalty[user]) {
                uint256 previousPenalty = confirmedPenalty[user];
                confirmedPenalty[user] = totalPenalty;

                emit PenaltyConfirmed(user, previousPenalty, totalPenalty, currentEpoch);
            } else {
                emit BatchSyncSkipped(user, "PenaltyNotHigher");
            }
            unchecked {
                ++i;
            }
        }
    }

    // =============================================================================
    // Keeper 函数
    // =============================================================================

    /// @notice 激活待处理根的内部函数
    /// @dev 使用循环缓冲区实现 O(1) gas 成本，而非 O(n) 数组移动
    function _activateRoot() internal {
        bytes32 oldRoot = penaltyRoot;
        penaltyRoot = pendingRoot;

        // 循环缓冲区实现 - O(1) gas 成本
        if (rootHistory.length < MAX_ROOT_HISTORY) {
            // 数组未满，直接推送
            rootHistory.push(pendingRoot);
        } else {
            // 数组已满，在头位置覆盖
            // 删除此位置的旧时间戳
            delete rootTimestamp[rootHistory[rootHistoryHead]];
            rootHistory[rootHistoryHead] = pendingRoot;
            rootHistoryHead = (rootHistoryHead + 1) % MAX_ROOT_HISTORY;
            rootHistoryFull = true;
        }

        rootTimestamp[pendingRoot] = block.timestamp;
        currentEpoch++;

        emit PenaltyRootActivated(oldRoot, pendingRoot, currentEpoch, block.timestamp);
        emit PenaltyRootUpdated(oldRoot, pendingRoot, currentEpoch, block.timestamp);

        // 清除待处理状态
        pendingRoot = bytes32(0);
        pendingRootEffectiveTime = 0;
    }

    /// @notice 排队新的惩罚根（将在 ROOT_DELAY 后生效）
    function updatePenaltyRoot(bytes32 newRoot) external onlyRole(KEEPER_ROLE) {
        // 如果有准备好的待处理根，先激活它
        if (pendingRoot != bytes32(0) && block.timestamp >= pendingRootEffectiveTime) {
            _activateRoot();
        }

        pendingRoot = newRoot;
        pendingRootEffectiveTime = block.timestamp + ROOT_DELAY;

        emit PenaltyRootQueued(newRoot, pendingRootEffectiveTime);
    }

    /// @notice 在延迟期后激活待处理根
    function activateRoot() external {
        if (pendingRoot == bytes32(0)) revert NoPendingRoot();
        if (block.timestamp < pendingRootEffectiveTime) {
            revert PendingRootNotReady(block.timestamp, pendingRootEffectiveTime);
        }
        _activateRoot();
    }

    /// @notice 紧急：立即激活根（仅限管理员，绕过延迟）
    function emergencyActivateRoot() external onlyRole(ADMIN_ROLE) {
        if (pendingRoot == bytes32(0)) revert NoPendingRoot();
        _activateRoot();
    }

    /// @notice 取消待处理根（仅限管理员）
    /// @dev 当排队的根有错误需要替换时使用
    function cancelPendingRoot() external onlyRole(ADMIN_ROLE) {
        if (pendingRoot == bytes32(0)) revert NoPendingRoot();

        bytes32 cancelledRoot = pendingRoot;
        uint256 cancelledEpoch = currentEpoch + 1;

        pendingRoot = bytes32(0);
        pendingRootEffectiveTime = 0;

        emit PendingRootCancelled(cancelledRoot, cancelledEpoch, msg.sender);
    }

    // =============================================================================
    // 管理员函数
    // =============================================================================

    /// @notice 设置惩罚率
    /// @param newRateBps 新的基点制费率（最大 10000 = 100%）
    function setPenaltyRate(uint256 newRateBps) external onlyRole(ADMIN_ROLE) {
        if (newRateBps > BASIS_POINTS) revert InvalidPenaltyRate();

        uint256 oldRate = penaltyRateBps;
        penaltyRateBps = newRateBps;

        emit PenaltyRateUpdated(oldRate, newRateBps);
    }

    /// @notice 管理员覆盖：增加用户的已确认惩罚
    /// @dev 惩罚只能增加，不能减少（安全约束）
    /// @param user 用户地址
    /// @param penalty 新的惩罚值（必须 >= 当前惩罚）
    function setUserPenalty(address user, uint256 penalty) external onlyRole(ADMIN_ROLE) {
        uint256 previousPenalty = confirmedPenalty[user];
        if (penalty < previousPenalty) {
            revert PenaltyCannotDecrease(previousPenalty, penalty);
        }
        confirmedPenalty[user] = penalty;

        emit PenaltyConfirmed(user, previousPenalty, penalty, currentEpoch);
    }

    /// @notice 批量设置惩罚（用于迁移/修复的管理员函数）
    function batchSetPenalties(address[] calldata users, uint256[] calldata penalties) external onlyRole(ADMIN_ROLE) {
        uint256 len = users.length;
        if (len != penalties.length) revert ArrayLengthMismatch();
        if (len > MAX_BATCH_SIZE) revert BatchTooLarge(len, MAX_BATCH_SIZE);

        for (uint256 i = 0; i < len;) {
            uint256 previousPenalty = confirmedPenalty[users[i]];
            confirmedPenalty[users[i]] = penalties[i];

            emit PenaltyConfirmed(users[i], previousPenalty, penalties[i], currentEpoch);
            unchecked {
                ++i;
            }
        }
    }

    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

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

    /// @dev 保留的存储空间，允许在未来升级中进行布局更改
    uint256[50] private __gap;
}
