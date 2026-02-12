# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Test Commands

```bash
forge build                              # Compile contracts
forge test                               # Run all tests
forge test -vvv                          # Verbose output
forge test --match-path test/StakingModule.t.sol  # Specific test file
forge test --match-test testStake        # Specific test function
forge test --gas-report                  # Gas report
forge test --profile ci                  # CI profile (1000 fuzz runs)
forge coverage                           # Test coverage report
forge fmt                                # Format code
forge fmt --check                        # Check formatting
```

### Deployment

```bash
# Deploy StakingModule (requires env vars: PPT_ADDRESS, ADMIN_ADDRESS, KEEPER_ADDRESS, UPGRADER_ADDRESS)
forge script script/DeployStakingModule.s.sol:DeployStakingModule \
  --rpc-url $RPC_URL --broadcast --verify -vvvv

# Testnet deployment
forge script script/DeployStakingModule.s.sol:DeployStakingModuleTestnet \
  --rpc-url $BSC_TESTNET_RPC --broadcast -vvvv
```

## Architecture Overview

Modular on-chain points system v2.3.0 with Hub-Module pattern (Credit Card Mode):

```
PointsHub (中央聚合器)
    │
    ├── IPointsModule 接口
    │   ├── StakingModule   (PPT 质押 - 灵活/锁定 + Boost 倍数)
    │   ├── LPModule        (LP 多池质押)
    │   └── ActivityModule  (Merkle proof 链下活动)
    │
    └── IPenaltyModule 接口
        └── PenaltyModule   (Merkle proof 惩罚扣除)
```

**Formula**: `claimablePoints = Σ modules.getPoints(user) - penalty - redeemedPoints`

### Credit Card Points Mode (v2.0)

与 Synthetix 风格的"瓜分池子"模式不同，信用卡模式保证后入者与早入者在同等条件下获得同等积分：
- **无全局状态**：每个用户的积分独立计算，不受他人影响
- **固定积分率**：`points = amount × rate × duration`
- **无稀释效应**：后入者不会被早期参与者稀释

### Module Algorithms

| Module | Source | Algorithm |
|--------|--------|-----------|
| StakingModule | Staked PPT | `points = amount × boost × pointsRatePerSecond × duration / (BOOST_BASE × RATE_PRECISION)` |
| LPModule | LP balances | `points = balance × (baseRate × multiplier / MULTIPLIER_BASE) × duration` |
| ActivityModule | Merkle tree | `leaf = keccak256(keccak256(abi.encode(user, amount)))` |
| PenaltyModule | Merkle tree | Same Merkle format, penalty only increases |

### Points Precision & Display (v2.3.0)

链上积分值继承 ERC20 的 18 位精度，raw 值非常大。系统采用 ERC20 decimals 模式：

```
链上: getPoints(user) → 8,640,000,000,000,000,000,000,000 (8.64e24)
前端: rawPoints / 10^POINTS_DECIMALS → 86.4

POINTS_DECIMALS = 23  ← PointsHub 链上常量
```

**前端集成:**
```javascript
const decimals = await pointsHub.POINTS_DECIMALS(); // 23
const raw = await pointsHub.getTotalPoints(user);
const display = formatUnits(raw, decimals); // "86.4"
```

### RATE_PRECISION 机制 (v2.3.0)

`pointsRatePerSecond` 使用 `RATE_PRECISION = 1e18` 作为精度基准，支持小数倍率：

```
rate = 1e18  → 1.0x（标准）    rate = 9e17  → 0.9x
rate = 5e17  → 0.5x           rate = 2e18  → 2.0x
```

公式: `points = amount × boost × rate × duration / (BOOST_BASE × RATE_PRECISION)`
当 rate = 1e18 时，RATE_PRECISION 抵消，退化为: `amount × boost × duration / BOOST_BASE`

**计算示例** (rate = 1e18):
- 1 PPT × 灵活 × 1 秒 = `1e18` raw → display `0.00001`
- 100 PPT × 灵活 × 1 天 = `8.64e24` raw → display `86.4`
- 1000 PPT × 2.0x × 365 天 = `6.31e28` raw → display `6,307,200`

### Checkpoint Mechanism

StakingModule, LPModule 使用检查点系统防止闪电贷攻击：
- **Keeper**: `checkpointUsers(address[])` 批量检查点用户
- **User**: `checkpoint(user)` 或 `checkpointSelf()` 随时调用
- **Flash loan protection**: 需持有 `minHoldingBlocks` 个区块后积分才生效

### Role System

| Role | Purpose |
|------|---------|
| ADMIN_ROLE | 配置、模块注册、暂停/恢复 |
| KEEPER_ROLE | Checkpoint、Merkle root 更新 |
| UPGRADER_ROLE | UUPS 升级 (建议配合 Timelock) |

### Critical Constants

