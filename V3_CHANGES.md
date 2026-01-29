# StakingModule v3.0 变更说明

## 🎯 核心变更：移除 pointsRatePerSecond

### 新的积分公式

```solidity
// v2.x (旧)
积分 = amount × boost × pointsRatePerSecond × duration / BOOST_BASE

// v3.0 (新)
积分 = amount × boost × duration / BOOST_BASE
```

### 具体变化

1. **删除的变量**
   - `uint256 public pointsRatePerSecond`
   - `MIN_POINTS_RATE`
   - `MAX_POINTS_RATE`

2. **修改的函数**
   - `initialize()` - 移除 `_pointsRatePerSecond` 参数
   - `_calculateStakePointsSinceLastAccrual()` - 简化公式
   - `estimatePoints()` - 简化公式

3. **删除的函数**
   - `setPointsRate()`

4. **删除的事件和错误**
   - `event PointsRateUpdated`
   - `error InvalidPointsRate`

### 新的积分计算示例

```javascript
// 100,000 PPT 灵活质押 1天
积分 = 100,000 × 10,000 × 86,400 / 10,000
    = 100,000 × 86,400
    = 8,640,000,000 (86.4亿)

// 100,000 PPT 365天锁定 1天  
积分 = 100,000 × 20,000 × 86,400 / 10,000
    = 100,000 × 2 × 86,400
    = 17,280,000,000 (172.8亿)
```

### 测试文件需要修改的地方

所有涉及 `POINTS_RATE_PER_SECOND` 的测试都需要调整积分预期值：

```solidity
// 旧的预期计算
expected = (amount * boost * POINTS_RATE_PER_SECOND * duration) / BOOST_BASE

// 新的预期计算  
expected = (amount * boost * duration) / BOOST_BASE
```

由于移除了 `pointsRatePerSecond = 1e15`，所有积分值将增加 1000倍！

## ⚠️ 重要提醒

1. **积分通胀**：移除 pointsRatePerSecond 后，积分产出将大幅增加
2. **不可调整**：上线后积分产出永远固定，无法修改
3. **需要升级才能改变**：如果需要调整积分产出，必须升级合约

## 📝 建议

在部署前，请确认：
- [ ] 积分产出量符合预期
- [ ] 理解不可调整的后果
- [ ] 准备好升级机制（如果需要调整）
