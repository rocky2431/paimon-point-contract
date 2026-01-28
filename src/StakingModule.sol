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

/// @title 质押模块 v2.0 - 信用卡积分模式
/// @author Paimon Protocol
/// @notice 带时间锁定加成的PPT质押积分模块
/// @dev 使用"信用卡积分"模式：积分 = 质押金额 × boost × pointsRate × 时长
///      每个用户的积分只与自己的行为相关，后入者不会被稀释
///      支持灵活质押（随时取出，1.0x boost）和锁定质押（7-365天，1.02x-2.0x boost）
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
    uint256 public constant BOOST_BASE = 10000; // 1倍 = 10000, 2倍 = 20000
    uint256 public constant MAX_EXTRA_BOOST = 10000; // 最大额外加成1倍（总共2倍）
    uint256 public constant MIN_LOCK_DURATION = 7 days;
    uint256 public constant MAX_LOCK_DURATION = 365 days;
    uint256 public constant EARLY_UNLOCK_PENALTY_BPS = 5000; // 50%
    uint256 public constant MAX_STAKES_PER_USER = 100;

    string public constant MODULE_NAME = "PPT Staking";
    string public constant VERSION = "2.0.0";

    uint256 public constant MAX_BATCH_USERS = 100;

    /// @notice 最大质押金额，防止uint128溢出
    uint256 public constant MAX_STAKE_AMOUNT = type(uint128).max / 2;

    /// @notice 每秒最小积分率
    uint256 public constant MIN_POINTS_RATE = 1;

    /// @notice 每秒最大积分率（防止计算溢出）
    uint256 public constant MAX_POINTS_RATE = 1e24;

    // =============================================================================
    // Data Structures
    // =============================================================================

    /// @notice 质押类型
    enum StakeType {
        Flexible, // 灵活质押，随时取出，1.0x boost
        Locked // 锁定质押，有 boost 加成
    }

    /// @notice 单个质押记录 (v2 - 信用卡积分模式)
    /// @dev 存储布局：
    ///      槽1 = amount(256)
    ///      槽2 = accruedPoints(256)
    ///      槽3 = startTime(64) + lockEndTime(64) + lastAccrualTime(64) + lockDurationDays(32) + stakeType(8) + isActive(8) = 240位
    struct StakeInfo {
        uint256 amount; // 质押金额
        uint256 accruedPoints; // 已累计积分（截至 lastAccrualTime）
        uint64 startTime; // 质押开始时间
        uint64 lockEndTime; // 锁定到期时间 (Flexible=0)
        uint64 lastAccrualTime; // 上次积分累计时间
        uint32 lockDurationDays; // 原始锁定天数 (0 for Flexible)
        StakeType stakeType; // 质押类型
        bool isActive; // 质押是否活跃
    }

    /// @notice 聚合用户状态
    struct UserState {
        uint256 totalStakedAmount; // 所有活跃质押的原始金额总和
        uint256 lastCheckpointBlock; // 用于闪电贷保护
    }

    // =============================================================================
    // State Variables
    // =============================================================================

    /// @notice PPT代币合约
    IERC20 public ppt;

    /// @notice 每秒每个PPT生成的积分（1e18精度）
    /// @dev 信用卡模式：积分 = amount × boost × pointsRatePerSecond × duration / BOOST_BASE
    uint256 public pointsRatePerSecond;

    /// @notice 用户状态映射
    mapping(address => UserState) public userStates;

    /// @notice 用户质押：用户 => 质押索引 => 质押信息
    mapping(address => mapping(uint256 => StakeInfo)) public userStakes;

    /// @notice 每个用户的质押数量（包括非活跃的）
    mapping(address => uint256) public userStakeCount;

    /// @notice 模块是否激活
    bool public active;

    /// @notice 积分计入前所需的最少区块数（闪电贷保护）
    uint256 public minHoldingBlocks;

    // =============================================================================
    // Events
    // =============================================================================

    event Staked(
        address indexed user,
        uint256 indexed stakeIndex,
        uint256 amount,
        StakeType stakeType,
        uint256 lockDurationDays,
        uint256 boost,
        uint256 lockEndTime
    );

    /// @notice 当用户解除质押时触发
    event Unstaked(
        address indexed user,
        uint256 indexed stakeIndex,
        uint256 amount,
        uint256 actualPenalty,
        uint256 theoreticalPenalty,
        bool isEarlyUnlock,
        bool penaltyWasCapped
    );

    event UserCheckpointed(address indexed user, uint256 totalPoints, uint256 totalStaked, uint256 timestamp);

    /// @notice 当闪电贷保护阻止积分计入时触发
    event FlashLoanProtectionTriggered(address indexed user, uint256 blocksRemaining);

    /// @notice 当批量检查点中跳过零地址时触发
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
    error AmountTooLarge(uint256 amount, uint256 max);
    error InvalidPointsRate(uint256 rate, uint256 min, uint256 max);
    error NotAContract(address addr);
    error InvalidERC20(address addr);

    // =============================================================================
    // Constructor & Initializer
    // =============================================================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice 初始化合约
    /// @param _ppt PPT代币地址（必须是有效的ERC20合约）
    /// @param admin 管理员地址
    /// @param keeper Keeper地址（用于检查点）
    /// @param upgrader 升级者地址（通常是时间锁）
    /// @param _pointsRatePerSecond 每秒每个PPT的初始积分率
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
        active = true;
        minHoldingBlocks = 1;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);
        _grantRole(KEEPER_ROLE, keeper);
        _grantRole(UPGRADER_ROLE, upgrader);
    }

    /// @notice 验证地址是否实现了ERC20接口
    function _validateERC20(address token) internal view {
        try IERC20(token).totalSupply() returns (uint256) {}
        catch {
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

    /// @notice 基于锁定天数计算原始加成倍数
    /// @param lockDurationDays 锁定天数
    /// @return boost 加成倍数（BOOST_BASE = 1倍）
    /// @dev 线性：7天 = 1.02倍，365天 = 2.0倍
    function calculateBoostFromDays(uint256 lockDurationDays) public pure returns (uint256 boost) {
        if (lockDurationDays == 0) {
            return BOOST_BASE; // 灵活质押 = 1.0x
        }
        if (lockDurationDays < 7) {
            return BOOST_BASE; // 少于7天 = 1.0x
        }
        if (lockDurationDays > 365) {
            lockDurationDays = 365; // 上限365天
        }

        uint256 extraBoost = (lockDurationDays * MAX_EXTRA_BOOST) / 365;
        return BOOST_BASE + extraBoost;
    }

    /// @notice 获取质押的当前有效 boost
    /// @dev 锁定到期后自动降为 1.0x
    /// @param stake 质押信息
    /// @return 有效 boost 值
    function _getEffectiveBoost(StakeInfo storage stake) internal view returns (uint256) {
        if (stake.stakeType == StakeType.Flexible) {
            return BOOST_BASE; // 灵活质押始终 1.0x
        }

        // 锁定质押：检查是否到期
        if (block.timestamp >= stake.lockEndTime) {
            return BOOST_BASE; // 到期后降为 1.0x
        }

        // 未到期：使用原始 boost
        return calculateBoostFromDays(stake.lockDurationDays);
    }

    // =============================================================================
    // Core Logic - Credit Card Points Calculation
    // =============================================================================

    /// @notice 计算单个质押从上次累计到现在的积分
    /// @dev 信用卡模式：积分 = amount × effectiveBoost × pointsRatePerSecond × duration / BOOST_BASE
    /// @param stake 质押信息
    /// @return 新增积分
    function _calculateStakePointsSinceLastAccrual(StakeInfo storage stake) internal view returns (uint256) {
        if (!stake.isActive || !active) return 0;

        uint256 duration = block.timestamp - stake.lastAccrualTime;
        if (duration == 0) return 0;

        uint256 effectiveBoost = _getEffectiveBoost(stake);

        // 积分 = amount × effectiveBoost × pointsRatePerSecond × duration / BOOST_BASE
        return (uint256(stake.amount) * effectiveBoost * pointsRatePerSecond * duration) / BOOST_BASE;
    }

    /// @notice 计算单个质押的总积分（包括已累计 + 待累计）
    function _calculateStakeTotalPoints(StakeInfo storage stake) internal view returns (uint256) {
        return stake.accruedPoints + _calculateStakePointsSinceLastAccrual(stake);
    }

    /// @notice 累计质押的积分到 accruedPoints
    /// @dev 更新 accruedPoints 和 lastAccrualTime
    function _accrueStakePoints(StakeInfo storage stake) internal {
        if (!stake.isActive) return;

        uint256 newPoints = _calculateStakePointsSinceLastAccrual(stake);
        if (newPoints > 0) {
            stake.accruedPoints += newPoints;
        }
        stake.lastAccrualTime = uint64(block.timestamp);
    }

    // =============================================================================
    // User Functions - Stake
    // =============================================================================

    /// @notice 灵活质押PPT代币（随时可取，1.0x boost）
    /// @param amount 要质押的PPT数量
    /// @return stakeIndex 创建的质押索引
    function stakeFlexible(uint256 amount) external nonReentrant whenNotPaused returns (uint256 stakeIndex) {
        return _stake(msg.sender, amount, StakeType.Flexible, 0);
    }

    /// @notice 锁定质押PPT代币（有boost加成）
    /// @param amount 要质押的PPT数量
    /// @param lockDurationDays 锁定天数（7-365天）
    /// @return stakeIndex 创建的质押索引
    function stakeLocked(uint256 amount, uint256 lockDurationDays)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 stakeIndex)
    {
        if (lockDurationDays < 7 || lockDurationDays > 365) {
            revert InvalidLockDuration(lockDurationDays * 1 days, MIN_LOCK_DURATION, MAX_LOCK_DURATION);
        }
        return _stake(msg.sender, amount, StakeType.Locked, lockDurationDays);
    }

    /// @notice 内部质押逻辑
    function _stake(address user, uint256 amount, StakeType stakeType, uint256 lockDurationDays)
        internal
        returns (uint256 stakeIndex)
    {
        if (amount == 0) revert ZeroAmount();
        if (amount > MAX_STAKE_AMOUNT) revert AmountTooLarge(amount, MAX_STAKE_AMOUNT);

        uint256 currentCount = userStakeCount[user];
        if (currentCount >= MAX_STAKES_PER_USER) {
            revert MaxStakesReached(currentCount, MAX_STAKES_PER_USER);
        }

        // 从用户转入PPT
        ppt.safeTransferFrom(user, address(this), amount);

        uint64 lockEndTime = 0;
        if (stakeType == StakeType.Locked) {
            lockEndTime = uint64(block.timestamp + lockDurationDays * 1 days);
        }

        uint256 boost = calculateBoostFromDays(lockDurationDays);

        // 创建质押记录
        stakeIndex = currentCount;
        userStakes[user][stakeIndex] = StakeInfo({
            amount: amount,
            accruedPoints: 0,
            startTime: uint64(block.timestamp),
            lockEndTime: lockEndTime,
            lastAccrualTime: uint64(block.timestamp),
            lockDurationDays: uint32(lockDurationDays),
            stakeType: stakeType,
            isActive: true
        });

        // 更新聚合状态
        userStates[user].totalStakedAmount += amount;
        userStates[user].lastCheckpointBlock = block.number;
        userStakeCount[user] = currentCount + 1;

        emit Staked(user, stakeIndex, amount, stakeType, lockDurationDays, boost, lockEndTime);
    }

    // =============================================================================
    // User Functions - Unstake
    // =============================================================================

    /// @notice 解除质押PPT代币
    /// @param stakeIndex 要解除的质押索引
    /// @dev 如果提前解锁锁定质押，将对质押后赚取的积分应用惩罚
    function unstake(uint256 stakeIndex) external nonReentrant whenNotPaused {
        address user = msg.sender;

        if (stakeIndex >= userStakeCount[user]) {
            revert StakeNotFound(stakeIndex);
        }

        StakeInfo storage stakeInfo = userStakes[user][stakeIndex];
        if (!stakeInfo.isActive) {
            revert StakeNotActive(stakeIndex);
        }

        // 先累计积分
        _accrueStakePoints(stakeInfo);

        uint256 amount = stakeInfo.amount;
        bool isEarlyUnlock = stakeInfo.stakeType == StakeType.Locked && block.timestamp < stakeInfo.lockEndTime;
        uint256 theoreticalPenalty = 0;
        uint256 actualPenalty = 0;
        bool penaltyWasCapped = false;

        // 计算并应用提前解锁的惩罚
        if (isEarlyUnlock) {
            theoreticalPenalty = _calculateEarlyUnlockPenalty(stakeInfo);
            if (theoreticalPenalty > 0) {
                if (theoreticalPenalty <= stakeInfo.accruedPoints) {
                    actualPenalty = theoreticalPenalty;
                    stakeInfo.accruedPoints -= theoreticalPenalty;
                } else {
                    // 将惩罚限制在已赚取的积分范围内
                    actualPenalty = stakeInfo.accruedPoints;
                    stakeInfo.accruedPoints = 0;
                    penaltyWasCapped = true;
                }
            }
        }

        // 更新聚合状态
        userStates[user].totalStakedAmount -= amount;

        // 标记质押为非活跃
        stakeInfo.isActive = false;

        // 将PPT返还给用户
        ppt.safeTransfer(user, amount);

        emit Unstaked(user, stakeIndex, amount, actualPenalty, theoreticalPenalty, isEarlyUnlock, penaltyWasCapped);
    }

    /// @notice 计算提前解锁惩罚
    /// @dev penalty = accruedPoints × (remainingTime / lockDuration) × 50%
    function _calculateEarlyUnlockPenalty(StakeInfo storage stakeInfo) internal view returns (uint256 penalty) {
        uint256 accruedPoints = stakeInfo.accruedPoints;
        if (accruedPoints == 0) return 0;

        // 计算剩余时间比率
        uint256 remainingTime = stakeInfo.lockEndTime > block.timestamp ? stakeInfo.lockEndTime - block.timestamp : 0;
        if (remainingTime == 0) return 0;

        uint256 lockDuration = uint256(stakeInfo.lockDurationDays) * 1 days;
        if (lockDuration == 0) return 0;

        // penalty = accruedPoints × (remainingTime / lockDuration) × PENALTY_BPS / 10000
        penalty = (accruedPoints * remainingTime * EARLY_UNLOCK_PENALTY_BPS) / (lockDuration * 10000);
    }

    // =============================================================================
    // View Functions - IPointsModule Implementation
    // =============================================================================

    /// @notice 获取用户积分（实时计算）
    /// @param user 用户地址
    /// @return 累积的总积分
    function getPoints(address user) external view override returns (uint256) {
        return _calculateUserTotalPoints(user);
    }

    /// @notice 计算用户所有质押的总积分（包括已 unstake 的）
    /// @dev inactive stakes 只计算已累计的 accruedPoints，不再增长
    function _calculateUserTotalPoints(address user) internal view returns (uint256 total) {
        uint256 count = userStakeCount[user];
        for (uint256 i = 0; i < count;) {
            StakeInfo storage stake = userStakes[user][i];
            if (stake.isActive) {
                // 活跃质押：累计积分 + 待累计积分
                total += _calculateStakeTotalPoints(stake);
            } else {
                // 非活跃质押：只计算已累计的积分（不再增长）
                total += stake.accruedPoints;
            }
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

    /// @notice 获取用户的聚合状态
    /// @param user 用户地址
    /// @return totalStakedAmount 总质押金额
    /// @return earnedPoints 总赚取积分
    /// @return activeStakeCount 活跃质押数量
    function getUserState(address user)
        external
        view
        returns (uint256 totalStakedAmount, uint256 earnedPoints, uint256 activeStakeCount)
    {
        totalStakedAmount = userStates[user].totalStakedAmount;
        earnedPoints = _calculateUserTotalPoints(user);

        // 计算活跃质押数
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

    /// @notice 获取用户的质押详情
    /// @param user 用户地址
    /// @param stakeIndex 质押索引
    /// @return info 质押信息
    function getStakeInfo(address user, uint256 stakeIndex) external view returns (StakeInfo memory info) {
        if (stakeIndex >= userStakeCount[user]) {
            revert StakeNotFound(stakeIndex);
        }
        return userStakes[user][stakeIndex];
    }

    /// @notice 获取单个质押的当前积分和有效boost
    /// @param user 用户地址
    /// @param stakeIndex 质押索引
    /// @return totalPoints 总积分
    /// @return effectiveBoost 有效boost
    /// @return isLockExpired 锁定是否已到期
    function getStakePointsAndBoost(address user, uint256 stakeIndex)
        external
        view
        returns (uint256 totalPoints, uint256 effectiveBoost, bool isLockExpired)
    {
        if (stakeIndex >= userStakeCount[user]) {
            revert StakeNotFound(stakeIndex);
        }

        StakeInfo storage stake = userStakes[user][stakeIndex];
        totalPoints = _calculateStakeTotalPoints(stake);
        effectiveBoost = _getEffectiveBoost(stake);
        isLockExpired = stake.stakeType == StakeType.Locked && block.timestamp >= stake.lockEndTime;
    }

    /// @notice 获取用户的所有质押
    /// @param user 用户地址
    /// @return stakes 质押信息数组
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

    /// @notice 估算质押场景的积分（信用卡模式 - 固定积分率）
    /// @param amount 要质押的金额
    /// @param lockDurationDays 锁定天数（0为灵活质押）
    /// @param holdDurationSeconds 持有时长（秒）
    /// @return 估算的积分
    function estimatePoints(uint256 amount, uint256 lockDurationDays, uint256 holdDurationSeconds)
        external
        view
        returns (uint256)
    {
        if (amount == 0) revert ZeroAmount();

        uint256 boost = calculateBoostFromDays(lockDurationDays);
        // 积分 = amount × boost × pointsRatePerSecond × duration / BOOST_BASE
        return (amount * boost * pointsRatePerSecond * holdDurationSeconds) / BOOST_BASE;
    }

    /// @notice 计算潜在的提前解锁惩罚
    /// @param user 用户地址
    /// @param stakeIndex 质押索引
    /// @return penalty 潜在惩罚金额
    function calculatePotentialPenalty(address user, uint256 stakeIndex) external view returns (uint256 penalty) {
        if (stakeIndex >= userStakeCount[user]) {
            revert StakeNotFound(stakeIndex);
        }

        StakeInfo storage stakeInfo = userStakes[user][stakeIndex];
        if (!stakeInfo.isActive) {
            revert StakeNotActive(stakeIndex);
        }

        // 灵活质押无惩罚
        if (stakeInfo.stakeType == StakeType.Flexible) return 0;

        // 如果锁定已过期则无惩罚
        if (block.timestamp >= stakeInfo.lockEndTime) return 0;

        // 计算当前总积分
        uint256 currentPoints = _calculateStakeTotalPoints(stakeInfo);
        if (currentPoints == 0) return 0;

        uint256 remainingTime = stakeInfo.lockEndTime - block.timestamp;
        uint256 lockDuration = uint256(stakeInfo.lockDurationDays) * 1 days;

        penalty = (currentPoints * remainingTime * EARLY_UNLOCK_PENALTY_BPS) / (lockDuration * 10000);
    }

    // =============================================================================
    // Checkpoint Functions
    // =============================================================================

    /// @notice 检查点用户所有质押的积分
    /// @param user 要检查点的用户地址
    function _checkpointUser(address user) internal {
        UserState storage state = userStates[user];

        // 闪电贷保护
        bool passedHoldingPeriod =
            state.lastCheckpointBlock == 0 || block.number >= state.lastCheckpointBlock + minHoldingBlocks;

        if (!passedHoldingPeriod) {
            uint256 blocksRemaining = (state.lastCheckpointBlock + minHoldingBlocks) - block.number;
            emit FlashLoanProtectionTriggered(user, blocksRemaining);
            return;
        }

        // 累计所有活跃质押的积分
        uint256 count = userStakeCount[user];
        uint256 totalPoints = 0;
        for (uint256 i = 0; i < count;) {
            StakeInfo storage stake = userStakes[user][i];
            if (stake.isActive) {
                _accrueStakePoints(stake);
                totalPoints += stake.accruedPoints;
            }
            unchecked {
                ++i;
            }
        }

        state.lastCheckpointBlock = block.number;

        emit UserCheckpointed(user, totalPoints, state.totalStakedAmount, block.timestamp);
    }

    /// @notice 检查点多个用户（keeper函数）
    /// @param users 要检查点的用户地址数组
    function checkpointUsers(address[] calldata users) external onlyRole(KEEPER_ROLE) {
        uint256 len = users.length;
        if (len > MAX_BATCH_USERS) revert BatchTooLarge(len, MAX_BATCH_USERS);

        for (uint256 i = 0; i < len;) {
            if (users[i] != address(0)) {
                _checkpointUser(users[i]);
            } else {
                emit ZeroAddressSkipped(i);
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @notice 检查点单个用户（任何人都可以调用）
    /// @param user 要检查点的用户地址
    function checkpoint(address user) external {
        _checkpointUser(user);
    }

    /// @notice 检查点调用者
    function checkpointSelf() external {
        _checkpointUser(msg.sender);
    }

    // =============================================================================
    // Admin Functions
    // =============================================================================

    /// @notice 设置每秒积分率
    /// @param newRate 新的比率（1e18精度）
    function setPointsRate(uint256 newRate) external onlyRole(ADMIN_ROLE) {
        if (newRate < MIN_POINTS_RATE || newRate > MAX_POINTS_RATE) {
            revert InvalidPointsRate(newRate, MIN_POINTS_RATE, MAX_POINTS_RATE);
        }

        uint256 oldRate = pointsRatePerSecond;
        pointsRatePerSecond = newRate;

        emit PointsRateUpdated(oldRate, newRate);
    }

    /// @notice 设置模块激活状态
    /// @param _active 模块是否激活
    function setActive(bool _active) external onlyRole(ADMIN_ROLE) {
        active = _active;
        emit ModuleActiveStatusUpdated(_active);
    }

    /// @notice 更新PPT地址（仅紧急情况）
    /// @param _ppt 新的PPT地址（必须是有效的ERC20）
    function setPpt(address _ppt) external onlyRole(ADMIN_ROLE) {
        if (_ppt == address(0)) revert ZeroAddress();
        if (_ppt.code.length == 0) revert NotAContract(_ppt);
        _validateERC20(_ppt);

        address oldPpt = address(ppt);
        ppt = IERC20(_ppt);
        emit PptUpdated(oldPpt, _ppt);
    }

    /// @notice 设置闪电贷保护的最少持有区块数
    /// @param blocks 最少区块数
    function setMinHoldingBlocks(uint256 blocks) external onlyRole(ADMIN_ROLE) {
        uint256 oldBlocks = minHoldingBlocks;
        minHoldingBlocks = blocks;
        emit MinHoldingBlocksUpdated(oldBlocks, blocks);
    }

    /// @notice 暂停合约操作
    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    /// @notice 取消暂停合约操作
    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    /// @notice 获取合约版本
    /// @return 版本字符串
    function version() external pure returns (string memory) {
        return VERSION;
    }

    // =============================================================================
    // Storage Gap - Reserved for future upgrades
    // =============================================================================

    /// @dev 预留存储空间，以便在未来升级中允许布局更改
    uint256[50] private __gap;
}
