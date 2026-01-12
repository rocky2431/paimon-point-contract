// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IPointsModule
/// @notice Interface for points modules that can be registered with PointsHub
/// @dev All points modules must implement this interface
interface IPointsModule {
    /// @notice Get the points earned by a user in this module
    /// @param user The address of the user
    /// @return The total points earned by the user
    function getPoints(address user) external view returns (uint256);

    /// @notice Get the name of this module
    /// @return The module name as a string
    function moduleName() external view returns (string memory);

    /// @notice Check if this module is currently active
    /// @return True if the module is active, false otherwise
    function isActive() external view returns (bool);
}

/// @title IPenaltyModule
/// @notice Interface for penalty module that tracks redemption penalties
interface IPenaltyModule {
    /// @notice Get the penalty points for a user
    /// @param user The address of the user
    /// @return The total penalty points for the user
    function getPenalty(address user) external view returns (uint256);
}

/// @title IPointsHub
/// @notice Interface for the central points aggregation hub
interface IPointsHub {
    /// @notice Get total points across all modules for a user
    /// @param user The address of the user
    /// @return Total points from all active modules
    function getTotalPoints(address user) external view returns (uint256);

    /// @notice Get penalty points for a user
    /// @param user The address of the user
    /// @return Penalty points
    function getPenaltyPoints(address user) external view returns (uint256);

    /// @notice Get claimable points after deducting penalties and redeemed amounts
    /// @param user The address of the user
    /// @return Claimable points
    function getClaimablePoints(address user) external view returns (uint256);

    /// @notice Redeem points for reward tokens
    /// @param pointsAmount Amount of points to redeem
    function redeem(uint256 pointsAmount) external;
}

/// @title IPPT
/// @notice Interface for PPT Vault (minimal interface needed by points system)
interface IPPT {
    function balanceOf(address account) external view returns (uint256);
    function effectiveSupply() external view returns (uint256);
    function totalSupply() external view returns (uint256);
}
