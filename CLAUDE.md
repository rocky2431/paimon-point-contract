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
forge fmt                                # Format code
forge fmt --check                        # Check formatting
```

## Architecture Overview

Modular on-chain points system v1.3.0 with Hub-Module pattern:

```
PointsHub (中央聚合器)
    │
    ├── IPointsModule 接口
    │   ├── HoldingModule   (PPT 持有积分, Synthetix-style)
    │   ├── StakingModule   (PPT 锁定质押 + Boost 倍数)
    │   ├── LPModule        (LP 多池质押)
    │   └── ActivityModule  (Merkle proof 链下活动)
    │
    └── IPenaltyModule 接口
        └── PenaltyModule   (Merkle proof 惩罚扣除)
```

**Formula**: `claimablePoints = Σ modules.getPoints(user) - penalty - redeemedPoints`

### Module Algorithms

| Module | Source | Algorithm |
|--------|--------|-----------|
| HoldingModule | PPT balanceOf | `points = balance × (pointsPerShare - paid)` |
| StakingModule | Locked PPT | `boostedAmount = amount × boost` (7d=1.02x, 365d=2.0x) |
| LPModule | LP balances | `points × multiplier / 100` per pool |
| ActivityModule | Merkle tree | `leaf = keccak256(keccak256(abi.encode(user, amount)))` |
| PenaltyModule | Merkle tree | Same Merkle format, penalty only increases |

### Checkpoint Mechanism

HoldingModule, StakingModule, LPModule 使用检查点系统防止闪电贷攻击：
- **Keeper**: `checkpointGlobal()` + `checkpointUsers(address[])` 定期调用
- **User**: `checkpoint(user)` 或 `checkpointSelf()` 随时调用
- **Flash loan protection**: 需持有 `minHoldingBlocks` 个区块后积分才生效

### Role System

| Role | Purpose |
|------|---------|
| ADMIN_ROLE | 配置、模块注册、暂停/恢复 |
| KEEPER_ROLE | Checkpoint、Merkle root 更新 |
| UPGRADER_ROLE | UUPS 升级 (建议配合 Timelock) |

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

### StakingModule Boost Table

| Lock Duration | Boost | Formula |
|--------------|-------|---------|
| 7 days (min) | 1.02x | `10000 + (7 × 10000 / 365)` |
| 90 days | 1.25x | `10000 + (90 × 10000 / 365)` |
| 365 days (max) | 2.0x | `10000 + (365 × 10000 / 365)` |

Early unlock penalty: `earnedSinceStake × (remainingTime / lockDuration) × 50%`

## Test Infrastructure

- **BaseTest** (`test/Base.t.sol`): 部署所有模块和 mocks，提供 helper functions
- **Mocks**: `MockPPT`, `MockERC20`, `MockStakingPPT`
- **Helpers**: `_generateMerkleProof()`, `_advanceTime()`, `_advanceBlocks()`, `_setActivityMerkleRoot()`

## Dependencies

Git submodules (`git submodule update --init --recursive`):
- OpenZeppelin Contracts v5.0.2
- OpenZeppelin Contracts Upgradeable v5.0.2
- Forge Std

## Configuration

foundry.toml: Solidity 0.8.24, optimizer 200 runs, fuzz 256/1000 runs (default/ci)
