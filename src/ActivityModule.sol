// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

import {IPointsModule} from "./interfaces/IPointsModule.sol";

/// @title 活动模块
/// @author Paimon Protocol
/// @notice 用于交易和活动奖励的积分模块
/// @dev 使用Merkle树进行链外计算验证
///      积分在链外计算，用户使用证明进行领取
contract ActivityModule is
    IPointsModule,
    Initializable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    // =============================================================================
    // 常量 & 角色
    // =============================================================================

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    string public constant MODULE_NAME = "Trading & Activity";
    string public constant VERSION = "1.3.0";

    /// @notice 批量领取的最大批次大小
    uint256 public constant MAX_BATCH_SIZE = 100;

    /// @notice 新的 Merkle 根生效前的时间延迟（防抢跑）
    uint256 public constant ROOT_DELAY = 24 hours;

    /// @notice 历史记录中保留的根的最大数量
    uint256 public constant MAX_ROOT_HISTORY = 100;

    // =============================================================================
    // 状态变量
    // =============================================================================

    /// @notice 用于积分领取的当前 Merkle 根
    bytes32 public merkleRoot;

    /// @notice 用户地址到已领取累计积分的映射
    mapping(address => uint256) public claimedPoints;

    /// @notice 模块是否激活
    bool public active;

    /// @notice 用于审计的 Merkle 根历史记录
    bytes32[] public rootHistory;

    /// @notice 根到其设置时间戳的映射
    mapping(bytes32 => uint256) public rootTimestamp;

    /// @notice 当前周期/时期编号
    uint256 public currentEpoch;

    /// @notice 当前周期的描述/标签
    string public currentEpochLabel;

    /// @notice 待处理的 Merkle 根（等待延迟期）
    bytes32 public pendingRoot;

    /// @notice 待处理的根生效的时间戳
    uint256 public pendingRootEffectiveTime;

    /// @notice 待处理的周期编号
    uint256 public pendingEpoch;

    /// @notice 待处理的周期标签
    string public pendingEpochLabel;

    /// @notice 循环缓冲区的头索引（下一个写入位置）
    uint256 public rootHistoryHead;

    /// @notice 根历史数组是否已循环回绕
    bool public rootHistoryFull;

    // =============================================================================
    // 事件
    // =============================================================================

    event MerkleRootQueued(bytes32 indexed newRoot, uint256 epoch, string label, uint256 effectiveTime);

    event MerkleRootActivated(bytes32 indexed oldRoot, bytes32 indexed newRoot, uint256 epoch, uint256 timestamp);

    event MerkleRootUpdated(
        bytes32 indexed oldRoot, bytes32 indexed newRoot, uint256 epoch, string label, uint256 timestamp
    );
    event PointsClaimed(address indexed user, uint256 claimedAmount, uint256 totalClaimed, uint256 epoch);
    event ModuleActiveStatusUpdated(bool active);
    event ActivityModuleUpgraded(address indexed newImplementation, uint256 timestamp);
    event BatchClaimSkipped(address indexed user, string reason);

    // =============================================================================
    // 错误
    // =============================================================================

    error ZeroAddress();
    error InvalidProof();
    error ProofForPendingRoot(bytes32 currentRoot, bytes32 pendingRoot, uint256 effectiveTime);
    error NothingToClaim();
    error MerkleRootNotSet();
    error ClaimExceedsMerkleAmount(uint256 claimed, uint256 merkleAmount);
    error ArrayLengthMismatch();
    error BatchTooLarge(uint256 size, uint256 max);
    error IndexOutOfBounds(uint256 index, uint256 length);
    error PendingRootNotReady(uint256 currentTime, uint256 effectiveTime);
    error NoPendingRoot();

    // =============================================================================
    // 附加事件
    // =============================================================================

    event UserClaimedReset(address indexed user, uint256 previousAmount, uint256 newAmount, address indexed admin);
    event PendingRootCancelled(bytes32 indexed cancelledRoot, uint256 epoch, address indexed admin);

    // =============================================================================
    // 构造函数 & 初始化器
    // =============================================================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice 初始化合约
    /// @param admin 管理员地址
    /// @param keeper Keeper 地址（用于更新 Merkle 根）
    /// @param upgrader 升级者地址
    function initialize(address admin, address keeper, address upgrader) external initializer {
        if (admin == address(0) || keeper == address(0) || upgrader == address(0)) revert ZeroAddress();

        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        active = true;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);
        _grantRole(KEEPER_ROLE, keeper);
        _grantRole(UPGRADER_ROLE, upgrader);
    }

    // =============================================================================
    // UUPS 升级
    // =============================================================================

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {
        emit ActivityModuleUpgraded(newImplementation, block.timestamp);
    }

    // =============================================================================
    // 内部辅助函数
    // =============================================================================

    /// @notice 计算用户获得积分的 Merkle 叶子
    /// @param user 用户地址
    /// @param totalEarned 总累计获得积分
    /// @return Merkle 叶子哈希
    function _computeLeaf(address user, uint256 totalEarned) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(user, totalEarned))));
    }

    // =============================================================================
    // 视图函数 - IPointsModule 实现
    // =============================================================================

    /// @notice 获取用户的积分
    /// @dev 仅返回已领取的积分；未领取的积分需要链外查询
    /// @param user 用户地址
    /// @return 已领取的积分
    function getPoints(address user) external view override returns (uint256) {
        return claimedPoints[user];
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
    // 视图函数 - 附加
    // =============================================================================

    /// @notice 验证领取请求但不执行
    /// @param user 用户地址
    /// @param totalEarned Merkle 树中的总累计获得积分
    /// @param proof Merkle 证明
    /// @return valid 证明是否有效
    /// @return claimable 可以领取的数量
    function verifyClaim(address user, uint256 totalEarned, bytes32[] calldata proof)
        public
        view
        returns (bool valid, uint256 claimable)
    {
        if (merkleRoot == bytes32(0)) return (false, 0);

        bytes32 leaf = _computeLeaf(user, totalEarned);
        valid = MerkleProof.verify(proof, merkleRoot, leaf);

        if (valid && totalEarned > claimedPoints[user]) {
            claimable = totalEarned - claimedPoints[user];
        }
    }

    /// @notice 获取根历史记录长度
    function getRootHistoryLength() external view returns (uint256) {
        return rootHistory.length;
    }

    /// @notice 获取指定索引处的根
    function getRootAt(uint256 index) external view returns (bytes32 root, uint256 timestamp) {
        if (index >= rootHistory.length) revert IndexOutOfBounds(index, rootHistory.length);
        root = rootHistory[index];
        timestamp = rootTimestamp[root];
    }

    /// @notice 获取用户的领取状态
    /// @param user 用户地址
    /// @return claimed 已领取的数量
    /// @return lastClaimTime 时间戳（从根更新近似得出）
    function getUserClaimStatus(address user) external view returns (uint256 claimed, uint256 lastClaimTime) {
        claimed = claimedPoints[user];
        // 注意：我们不跟踪单独的领取时间，返回根时间戳作为近似值
        if (merkleRoot != bytes32(0)) {
            lastClaimTime = rootTimestamp[merkleRoot];
        }
    }

    // =============================================================================
    // 用户函数
    // =============================================================================

    /// @notice 使用 Merkle 证明领取积分
    /// @param totalEarned 总累计获得积分（来自 Merkle 树）
    /// @param proof Merkle 证明
    function claim(uint256 totalEarned, bytes32[] calldata proof) external nonReentrant whenNotPaused {
        if (merkleRoot == bytes32(0)) revert MerkleRootNotSet();

        // 验证证明
        bytes32 leaf = _computeLeaf(msg.sender, totalEarned);
        if (!MerkleProof.verify(proof, merkleRoot, leaf)) {
            revert InvalidProof();
        }

        // 计算可领取数量
        uint256 alreadyClaimed = claimedPoints[msg.sender];
        if (totalEarned <= alreadyClaimed) {
            revert NothingToClaim();
        }

        uint256 toClaim = totalEarned - alreadyClaimed;

        // 更新已领取数量
        claimedPoints[msg.sender] = totalEarned;

        emit PointsClaimed(msg.sender, toClaim, totalEarned, currentEpoch);
    }

    /// @notice 为多个用户批量领取（keeper 可以帮助用户领取）
    /// @dev 用户必须在链外签名或这是空投场景
    /// @param users 用户地址数组
    /// @param totalEarnedAmounts 总获得数量数组
    /// @param proofs Merkle 证明数组
    function batchClaim(address[] calldata users, uint256[] calldata totalEarnedAmounts, bytes32[][] calldata proofs)
        external
        onlyRole(KEEPER_ROLE)
        whenNotPaused
    {
        if (merkleRoot == bytes32(0)) revert MerkleRootNotSet();

        uint256 len = users.length;
        if (len != totalEarnedAmounts.length || len != proofs.length) revert ArrayLengthMismatch();
        if (len > MAX_BATCH_SIZE) revert BatchTooLarge(len, MAX_BATCH_SIZE);

        for (uint256 i = 0; i < len;) {
            address user = users[i];
            uint256 totalEarned = totalEarnedAmounts[i];
            bytes32[] calldata proof = proofs[i];

            // 验证证明
            bytes32 leaf = _computeLeaf(user, totalEarned);
            if (!MerkleProof.verify(proof, merkleRoot, leaf)) {
                emit BatchClaimSkipped(user, "InvalidProof");
                unchecked {
                    ++i;
                }
                continue;
            }

            // 计算可领取数量
            uint256 alreadyClaimed = claimedPoints[user];
            if (totalEarned <= alreadyClaimed) {
                emit BatchClaimSkipped(user, "NothingToClaim");
                unchecked {
                    ++i;
                }
                continue;
            }

            uint256 toClaim = totalEarned - alreadyClaimed;
            claimedPoints[user] = totalEarned;

            emit PointsClaimed(user, toClaim, totalEarned, currentEpoch);
            unchecked {
                ++i;
            }
        }
    }

    // =============================================================================
    // Keeper 函数
    // =============================================================================

    /// @notice 激活待处理根的内部函数
    /// @dev 使用循环缓冲区实现 O(1) gas 成本而不是 O(n) 数组移位
    function _activateRoot() internal {
        bytes32 oldRoot = merkleRoot;
        merkleRoot = pendingRoot;

        // 循环缓冲区实现 - O(1) gas 成本
        if (rootHistory.length < MAX_ROOT_HISTORY) {
            // 数组尚未填满，直接推入
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

        currentEpoch = pendingEpoch;
        currentEpochLabel = pendingEpochLabel;

        emit MerkleRootActivated(oldRoot, pendingRoot, pendingEpoch, block.timestamp);
        emit MerkleRootUpdated(oldRoot, pendingRoot, pendingEpoch, pendingEpochLabel, block.timestamp);

        // 清除待处理状态
        pendingRoot = bytes32(0);
        pendingRootEffectiveTime = 0;
    }

    /// @notice 将新的 Merkle 根加入队列（将在 ROOT_DELAY 后生效）
    /// @param newRoot 新的 Merkle 根
    /// @param label 此周期的描述
    function updateMerkleRoot(bytes32 newRoot, string calldata label) external onlyRole(KEEPER_ROLE) {
        // 如果有准备就绪的待处理根，首先激活它
        if (pendingRoot != bytes32(0) && block.timestamp >= pendingRootEffectiveTime) {
            _activateRoot();
        }

        pendingRoot = newRoot;
        pendingEpoch = currentEpoch + 1;
        pendingEpochLabel = label;
        pendingRootEffectiveTime = block.timestamp + ROOT_DELAY;

        emit MerkleRootQueued(newRoot, pendingEpoch, label, pendingRootEffectiveTime);
    }

    /// @notice 将具有特定周期编号的 Merkle 根加入队列
    function updateMerkleRootWithEpoch(bytes32 newRoot, uint256 epoch, string calldata label)
        external
        onlyRole(KEEPER_ROLE)
    {
        if (pendingRoot != bytes32(0) && block.timestamp >= pendingRootEffectiveTime) {
            _activateRoot();
        }

        pendingRoot = newRoot;
        pendingEpoch = epoch;
        pendingEpochLabel = label;
        pendingRootEffectiveTime = block.timestamp + ROOT_DELAY;

        emit MerkleRootQueued(newRoot, epoch, label, pendingRootEffectiveTime);
    }

    /// @notice 在延迟期后激活待处理的根
    function activateRoot() external {
        if (pendingRoot == bytes32(0)) revert NoPendingRoot();
        if (block.timestamp < pendingRootEffectiveTime) {
            revert PendingRootNotReady(block.timestamp, pendingRootEffectiveTime);
        }
        _activateRoot();
    }

    /// @notice 紧急情况：立即激活根（仅限管理员，绕过延迟）
    /// @dev 仅在延迟会导致问题的紧急情况下使用
    function emergencyActivateRoot() external onlyRole(ADMIN_ROLE) {
        if (pendingRoot == bytes32(0)) revert NoPendingRoot();
        _activateRoot();
    }

    /// @notice 取消待处理的根（仅限管理员）
    /// @dev 当队列中的根有错误需要替换时使用
    function cancelPendingRoot() external onlyRole(ADMIN_ROLE) {
        if (pendingRoot == bytes32(0)) revert NoPendingRoot();

        bytes32 cancelledRoot = pendingRoot;
        uint256 cancelledEpoch = pendingEpoch;

        pendingRoot = bytes32(0);
        pendingRootEffectiveTime = 0;
        pendingEpoch = 0;
        pendingEpochLabel = "";

        emit PendingRootCancelled(cancelledRoot, cancelledEpoch, msg.sender);
    }

    // =============================================================================
    // 管理员函数
    // =============================================================================

    /// @notice 设置模块激活状态
    function setActive(bool _active) external onlyRole(ADMIN_ROLE) {
        active = _active;
        emit ModuleActiveStatusUpdated(_active);
    }

    /// @notice 紧急情况：重置用户的已领取数量（仅限管理员）
    /// @dev 谨慎使用，仅用于修复错误
    function resetUserClaimed(address user, uint256 newAmount) external onlyRole(ADMIN_ROLE) {
        uint256 previousAmount = claimedPoints[user];
        claimedPoints[user] = newAmount;
        emit UserClaimedReset(user, previousAmount, newAmount, msg.sender);
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
    // 存储间隙 - 为未来升级预留
    // =============================================================================

    /// @dev 预留的存储空间，用于在未来升级中允许布局更改
    uint256[50] private __gap;
}
