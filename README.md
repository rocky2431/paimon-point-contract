# Paimon Points System v2.3.0

链上模块化积分系统，采用**信用卡积分模式**，支持多种积分获取方式和统一兑换机制。

> **v2.0.0 重大变更**: 从 Synthetix 风格的"瓜分池子"模式迁移到"信用卡积分"模式，确保后入者与早入者在同等条件下获得同等积分，无稀释效应。
>
> **v2.3.0 变更**: 新增 `RATE_PRECISION` 精度基准，`pointsRatePerSecond` 支持小数倍率（如 0.9x = `9e17`）；新增 `POINTS_DECIMALS = 24` 前端显示精度常量。

## 目录

- [架构概述](#架构概述)
- [合约清单](#合约清单)
- [PointsHub (中央聚合器)](#pointshub-中央聚合器)
- [StakingModule (质押模块)](#stakingmodule-质押模块)
- [LPModule (LP模块)](#lpmodule-lp模块)
- [ActivityModule (活动模块)](#activitymodule-活动模块)
- [PenaltyModule (惩罚模块)](#penaltymodule-惩罚模块)
- [接口定义](#接口定义)
- [角色权限](#角色权限)
- [部署指南](#部署指南)
- [安全机制](#安全机制)
- [Gas 估算](#gas-估算)

---

## 架构概述

### 系统拓扑

```
┌─────────────────────────────────────────────────────────────────────┐
│                         PointsHub v1.3.0                            │
│                    (中央聚合器 + 兑换引擎)                            │
│                                                                     │
│  公式: claimablePoints = Σ modules.getPoints(user)                  │
│                         - penaltyModule.getPenalty(user)            │
│                         - redeemedPoints[user]                      │
└─────────────────┬───────────────────────────────────┬───────────────┘
                  │                                   │
      ┌───────────┴───────────────┐       ┌──────────┴──────────┐
      │     Points Modules        │       │   Penalty Module    │
      │   (IPointsModule 接口)    │       │ (IPenaltyModule)    │
      └───────────┬───────────────┘       └─────────────────────┘
                  │
    ┌─────────────┼─────────────────────────┐
    │             │                         │
    ▼             ▼                         ▼
┌─────────────┐ ┌─────────┐ ┌─────────────────┐
│  Staking    │ │   LP    │ │    Activity     │
│  Module     │ │ Module  │ │     Module      │
│             │ │         │ │                 │
│ 灵活/锁定   │ │ 质押LP  │ │  Merkle proof   │
│ 质押PPT    │ │ 多池支持│ │   链下活动      │
│ Boost加成  │ │         │ │                 │
└─────────────┘ └─────────┘ └─────────────────┘
```

### 信用卡积分模式 (Credit Card Mode)

v2.0.0 采用**信用卡积分模式**，与传统 Synthetix-style 的"瓜分池子"模式不同：

| 特性 | 旧模式 (Synthetix) | 新模式 (Credit Card) |
|------|-------------------|---------------------|
| 全局状态 | `pointsPerShareStored`, `totalBoostedStaked` | **无全局状态** |
| 积分计算 | `balance × (currentPointsPerShare - userPaid)` | `amount × rate × duration` |
| 稀释效应 | 后入者会稀释早入者 | **无稀释** |
| 公平性 | 早入者优势 | **同等条件同等积分** |
| 复杂度 | 较高 (全局追踪) | 较低 (独立计算) |

**核心公式:**
```
StakingModule: points = amount × boost × pointsRatePerSecond × duration / (BOOST_BASE × RATE_PRECISION)
LPModule:      points = balance × (baseRate × multiplier / MULTIPLIER_BASE) × duration
```

### 积分精度与前端显示

链上积分值继承了 ERC20 代币的 18 位精度，加上时间和倍率的乘积，原始值非常大。
系统采用 **ERC20 decimals 模式** 来解决显示问题：

```
┌──────────────────────────────────────────────────────────────┐
│  链上 (Raw Value)           前端 (Display Value)              │
│                                                              │
│  getPoints(user)            rawPoints / 10^POINTS_DECIMALS   │
│  = 8,640,000,000,...        = 8.64                           │
│    (8.64e24)                                                 │
│                                                              │
│  POINTS_DECIMALS = 24  ← PointsHub 链上常量                   │
└──────────────────────────────────────────────────────────────┘
```

**前端集成示例:**
```javascript
const decimals = await pointsHub.POINTS_DECIMALS(); // 24
const rawPoints = await pointsHub.getTotalPoints(userAddress);
const displayPoints = formatUnits(rawPoints, decimals); // "8.64"
```

**各场景积分参考** (rate = 1e18, 即 1.0x):

| 场景 | Raw Value | Display Value |
|------|-----------|---------------|
| 100 PPT × 灵活 × 1 天 | `8.64e24` | **8.64** |
| 1000 PPT × 灵活 × 1 天 | `8.64e25` | **86.4** |
| 1000 PPT × 2.0x boost × 365 天 | `6.31e28` | **63,072** |
| 100 PPT × 0.9x rate × 1 天 | `7.776e24` | **7.776** |

### pointsRatePerSecond 精度机制

`pointsRatePerSecond` 使用 `RATE_PRECISION = 1e18` 作为精度基准：

```
RATE_PRECISION = 1e18

rate = 1e18   → 1.0x（标准速率）
rate = 9e17   → 0.9x（降低 10%）
rate = 5e17   → 0.5x（降低 50%）
rate = 15e17  → 1.5x（提高 50%）
rate = 2e18   → 2.0x（双倍速率）
```

**为什么需要 RATE_PRECISION?**

Solidity 没有浮点数，`0.9` 会被截断为 `0`。通过放大到 `9e17` 并在公式中除以 `1e18`，实现了无损的小数倍率：

```solidity
// 公式
points = (amount × boost × pointsRatePerSecond × duration) / (BOOST_BASE × RATE_PRECISION)

// 当 rate = 1e18 时，RATE_PRECISION 抵消，等价于旧版公式：
// points = amount × boost × duration / BOOST_BASE
```

---

## 合约清单

| 合约 | 文件 | 版本 | 描述 |
|------|------|------|------|
| PointsHub | `src/PointsHub.sol` | 1.3.0 | 中央聚合器，积分兑换，`POINTS_DECIMALS` |
| StakingModule | `src/StakingModule.sol` | 2.3.0 | PPT 灵活/锁定质押 (信用卡模式 + RATE_PRECISION) |
| LPModule | `src/LPModule.sol` | 2.0.0 | LP Token 多池质押 (信用卡模式) |
| ActivityModule | `src/ActivityModule.sol` | 1.3.0 | 链下活动积分 (Merkle) |
| PenaltyModule | `src/PenaltyModule.sol` | 1.3.0 | 惩罚扣除 (Merkle) |

---

## PointsHub (中央聚合器)

### 功能概述

- 注册和管理积分模块
- 聚合用户在所有模块的总积分
- 处理积分兑换为代币

### 常量

| 常量 | 值 | 描述 |
|------|-----|------|
| `PRECISION` | `1e18` | 计算精度 |
| `POINTS_DECIMALS` | `24` | 积分显示精度（类似 ERC20 decimals，前端 `÷ 10^24` 显示） |
| `MAX_MODULES` | `10` | 最大模块数 |
| `DEFAULT_MODULE_GAS_LIMIT` | `200,000` | 模块调用 Gas 限制 |
| `MAX_EXCHANGE_RATE` | `1e24` | 最大兑换率 |
| `MIN_EXCHANGE_RATE` | `1e12` | 最小兑换率 |

### 状态变量

| 变量 | 类型 | 描述 |
|------|------|------|
| `modules` | `IPointsModule[]` | 已注册模块数组 |
| `isModule` | `mapping(address => bool)` | 模块注册状态 |
| `penaltyModule` | `IPenaltyModule` | 惩罚模块地址 |
| `rewardToken` | `IERC20` | 兑换代币 |
| `exchangeRate` | `uint256` | 兑换率 (1e18 精度) |
| `redeemEnabled` | `bool` | 兑换开关 |
| `redeemedPoints` | `mapping(address => uint256)` | 用户已兑换积分 |
| `maxRedeemPerTx` | `uint256` | 单笔最大兑换量 (0=无限) |
| `totalRedeemedPoints` | `uint256` | 全局已兑换积分 |
| `moduleGasLimit` | `uint256` | 模块调用 Gas 限制 |

### 核心函数

#### 查询函数

```solidity
// 获取用户总积分 (所有活跃模块)
function getTotalPoints(address user) public view returns (uint256 total)

// 获取用户总积分 (带模块成功状态)
function getTotalPointsWithStatus(address user)
    public view returns (uint256 total, bool[] memory moduleSuccess)

// 获取用户惩罚积分
function getPenaltyPoints(address user) public view returns (uint256)

// 获取可兑换积分 = 总积分 - 惩罚 - 已兑换
function getClaimablePoints(address user) public view returns (uint256)

// 获取积分明细
function getPointsBreakdown(address user) external view returns (
    string[] memory names,      // 模块名称
    uint256[] memory points,    // 各模块积分
    uint256 penalty,            // 惩罚积分
    uint256 redeemed,           // 已兑换积分
    uint256 claimable           // 可兑换积分
)

// 预览兑换
function previewRedeem(uint256 pointsAmount) public view returns (uint256 tokenAmount)
```

#### 用户函数

```solidity
// 兑换积分为代币
// tokenAmount = pointsAmount × exchangeRate / PRECISION
function redeem(uint256 pointsAmount) external nonReentrant whenNotPaused
```

#### 管理函数

```solidity
// 模块管理 (ADMIN_ROLE)
function registerModule(address module) external onlyRole(ADMIN_ROLE)
function removeModule(address module) external onlyRole(ADMIN_ROLE)
function emergencyRemoveModuleByIndex(uint256 index) external onlyRole(ADMIN_ROLE)
function setPenaltyModule(address _penaltyModule) external onlyRole(ADMIN_ROLE)

// 兑换配置 (ADMIN_ROLE)
function setRewardToken(address token) external onlyRole(ADMIN_ROLE)
function setExchangeRate(uint256 rate) external onlyRole(ADMIN_ROLE)
function setRedeemEnabled(bool enabled) external onlyRole(ADMIN_ROLE)
function setMaxRedeemPerTx(uint256 max) external onlyRole(ADMIN_ROLE)
function withdrawRewardTokens(address to, uint256 amount) external onlyRole(ADMIN_ROLE)

// 系统配置 (ADMIN_ROLE)
function setModuleGasLimit(uint256 limit) external onlyRole(ADMIN_ROLE)
function pause() external onlyRole(ADMIN_ROLE)
function unpause() external onlyRole(ADMIN_ROLE)
```

### 事件

```solidity
event ModuleRegistered(address indexed module, string name, uint256 moduleIndex);
event ModuleRemoved(address indexed module, uint256 moduleIndex);
event PenaltyModuleUpdated(address indexed oldModule, address indexed newModule);
event RewardTokenUpdated(address indexed oldToken, address indexed newToken);
event ExchangeRateUpdated(uint256 oldRate, uint256 newRate);
event RedeemStatusUpdated(bool enabled);
event MaxRedeemPerTxUpdated(uint256 oldMax, uint256 newMax);
event PointsRedeemed(address indexed user, uint256 pointsAmount, uint256 tokenAmount, uint256 totalRedeemed);
event PointsHubUpgraded(address indexed newImplementation, uint256 timestamp);
event ModuleGasLimitUpdated(uint256 oldLimit, uint256 newLimit);
```

### 错误

```solidity
error ZeroAddress();
error ZeroAmount();
error ModuleAlreadyRegistered(address module);
error ModuleNotFound(address module);
error RedeemNotEnabled();
error InsufficientPoints(uint256 available, uint256 requested);
error ExceedsMaxRedeemPerTx(uint256 requested, uint256 max);
error InsufficientRewardTokens(uint256 available, uint256 required);
error ExchangeRateNotSet();
error RewardTokenNotSet();
error IndexOutOfBounds(uint256 index, uint256 length);
error InvalidModuleInterface(address module);
error MaxModulesReached();
error InvalidExchangeRate(uint256 rate, uint256 min, uint256 max);
error InvalidPenaltyModuleInterface(address module);
error ZeroTokenAmount();
```

---

## StakingModule (质押模块)

### 功能概述

PPT 质押积分模块，支持**灵活质押**和**锁定质押**两种模式，采用信用卡积分模式计算。

### 质押类型

| 类型 | Boost | 描述 |
|------|-------|------|
| **灵活质押** (Flexible) | 1.0x | 随时取出，无锁定期 |
| **锁定质押** (Locked) | 1.02x~2.0x | 锁定期内有 boost 加成，到期后自动降为 1.0x |

### 常量

| 常量 | 值 | 描述 |
|------|-----|------|
| `PRECISION` | `1e18` | 计算精度 |
| `RATE_PRECISION` | `1e18` | `pointsRatePerSecond` 精度基准（`1e18` = 1.0x） |
| `BOOST_BASE` | `10000` | Boost 基数 (1x = 10000) |
| `MAX_EXTRA_BOOST` | `10000` | 最大额外 Boost (1x) |
| `MIN_LOCK_DURATION` | `7 days` | 最小锁定期 |
| `MAX_LOCK_DURATION` | `365 days` | 最大锁定期 |
| `EARLY_UNLOCK_PENALTY_BPS` | `5000` | 提前解锁惩罚 (50%) |
| `MAX_STAKES_PER_USER` | `100` | 每用户最大质押数 |
| `MAX_BATCH_USERS` | `100` | 批量 checkpoint 最大用户数 |
| `MIN_STAKE_AMOUNT` | `100e18` | 最小质押量 (100 PPT) |
| `MAX_STAKE_AMOUNT` | `type(uint128).max / 2` | 最大质押量（防止积分计算乘法溢出） |
| `MIN_POINTS_RATE` | `1` | 最小积分率 |
| `MAX_POINTS_RATE` | `1e24` | 最大积分率 |

### Boost 倍数表

| 锁定时长 | Boost 倍数 | 计算公式 |
|----------|-----------|----------|
| 灵活质押 | 1.0x | `BOOST_BASE (10000)` |
| 7 天 (最小) | 1.019x | `10000 + (7 × 10000 / 365) = 10191` |
| 30 天 | 1.082x | `10000 + (30 × 10000 / 365) = 10822` |
| 90 天 | 1.247x | `10000 + (90 × 10000 / 365) = 12466` |
| 180 天 | 1.493x | `10000 + (180 × 10000 / 365) = 14932` |
| 365 天 (最大) | 2.0x | `10000 + (365 × 10000 / 365) = 20000` |

**锁定到期行为**: 锁定到期后 boost 自动降为 1.0x，用户无需手动操作。

### 数据结构

```solidity
/// @notice 质押类型
enum StakeType {
    Flexible, // 灵活质押，随时取出，1.0x boost
    Locked    // 锁定质押，有 boost 加成
}

/// @notice 单个质押记录 (信用卡积分模式)
struct StakeInfo {
    uint256 amount;           // 质押金额
    uint256 accruedPoints;    // 已累计积分（截至 lastAccrualTime）
    uint64 startTime;         // 质押开始时间
    uint64 lockEndTime;       // 锁定到期时间 (Flexible=0)
    uint64 lastAccrualTime;   // 上次积分累计时间
    uint32 lockDurationDays;  // 原始锁定天数 (0 for Flexible)
    StakeType stakeType;      // 质押类型
    bool isActive;            // 质押是否活跃
}

/// @notice 聚合用户状态
struct UserState {
    uint256 totalStakedAmount;   // 所有活跃质押的原始金额总和
    uint256 lastCheckpointBlock; // 用于闪电贷保护
}
```

### 积分计算公式 (信用卡模式)

```
// 每个质押独立计算，无全局状态
points = amount × boost × pointsRatePerSecond × duration / (BOOST_BASE × RATE_PRECISION)

// boost 根据质押类型和锁定状态动态计算
effectiveBoost = isLocked && notExpired ? calculateBoost(lockDuration) : BOOST_BASE

// RATE_PRECISION = 1e18，rate = 1e18 时公式退化为：
// points = amount × boost × duration / BOOST_BASE
```

**计算示例** (rate = 1e18, 即 1.0x):

```
100 PPT 灵活质押 1 天:
= 100e18 × 10000 × 1e18 × 86400 / (10000 × 1e18)
= 100e18 × 86400
= 8.64e24 (raw)
= 8.64 (display, ÷ 10^24)

1000 PPT 锁定 365 天 (2.0x boost) 质押 1 天:
= 1000e18 × 20000 × 1e18 × 86400 / (10000 × 1e18)
= 1000e18 × 2 × 86400
= 1.728e26 (raw)
= 172.8 (display)

100 PPT 灵活质押 1 天, rate = 0.9x (9e17):
= 100e18 × 10000 × 9e17 × 86400 / (10000 × 1e18)
= 100e18 × 0.9 × 86400
= 7.776e24 (raw)
= 7.776 (display)
```

### 核心函数

#### 质押/解锁

```solidity
// 灵活质押 (1.0x boost，随时取出)
function stakeFlexible(uint256 amount)
    external nonReentrant whenNotPaused returns (uint256 stakeIndex)

// 锁定质押 (锁定 7-365 天，有 boost 加成)
function stakeLocked(uint256 amount, uint256 lockDurationDays)
    external nonReentrant whenNotPaused returns (uint256 stakeIndex)

// 解锁质押 (锁定质押提前解锁有惩罚)
function unstake(uint256 stakeIndex) external nonReentrant whenNotPaused
```

#### 查询函数

```solidity
// IPointsModule 实现
function getPoints(address user) external view returns (uint256)
function moduleName() external pure returns (string memory)
function isActive() external view returns (bool)

// 状态查询
function getUserState(address user) external view returns (
    uint256 totalStaked,
    uint256 earnedPoints,
    uint256 activeStakeCount
)
function getStakeInfo(address user, uint256 stakeIndex) external view returns (StakeInfo memory)
function getStakePointsAndBoost(address user, uint256 stakeIndex) external view returns (
    uint256 totalPoints,
    uint256 effectiveBoost,
    bool isLockExpired
)
function getAllStakes(address user) external view returns (StakeInfo[] memory)

// 估算
function estimatePoints(uint256 amount, uint256 lockDurationDays, uint256 holdDurationSeconds) external view returns (uint256)
function calculatePotentialPenalty(address user, uint256 stakeIndex) external view returns (uint256 penalty)
```

#### Checkpoint

```solidity
// Keeper 批量检查点
function checkpointUsers(address[] calldata users) external onlyRole(KEEPER_ROLE)

// 任何人可调用
function checkpoint(address user) external
function checkpointSelf() external
```

### 提前解锁惩罚公式

```
currentPoints = 当前累计积分
remainingTime = lockEndTime - block.timestamp
penalty = currentPoints × (remainingTime / lockDuration) × 50%
```

**示例:**
- 用户质押 365 天，已锁定 180 天，期间获得 1000 积分
- remainingTime = 185 天
- penalty = 1000 × (185 / 365) × 50% = 253 积分

### 事件

```solidity
event Staked(address indexed user, uint256 indexed stakeIndex, uint256 amount, StakeType stakeType, uint256 lockDurationDays, uint256 boost, uint256 lockEndTime);
event Unstaked(address indexed user, uint256 indexed stakeIndex, uint256 amount, uint256 actualPenalty, uint256 theoreticalPenalty, bool isEarlyUnlock, bool penaltyWasCapped);
event UserCheckpointed(address indexed user, uint256 totalPoints, uint256 totalStaked, uint256 timestamp);
event FlashLoanProtectionTriggered(address indexed user, uint256 blocksRemaining);
event ZeroAddressSkipped(uint256 indexed position);
event PointsRateUpdated(uint256 oldRate, uint256 newRate);
event ModuleActiveStatusUpdated(bool active);
event MinHoldingBlocksUpdated(uint256 oldBlocks, uint256 newBlocks);
event PptUpdated(address indexed oldPpt, address indexed newPpt);
```

### 错误

```solidity
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
```

---

## LPModule (LP模块)

### 功能概述

质押 LP Token 获得积分，支持多个 LP 池和不同倍数。

### 常量

| 常量 | 值 | 描述 |
|------|-----|------|
| `PRECISION` | `1e18` | 计算精度 |
| `MULTIPLIER_BASE` | `100` | 倍数基数 (100 = 1x) |
| `MAX_MULTIPLIER` | `1000` | 最大倍数 (10x) |
| `MAX_POOLS` | `20` | 最大池数 |
| `MAX_BATCH_USERS` | `25` | 批量最大用户数 |
| `MAX_OPERATIONS_PER_BATCH` | `200` | 批量最大操作数 |

### 数据结构

```solidity
struct PoolConfig {
    address lpToken;     // LP Token 地址
    uint256 multiplier;  // 积分倍数 (100 = 1x)
    bool isActive;       // 池是否活跃
    string name;         // 池名称
}

/// @notice v2.0 信用卡模式 - 无全局 PoolState，每用户独立计算
struct UserPoolState {
    uint256 accruedPoints;       // 已累计积分
    uint256 lastBalance;         // 上次检查点时的 LP 余额
    uint256 lastAccrualTime;     // 上次积分累计时间
    uint256 lastCheckpointBlock; // 用于闪电贷保护
}
```

### 核心函数

#### 池管理

```solidity
// 添加 LP 池
function addPool(address lpToken, uint256 multiplier, string calldata name) external onlyRole(ADMIN_ROLE)

// 更新池配置
function updatePool(uint256 poolId, uint256 multiplier, bool poolActive) external onlyRole(ADMIN_ROLE)

// 更新池名称
function updatePoolName(uint256 poolId, string calldata name) external onlyRole(ADMIN_ROLE)

// 移除池 (标记为 inactive)
function removePool(uint256 poolId) external onlyRole(ADMIN_ROLE)
```

#### 查询函数

```solidity
// IPointsModule 实现
function getPoints(address user) external view returns (uint256 total)

// 池信息
function getPoolCount() external view returns (uint256)
function getPool(uint256 poolId) external view returns (
    address lpToken,
    uint256 multiplier,
    bool poolActive,
    string memory name,
    uint256 totalSupply,
    uint256 pointsPerLp
)

// 用户信息
function getUserPoolBreakdown(address user) external view returns (
    string[] memory names,
    uint256[] memory points,
    uint256[] memory balances,
    uint256[] memory multipliers
)
function getUserPoolState(address user, uint256 poolId) external view returns (
    uint256 balance,
    uint256 lastCheckpointBalance,
    uint256 earnedPoints,
    uint256 lastAccrualTime,
    uint256 lastCheckpointBlock
)

// 估算
function estimatePoolPoints(uint256 poolId, uint256 lpAmount, uint256 durationSeconds) external view returns (uint256)
```

#### Checkpoint

```solidity
function checkpointAllPools() external onlyRole(KEEPER_ROLE)
function checkpointPools(uint256[] calldata poolIds) external onlyRole(KEEPER_ROLE)
function checkpointUsers(address[] calldata users) external onlyRole(KEEPER_ROLE)
function checkpoint(address user) external
function checkpointSelf() external
function checkpointUserPool(address user, uint256 poolId) external
```

### 积分计算 (信用卡模式)

```
// 每个用户独立计算，无全局状态
effectiveRate = basePointsRatePerSecond × multiplier / MULTIPLIER_BASE
userPoints = userBalance × effectiveRate × duration
```

**特点:**
- 无全局 `pointsPerLpStored` 状态
- 用户积分只与自身余额和时间相关
- 后入者不会稀释早入者的积分

---

## ActivityModule (活动模块)

### 功能概述

链下计算活动积分，用户通过 Merkle proof 领取。

### 常量

| 常量 | 值 | 描述 |
|------|-----|------|
| `MAX_BATCH_SIZE` | `100` | 批量领取最大数量 |
| `ROOT_DELAY` | `24 hours` | Root 生效延迟 (防抢跑) |
| `MAX_ROOT_HISTORY` | `100` | Root 历史最大保留数 |

### 状态变量

| 变量 | 类型 | 描述 |
|------|------|------|
| `merkleRoot` | `bytes32` | 当前 Merkle Root |
| `claimedPoints` | `mapping(address => uint256)` | 用户已领取积分 |
| `active` | `bool` | 模块激活状态 |
| `currentEpoch` | `uint256` | 当前纪元号 |
| `currentEpochLabel` | `string` | 当前纪元描述 |
| `pendingRoot` | `bytes32` | 待生效 Root |
| `pendingRootEffectiveTime` | `uint256` | 待生效时间 |

### Merkle Leaf 格式

```solidity
leaf = keccak256(bytes.concat(keccak256(abi.encode(userAddress, totalCumulativePoints))))
```

### 核心函数

#### 用户领取

```solidity
// 用户领取积分
function claim(uint256 totalEarned, bytes32[] calldata proof) external nonReentrant whenNotPaused

// 验证领取 (view)
function verifyClaim(address user, uint256 totalEarned, bytes32[] calldata proof)
    public view returns (bool valid, uint256 claimable)
```

#### Keeper 函数

```solidity
// 排队新 Root (24小时后生效)
function updateMerkleRoot(bytes32 newRoot, string calldata label) external onlyRole(KEEPER_ROLE)

// 排队新 Root (指定纪元号)
function updateMerkleRootWithEpoch(bytes32 newRoot, uint256 epoch, string calldata label) external onlyRole(KEEPER_ROLE)

// 激活待生效 Root
function activateRoot() external

// 批量帮用户领取
function batchClaim(address[] calldata users, uint256[] calldata totalEarnedAmounts, bytes32[][] calldata proofs)
    external onlyRole(KEEPER_ROLE)
```

#### Admin 函数

```solidity
// 紧急立即激活 Root
function emergencyActivateRoot() external onlyRole(ADMIN_ROLE)

// 取消待生效 Root
function cancelPendingRoot() external onlyRole(ADMIN_ROLE)

// 重置用户已领取数量
function resetUserClaimed(address user, uint256 newAmount) external onlyRole(ADMIN_ROLE)
```

---

## PenaltyModule (惩罚模块)

### 功能概述

链下计算惩罚积分，通过 Merkle proof 同步到链上。

### 常量

| 常量 | 值 | 描述 |
|------|-----|------|
| `BASIS_POINTS` | `10000` | 基点 (100%) |
| `MAX_BATCH_SIZE` | `100` | 批量同步最大数量 |
| `ROOT_DELAY` | `24 hours` | Root 生效延迟 |
| `MAX_ROOT_HISTORY` | `100` | Root 历史最大保留数 |

### 状态变量

| 变量 | 类型 | 描述 |
|------|------|------|
| `penaltyRoot` | `bytes32` | 当前 Penalty Merkle Root |
| `confirmedPenalty` | `mapping(address => uint256)` | 用户确认的惩罚积分 |
| `penaltyRateBps` | `uint256` | 惩罚率 (基点) |
| `pendingRoot` | `bytes32` | 待生效 Root |
| `pendingRootEffectiveTime` | `uint256` | 待生效时间 |

### Merkle Leaf 格式

```solidity
leaf = keccak256(bytes.concat(keccak256(abi.encode(userAddress, totalCumulativePenalty))))
```

### 核心函数

```solidity
// IPenaltyModule 实现
function getPenalty(address user) external view returns (uint256)

// 同步惩罚
function syncPenalty(address user, uint256 totalPenalty, bytes32[] calldata proof) external nonReentrant whenNotPaused
function batchSyncPenalty(address[] calldata users, uint256[] calldata totalPenalties, bytes32[][] calldata proofs) external onlyRole(KEEPER_ROLE)

// 验证
function verifyPenalty(address user, uint256 totalPenalty, bytes32[] calldata proof) public view returns (bool)

// 计算惩罚 (参考)
function calculatePenalty(uint256 redemptionAmount) external view returns (uint256)

// Keeper
function updatePenaltyRoot(bytes32 newRoot) external onlyRole(KEEPER_ROLE)
function activateRoot() external

// Admin
function emergencyActivateRoot() external onlyRole(ADMIN_ROLE)
function cancelPendingRoot() external onlyRole(ADMIN_ROLE)
function setPenaltyRate(uint256 newRateBps) external onlyRole(ADMIN_ROLE)
function setUserPenalty(address user, uint256 penalty) external onlyRole(ADMIN_ROLE)
function batchSetPenalties(address[] calldata users, uint256[] calldata penalties) external onlyRole(ADMIN_ROLE)
```

**注意:** 惩罚只能增加，不能减少 (`PenaltyCannotDecrease` 错误)。

---

## 接口定义

### IPointsModule

```solidity
interface IPointsModule {
    function getPoints(address user) external view returns (uint256);
    function moduleName() external view returns (string memory);
    function isActive() external view returns (bool);
}
```

### IPenaltyModule

```solidity
interface IPenaltyModule {
    function getPenalty(address user) external view returns (uint256);
}
```

### IPointsHub

```solidity
interface IPointsHub {
    function getTotalPoints(address user) external view returns (uint256);
    function getPenaltyPoints(address user) external view returns (uint256);
    function getClaimablePoints(address user) external view returns (uint256);
    function redeem(uint256 pointsAmount) external;
}
```

### IPPT

```solidity
interface IPPT {
    function balanceOf(address account) external view returns (uint256);
    function effectiveSupply() external view returns (uint256);
    function totalSupply() external view returns (uint256);
}
```

---

## 角色权限

### 角色定义

| 角色 | bytes32 | 描述 |
|------|---------|------|
| `DEFAULT_ADMIN_ROLE` | `0x00` | OpenZeppelin 默认管理员 |
| `ADMIN_ROLE` | `keccak256("ADMIN_ROLE")` | 配置管理 |
| `KEEPER_ROLE` | `keccak256("KEEPER_ROLE")` | 日常运维 (checkpoint, root 更新) |
| `UPGRADER_ROLE` | `keccak256("UPGRADER_ROLE")` | 合约升级 (建议使用 Timelock) |

### 权限矩阵

| 操作 | ADMIN | KEEPER | UPGRADER | Public |
|------|-------|--------|----------|--------|
| 模块注册/移除 | Y | - | - | - |
| 设置兑换率 | Y | - | - | - |
| 暂停/恢复 | Y | - | - | - |
| Checkpoint 全局 | - | Y | - | - |
| Checkpoint 批量用户 | - | Y | - | - |
| 更新 Merkle Root | - | Y | - | - |
| Checkpoint 单用户 | - | - | - | Y |
| Checkpoint 自己 | - | - | - | Y |
| 领取积分 | - | - | - | Y |
| 兑换积分 | - | - | - | Y |
| 合约升级 | - | - | Y | - |

---

## 部署指南

### 部署顺序

```
1. 部署 Mocks (测试环境)
   - MockPPT, MockERC20 (Reward Token, LP Tokens)

2. 部署 PointsHub
   - initialize(admin, upgrader)

3. 部署 Points Modules
   - StakingModule.initialize(ppt, admin, keeper, upgrader, pointsRatePerSecond)
   - LPModule.initialize(admin, keeper, upgrader, baseRate)
   - ActivityModule.initialize(admin, keeper, upgrader)

4. 部署 PenaltyModule
   - initialize(admin, keeper, upgrader, penaltyRateBps)

5. 配置 PointsHub
   - registerModule(stakingModule)
   - registerModule(lpModule)
   - registerModule(activityModule)
   - setPenaltyModule(penaltyModule)
   - setRewardToken(rewardToken)
   - setExchangeRate(rate)

6. 配置 LPModule
   - addPool(lpToken, multiplier, name) x N

7. 充值 Reward Token 到 PointsHub
```

### 部署脚本示例

```solidity
// script/DeployStakingModule.s.sol
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {StakingModule} from "../src/StakingModule.sol";

contract DeployStakingModule is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address ppt = vm.envAddress("PPT_ADDRESS");
        address admin = vm.envAddress("ADMIN_ADDRESS");
        address keeper = vm.envAddress("KEEPER_ADDRESS");
        address upgrader = vm.envAddress("UPGRADER_ADDRESS");
        uint256 pointsRatePerSecond = vm.envUint("POINTS_RATE_PER_SECOND");

        vm.startBroadcast(deployerPrivateKey);

        // 1. 部署实现
        StakingModule impl = new StakingModule();

        // 2. 部署代理
        bytes memory initData = abi.encodeWithSelector(
            StakingModule.initialize.selector,
            ppt,
            admin,
            keeper,
            upgrader,
            pointsRatePerSecond
        );
        StakingModule module = StakingModule(
            address(new ERC1967Proxy(address(impl), initData))
        );

        vm.stopBroadcast();
    }
}
```

---

## 安全机制

### 1. UUPS 升级模式

所有合约使用 UUPS Upgradeable pattern：
- 构造函数调用 `_disableInitializers()` 防止实现合约被初始化
- 升级权限由 `UPGRADER_ROLE` 控制 (建议使用 Timelock)
- `__gap[50]` 存储间隙预留未来升级空间

### 2. Flash Loan 防护

```solidity
// 检查是否通过持有期
bool passedHoldingPeriod = lastCheckpointBlock == 0
    || block.number >= lastCheckpointBlock + minHoldingBlocks;

// 只有通过持有期才计入积分
if (passedHoldingPeriod) {
    userPointsEarned += newEarned;
}
```

### 3. Merkle Root 延迟激活

ActivityModule 和 PenaltyModule 的 Root 更新有 24 小时延迟：

```
updateMerkleRoot() -> pendingRoot (等待 24h) -> activateRoot() -> merkleRoot
```

### 4. Gas 限制保护

PointsHub 调用模块时使用 gas limit 防止恶意模块 DoS：

```solidity
(bool success, bytes memory data) = moduleAddr.staticcall{gas: moduleGasLimit}(
    abi.encodeWithSelector(IPointsModule.getPoints.selector, user)
);
```

### 5. 重入防护

关键函数使用 `ReentrancyGuard`：
- `redeem()`
- `stake()` / `unstake()`
- `claim()` / `syncPenalty()`

### 6. SafeERC20

所有 Token 操作使用 `SafeERC20`：
- `safeTransfer()`
- `safeTransferFrom()`

---

## Gas 估算

| 操作 | Gas | 说明 |
|------|-----|------|
| `PointsHub.getTotalPoints()` | ~20,000 - 50,000 | 取决于模块数量 |
| `PointsHub.redeem()` | ~80,000 | 含 ERC20 转账 |
| `StakingModule.getPoints()` | ~5,000 - 20,000 | 取决于用户质押数量 |
| `StakingModule.stakeFlexible()` | ~80,000 | 含 ERC20 转账 |
| `StakingModule.stakeLocked()` | ~85,000 | 含 ERC20 转账 |
| `StakingModule.unstake()` | ~60,000 | 含 ERC20 转账 |
| `LPModule.getPoints()` | ~10,000 - 40,000 | 取决于池数量 |
| `ActivityModule.claim()` | ~50,000 | 含 Merkle 验证 |
| `PenaltyModule.syncPenalty()` | ~40,000 | 含 Merkle 验证 |

---

## 测试

```bash
# 编译
forge build

# 运行所有测试
forge test

# 详细输出
forge test -vvv

# 运行特定测试
forge test --match-contract StakingModuleTest

# Gas 报告
forge test --gas-report

# CI 模式 (更多 fuzz 测试)
forge test --profile ci

# 覆盖率
forge coverage
```

### 测试文件

| 文件 | 测试数 | 描述 |
|------|--------|------|
| `test/StakingModule.t.sol` | 67 | 质押模块全面测试 (信用卡模式) |
| `test/LPModule.t.sol` | 44 | LP 模块测试 (信用卡模式) |
| `test/ActivityModule.t.sol` | 24 | 活动模块测试 |
| `test/PenaltyModule.t.sol` | 23 | 惩罚模块测试 |
| `test/PointsHub.t.sol` | 22 | 聚合器测试 |
| `test/Integration.t.sol` | 12 | 集成测试 |
| `test/Security.t.sol` | 23 | 安全测试 |
| **Total** | **215** | |

---

## 依赖

- [OpenZeppelin Contracts v5.0.2](https://github.com/OpenZeppelin/openzeppelin-contracts)
- [OpenZeppelin Contracts Upgradeable v5.0.2](https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable)
- [Forge Std](https://github.com/foundry-rs/forge-std)

## 许可证

MIT License
