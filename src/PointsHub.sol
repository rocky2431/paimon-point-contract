// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IPointsModule, IPenaltyModule} from "./interfaces/IPointsModule.sol";

/// @title PointsHub
/// @author Paimon Protocol
/// @notice Central hub for aggregating points from multiple modules
/// @dev UUPS upgradeable pattern, aggregates points from registered modules
contract PointsHub is
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
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    uint256 public constant PRECISION = 1e18;
    uint256 public constant MAX_MODULES = 10;

    /// @notice Default gas limit for module calls
    uint256 public constant DEFAULT_MODULE_GAS_LIMIT = 200_000;

    /// @notice Maximum exchange rate (prevents extreme values)
    uint256 public constant MAX_EXCHANGE_RATE = 1e24;

    /// @notice Minimum exchange rate (prevents dust amounts)
    uint256 public constant MIN_EXCHANGE_RATE = 1e12;

    /// @notice Contract version for upgrade tracking
    string public constant VERSION = "1.3.0";

    // =============================================================================
    // State Variables
    // =============================================================================

    /// @notice Array of registered points modules
    IPointsModule[] public modules;

    /// @notice Mapping to check if an address is a registered module
    mapping(address => bool) public isModule;

    /// @notice Penalty module for tracking redemption penalties
    IPenaltyModule public penaltyModule;

    /// @notice Reward token for points redemption
    IERC20 public rewardToken;

    /// @notice Exchange rate: points to token (1e18 precision)
    /// @dev tokenAmount = pointsAmount * exchangeRate / PRECISION
    uint256 public exchangeRate;

    /// @notice Whether redemption is enabled
    bool public redeemEnabled;

    /// @notice Mapping of user address to total redeemed points
    mapping(address => uint256) public redeemedPoints;

    /// @notice Maximum points that can be redeemed per transaction (0 = unlimited)
    uint256 public maxRedeemPerTx;

    /// @notice Total points redeemed by all users
    uint256 public totalRedeemedPoints;

    /// @notice Configurable gas limit for module calls
    uint256 public moduleGasLimit;

    // =============================================================================
    // Events
    // =============================================================================

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

    // =============================================================================
    // Errors
    // =============================================================================

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

    // =============================================================================
    // Constructor & Initializer
    // =============================================================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the contract
    /// @param admin Admin address (receives ADMIN_ROLE)
    /// @param upgrader Upgrader address (receives UPGRADER_ROLE, typically timelock)
    function initialize(address admin, address upgrader) external initializer {
        if (admin == address(0) || upgrader == address(0)) revert ZeroAddress();

        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);
        _grantRole(UPGRADER_ROLE, upgrader);

        moduleGasLimit = DEFAULT_MODULE_GAS_LIMIT;
    }

    // =============================================================================
    // UUPS Upgrade
    // =============================================================================

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {
        emit PointsHubUpgraded(newImplementation, block.timestamp);
    }

    // =============================================================================
    // View Functions
    // =============================================================================

    /// @notice Get total points for a user across all active modules
    /// @dev Uses try-catch to prevent one faulty module from blocking entire system
    /// @param user The user address
    /// @return total Total points from all modules
    function getTotalPoints(address user) public view returns (uint256 total) {
        uint256 len = modules.length;
        uint256 gasLimit = moduleGasLimit > 0 ? moduleGasLimit : DEFAULT_MODULE_GAS_LIMIT;

        for (uint256 i = 0; i < len;) {
            address moduleAddr = address(modules[i]);

            // Check if module is active with gas limit
            (bool successActive, bytes memory dataActive) =
                moduleAddr.staticcall{gas: gasLimit}(abi.encodeWithSelector(IPointsModule.isActive.selector));

            if (successActive && dataActive.length >= 32) {
                bool isActiveFlag = abi.decode(dataActive, (bool));
                if (isActiveFlag) {
                    // Get points with gas limit
                    (bool successPoints, bytes memory dataPoints) = moduleAddr.staticcall{gas: gasLimit}(
                        abi.encodeWithSelector(IPointsModule.getPoints.selector, user)
                    );

                    if (successPoints && dataPoints.length >= 32) {
                        uint256 points = abi.decode(dataPoints, (uint256));
                        total += points;
                    }
                    // If call failed or returned invalid data, skip module
                }
            }
            // If isActive call failed, skip module

            unchecked {
                ++i;
            }
        }
    }

    /// @notice Get total points for a user with detailed module success status
    /// @dev Returns which modules succeeded/failed so callers can detect issues
    /// @param user The user address
    /// @return total Total points from successful modules
    /// @return moduleSuccess Array indicating success status for each module
    function getTotalPointsWithStatus(address user) public view returns (uint256 total, bool[] memory moduleSuccess) {
        uint256 len = modules.length;
        moduleSuccess = new bool[](len);
        uint256 gasLimit = moduleGasLimit > 0 ? moduleGasLimit : DEFAULT_MODULE_GAS_LIMIT;

        for (uint256 i = 0; i < len;) {
            address moduleAddr = address(modules[i]);

            (bool successActive, bytes memory dataActive) =
                moduleAddr.staticcall{gas: gasLimit}(abi.encodeWithSelector(IPointsModule.isActive.selector));

            if (successActive && dataActive.length >= 32) {
                bool isActiveFlag = abi.decode(dataActive, (bool));
                if (isActiveFlag) {
                    (bool successPoints, bytes memory dataPoints) = moduleAddr.staticcall{gas: gasLimit}(
                        abi.encodeWithSelector(IPointsModule.getPoints.selector, user)
                    );

                    if (successPoints && dataPoints.length >= 32) {
                        total += abi.decode(dataPoints, (uint256));
                        moduleSuccess[i] = true;
                    }
                    // moduleSuccess[i] remains false if call failed
                } else {
                    moduleSuccess[i] = true; // Module inactive is not a failure
                }
            }
            // moduleSuccess[i] remains false if isActive call failed

            unchecked {
                ++i;
            }
        }
    }

    /// @notice Get penalty points for a user
    /// @dev Uses try-catch to prevent penalty module failures from blocking system
    /// @param user The user address
    /// @return Penalty points (0 if no penalty module set or call fails)
    function getPenaltyPoints(address user) public view returns (uint256) {
        if (address(penaltyModule) == address(0)) return 0;
        try penaltyModule.getPenalty(user) returns (uint256 penalty) {
            return penalty;
        } catch {
            return 0;
        }
    }

    /// @notice Get claimable points for a user
    /// @dev claimable = total - penalty - redeemed
    /// @param user The user address
    /// @return Claimable points
    function getClaimablePoints(address user) public view returns (uint256) {
        uint256 total = getTotalPoints(user);
        uint256 penalty = getPenaltyPoints(user);
        uint256 redeemed = redeemedPoints[user];

        uint256 deductions = penalty + redeemed;
        if (deductions >= total) return 0;
        return total - deductions;
    }

    /// @notice Get detailed points breakdown for a user
    /// @dev Uses try-catch to handle faulty modules gracefully
    /// @param user The user address
    /// @return names Array of module names
    /// @return points Array of points per module
    /// @return penalty Total penalty points
    /// @return redeemed Total redeemed points
    /// @return claimable Net claimable points
    function getPointsBreakdown(address user)
        external
        view
        returns (string[] memory names, uint256[] memory points, uint256 penalty, uint256 redeemed, uint256 claimable)
    {
        uint256 len = modules.length;
        names = new string[](len);
        points = new uint256[](len);

        for (uint256 i = 0; i < len;) {
            try modules[i].moduleName() returns (string memory name) {
                names[i] = name;
            } catch {
                names[i] = "Unknown";
            }

            try modules[i].isActive() returns (bool isActiveFlag) {
                if (isActiveFlag) {
                    try modules[i].getPoints(user) returns (uint256 pts) {
                        points[i] = pts;
                    } catch {
                        points[i] = 0;
                    }
                }
            } catch {
                points[i] = 0;
            }
            unchecked {
                ++i;
            }
        }

        penalty = getPenaltyPoints(user);
        redeemed = redeemedPoints[user];
        claimable = getClaimablePoints(user);
    }

    /// @notice Preview redemption - calculate tokens for given points
    /// @param pointsAmount Points to redeem
    /// @return tokenAmount Tokens that would be received
    function previewRedeem(uint256 pointsAmount) public view returns (uint256 tokenAmount) {
        if (exchangeRate == 0) return 0;
        tokenAmount = (pointsAmount * exchangeRate) / PRECISION;
    }

    /// @notice Get number of registered modules
    /// @return Module count
    function getModuleCount() external view returns (uint256) {
        return modules.length;
    }

    /// @notice Get module at index
    /// @param index Module index
    /// @return Module address
    function getModuleAt(uint256 index) external view returns (address) {
        if (index >= modules.length) revert IndexOutOfBounds(index, modules.length);
        return address(modules[index]);
    }

    /// @notice Get all registered modules
    /// @return Array of module addresses
    function getAllModules() external view returns (address[] memory) {
        uint256 len = modules.length;
        address[] memory result = new address[](len);
        for (uint256 i = 0; i < len;) {
            result[i] = address(modules[i]);
            unchecked {
                ++i;
            }
        }
        return result;
    }

    // =============================================================================
    // User Functions
    // =============================================================================

    /// @notice Redeem points for reward tokens
    /// @param pointsAmount Amount of points to redeem
    function redeem(uint256 pointsAmount) external nonReentrant whenNotPaused {
        if (!redeemEnabled) revert RedeemNotEnabled();
        if (pointsAmount == 0) revert ZeroAmount();
        if (exchangeRate == 0) revert ExchangeRateNotSet();
        if (address(rewardToken) == address(0)) revert RewardTokenNotSet();

        // Check max per tx
        if (maxRedeemPerTx > 0 && pointsAmount > maxRedeemPerTx) {
            revert ExceedsMaxRedeemPerTx(pointsAmount, maxRedeemPerTx);
        }

        // Check claimable
        uint256 claimable = getClaimablePoints(msg.sender);
        if (pointsAmount > claimable) {
            revert InsufficientPoints(claimable, pointsAmount);
        }

        // Calculate token amount
        uint256 tokenAmount = previewRedeem(pointsAmount);

        // Prevent precision loss - ensure non-zero token output
        if (tokenAmount == 0) revert ZeroTokenAmount();

        // Check reward token balance
        uint256 available = rewardToken.balanceOf(address(this));
        if (tokenAmount > available) {
            revert InsufficientRewardTokens(available, tokenAmount);
        }

        // Update state
        redeemedPoints[msg.sender] += pointsAmount;
        totalRedeemedPoints += pointsAmount;

        // Transfer tokens
        rewardToken.safeTransfer(msg.sender, tokenAmount);

        emit PointsRedeemed(msg.sender, pointsAmount, tokenAmount, redeemedPoints[msg.sender]);
    }

    // =============================================================================
    // Admin Functions - Module Management
    // =============================================================================

    /// @notice Register a new points module
    /// @param module Address of the module to register
    function registerModule(address module) external onlyRole(ADMIN_ROLE) {
        if (module == address(0)) revert ZeroAddress();
        if (isModule[module]) revert ModuleAlreadyRegistered(module);
        if (modules.length >= MAX_MODULES) revert MaxModulesReached();

        // Verify module implements required interface before adding
        string memory name;
        try IPointsModule(module).moduleName() returns (string memory _name) {
            name = _name;
        } catch {
            revert InvalidModuleInterface(module);
        }

        // Verify getPoints and isActive are callable
        try IPointsModule(module).isActive() returns (
            bool
        ) {
        // Valid
        }
        catch {
            revert InvalidModuleInterface(module);
        }

        modules.push(IPointsModule(module));
        isModule[module] = true;

        emit ModuleRegistered(module, name, modules.length - 1);
    }

    /// @notice Remove a points module
    /// @param module Address of the module to remove
    function removeModule(address module) external onlyRole(ADMIN_ROLE) {
        if (!isModule[module]) revert ModuleNotFound(module);

        uint256 len = modules.length;
        uint256 indexToRemove;
        for (uint256 i = 0; i < len;) {
            if (address(modules[i]) == module) {
                indexToRemove = i;
                break;
            }
            unchecked {
                ++i;
            }
        }

        // Swap with last and pop
        modules[indexToRemove] = modules[len - 1];
        modules.pop();
        isModule[module] = false;

        emit ModuleRemoved(module, indexToRemove);
    }

    /// @notice Emergency: Remove module by index (when module address lookup fails)
    /// @dev Use only when a malicious module prevents normal removal
    /// @param index Index of the module to remove
    function emergencyRemoveModuleByIndex(uint256 index) external onlyRole(ADMIN_ROLE) {
        if (index >= modules.length) revert IndexOutOfBounds(index, modules.length);

        address moduleAddr = address(modules[index]);
        isModule[moduleAddr] = false;

        // Swap with last and pop
        uint256 lastIndex = modules.length - 1;
        if (index != lastIndex) {
            modules[index] = modules[lastIndex];
        }
        modules.pop();

        emit ModuleRemoved(moduleAddr, index);
    }

    /// @notice Set the penalty module
    /// @param _penaltyModule Address of the penalty module (address(0) to disable)
    function setPenaltyModule(address _penaltyModule) external onlyRole(ADMIN_ROLE) {
        // Allow setting to address(0) to disable penalty module
        if (_penaltyModule != address(0)) {
            // Verify the module implements IPenaltyModule interface
            try IPenaltyModule(_penaltyModule).getPenalty(address(0)) returns (
                uint256
            ) {
            // Valid interface
            }
            catch {
                revert InvalidPenaltyModuleInterface(_penaltyModule);
            }
        }

        address oldModule = address(penaltyModule);
        penaltyModule = IPenaltyModule(_penaltyModule);
        emit PenaltyModuleUpdated(oldModule, _penaltyModule);
    }

    // =============================================================================
    // Admin Functions - Redemption Configuration
    // =============================================================================

    /// @notice Set the reward token for redemption
    /// @param token Address of the reward token
    function setRewardToken(address token) external onlyRole(ADMIN_ROLE) {
        address oldToken = address(rewardToken);
        rewardToken = IERC20(token);
        emit RewardTokenUpdated(oldToken, token);
    }

    /// @notice Set the exchange rate for points to tokens
    /// @param rate Exchange rate (1e18 precision)
    function setExchangeRate(uint256 rate) external onlyRole(ADMIN_ROLE) {
        // Allow rate = 0 to disable redemption, otherwise enforce bounds
        if (rate != 0 && (rate < MIN_EXCHANGE_RATE || rate > MAX_EXCHANGE_RATE)) {
            revert InvalidExchangeRate(rate, MIN_EXCHANGE_RATE, MAX_EXCHANGE_RATE);
        }
        uint256 oldRate = exchangeRate;
        exchangeRate = rate;
        emit ExchangeRateUpdated(oldRate, rate);
    }

    /// @notice Enable or disable redemption
    /// @param enabled True to enable, false to disable
    function setRedeemEnabled(bool enabled) external onlyRole(ADMIN_ROLE) {
        redeemEnabled = enabled;
        emit RedeemStatusUpdated(enabled);
    }

    /// @notice Set maximum points that can be redeemed per transaction
    /// @param max Maximum points (0 = unlimited)
    function setMaxRedeemPerTx(uint256 max) external onlyRole(ADMIN_ROLE) {
        uint256 oldMax = maxRedeemPerTx;
        maxRedeemPerTx = max;
        emit MaxRedeemPerTxUpdated(oldMax, max);
    }

    /// @notice Withdraw reward tokens (admin only, for emergency or adjustment)
    /// @param to Recipient address
    /// @param amount Amount to withdraw
    function withdrawRewardTokens(address to, uint256 amount) external onlyRole(ADMIN_ROLE) {
        if (to == address(0)) revert ZeroAddress();
        if (address(rewardToken) == address(0)) revert RewardTokenNotSet();
        rewardToken.safeTransfer(to, amount);
    }

    // =============================================================================
    // Admin Functions - Pause
    // =============================================================================

    /// @notice Set the gas limit for module calls
    /// @param limit New gas limit (0 to use default)
    function setModuleGasLimit(uint256 limit) external onlyRole(ADMIN_ROLE) {
        uint256 oldLimit = moduleGasLimit;
        moduleGasLimit = limit;
        emit ModuleGasLimitUpdated(oldLimit, limit);
    }

    /// @notice Pause contract operations
    /// @dev Only callable by ADMIN_ROLE
    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    /// @notice Unpause contract operations
    /// @dev Only callable by ADMIN_ROLE
    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
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
