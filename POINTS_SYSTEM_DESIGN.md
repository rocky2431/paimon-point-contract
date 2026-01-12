# Paimon Points System - 技术设计文档

> Version: 1.0.0
> Date: 2026-01-12
> Status: Draft

---

## 目录

1. [系统概述](#1-系统概述)
2. [架构设计](#2-架构设计)
3. [合约详细说明](#3-合约详细说明)
4. [积分计算规则](#4-积分计算规则)
5. [角色与权限](#5-角色与权限)
6. [部署流程](#6-部署流程)
7. [运维操作](#7-运维操作)
8. [链下服务](#8-链下服务)
9. [安全考虑](#9-安全考虑)
10. [待定参数](#10-待定参数)
11. [FAQ](#11-faq)

---

## 1. 系统概述

### 1.1 背景

Paimon Points System 是一个独立于 PPT Vault 主合约的积分激励系统，旨在奖励用户的多种贡献行为，包括持有 PPT、提供流动性、交易等。

### 1.2 目标

- **激励长期持有**: 持有 PPT 时间越长，获得积分越多
- **激励流动性提供**: 在指定池子提供 LP 获得额外积分
- **激励交易活跃度**: 交易行为产生积分奖励
- **惩罚短期行为**: 赎回行为会扣减一定比例积分

### 1.3 积分用途

| 用途 | 描述 | 状态 |
|-----|------|------|
| 空投资格 | 积分决定空投分配比例 | 计划中 |
| 兑换代币 | 积分可兑换为指定代币 | 计划中 |
| VIP 等级 | 积分累计决定 VIP 等级 | 计划中 |

### 1.4 设计原则

1. **独立性**: 积分系统完全独立于 PPT 主合约，不影响核心资金安全
2. **可升级性**: 所有合约采用 UUPS 代理模式，支持独立升级
3. **模块化**: 不同积分来源由独立模块处理，便于扩展
4. **Gas 优化**: 采用 checkpoint 机制，避免每次交易都更新积分
5. **去中心化验证**: 链下计算的积分通过 Merkle Proof 验证

---

## 2. 架构设计

### 2.1 整体架构图

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              用户交互层                                      │
├─────────────────────────────────────────────────────────────────────────────┤
│  - 查询积分: PointsHub.getClaimablePoints(user)                             │
│  - 兑换代币: PointsHub.redeem(amount)                                       │
│  - 主动 checkpoint: xxxModule.checkpoint(user)                              │
│  - Claim 活动积分: ActivityModule.claim(amount, proof)                      │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                           PointsHub.sol (核心聚合层)                         │
├─────────────────────────────────────────────────────────────────────────────┤
│  职责:                                                                       │
│  - 聚合所有模块的积分                                                        │
│  - 扣除惩罚积分                                                              │
│  - 管理积分兑换逻辑                                                          │
│  - 注册/移除积分模块                                                         │
│                                                                              │
│  核心公式:                                                                   │
│  claimablePoints = Σ modules[i].getPoints(user) - penalty - redeemed        │
└─────────────────────────────────────────────────────────────────────────────┘
          │              │              │              │
          ▼              ▼              ▼              ▼
┌──────────────┐ ┌──────────────┐ ┌──────────────┐ ┌──────────────┐
│ HoldingModule│ │  LPModule    │ │ActivityModule│ │PenaltyModule │
│  (持有积分)   │ │  (LP积分)    │ │ (活动积分)   │ │ (赎回惩罚)   │
├──────────────┤ ├──────────────┤ ├──────────────┤ ├──────────────┤
│ 数据源:      │ │ 数据源:      │ │ 数据源:      │ │ 数据源:      │
│ PPT.balanceOf│ │ LP Token     │ │ Merkle Tree  │ │ Merkle Tree  │
│              │ │ balanceOf    │ │ (链下计算)   │ │ (链下计算)   │
├──────────────┤ ├──────────────┤ ├──────────────┤ ├──────────────┤
│ 计算方式:    │ │ 计算方式:    │ │ 计算方式:    │ │ 计算方式:    │
│ 链上实时     │ │ 链上实时     │ │ 链下+验证    │ │ 链下+验证    │
│ + checkpoint │ │ + checkpoint │ │              │ │              │
└──────────────┘ └──────────────┘ └──────────────┘ └──────────────┘
          │              │              │              │
          ▼              ▼              ▼              ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                              外部数据源                                      │
├──────────────┬──────────────┬──────────────────┬───────────────────────────┤
│   PPT Vault  │ LP Tokens    │   DEX Events     │  RedemptionManager Events │
│  (链上读取)   │ (链上读取)   │   (链下索引)     │      (链下索引)           │
└──────────────┴──────────────┴──────────────────┴───────────────────────────┘
```

### 2.2 数据流图

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           积分数据流                                         │
└─────────────────────────────────────────────────────────────────────────────┘

【持有积分流程】
User 存入 PPT → PPT.balanceOf 增加 → 定期 checkpoint → HoldingModule 记录积分
                                              ↑
                                         Keeper 每周调用

【LP 积分流程】
User 添加流动性 → LP Token 增加 → 定期 checkpoint → LPModule 记录积分
                                         ↑
                                    Keeper 每周调用

【交易积分流程】
User DEX 交易 → Swap 事件 → 链下索引服务 → 计算积分 → 生成 Merkle Tree
                                                            ↓
                                                   Keeper 更新 Root
                                                            ↓
                                              User claim(proof) → 积分记录

【赎回惩罚流程】
User 赎回 PPT → RedemptionSettled 事件 → 链下索引 → 计算惩罚 → 生成 Merkle Tree
                                                                     ↓
                                                            Keeper 更新 Root
                                                                     ↓
                                                    PointsHub 读取惩罚 → 扣减积分
```

### 2.3 合约关系图

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           合约依赖关系                                       │
└─────────────────────────────────────────────────────────────────────────────┘

                    ┌─────────────────┐
                    │   PointsHub     │
                    │   (核心合约)     │
                    └────────┬────────┘
                             │
           ┌─────────────────┼─────────────────┐
           │ registerModule  │ setPenaltyModule│
           ▼                 ▼                 ▼
    ┌──────────────┐ ┌──────────────┐ ┌──────────────┐
    │HoldingModule │ │  LPModule    │ │ActivityModule│
    └──────┬───────┘ └──────┬───────┘ └──────────────┘
           │                │
           │ reads          │ reads
           ▼                ▼
    ┌──────────────┐ ┌──────────────┐ ┌──────────────┐
    │  PPT Vault   │ │  LP Tokens   │ │PenaltyModule │
    │  (外部)      │ │  (外部)      │ └──────────────┘
    └──────────────┘ └──────────────┘         │
                                              │ reads (getPenalty)
                                              ▼
                                       ┌──────────────┐
                                       │  PointsHub   │
                                       └──────────────┘
```

---

## 3. 合约详细说明

### 3.1 PointsHub.sol

**职责**: 积分聚合中心，管理所有积分模块和兑换逻辑

**存储结构**:
```solidity
// 积分模块列表
IPointsModule[] public modules;
mapping(address => bool) public isModule;

// 惩罚模块
IPenaltyModule public penaltyModule;

// 兑换配置
IERC20 public rewardToken;        // 兑换目标代币
uint256 public exchangeRate;      // 兑换比例 (1e18 精度)
bool public redeemEnabled;        // 兑换开关

// 用户状态
mapping(address => uint256) public redeemedPoints;  // 已兑换积分
```

**核心函数**:

| 函数 | 可见性 | 描述 |
|-----|--------|------|
| `getTotalPoints(user)` | view | 获取用户总积分 (所有模块之和) |
| `getPenaltyPoints(user)` | view | 获取用户惩罚积分 |
| `getClaimablePoints(user)` | view | 获取可用积分 = 总积分 - 惩罚 - 已兑换 |
| `getPointsBreakdown(user)` | view | 获取积分明细 (各模块分别) |
| `redeem(amount)` | external | 兑换积分为代币 |
| `registerModule(module)` | admin | 注册新积分模块 |
| `removeModule(module)` | admin | 移除积分模块 |
| `setPenaltyModule(module)` | admin | 设置惩罚模块 |
| `setRewardToken(token)` | admin | 设置兑换代币 |
| `setExchangeRate(rate)` | admin | 设置兑换比例 |
| `setRedeemEnabled(bool)` | admin | 开启/关闭兑换 |

**事件**:
```solidity
event ModuleRegistered(address indexed module, string name);
event ModuleRemoved(address indexed module);
event PointsRedeemed(address indexed user, uint256 points, uint256 tokens);
event ExchangeRateUpdated(uint256 oldRate, uint256 newRate);
event RedeemStatusUpdated(bool enabled);
```

---

### 3.2 HoldingModule.sol

**职责**: 计算用户持有 PPT 产生的积分

**算法**: 基于 Synthetix StakingRewards 的时间加权算法

```
pointsPerShare += (timeDelta × pointsRatePerSecond) / effectiveSupply
userPoints = lastBalance × (pointsPerShare - userPointsPerSharePaid) + userPointsEarned
```

**存储结构**:
```solidity
// 外部合约
IPPT public ppt;

// 全局参数
uint256 public pointsRatePerSecond;  // 每秒每 PPT 产生的积分
uint256 public lastUpdateTime;        // 上次更新时间
uint256 public pointsPerShareStored;  // 累计每份额积分

// 用户状态
mapping(address => uint256) public userPointsPerSharePaid;  // 用户已结算的每份额积分
mapping(address => uint256) public userPointsEarned;        // 用户已累计积分
mapping(address => uint256) public userLastBalance;         // 用户上次余额快照
```

**核心函数**:

| 函数 | 可见性 | 描述 |
|-----|--------|------|
| `getPoints(user)` | view | 获取用户当前持有积分 (实时计算) |
| `currentPointsPerShare()` | view | 获取当前每份额积分值 |
| `checkpoint(user)` | external | 更新用户积分快照 (任何人可调用) |
| `checkpointGlobal()` | keeper | 更新全局状态 |
| `checkpointUsers(users[])` | keeper | 批量更新用户状态 |
| `setPointsRate(rate)` | admin | 设置积分产生速率 |

**Checkpoint 机制说明**:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         Checkpoint 时间线                                    │
└─────────────────────────────────────────────────────────────────────────────┘

Week 1                 Week 2                 Week 3
  │                      │                      │
  ▼                      ▼                      ▼
  ┌──────────────────────┬──────────────────────┬──────────────────────┐
  │ Global Checkpoint    │ Global Checkpoint    │ Global Checkpoint    │
  │ + User Checkpoints   │ + User Checkpoints   │ + User Checkpoints   │
  └──────────────────────┴──────────────────────┴──────────────────────┘

用户在任意时刻调用 getPoints(user):
- 使用 lastCheckpoint 时的 userLastBalance 计算已确认积分
- 加上从 lastCheckpoint 到当前的实时积分 (使用当前 balance)

用户自行调用 checkpoint(user):
- 更新 userLastBalance 为当前余额
- 结算之前的积分到 userPointsEarned
```

---

### 3.3 LPModule.sol

**职责**: 计算用户在指定 LP 池子提供流动性产生的积分

**特性**:
- 支持多个 LP 池子
- 每个池子可设置不同权重 (multiplier)
- 算法与 HoldingModule 类似，但按池子独立计算

**存储结构**:
```solidity
// 池子配置
struct PoolConfig {
    address lpToken;      // LP Token 地址
    uint256 multiplier;   // 倍率 (100 = 1x, 200 = 2x)
    bool isActive;        // 是否启用
    string name;          // 池子名称
}

PoolConfig[] public pools;
mapping(address => uint256) public poolIndex;  // lpToken => index + 1

// 全局参数
uint256 public basePointsRatePerSecond;

// 池子状态
struct PoolState {
    uint256 lastUpdateTime;
    uint256 pointsPerLPStored;
}
mapping(uint256 => PoolState) public poolStates;

// 用户池子状态
struct UserPoolState {
    uint256 pointsPerLPPaid;
    uint256 pointsEarned;
    uint256 lastBalance;
}
mapping(address => mapping(uint256 => UserPoolState)) public userPoolStates;
```

**池子配置示例**:

| 池子 | LP Token | Multiplier | 说明 |
|-----|----------|------------|------|
| Paimon Pool (自有) | 0x1234... | 200 (2x) | 最高权重，鼓励自有池子 |
| PancakeSwap PPT/USDT | 0x5678... | 100 (1x) | 标准权重 |

**核心函数**:

| 函数 | 可见性 | 描述 |
|-----|--------|------|
| `getPoints(user)` | view | 获取用户所有池子的总 LP 积分 |
| `getUserPoolBreakdown(user)` | view | 获取各池子积分明细 |
| `addPool(lpToken, multiplier, name)` | admin | 添加 LP 池子 |
| `updatePool(poolId, multiplier, isActive)` | admin | 更新池子配置 |
| `checkpoint(user)` | external | 更新用户所有池子积分 |
| `checkpointAllPools()` | keeper | 更新所有池子全局状态 |
| `checkpointUsers(users[])` | keeper | 批量更新用户状态 |

---

### 3.4 ActivityModule.sol

**职责**: 管理交易积分和活动奖励积分 (链下计算，链上验证)

**工作流程**:
```
1. 链下服务监听 DEX Swap 事件
2. 每周计算用户交易积分
3. 生成 Merkle Tree，发布 Root 到链上
4. 用户使用 Merkle Proof 调用 claim()
```

**存储结构**:
```solidity
// Merkle Root
bytes32 public merkleRoot;

// 用户已 claim 的累计积分
mapping(address => uint256) public claimedPoints;

// 历史记录 (审计用)
bytes32[] public rootHistory;
mapping(bytes32 => uint256) public rootTimestamp;
```

**Merkle Leaf 格式**:
```solidity
bytes32 leaf = keccak256(abi.encodePacked(userAddress, totalEarnedPoints));
```

**核心函数**:

| 函数 | 可见性 | 描述 |
|-----|--------|------|
| `getPoints(user)` | view | 获取用户已 claim 的积分 |
| `verifyClaim(user, amount, proof)` | view | 验证 Merkle Proof |
| `claim(totalEarned, proof)` | external | Claim 积分 |
| `updateMerkleRoot(root)` | keeper | 更新 Merkle Root |

**Claim 逻辑**:
```solidity
function claim(uint256 totalEarned, bytes32[] calldata proof) external {
    // 1. 验证 proof
    require(verifyClaim(msg.sender, totalEarned, proof), "Invalid proof");

    // 2. 计算可 claim 数量 (增量)
    uint256 alreadyClaimed = claimedPoints[msg.sender];
    require(totalEarned > alreadyClaimed, "Nothing to claim");

    // 3. 更新已 claim 数量
    claimedPoints[msg.sender] = totalEarned;

    // 4. 积分自动计入 PointsHub (通过 getPoints)
}
```

---

### 3.5 PenaltyModule.sol

**职责**: 追踪用户赎回行为产生的惩罚积分

**工作流程**:
```
1. 链下服务监听 RedemptionSettled 事件
2. 根据赎回金额和惩罚比例计算惩罚积分
3. 生成 Merkle Tree，发布 Root 到链上
4. PointsHub 调用 getPenalty() 获取惩罚值
```

**惩罚计算公式**:
```
penaltyPoints = redemptionAmount × penaltyRateBps / 10000
```

**存储结构**:
```solidity
// Merkle Root
bytes32 public penaltyRoot;

// 用户已确认的惩罚
mapping(address => uint256) public confirmedPenalty;

// 惩罚比例
uint256 public penaltyRateBps;  // 1000 = 10%
```

**核心函数**:

| 函数 | 可见性 | 描述 |
|-----|--------|------|
| `getPenalty(user)` | view | 获取用户惩罚积分 (PointsHub 调用) |
| `verifyPenalty(user, amount, proof)` | view | 验证惩罚 Merkle Proof |
| `syncPenalty(user, amount, proof)` | external | 同步用户惩罚 |
| `updatePenaltyRoot(root)` | keeper | 更新惩罚 Merkle Root |
| `setPenaltyRate(rateBps)` | admin | 设置惩罚比例 |

---

## 4. 积分计算规则

### 4.1 持有积分 (HoldingModule)

**公式**:
```
积分 = PPT 持有量 × 持有时间(秒) × pointsRatePerSecond
```

**示例** (假设 `pointsRatePerSecond = 1e15`):
```
用户持有 1000 PPT，持续 7 天:
积分 = 1000 × (7 × 24 × 3600) × 1e15 / 1e18
     = 1000 × 604800 × 0.001
     = 604,800 积分
```

### 4.2 LP 积分 (LPModule)

**公式**:
```
积分 = LP 持有量 × 持有时间(秒) × basePointsRatePerSecond × multiplier / 100
```

**示例** (假设 `baseRate = 1e15`, Paimon Pool `multiplier = 200`):
```
用户在 Paimon Pool 持有 100 LP，持续 7 天:
积分 = 100 × 604800 × 1e15 × 200 / 100 / 1e18
     = 100 × 604800 × 0.001 × 2
     = 120,960 积分
```

### 4.3 交易积分 (ActivityModule)

**规则**:
```
1. 只计算 DEX Swap (涉及 PPT 的交易)
2. 买入和卖出分开计算:
   - 买入 PPT: 1.5x 积分系数
   - 卖出 PPT: 1.0x 积分系数

3. 阶梯费率 (防刷):
   - 0 - 1,000 USDT:    1.0x
   - 1,000 - 10,000:    0.8x
   - 10,000+:           0.5x

4. 每日上限: 单地址每日最多获得 X 积分 (待定)

5. 基础公式:
   积分 = 交易量(USDT) × 基础比例 × 买卖系数 × 阶梯系数
```

**示例**:
```
用户买入 5000 USDT 等值的 PPT:
- 前 1000: 1000 × 0.01 × 1.5 × 1.0 = 15
- 后 4000: 4000 × 0.01 × 1.5 × 0.8 = 48
- 总计: 63 积分
```

### 4.4 赎回惩罚 (PenaltyModule)

**公式**:
```
惩罚积分 = 赎回金额(USDT) × penaltyRateBps / 10000
```

**示例** (假设 `penaltyRateBps = 1000` = 10%):
```
用户赎回 10000 USDT:
惩罚积分 = 10000 × 1000 / 10000 = 1000 积分
```

### 4.5 总积分计算

```
总积分 = HoldingModule.getPoints(user)
       + LPModule.getPoints(user)
       + ActivityModule.getPoints(user)

可用积分 = 总积分
         - PenaltyModule.getPenalty(user)
         - redeemedPoints[user]
```

---

## 5. 角色与权限

### 5.1 角色定义

| 角色 | 描述 | 权限范围 |
|-----|------|---------|
| `DEFAULT_ADMIN_ROLE` | 超级管理员 | 管理其他角色 |
| `ADMIN_ROLE` | 管理员 | 配置参数、注册模块 |
| `KEEPER_ROLE` | 运维角色 | 定期 checkpoint、更新 Merkle Root |
| `UPGRADER_ROLE` | 升级角色 | 合约升级 (建议使用 Timelock) |

### 5.2 权限矩阵

| 操作 | DEFAULT_ADMIN | ADMIN | KEEPER | UPGRADER | 普通用户 |
|-----|---------------|-------|--------|----------|---------|
| 管理角色 | ✓ | - | - | - | - |
| 注册/移除模块 | - | ✓ | - | - | - |
| 设置兑换参数 | - | ✓ | - | - | - |
| 设置积分率 | - | ✓ | - | - | - |
| 添加/更新 LP 池 | - | ✓ | - | - | - |
| 设置惩罚比例 | - | ✓ | - | - | - |
| 暂停/恢复模块 | - | ✓ | - | - | - |
| 全局 checkpoint | - | - | ✓ | - | - |
| 批量用户 checkpoint | - | - | ✓ | - | - |
| 更新 Merkle Root | - | - | ✓ | - | - |
| 升级合约 | - | - | - | ✓ | - |
| 查询积分 | ✓ | ✓ | ✓ | ✓ | ✓ |
| 兑换积分 | ✓ | ✓ | ✓ | ✓ | ✓ |
| 自行 checkpoint | ✓ | ✓ | ✓ | ✓ | ✓ |
| Claim 活动积分 | ✓ | ✓ | ✓ | ✓ | ✓ |

### 5.3 推荐的权限配置

```
DEFAULT_ADMIN_ROLE → Gnosis Safe (多签)
ADMIN_ROLE         → Gnosis Safe (多签)
KEEPER_ROLE        → Keeper Bot EOA / Chainlink Automation
UPGRADER_ROLE      → TimelockController (带延迟)
```

---

## 6. 部署流程

### 6.1 部署顺序

```
Step 1: 部署基础设施
├── TimelockController (如果尚未部署)
└── 准备 Gnosis Safe 地址

Step 2: 部署 PointsHub
├── 部署 Implementation
├── 部署 ERC1967Proxy
└── 调用 initialize(admin, upgrader)

Step 3: 部署 HoldingModule
├── 部署 Implementation
├── 部署 ERC1967Proxy
└── 调用 initialize(ppt, admin, keeper, upgrader, pointsRate)

Step 4: 部署 LPModule
├── 部署 Implementation
├── 部署 ERC1967Proxy
└── 调用 initialize(admin, keeper, upgrader, baseRate)

Step 5: 部署 ActivityModule
├── 部署 Implementation
├── 部署 ERC1967Proxy
└── 调用 initialize(admin, keeper, upgrader)

Step 6: 部署 PenaltyModule
├── 部署 Implementation
├── 部署 ERC1967Proxy
└── 调用 initialize(admin, keeper, upgrader, penaltyRate)

Step 7: 配置 PointsHub
├── registerModule(HoldingModule)
├── registerModule(LPModule)
├── registerModule(ActivityModule)
└── setPenaltyModule(PenaltyModule)

Step 8: 配置 LPModule
├── addPool(PaimonPoolLP, 200, "Paimon Pool")
└── addPool(PancakeSwapLP, 100, "PancakeSwap PPT/USDT")

Step 9: 验证配置
├── 检查所有模块注册状态
├── 检查角色配置
└── 测试积分计算
```

### 6.2 部署脚本示例

```solidity
// script/DeployPointsSystem.s.sol
contract DeployPointsSystem is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address gnosisSafe = vm.envAddress("GNOSIS_SAFE");
        address timelock = vm.envAddress("TIMELOCK");
        address keeper = vm.envAddress("KEEPER");
        address ppt = vm.envAddress("PPT_VAULT");

        vm.startBroadcast(deployerKey);

        // 1. Deploy PointsHub
        PointsHub hubImpl = new PointsHub();
        ERC1967Proxy hubProxy = new ERC1967Proxy(
            address(hubImpl),
            abi.encodeCall(PointsHub.initialize, (gnosisSafe, timelock))
        );
        PointsHub hub = PointsHub(address(hubProxy));

        // 2. Deploy HoldingModule
        HoldingModule holdingImpl = new HoldingModule();
        ERC1967Proxy holdingProxy = new ERC1967Proxy(
            address(holdingImpl),
            abi.encodeCall(HoldingModule.initialize, (
                ppt, gnosisSafe, keeper, timelock, 1e15
            ))
        );
        HoldingModule holding = HoldingModule(address(holdingProxy));

        // 3. Deploy LPModule
        LPModule lpImpl = new LPModule();
        ERC1967Proxy lpProxy = new ERC1967Proxy(
            address(lpImpl),
            abi.encodeCall(LPModule.initialize, (
                gnosisSafe, keeper, timelock, 1e15
            ))
        );
        LPModule lp = LPModule(address(lpProxy));

        // 4. Deploy ActivityModule
        ActivityModule activityImpl = new ActivityModule();
        ERC1967Proxy activityProxy = new ERC1967Proxy(
            address(activityImpl),
            abi.encodeCall(ActivityModule.initialize, (
                gnosisSafe, keeper, timelock
            ))
        );
        ActivityModule activity = ActivityModule(address(activityProxy));

        // 5. Deploy PenaltyModule
        PenaltyModule penaltyImpl = new PenaltyModule();
        ERC1967Proxy penaltyProxy = new ERC1967Proxy(
            address(penaltyImpl),
            abi.encodeCall(PenaltyModule.initialize, (
                gnosisSafe, keeper, timelock, 1000 // 10%
            ))
        );
        PenaltyModule penalty = PenaltyModule(address(penaltyProxy));

        // 6. Configure PointsHub
        hub.registerModule(address(holding));
        hub.registerModule(address(lp));
        hub.registerModule(address(activity));
        hub.setPenaltyModule(address(penalty));

        vm.stopBroadcast();

        // Log addresses
        console.log("PointsHub:", address(hub));
        console.log("HoldingModule:", address(holding));
        console.log("LPModule:", address(lp));
        console.log("ActivityModule:", address(activity));
        console.log("PenaltyModule:", address(penalty));
    }
}
```

---

## 7. 运维操作

### 7.1 每周例行操作

```
每周一 00:00 UTC (建议):

1. HoldingModule 全局 checkpoint
   → keeper 调用 checkpointGlobal()

2. HoldingModule 批量用户 checkpoint
   → keeper 调用 checkpointUsers(activeUsers[])

3. LPModule 全局 checkpoint
   → keeper 调用 checkpointAllPools()

4. LPModule 批量用户 checkpoint
   → keeper 调用 checkpointUsers(lpUsers[])

5. ActivityModule 更新 Merkle Root
   → 链下服务计算上周交易积分
   → 生成 Merkle Tree
   → keeper 调用 updateMerkleRoot(newRoot)

6. PenaltyModule 更新 Merkle Root
   → 链下服务计算上周赎回惩罚
   → 生成 Merkle Tree
   → keeper 调用 updatePenaltyRoot(newRoot)
```

### 7.2 活跃用户列表获取

```javascript
// 链下服务逻辑
async function getActiveUsers() {
    // 方式 1: 监听 PPT Transfer 事件，收集持有人
    const transfers = await ppt.queryFilter('Transfer', fromBlock, toBlock);
    const holders = new Set();
    transfers.forEach(e => {
        holders.add(e.args.to);
        // 排除零地址和合约地址
    });

    // 方式 2: 使用 The Graph 或自建索引
    const holders = await graphClient.query(GET_PPT_HOLDERS);

    return Array.from(holders);
}
```

### 7.3 Merkle Tree 生成

```javascript
// 链下服务逻辑
const { StandardMerkleTree } = require("@openzeppelin/merkle-tree");

// 交易积分 Merkle Tree
function generateActivityMerkleTree(userPoints) {
    // userPoints = [{ address: "0x...", points: 1000 }, ...]

    const leaves = userPoints.map(u => [u.address, u.points.toString()]);
    const tree = StandardMerkleTree.of(leaves, ["address", "uint256"]);

    return {
        root: tree.root,
        tree: tree,
        getProof: (address, points) => tree.getProof([address, points.toString()])
    };
}

// 惩罚 Merkle Tree (类似)
function generatePenaltyMerkleTree(userPenalties) {
    const leaves = userPenalties.map(u => [u.address, u.penalty.toString()]);
    const tree = StandardMerkleTree.of(leaves, ["address", "uint256"]);

    return {
        root: tree.root,
        tree: tree
    };
}
```

### 7.4 监控告警

| 监控项 | 阈值 | 告警 |
|-------|------|------|
| checkpoint 间隔 | > 8 天 | High |
| Merkle Root 更新间隔 | > 8 天 | High |
| 单用户积分异常增长 | > 100x 周均 | Medium |
| 合约暂停状态 | paused = true | High |

---

## 8. 链下服务

### 8.1 服务架构

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           链下服务架构                                       │
└─────────────────────────────────────────────────────────────────────────────┘

┌──────────────┐     ┌──────────────┐     ┌──────────────┐
│  Event       │     │  Points      │     │  Keeper      │
│  Indexer     │────▶│  Calculator  │────▶│  Bot         │
└──────────────┘     └──────────────┘     └──────────────┘
       │                    │                    │
       ▼                    ▼                    ▼
┌──────────────┐     ┌──────────────┐     ┌──────────────┐
│  Database    │     │  Merkle      │     │  Blockchain  │
│  (Events)    │     │  Storage     │     │  (Txs)       │
└──────────────┘     └──────────────┘     └──────────────┘
```

### 8.2 Event Indexer

**需要索引的事件**:

| 合约 | 事件 | 用途 |
|-----|------|------|
| PPT | `Transfer(from, to, value)` | 追踪持有人 |
| PPT | `Deposit(sender, owner, assets, shares)` | 追踪存款 |
| RedemptionManager | `RedemptionSettled(...)` | 计算惩罚 |
| DEX (Uniswap V2) | `Swap(...)` | 计算交易积分 |
| LP Token | `Transfer(from, to, value)` | 追踪 LP 持有人 |

### 8.3 Points Calculator

```python
# 伪代码
class PointsCalculator:
    def calculate_trading_points(self, user, week_start, week_end):
        swaps = self.db.get_swaps(user, week_start, week_end)

        total_points = 0
        daily_points = {}

        for swap in swaps:
            day = swap.timestamp.date()

            # 计算基础积分
            volume = swap.amount_usd
            base_points = volume * BASE_RATE

            # 应用买卖系数
            if swap.is_buy:
                base_points *= 1.5

            # 应用阶梯系数
            tier_multiplier = self.get_tier_multiplier(volume)
            points = base_points * tier_multiplier

            # 检查每日上限
            if daily_points.get(day, 0) + points > DAILY_CAP:
                points = max(0, DAILY_CAP - daily_points.get(day, 0))

            daily_points[day] = daily_points.get(day, 0) + points
            total_points += points

        return total_points

    def calculate_redemption_penalty(self, user, week_start, week_end):
        redemptions = self.db.get_redemptions(user, week_start, week_end)

        total_penalty = 0
        for r in redemptions:
            penalty = r.gross_amount * PENALTY_RATE / 10000
            total_penalty += penalty

        return total_penalty
```

### 8.4 Keeper Bot

```javascript
// 使用 ethers.js
class KeeperBot {
    async weeklyRoutine() {
        console.log("Starting weekly checkpoint routine...");

        // 1. Checkpoint HoldingModule
        await this.checkpointHolding();

        // 2. Checkpoint LPModule
        await this.checkpointLP();

        // 3. Update Activity Merkle Root
        await this.updateActivityRoot();

        // 4. Update Penalty Merkle Root
        await this.updatePenaltyRoot();

        console.log("Weekly routine completed.");
    }

    async checkpointHolding() {
        const users = await this.getActiveHolders();
        const batchSize = 100;

        // Global checkpoint first
        await this.holdingModule.checkpointGlobal();

        // Batch user checkpoints
        for (let i = 0; i < users.length; i += batchSize) {
            const batch = users.slice(i, i + batchSize);
            await this.holdingModule.checkpointUsers(batch);
        }
    }

    async updateActivityRoot() {
        // 从计算服务获取最新积分数据
        const pointsData = await this.calculator.getWeeklyTradingPoints();

        // 生成 Merkle Tree
        const { root, tree } = generateActivityMerkleTree(pointsData);

        // 存储 tree 到数据库 (用户 claim 时需要)
        await this.storage.saveMerkleTree('activity', tree);

        // 更新链上 Root
        await this.activityModule.updateMerkleRoot(root);
    }
}
```

---

## 9. 安全考虑

### 9.1 智能合约安全

| 风险 | 缓解措施 |
|-----|---------|
| **重入攻击** | 所有状态更新在外部调用前完成；使用 ReentrancyGuard |
| **整数溢出** | Solidity 0.8+ 内置检查；长期运行使用 uint256 |
| **权限提升** | 使用 OpenZeppelin AccessControl；多签管理 |
| **代理升级风险** | UUPS 模式；升级通过 Timelock；初始化保护 |
| **闪电贷攻击** | checkpoint 使用历史余额而非实时余额 |

### 9.2 链下服务安全

| 风险 | 缓解措施 |
|-----|---------|
| **Keeper 密钥泄露** | 使用独立 EOA，最小权限，定期轮换 |
| **Merkle Root 伪造** | 多方验证；公开计算逻辑；审计日志 |
| **服务中断** | 多节点部署；告警监控；手动备用流程 |
| **数据不一致** | 区块确认数要求；重放机制 |

### 9.3 经济安全

| 风险 | 缓解措施 |
|-----|---------|
| **积分通胀** | 控制积分率；设置总量上限 (可选) |
| **刷量攻击** | 交易积分阶梯递减；每日上限；洗盘检测 |
| **Sybil 攻击** | 最小金额门槛；链下异常检测 |

### 9.4 审计清单

- [ ] 所有合约通过 Slither 静态分析
- [ ] 所有合约通过 Mythril 符号执行
- [ ] 权限配置正确性验证
- [ ] 升级流程测试
- [ ] 边界条件测试 (零值、极大值)
- [ ] Gas 消耗测试 (大批量 checkpoint)
- [ ] 第三方审计 (建议)

---

## 10. 待定参数

以下参数需要在部署前确定:

### 10.1 积分率参数

| 参数 | 建议范围 | 说明 |
|-----|---------|------|
| `HoldingModule.pointsRatePerSecond` | 1e14 - 1e16 | 每秒每 PPT 积分 |
| `LPModule.basePointsRatePerSecond` | 1e14 - 1e16 | LP 基础积分率 |
| `LPModule.PaimonPool.multiplier` | 150 - 300 | 自有池倍率 |
| `LPModule.PCSPool.multiplier` | 100 | PCS 池倍率 |

### 10.2 交易积分参数

| 参数 | 建议值 | 说明 |
|-----|-------|------|
| 基础比例 | 0.01 (1%) | 交易量 → 积分转换 |
| 买入系数 | 1.5x | 买入 PPT 额外奖励 |
| 卖出系数 | 1.0x | 卖出 PPT 标准 |
| 阶梯 1 上限 | 1,000 USDT | 全额积分 |
| 阶梯 2 上限 | 10,000 USDT | 0.8x 积分 |
| 阶梯 3 | 10,000+ | 0.5x 积分 |
| 每日上限 | 待定 | 单地址每日最大积分 |

### 10.3 惩罚参数

| 参数 | 建议范围 | 说明 |
|-----|---------|------|
| `PenaltyModule.penaltyRateBps` | 500 - 2000 | 赎回惩罚比例 (5%-20%) |

### 10.4 积分过期

| 参数 | 选项 | 说明 |
|-----|------|------|
| 是否过期 | 是 / 否 | 积分是否有有效期 |
| 过期周期 | 6个月 / 1年 / 永不 | 如果过期，周期多长 |

### 10.5 兑换参数

| 参数 | 状态 | 说明 |
|-----|------|------|
| `rewardToken` | 待定 | 兑换目标代币 |
| `exchangeRate` | 待定 | 积分:代币 比例 |
| 兑换上限 | 待定 | 单次/每日/总量限制 |

---

## 11. FAQ

### Q1: 用户需要做什么才能获得积分？

**A**:
- **持有积分**: 自动获得，无需操作
- **LP 积分**: 在指定池子添加流动性，自动获得
- **交易积分**: DEX 交易后，每周可 claim
- 用户可随时调用 `checkpoint()` 更新积分快照

### Q2: 积分多久更新一次？

**A**:
- Keeper 每周执行全局 checkpoint
- 用户可随时自行调用 checkpoint 获取最新积分
- 交易积分和惩罚通过 Merkle Proof 每周更新

### Q3: 如果 Keeper 不执行 checkpoint 会怎样？

**A**:
- 用户可自行调用 checkpoint 更新自己的积分
- 积分计算使用实时数据，不会丢失，只是需要用户主动触发
- 监控系统会发出告警

### Q4: 赎回 PPT 会损失多少积分？

**A**:
- 根据 `penaltyRateBps` 参数计算
- 例如 10% 惩罚率：赎回 10,000 USDT，扣减 1,000 积分
- 惩罚在下周 Merkle Root 更新后生效

### Q5: 积分可以转让吗？

**A**:
- 当前设计：积分不可转让（纯数值记录）
- 兑换后的代币可以转让
- 如需积分可转让，需要改为 ERC20 实现

### Q6: 如何验证我的积分计算正确？

**A**:
- 链上：调用 `PointsHub.getPointsBreakdown(user)` 查看明细
- 链下：公开积分计算逻辑，用户可自行验证
- Merkle Tree 数据公开，可验证 proof

---

## 附录

### A. 合约地址 (部署后更新)

| 合约 | 地址 | 网络 |
|-----|------|------|
| PointsHub | TBD | BSC |
| HoldingModule | TBD | BSC |
| LPModule | TBD | BSC |
| ActivityModule | TBD | BSC |
| PenaltyModule | TBD | BSC |

### B. 相关链接

- PPT Vault 合约: [地址]
- Paimon LP Pool: [地址]
- PancakeSwap Pool: [地址]
- 积分查询前端: [URL]
- API 文档: [URL]

### C. 变更日志

| 版本 | 日期 | 变更内容 |
|-----|------|---------|
| 1.0.0 | 2026-01-12 | 初始设计文档 |
