// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {IPointsModule, IPPT} from "./interfaces/IPointsModule.sol";

/// @title HoldingModule
/// @author Paimon Protocol
/// @notice Points module for PPT holding rewards
/// @dev Uses Synthetix-style rewards algorithm with checkpoint mechanism
///      Points accumulate based on PPT balance over time
contract HoldingModule is
    IPointsModule,
    Initializable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    // =============================================================================
    // Constants & Roles
    // =============================================================================

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    uint256 public constant PRECISION = 1e18;
    string public constant MODULE_NAME = "PPT Holding";
    string public constant VERSION = "1.3.0";

    /// @notice Maximum batch size for user checkpoints
    uint256 public constant MAX_BATCH_USERS = 100;

    // =============================================================================
    // State Variables
    // =============================================================================

    /// @notice PPT Vault contract
    IPPT public ppt;

    /// @notice Points generated per second per PPT share (1e18 precision)
    uint256 public pointsRatePerSecond;

    /// @notice Last time the global state was updated
    uint256 public lastUpdateTime;

    /// @notice Accumulated points per share (1e18 precision)
    uint256 public pointsPerShareStored;

    /// @notice User's last recorded points per share
    mapping(address => uint256) public userPointsPerSharePaid;

    /// @notice User's accumulated earned points
    mapping(address => uint256) public userPointsEarned;

    /// @notice User's last recorded balance (at checkpoint time)
    mapping(address => uint256) public userLastBalance;

    /// @notice User's last checkpoint timestamp
    mapping(address => uint256) public userLastCheckpoint;

    /// @notice User's last checkpoint block number (for flash loan protection)
    mapping(address => uint256) public userLastCheckpointBlock;

    /// @notice Whether the module is active
    bool public active;

    /// @notice Minimum balance required to earn points
    uint256 public minBalanceThreshold;

    /// @notice Whether to use effectiveSupply (true) or totalSupply (false)
    /// @dev Set based on whether PPT supports effectiveSupply()
    bool public useEffectiveSupply;

    /// @notice Whether effectiveSupply mode has been determined
    bool public supplyModeInitialized;

    /// @notice Minimum blocks a balance must be held before counting for points (flash loan protection)
    uint256 public minHoldingBlocks;

    // =============================================================================
    // Events
    // =============================================================================

    event GlobalCheckpointed(uint256 pointsPerShare, uint256 timestamp, uint256 effectiveSupply);
    event UserCheckpointed(
        address indexed user,
        uint256 pointsEarned,
        uint256 balance,
        uint256 timestamp
    );
    event PointsRateUpdated(uint256 oldRate, uint256 newRate);
    event MinBalanceThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);
    event ModuleActiveStatusUpdated(bool active);
    event HoldingModuleUpgraded(address indexed newImplementation, uint256 timestamp);
    event SupplyModeInitialized(bool useEffectiveSupply);
    event PptUpdated(address indexed oldPpt, address indexed newPpt);

    // =============================================================================
    // Errors
    // =============================================================================

    error ZeroAddress();
    error ZeroRate();
    error BatchTooLarge(uint256 size, uint256 max);

    // =============================================================================
    // Additional Events
    // =============================================================================

    event MinHoldingBlocksUpdated(uint256 oldBlocks, uint256 newBlocks);

    // =============================================================================
    // Constructor & Initializer
    // =============================================================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the contract
    /// @param _ppt PPT Vault address
    /// @param admin Admin address
    /// @param keeper Keeper address (for checkpoints)
    /// @param upgrader Upgrader address (typically timelock)
    /// @param _pointsRatePerSecond Initial points rate per second per PPT
    function initialize(
        address _ppt,
        address admin,
        address keeper,
        address upgrader,
        uint256 _pointsRatePerSecond
    ) external initializer {
        if (_ppt == address(0) || admin == address(0) || keeper == address(0) || upgrader == address(0)) {
            revert ZeroAddress();
        }

        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        ppt = IPPT(_ppt);
        pointsRatePerSecond = _pointsRatePerSecond;
        lastUpdateTime = block.timestamp;
        active = true;
        minHoldingBlocks = 1; // Default: 1 block for flash loan protection

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);
        _grantRole(KEEPER_ROLE, keeper);
        _grantRole(UPGRADER_ROLE, upgrader);
    }

    // =============================================================================
    // UUPS Upgrade
    // =============================================================================

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {
        emit HoldingModuleUpgraded(newImplementation, block.timestamp);
    }

    // =============================================================================
    // Core Logic - Internal
    // =============================================================================

    /// @notice Calculate current points per share
    /// @return Current accumulated points per share
    function _currentPointsPerShare() internal view returns (uint256) {
        if (!active) return pointsPerShareStored;

        uint256 supply = _getEffectiveSupply();
        if (supply == 0) return pointsPerShareStored;

        uint256 timeDelta = block.timestamp - lastUpdateTime;
        uint256 newPoints = timeDelta * pointsRatePerSecond;

        return pointsPerShareStored + (newPoints * PRECISION) / supply;
    }

    /// @notice Get effective supply for calculations
    /// @dev Uses effectiveSupply if PPT supports it, otherwise totalSupply
    function _getEffectiveSupply() internal view returns (uint256) {
        if (supplyModeInitialized) {
            return useEffectiveSupply ? ppt.effectiveSupply() : ppt.totalSupply();
        }
        // Fallback for view calls before initialization
        try ppt.effectiveSupply() returns (uint256 supply) {
            return supply;
        } catch {
            return ppt.totalSupply();
        }
    }

    /// @notice Initialize supply mode by detecting PPT capabilities
    /// @dev Called once during first global update
    function _initSupplyMode() internal {
        if (supplyModeInitialized) return;

        try ppt.effectiveSupply() returns (uint256) {
            useEffectiveSupply = true;
        } catch {
            useEffectiveSupply = false;
        }
        supplyModeInitialized = true;
        emit SupplyModeInitialized(useEffectiveSupply);
    }

    /// @notice Update global state
    function _updateGlobal() internal {
        _initSupplyMode();
        uint256 supply = _getEffectiveSupply();
        pointsPerShareStored = _currentPointsPerShare();
        lastUpdateTime = block.timestamp;

        emit GlobalCheckpointed(pointsPerShareStored, block.timestamp, supply);
    }

    /// @notice Update user state
    /// @param user User address to update
    function _updateUser(address user) internal {
        uint256 cachedPointsPerShare = pointsPerShareStored;
        uint256 lastBalance = userLastBalance[user];
        uint256 lastCheckpointBlock = userLastCheckpointBlock[user];

        // Flash loan protection: only credit points if minimum holding blocks have passed
        // This prevents attackers from borrowing tokens, checkpointing, and returning in same block
        bool passedHoldingPeriod = lastCheckpointBlock == 0 ||
            block.number >= lastCheckpointBlock + minHoldingBlocks;

        // Calculate new earned points using last recorded balance
        // Only credit if holding period requirement is met
        if (lastBalance > 0 && lastBalance >= minBalanceThreshold && passedHoldingPeriod) {
            uint256 pointsDelta = cachedPointsPerShare - userPointsPerSharePaid[user];
            uint256 newEarned = (lastBalance * pointsDelta) / PRECISION;
            userPointsEarned[user] += newEarned;
        }

        // Update user state
        uint256 newBalance = ppt.balanceOf(user);
        userPointsPerSharePaid[user] = cachedPointsPerShare;
        userLastBalance[user] = newBalance;
        userLastCheckpoint[user] = block.timestamp;
        userLastCheckpointBlock[user] = block.number;

        emit UserCheckpointed(user, userPointsEarned[user], newBalance, block.timestamp);
    }

    // =============================================================================
    // View Functions - IPointsModule Implementation
    // =============================================================================

    /// @notice Internal calculation of user points
    /// @param user User address
    /// @return Total accumulated points
    function _calculatePoints(address user) internal view returns (uint256) {
        if (!active) return userPointsEarned[user];

        uint256 lastBalance = userLastBalance[user];
        uint256 cachedPointsPerShare = _currentPointsPerShare();

        // Calculate earned points from last checkpoint
        uint256 earned = userPointsEarned[user];

        // Add points from last checkpoint to now using last recorded balance
        if (lastBalance > 0 && lastBalance >= minBalanceThreshold) {
            uint256 pointsDelta = cachedPointsPerShare - userPointsPerSharePaid[user];
            earned += (lastBalance * pointsDelta) / PRECISION;
        }

        return earned;
    }

    /// @notice Get points for a user (real-time calculation)
    /// @param user User address
    /// @return Total accumulated points
    function getPoints(address user) external view override returns (uint256) {
        return _calculatePoints(user);
    }

    /// @notice Get module name
    function moduleName() external pure override returns (string memory) {
        return MODULE_NAME;
    }

    /// @notice Check if module is active
    function isActive() external view override returns (bool) {
        return active;
    }

    // =============================================================================
    // View Functions - Additional
    // =============================================================================

    /// @notice Get current points per share
    function currentPointsPerShare() external view returns (uint256) {
        return _currentPointsPerShare();
    }

    /// @notice Get user's detailed state
    /// @param user User address
    /// @return balance Current PPT balance
    /// @return lastCheckpointBalance Balance at last checkpoint
    /// @return earnedPoints Total earned points
    /// @return lastCheckpointTime Last checkpoint timestamp
    function getUserState(address user)
        external
        view
        returns (
            uint256 balance,
            uint256 lastCheckpointBalance,
            uint256 earnedPoints,
            uint256 lastCheckpointTime
        )
    {
        balance = ppt.balanceOf(user);
        lastCheckpointBalance = userLastBalance[user];
        earnedPoints = _calculatePoints(user);
        lastCheckpointTime = userLastCheckpoint[user];
    }

    /// @notice Calculate points that would be earned over a period
    /// @param balance PPT balance
    /// @param durationSeconds Duration in seconds
    /// @return Estimated points
    function estimatePoints(uint256 balance, uint256 durationSeconds) external view returns (uint256) {
        if (balance < minBalanceThreshold) return 0;
        uint256 supply = _getEffectiveSupply();
        if (supply == 0) return 0;

        uint256 pointsGenerated = durationSeconds * pointsRatePerSecond;
        return (balance * pointsGenerated) / supply;
    }

    // =============================================================================
    // Checkpoint Functions
    // =============================================================================

    /// @notice Checkpoint global state (keeper function)
    function checkpointGlobal() external onlyRole(KEEPER_ROLE) {
        _updateGlobal();
    }

    /// @notice Checkpoint multiple users (keeper function)
    /// @param users Array of user addresses to checkpoint
    function checkpointUsers(address[] calldata users) external onlyRole(KEEPER_ROLE) {
        uint256 len = users.length;
        if (len > MAX_BATCH_USERS) revert BatchTooLarge(len, MAX_BATCH_USERS);

        _updateGlobal();

        for (uint256 i = 0; i < len; ) {
            _updateUser(users[i]);
            unchecked { ++i; }
        }
    }

    /// @notice Checkpoint a single user (anyone can call)
    /// @param user User address to checkpoint
    function checkpoint(address user) external {
        _updateGlobal();
        _updateUser(user);
    }

    /// @notice Checkpoint caller
    function checkpointSelf() external {
        _updateGlobal();
        _updateUser(msg.sender);
    }

    // =============================================================================
    // Admin Functions
    // =============================================================================

    /// @notice Set points rate per second
    /// @param newRate New rate (1e18 precision)
    function setPointsRate(uint256 newRate) external onlyRole(ADMIN_ROLE) {
        // Update global state first with old rate
        _updateGlobal();

        uint256 oldRate = pointsRatePerSecond;
        pointsRatePerSecond = newRate;

        emit PointsRateUpdated(oldRate, newRate);
    }

    /// @notice Set minimum balance threshold
    /// @param threshold Minimum balance required to earn points
    function setMinBalanceThreshold(uint256 threshold) external onlyRole(ADMIN_ROLE) {
        uint256 oldThreshold = minBalanceThreshold;
        minBalanceThreshold = threshold;
        emit MinBalanceThresholdUpdated(oldThreshold, threshold);
    }

    /// @notice Set module active status
    /// @param _active Whether the module is active
    function setActive(bool _active) external onlyRole(ADMIN_ROLE) {
        if (_active && !active) {
            // Reactivating - update lastUpdateTime to now
            lastUpdateTime = block.timestamp;
        } else if (!_active && active) {
            // Deactivating - finalize current points
            _updateGlobal();
        }
        active = _active;
        emit ModuleActiveStatusUpdated(_active);
    }

    /// @notice Update PPT address (emergency only)
    /// @param _ppt New PPT address
    function setPpt(address _ppt) external onlyRole(ADMIN_ROLE) {
        if (_ppt == address(0)) revert ZeroAddress();
        if (_ppt == address(ppt)) return; // No change needed
        _updateGlobal();
        address oldPpt = address(ppt);
        ppt = IPPT(_ppt);
        // Reset supply mode detection for new PPT
        supplyModeInitialized = false;
        emit PptUpdated(oldPpt, _ppt);
    }

    /// @notice Force supply mode (admin override)
    /// @param _useEffectiveSupply Whether to use effectiveSupply
    function setSupplyMode(bool _useEffectiveSupply) external onlyRole(ADMIN_ROLE) {
        useEffectiveSupply = _useEffectiveSupply;
        supplyModeInitialized = true;
        emit SupplyModeInitialized(_useEffectiveSupply);
    }

    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    /// @notice Set minimum holding blocks for flash loan protection
    /// @param blocks Minimum blocks a balance must be held
    function setMinHoldingBlocks(uint256 blocks) external onlyRole(ADMIN_ROLE) {
        uint256 oldBlocks = minHoldingBlocks;
        minHoldingBlocks = blocks;
        emit MinHoldingBlocksUpdated(oldBlocks, blocks);
    }

    /// @notice Get contract version
    /// @return Version string
    function version() external pure returns (string memory) {
        return VERSION;
    }

    // =============================================================================
    // Storage Gap - Reserved for future upgrades
    // =============================================================================

    /// @dev Reserved storage space to allow for layout changes in future upgrades
    uint256[50] private __gap;
}