| Contract | Constant | Value | Impact |
|----------|----------|-------|--------|
| PointsHub | `POINTS_DECIMALS` | 23 | 前端显示精度 (÷ 10^23) |
| PointsHub | `MAX_MODULES` | 10 | 最大可注册模块数 |
| StakingModule | `RATE_PRECISION` | 1e18 | pointsRatePerSecond 精度基准 |
| StakingModule | `BOOST_BASE` | 10000 | Boost 基数 (1x=10000, 2x=20000) |
| StakingModule | `MIN_STAKE_AMOUNT` | 10e18 | 最小质押量 (10 PPT) |
| StakingModule | `EARLY_UNLOCK_PENALTY_BPS` | 5000 (50%) | 提前解锁罚金比例 |
| StakingModule | `MIN_LOCK_DURATION` | 7 days | 最短锁定期 |
| StakingModule | `MAX_LOCK_DURATION` | 365 days | 最长锁定期 |
| StakingModule | `MAX_STAKES_PER_USER` | 100 | 每用户最大质押数 |
| StakingModule | `MIN_POINTS_RATE` / `MAX_POINTS_RATE` | 1 / 1e24 | 积分率范围 |
| Activity/Penalty | `ROOT_DELAY` | 24 hours | Merkle root 生效延迟 |
| LPModule | `MAX_POOLS` | 20 | 最大 LP 池数 |

## Key Patterns

### UUPS Upgradeable
All contracts: `_disableInitializers()` in constructor + `__gap[50]` storage gap.
Deploy: Implementation → ERC1967Proxy → `initialize()`

### Merkle Root Timelock
ActivityModule/PenaltyModule 的 root 更新有 24 小时延迟:
```
updateMerkleRoot() → pendingRoot → (24h) → activateRoot() → merkleRoot
```
Admin 可通过 `emergencyActivateRoot()` 跳过延迟。

### StakingModule v2.3

**质押类型**:
| Type | Boost | Description |
|------|-------|-------------|
| Flexible | 1.0x | 随时取出，无锁定 |
| Locked | 1.02x~2.0x | 锁定期内 boost 加成，到期后自动降为 1.0x |

**Boost 计算表**:
| Lock Duration | Boost | Formula |
|--------------|-------|---------|
| Flexible | 1.0x | `BOOST_BASE (10000)` |
| 7 days (min) | 1.02x | `10000 + (7 × 10000 / 365)` |
| 90 days | 1.25x | `10000 + (90 × 10000 / 365)` |
| 365 days (max) | 2.0x | `10000 + (365 × 10000 / 365)` |

**锁定到期行为**: 锁定到期后 boost 自动降为 1.0x，用户无需手动操作
**提前解锁惩罚**: `earnedPoints × (remainingTime / lockDuration) × 50%`

## Test Infrastructure

- **BaseTest** (`test/Base.t.sol`): 部署所有模块和 mocks，提供 helper functions
- **Mocks**: `MockPPT`, `MockERC20` (位于 `test/mocks/`)

### Test Helpers (from BaseTest)

| Helper | Usage |
|--------|-------|
| `_generateMerkleProof(user, amount, allUsers, allAmounts)` | 生成 Merkle proof (支持 1-4 用户) |
| `_advanceTime(seconds_)` | `vm.warp(block.timestamp + seconds_)` |
| `_advanceBlocks(blocks_)` | `vm.roll(block.number + blocks_)` |
| `_setActivityMerkleRoot(root, label)` | 设置 ActivityModule root (含 24h 等待) |
| `_setPenaltyMerkleRoot(root)` | 设置 PenaltyModule root (含 24h 等待) |

### Default Test Constants

**Base.t.sol** (集成/安全测试使用):
```solidity
PRECISION = 1e18
POINTS_RATE_PER_SECOND = 1e18  // 1.0x rate (RATE_PRECISION base)
STAKING_RATE = 1e18            // 1.0x rate (RATE_PRECISION base)
LP_BASE_RATE = 1               // 每 LP 每秒 1 积分
EXCHANGE_RATE = 1e18           // 1:1 兑换
PENALTY_RATE_BPS = 1000        // 10% 惩罚率
```

**StakingModule.t.sol** (独立质押测试):
```solidity
POINTS_RATE_PER_SECOND = 1e15  // 0.001x rate (用于测试精度场景)
```

注意：两个测试文件使用不同的 rate 值，测试公式中需要对应 `/ (BOOST_BASE * PRECISION)`。

## Dependencies

Git submodules (`git submodule update --init --recursive`):
- OpenZeppelin Contracts v5.0.2
- OpenZeppelin Contracts Upgradeable v5.0.2
- Forge Std

## Environment Variables

Deployment scripts require:

| Variable | Description |
|----------|-------------|
| `PPT_ADDRESS` | PPT token 合约地址 |
| `ADMIN_ADDRESS` | Admin 多签地址 |
| `KEEPER_ADDRESS` | Keeper 地址 (运维账户) |
| `UPGRADER_ADDRESS` | Upgrader 地址 (建议 Timelock) |
| `POINTS_HUB_ADDRESS` | (Optional) PointsHub 地址 |
| `POINTS_RATE_PER_SECOND` | (Optional) 积分率，默认 1e15 |

## Configuration

foundry.toml: Solidity 0.8.24, optimizer 200 runs, fuzz 256/1000 runs (default/ci)
