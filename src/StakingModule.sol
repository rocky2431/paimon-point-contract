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

/// @title 质押模块
/// @author Paimon Protocol
/// @notice 带时间锁定加成的PPT质押积分模块
/// @dev 使用Synthetix风格的奖励机制，根据锁定期提供加成
///      取代HoldingModule，为希望通过质押获得增强积分的用户提供服务
///      注意：MAX_STAKES_PER_USER（10）是每个地址的终身限制
///      一旦用户创建了10个质押，即使解除质押后也无法创建更多
///      需要更多质押的用户应使用新地址
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
    uint256 public constant MAX_STAKES_PER_USER = 10;

    string public constant MODULE_NAME = "PPT Staking";
    string public constant VERSION = "1.3.0";

    uint256 public constant MAX_BATCH_USERS = 100;

    /// @notice 最大质押金额，防止uint128溢出（预留2倍加成空间）
    uint256 public constant MAX_STAKE_AMOUNT = type(uint128).max / 2;

    /// @notice 每秒最小积分率
    uint256 public constant MIN_POINTS_RATE = 1;

    /// @notice 每秒最大积分率（防止计算溢出）
    uint256 public constant MAX_POINTS_RATE = 1e24;

    // =============================================================================
    // Data Structures
    // =============================================================================

    /// @notice 单个质押记录
    /// @dev 优化打包到2个存储槽：
    ///      槽1 = amount(128) + boostedAmount(128) = 256位
    ///      槽2 = pointsEarnedAtStake(128) + lockEndTime(64) + lockDuration(56) + isActive(8) = 256位
    struct StakeInfo {
        uint128 amount; // 质押金额
        uint128 boostedAmount; // amount × boost / BOOST_BASE
        uint128 pointsEarnedAtStake; // 质押时已赚取的积分（用于惩罚计算）
        uint64 lockEndTime; // 锁定到期时间
        uint56 lockDuration; // 锁定期（秒），最大约2.28e9年，受MAX_LOCK_DURATION限制
        bool isActive; // 质押是否活跃
    }

    /// @notice 聚合用户状态，用于O(1)复杂度的getPoints
    struct UserState {
        uint256 totalBoostedAmount; // 所有活跃质押的boostedAmount总和
        uint256 pointsPerSharePaid; // 上次检查点的每份额积分
        uint256 pointsEarned; // 累积积分（扣除惩罚后）
        uint256 lastCheckpointBlock; // 用于闪电贷保护
    }

    // =============================================================================
    // State Variables
    // =============================================================================

    /// @notice PPT代币合约
    IERC20 public ppt;

    /// @notice 每秒每个加成PPT份额生成的积分（1e18精度）
    uint256 public pointsRatePerSecond;

    /// @notice 上次更新全局状态的时间
    uint256 public lastUpdateTime;

    /// @notice 每个加成份额累积的积分（1e18精度）
    uint256 public pointsPerShareStored;

    /// @notice 所有用户的总加成质押量
    uint256 public totalBoostedStaked;

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
        uint256 lockDuration,
        uint256 boostedAmount,
        uint256 lockEndTime
    );

    /// @notice 当用户解除质押时触发
    /// @param user 用户地址
    /// @param stakeIndex 质押索引
    /// @param amount 返还的质押金额
    /// @param actualPenalty 实际应用的惩罚（可能被限制）
    /// @param theoreticalPenalty 限制前计算的惩罚
    /// @param isEarlyUnlock 是否为提前解锁
    /// @param penaltyWasCapped 惩罚是否被限制在已赚取积分范围内
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

    /// @notice 当闪电贷保护阻止积分计入时触发
    /// @param user 用户地址
    /// @param blocksRemaining 积分可以计入前剩余的区块数
    event FlashLoanProtectionTriggered(address indexed user, uint256 blocksRemaining);

    /// @notice 当批量检查点中跳过零地址时触发
    /// @param position 批量数组中的位置
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

    /// @notice 金额超过允许的最大值以防止溢出
    error AmountTooLarge(uint256 amount, uint256 max);

    /// @notice 积分率超出有效范围
    error InvalidPointsRate(uint256 rate, uint256 min, uint256 max);

    /// @notice 地址不是合约
    error NotAContract(address addr);

    /// @notice 地址未实现ERC20接口
    error InvalidERC20(address addr);

    /// @notice 检测到积分溢出（正常操作下不应发生）
    error PointsOverflow(uint256 points);

    /// @notice 持有期超过锁定期
    error InvalidHoldDuration(uint256 holdDuration, uint256 lockDuration);

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
    /// @param _pointsRatePerSecond 每秒每个加成PPT的初始积分率
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
        // 验证ERC20接口
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

    /// @notice 验证地址是否实现了ERC20接口
    /// @param token 要验证的代币地址
    function _validateERC20(address token) internal view {
        // 通过调用视图函数检查基本的ERC20函数是否存在
        try IERC20(token).totalSupply() returns (uint256) {
            // 有效 - 有totalSupply
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

    /// @notice 基于锁定期计算加成倍数（宽松版本）
    /// @param lockDuration 锁定期（秒）
    /// @return boost 加成倍数（BOOST_BASE = 1倍）
    /// @dev 线性：7天 = 1.02倍，365天 = 2.0倍
    ///      对于duration < MIN_LOCK_DURATION返回BOOST_BASE
    ///      对于duration > MAX_LOCK_DURATION上限为MAX_LOCK_DURATION
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

    /// @notice 使用严格验证计算加成倍数
    /// @param lockDuration 锁定期（秒）
    /// @return boost 加成倍数（BOOST_BASE = 1倍）
    /// @dev 如果期限超出有效范围则回滚
    function calculateBoostStrict(uint256 lockDuration) public pure returns (uint256 boost) {
        if (lockDuration < MIN_LOCK_DURATION || lockDuration > MAX_LOCK_DURATION) {
            revert InvalidLockDuration(lockDuration, MIN_LOCK_DURATION, MAX_LOCK_DURATION);
        }

        uint256 extraBoost = (lockDuration * MAX_EXTRA_BOOST) / MAX_LOCK_DURATION;
        return BOOST_BASE + extraBoost;
    }

    /// @notice 计算加成后的金额
    /// @param amount 原始质押金额
    /// @param lockDuration 锁定期（秒）
    /// @return 加成后的金额
    function calculateBoostedAmount(uint256 amount, uint256 lockDuration) public pure returns (uint256) {
        uint256 boost = calculateBoost(lockDuration);
        return (amount * boost) / BOOST_BASE;
    }

    // =============================================================================
    // Core Logic - Points Calculation
    // =============================================================================

    /// @notice 计算当前每份额积分
    /// @return 当前每个加成份额的累积积分
    function _currentPointsPerShare() internal view returns (uint256) {
        if (!active) return pointsPerShareStored;
        if (totalBoostedStaked == 0) return pointsPerShareStored;

        uint256 timeDelta = block.timestamp - lastUpdateTime;
        uint256 newPoints = timeDelta * pointsRatePerSecond;

        return pointsPerShareStored + (newPoints * PRECISION) / totalBoostedStaked;
    }

    /// @notice 更新全局状态
    function _updateGlobal() internal {
        pointsPerShareStored = _currentPointsPerShare();
        lastUpdateTime = block.timestamp;

        emit GlobalCheckpointed(pointsPerShareStored, block.timestamp, totalBoostedStaked);
    }

    /// @notice 更新用户状态
    /// @param user 要更新的用户地址
    /// @return pointsCredited 积分是否已计入（如果触发闪电贷保护则为false）
    /// @dev 重要：只有在成功计入积分时才更新pointsPerSharePaid
    ///      这确保闪电贷保护不会导致永久的积分损失
    function _updateUser(address user) internal returns (bool pointsCredited) {
        UserState storage state = userStates[user];
        uint256 cachedPointsPerShare = pointsPerShareStored;
        uint256 lastCheckpointBlock = state.lastCheckpointBlock;

        // 闪电贷保护
        bool passedHoldingPeriod = lastCheckpointBlock == 0 || block.number >= lastCheckpointBlock + minHoldingBlocks;

        // 使用加成金额计算新赚取的积分
        if (state.totalBoostedAmount > 0 && passedHoldingPeriod) {
            uint256 pointsDelta = cachedPointsPerShare - state.pointsPerSharePaid;
            uint256 newEarned = (state.totalBoostedAmount * pointsDelta) / PRECISION;
            state.pointsEarned += newEarned;
            // 只有在实际计入积分时才更新pointsPerSharePaid
            state.pointsPerSharePaid = cachedPointsPerShare;
            pointsCredited = true;
        } else if (state.totalBoostedAmount > 0 && !passedHoldingPeriod) {
            // 当触发闪电贷保护时触发事件
            // 注意：这里不更新pointsPerSharePaid，所以积分会保留到以后
            uint256 blocksRemaining = (lastCheckpointBlock + minHoldingBlocks) - block.number;
            emit FlashLoanProtectionTriggered(user, blocksRemaining);
            pointsCredited = false;
        }

        // 始终更新lastCheckpointBlock以跟踪持有期
        state.lastCheckpointBlock = block.number;

        emit UserCheckpointed(user, state.pointsEarned, state.totalBoostedAmount, block.timestamp, pointsCredited);
    }

    /// @notice 用户积分的内部计算（视图函数）
    /// @param user 用户地址
    /// @return 累积的总积分
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

    /// @notice 质押PPT代币并设置锁定期
    /// @param amount 要质押的PPT数量
    /// @param lockDuration 锁定期（秒），7-365天
    /// @return stakeIndex 创建的质押索引
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

        // 首先更新全局和用户状态
        _updateGlobal();
        _updateUser(user);

        // 从用户转入PPT
        ppt.safeTransferFrom(user, address(this), amount);

        // 计算加成金额（由于MAX_STAKE_AMOUNT检查是安全的）
        uint256 boostedAmount = calculateBoostedAmount(amount, lockDuration);

        // 验证积分不会溢出uint128（防御性检查）
        uint256 currentUserPoints = userStates[user].pointsEarned;
        if (currentUserPoints > type(uint128).max) {
            revert PointsOverflow(currentUserPoints);
        }

        uint64 lockEndTime = uint64(block.timestamp + lockDuration);

        // 创建质押记录（由于验证，所有类型转换现在都是安全的）
        stakeIndex = currentCount;
        userStakes[user][stakeIndex] = StakeInfo({
            amount: uint128(amount),
            boostedAmount: uint128(boostedAmount),
            pointsEarnedAtStake: uint128(currentUserPoints),
            lockEndTime: lockEndTime,
            lockDuration: uint56(lockDuration),
            isActive: true
        });

        // 更新聚合状态
        userStates[user].totalBoostedAmount += boostedAmount;
        totalBoostedStaked += boostedAmount;
        userStakeCount[user] = currentCount + 1;

        emit Staked(user, stakeIndex, amount, lockDuration, boostedAmount, lockEndTime);
    }

    /// @notice 解除质押PPT代币
    /// @param stakeIndex 要解除的质押索引
    /// @dev 如果提前解锁，将对质押后赚取的积分应用惩罚
    function unstake(uint256 stakeIndex) external nonReentrant whenNotPaused {
        address user = msg.sender;

        if (stakeIndex >= userStakeCount[user]) {
            revert StakeNotFound(stakeIndex);
        }

        StakeInfo storage stakeInfo = userStakes[user][stakeIndex];
        if (!stakeInfo.isActive) {
            revert StakeNotActive(stakeIndex);
        }

        // 首先更新全局和用户状态
        _updateGlobal();
        _updateUser(user);

        uint256 amount = stakeInfo.amount;
        uint256 boostedAmount = stakeInfo.boostedAmount;
        bool isEarlyUnlock = block.timestamp < stakeInfo.lockEndTime;
        uint256 theoreticalPenalty = 0;
        uint256 actualPenalty = 0;
        bool penaltyWasCapped = false;

        // 计算并应用提前解锁的惩罚
        if (isEarlyUnlock) {
            theoreticalPenalty = _calculateEarlyUnlockPenalty(user, stakeInfo);
            if (theoreticalPenalty > 0) {
                if (theoreticalPenalty <= userStates[user].pointsEarned) {
                    actualPenalty = theoreticalPenalty;
                    userStates[user].pointsEarned -= theoreticalPenalty;
                } else {
                    // 将惩罚限制在已赚取的积分范围内
                    actualPenalty = userStates[user].pointsEarned;
                    userStates[user].pointsEarned = 0;
                    penaltyWasCapped = true;
                }
            }
        }

        // 更新聚合状态
        userStates[user].totalBoostedAmount -= boostedAmount;
        totalBoostedStaked -= boostedAmount;

        // 标记质押为非活跃
        stakeInfo.isActive = false;

        // 将PPT返还给用户
        ppt.safeTransfer(user, amount);

        emit Unstaked(user, stakeIndex, amount, actualPenalty, theoreticalPenalty, isEarlyUnlock, penaltyWasCapped);
    }

    /// @notice 计算提前解锁惩罚
    /// @param user 用户地址
    /// @param stakeInfo 质押信息
    /// @return penalty 积分惩罚金额
    /// @dev penalty = earnedSinceStake × (remainingTime / lockDuration) × 50%
    function _calculateEarlyUnlockPenalty(address user, StakeInfo storage stakeInfo)
        internal
        view
        returns (uint256 penalty)
    {
        uint256 currentPoints = userStates[user].pointsEarned;
        uint256 pointsAtStake = stakeInfo.pointsEarnedAtStake;

        // 自此次质押以来赚取的积分
        uint256 earnedSinceStake = currentPoints > pointsAtStake ? currentPoints - pointsAtStake : 0;
        if (earnedSinceStake == 0) return 0;

        // 计算剩余时间比率
        uint256 remainingTime = stakeInfo.lockEndTime > block.timestamp ? stakeInfo.lockEndTime - block.timestamp : 0;
        if (remainingTime == 0) return 0;

        uint256 lockDuration = stakeInfo.lockDuration;

        // penalty = earnedSinceStake × (remainingTime / lockDuration) × PENALTY_BPS / 10000
        penalty = (earnedSinceStake * remainingTime * EARLY_UNLOCK_PENALTY_BPS) / (lockDuration * 10000);
    }

    // =============================================================================
    // View Functions - IPointsModule Implementation
    // =============================================================================

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
    // View Functions - Additional
    // =============================================================================

    /// @notice 获取当前每份额积分
    function currentPointsPerShare() external view returns (uint256) {
        return _currentPointsPerShare();
    }

    /// @notice 获取用户的聚合状态
    /// @param user 用户地址
    /// @return totalBoostedAmount 总加成质押金额
    /// @return earnedPoints 总赚取积分
    /// @return activeStakeCount 活跃质押数量
    function getUserState(address user)
        external
        view
        returns (uint256 totalBoostedAmount, uint256 earnedPoints, uint256 activeStakeCount)
    {
        totalBoostedAmount = userStates[user].totalBoostedAmount;
        earnedPoints = _calculatePoints(user);

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

    /// @notice 估算质押场景的积分
    /// @param amount 要质押的金额（必须 > 0）
    /// @param lockDuration 锁定期（必须在有效范围内）
    /// @param holdDuration 持有质押的时长
    /// @return 估算的积分
    /// @dev 为保持一致性，无效输入会回滚
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
            // 将成为唯一的质押者 - 获得所有积分
            return holdDuration * pointsRatePerSecond;
        }

        uint256 totalWithNew = totalBoostedStaked + boostedAmount;
        uint256 pointsGenerated = holdDuration * pointsRatePerSecond;
        return (boostedAmount * pointsGenerated) / totalWithNew;
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

        // 如果锁定已过期则无惩罚
        if (block.timestamp >= stakeInfo.lockEndTime) return 0;

        // 需要先计算当前积分
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

    /// @notice 检查点全局状态（keeper函数）
    function checkpointGlobal() external onlyRole(KEEPER_ROLE) {
        _updateGlobal();
    }

    /// @notice 检查点多个用户（keeper函数）
    /// @param users 要检查点的用户地址数组
    /// @dev 对于数组中的任何零地址触发ZeroAddressSkipped事件
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

    /// @notice 检查点单个用户（任何人都可以调用）
    /// @param user 要检查点的用户地址
    /// @return pointsCredited 积分是否已计入
    function checkpoint(address user) external returns (bool pointsCredited) {
        _updateGlobal();
        return _updateUser(user);
    }

    /// @notice 检查点调用者
    /// @return pointsCredited 积分是否已计入
    function checkpointSelf() external returns (bool pointsCredited) {
        _updateGlobal();
        return _updateUser(msg.sender);
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

        _updateGlobal();

        uint256 oldRate = pointsRatePerSecond;
        pointsRatePerSecond = newRate;

        emit PointsRateUpdated(oldRate, newRate);
    }

    /// @notice 设置模块激活状态
    /// @param _active 模块是否激活
    function setActive(bool _active) external onlyRole(ADMIN_ROLE) {
        if (_active && !active) {
            lastUpdateTime = block.timestamp;
        } else if (!_active && active) {
            _updateGlobal();
        }
        active = _active;
        emit ModuleActiveStatusUpdated(_active);
    }

    /// @notice 更新PPT地址（仅紧急情况）
    /// @param _ppt 新的PPT地址（必须是有效的ERC20）
    function setPpt(address _ppt) external onlyRole(ADMIN_ROLE) {
        if (_ppt == address(0)) revert ZeroAddress();
        if (_ppt.code.length == 0) revert NotAContract(_ppt);
        _validateERC20(_ppt);

        _updateGlobal();
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
