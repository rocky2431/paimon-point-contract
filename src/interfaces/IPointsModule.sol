// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IPointsModule
/// @notice 可以注册到 PointsHub 的积分模块接口
/// @dev 所有积分模块都必须实现此接口
interface IPointsModule {
    /// @notice 获取用户在此模块中获得的积分
    /// @param user 用户地址
    /// @return 用户获得的总积分
    function getPoints(address user) external view returns (uint256);

    /// @notice 获取此模块的名称
    /// @return 模块名称字符串
    function moduleName() external view returns (string memory);

    /// @notice 检查此模块当前是否处于活跃状态
    /// @return 如果模块处于活跃状态返回 true，否则返回 false
    function isActive() external view returns (bool);
}

/// @title IPenaltyModule
/// @notice 追踪兑换惩罚的惩罚模块接口
interface IPenaltyModule {
    /// @notice 获取用户的惩罚积分
    /// @param user 用户地址
    /// @return 用户的总惩罚积分
    function getPenalty(address user) external view returns (uint256);
}

/// @title IPointsHub
/// @notice 中央积分聚合中心接口
interface IPointsHub {
    /// @notice 获取用户在所有模块中的总积分
    /// @param user 用户地址
    /// @return 所有活跃模块的总积分
    function getTotalPoints(address user) external view returns (uint256);

    /// @notice 获取用户的惩罚积分
    /// @param user 用户地址
    /// @return 惩罚积分
    function getPenaltyPoints(address user) external view returns (uint256);

    /// @notice 获取扣除惩罚和已兑换数量后的可领取积分
    /// @param user 用户地址
    /// @return 可领取积分
    function getClaimablePoints(address user) external view returns (uint256);

    /// @notice 兑换积分为奖励代币
    /// @param pointsAmount 要兑换的积分数量
    function redeem(uint256 pointsAmount) external;
}

/// @title IPPT
/// @notice PPT Vault 接口（积分系统所需的最小接口）
interface IPPT {
    function balanceOf(address account) external view returns (uint256);
    function effectiveSupply() external view returns (uint256);
    function totalSupply() external view returns (uint256);
}
