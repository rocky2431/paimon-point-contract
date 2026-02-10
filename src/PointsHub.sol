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
/// @notice 用于聚合多个模块积分的中央枢纽
/// @dev UUPS 可升级模式，聚合已注册模块的积分
contract PointsHub is
    Initializable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    // =============================================================================
    // 常量与角色
    // =============================================================================

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    uint256 public constant PRECISION = 1e18;
    uint256 public constant MAX_MODULES = 10;

    /// @notice 模块调用的默认 gas 限制
    uint256 public constant DEFAULT_MODULE_GAS_LIMIT = 200_000;

    /// @notice 最大兑换率（防止极端值）
    uint256 public constant MAX_EXCHANGE_RATE = 1e24;

    /// @notice 最小兑换率（防止粉尘数量）
    uint256 public constant MIN_EXCHANGE_RATE = 1e12;

    /// @notice 积分显示精度（类似 ERC20 decimals）
    /// @dev 前端显示时: displayPoints = rawPoints / 10^POINTS_DECIMALS
    /// 例: rawPoints = 1e18 (1 PPT × 1s × 1.0x) → displayPoints = 0.00001
    uint8 public constant POINTS_DECIMALS = 23;

    /// @notice 用于跟踪升级的合约版本
    string public constant VERSION = "1.3.0";

    // =============================================================================
    // 状态变量
    // =============================================================================

    /// @notice 已注册的积分模块数组
    IPointsModule[] public modules;

    /// @notice 用于检查地址是否为已注册模块的映射
    mapping(address => bool) public isModule;

    /// @notice 用于跟踪兑换惩罚的惩罚模块
    IPenaltyModule public penaltyModule;

    /// @notice 用于积分兑换的奖励代币
    IERC20 public rewardToken;

    /// @notice 兑换率：积分到代币（1e18 精度）
    /// @dev tokenAmount = pointsAmount * exchangeRate / PRECISION
    uint256 public exchangeRate;

    /// @notice 兑换是否启用
    bool public redeemEnabled;

    /// @notice 用户地址到已兑换总积分的映射
    mapping(address => uint256) public redeemedPoints;

    /// @notice 每笔交易可兑换的最大积分（0 = 无限制）
    uint256 public maxRedeemPerTx;

    /// @notice 所有用户已兑换的总积分
    uint256 public totalRedeemedPoints;

    /// @notice 模块调用的可配置 gas 限制
    uint256 public moduleGasLimit;

    // =============================================================================
    // 事件
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
    // 错误
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
    // 构造函数与初始化器
    // =============================================================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice 初始化合约
    /// @param admin 管理员地址（接收 ADMIN_ROLE）
    /// @param upgrader 升级者地址（接收 UPGRADER_ROLE，通常为时间锁）
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
    // UUPS 升级
    // =============================================================================

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {
        emit PointsHubUpgraded(newImplementation, block.timestamp);
    }

    // =============================================================================
    // 视图函数
    // =============================================================================

    /// @notice 获取用户在所有活跃模块中的总积分
    /// @dev 使用 try-catch 防止一个故障模块阻塞整个系统
    /// @param user 用户地址
    /// @return total 所有模块的总积分
    function getTotalPoints(address user) public view returns (uint256 total) {
        uint256 len = modules.length;
        uint256 gasLimit = moduleGasLimit > 0 ? moduleGasLimit : DEFAULT_MODULE_GAS_LIMIT;

        for (uint256 i = 0; i < len;) {
            address moduleAddr = address(modules[i]);

            // 使用 gas 限制检查模块是否活跃
            (bool successActive, bytes memory dataActive) =
                moduleAddr.staticcall{gas: gasLimit}(abi.encodeWithSelector(IPointsModule.isActive.selector));

            if (successActive && dataActive.length >= 32) {
                bool isActiveFlag = abi.decode(dataActive, (bool));
                if (isActiveFlag) {
                    // 使用 gas 限制获取积分
                    (bool successPoints, bytes memory dataPoints) = moduleAddr.staticcall{gas: gasLimit}(
                        abi.encodeWithSelector(IPointsModule.getPoints.selector, user)
                    );

                    if (successPoints && dataPoints.length >= 32) {
                        uint256 points = abi.decode(dataPoints, (uint256));
                        total += points;
                    }
                    // 如果调用失败或返回无效数据，跳过该模块
                }
            }
            // 如果 isActive 调用失败，跳过该模块

            unchecked {
                ++i;
            }
        }
    }

    /// @notice 获取用户的总积分及详细的模块成功状态
    /// @dev 返回哪些模块成功/失败，以便调用者可以检测问题
    /// @param user 用户地址
    /// @return total 来自成功模块的总积分
    /// @return moduleSuccess 指示每个模块成功状态的数组
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
                    // 如果调用失败，moduleSuccess[i] 保持为 false
                } else {
                    moduleSuccess[i] = true; // 模块未激活不算失败
                }
            }
            // 如果 isActive 调用失败，moduleSuccess[i] 保持为 false

            unchecked {
                ++i;
            }
        }
    }

    /// @notice 获取用户的惩罚积分
    /// @dev 使用 try-catch 防止惩罚模块失败阻塞系统
    /// @param user 用户地址
    /// @return 惩罚积分（如果未设置惩罚模块或调用失败则为 0）
    function getPenaltyPoints(address user) public view returns (uint256) {
        if (address(penaltyModule) == address(0)) return 0;
        try penaltyModule.getPenalty(user) returns (uint256 penalty) {
            return penalty;
        } catch {
            return 0;
        }
    }

    /// @notice 获取用户的可领取积分
    /// @dev claimable = total - penalty - redeemed
    /// @param user 用户地址
    /// @return 可领取积分
    function getClaimablePoints(address user) public view returns (uint256) {
        uint256 total = getTotalPoints(user);
        uint256 penalty = getPenaltyPoints(user);
        uint256 redeemed = redeemedPoints[user];

        uint256 deductions = penalty + redeemed;
        if (deductions >= total) return 0;
        return total - deductions;
    }

    /// @notice 获取用户的详细积分分解
    /// @dev 使用 try-catch 优雅地处理故障模块
    /// @param user 用户地址
    /// @return names 模块名称数组
    /// @return points 每个模块的积分数组
    /// @return penalty 总惩罚积分
    /// @return redeemed 已兑换总积分
    /// @return claimable 净可领取积分
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

    /// @notice 预览兑换 - 计算给定积分可获得的代币
    /// @param pointsAmount 要兑换的积分
    /// @return tokenAmount 将接收的代币数量
    function previewRedeem(uint256 pointsAmount) public view returns (uint256 tokenAmount) {
        if (exchangeRate == 0) return 0;
        tokenAmount = (pointsAmount * exchangeRate) / PRECISION;
    }

    /// @notice 获取已注册模块的数量
    /// @return 模块数量
    function getModuleCount() external view returns (uint256) {
        return modules.length;
    }

    /// @notice 获取指定索引的模块
    /// @param index 模块索引
    /// @return 模块地址
    function getModuleAt(uint256 index) external view returns (address) {
        if (index >= modules.length) revert IndexOutOfBounds(index, modules.length);
        return address(modules[index]);
    }

    /// @notice 获取所有已注册的模块
    /// @return 模块地址数组
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
    // 用户函数
    // =============================================================================

    /// @notice 兑换积分以获取奖励代币
    /// @param pointsAmount 要兑换的积分数量
    function redeem(uint256 pointsAmount) external nonReentrant whenNotPaused {
        if (!redeemEnabled) revert RedeemNotEnabled();
        if (pointsAmount == 0) revert ZeroAmount();
        if (exchangeRate == 0) revert ExchangeRateNotSet();
        if (address(rewardToken) == address(0)) revert RewardTokenNotSet();

        // 检查每笔交易最大值
        if (maxRedeemPerTx > 0 && pointsAmount > maxRedeemPerTx) {
            revert ExceedsMaxRedeemPerTx(pointsAmount, maxRedeemPerTx);
        }

        // 检查可领取量
        uint256 claimable = getClaimablePoints(msg.sender);
        if (pointsAmount > claimable) {
            revert InsufficientPoints(claimable, pointsAmount);
        }

        // 计算代币数量
        uint256 tokenAmount = previewRedeem(pointsAmount);

        // 防止精度损失 - 确保非零代币输出
        if (tokenAmount == 0) revert ZeroTokenAmount();

        // 检查奖励代币余额
        uint256 available = rewardToken.balanceOf(address(this));
        if (tokenAmount > available) {
            revert InsufficientRewardTokens(available, tokenAmount);
        }

        // 更新状态
        redeemedPoints[msg.sender] += pointsAmount;
        totalRedeemedPoints += pointsAmount;

        // 转移代币
        rewardToken.safeTransfer(msg.sender, tokenAmount);

        emit PointsRedeemed(msg.sender, pointsAmount, tokenAmount, redeemedPoints[msg.sender]);
    }

    // =============================================================================
    // 管理员函数 - 模块管理
    // =============================================================================

    /// @notice 注册新的积分模块
    /// @param module 要注册的模块地址
    function registerModule(address module) external onlyRole(ADMIN_ROLE) {
        if (module == address(0)) revert ZeroAddress();
        if (isModule[module]) revert ModuleAlreadyRegistered(module);
        if (modules.length >= MAX_MODULES) revert MaxModulesReached();

        // 在添加之前验证模块实现了所需的接口
        string memory name;
        try IPointsModule(module).moduleName() returns (string memory _name) {
            name = _name;
        } catch {
            revert InvalidModuleInterface(module);
        }

        // 验证 getPoints 和 isActive 可调用
        try IPointsModule(module).isActive() returns (
            bool
        ) {
        // 有效
        }
        catch {
            revert InvalidModuleInterface(module);
        }

        modules.push(IPointsModule(module));
        isModule[module] = true;

        emit ModuleRegistered(module, name, modules.length - 1);
    }

    /// @notice 移除积分模块
    /// @param module 要移除的模块地址
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

        // 与最后一个交换并弹出
        modules[indexToRemove] = modules[len - 1];
        modules.pop();
        isModule[module] = false;

        emit ModuleRemoved(module, indexToRemove);
    }

    /// @notice 紧急：通过索引移除模块（当模块地址查找失败时）
    /// @dev 仅在恶意模块阻止正常移除时使用
    /// @param index 要移除的模块索引
    function emergencyRemoveModuleByIndex(uint256 index) external onlyRole(ADMIN_ROLE) {
        if (index >= modules.length) revert IndexOutOfBounds(index, modules.length);

        address moduleAddr = address(modules[index]);
        isModule[moduleAddr] = false;

        // 与最后一个交换并弹出
        uint256 lastIndex = modules.length - 1;
        if (index != lastIndex) {
            modules[index] = modules[lastIndex];
        }
        modules.pop();

        emit ModuleRemoved(moduleAddr, index);
    }

    /// @notice 设置惩罚模块
    /// @param _penaltyModule 惩罚模块的地址（address(0) 表示禁用）
    function setPenaltyModule(address _penaltyModule) external onlyRole(ADMIN_ROLE) {
        // 允许设置为 address(0) 以禁用惩罚模块
        if (_penaltyModule != address(0)) {
            // 验证模块实现了 IPenaltyModule 接口
            try IPenaltyModule(_penaltyModule).getPenalty(address(0)) returns (
                uint256
            ) {
            // 有效接口
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
    // 管理员函数 - 兑换配置
    // =============================================================================

    /// @notice 设置用于兑换的奖励代币
    /// @param token 奖励代币的地址
    function setRewardToken(address token) external onlyRole(ADMIN_ROLE) {
        address oldToken = address(rewardToken);
        rewardToken = IERC20(token);
        emit RewardTokenUpdated(oldToken, token);
    }

    /// @notice 设置积分到代币的兑换率
    /// @param rate 兑换率（1e18 精度）
    function setExchangeRate(uint256 rate) external onlyRole(ADMIN_ROLE) {
        // 允许 rate = 0 以禁用兑换，否则强制边界检查
        if (rate != 0 && (rate < MIN_EXCHANGE_RATE || rate > MAX_EXCHANGE_RATE)) {
            revert InvalidExchangeRate(rate, MIN_EXCHANGE_RATE, MAX_EXCHANGE_RATE);
        }
        uint256 oldRate = exchangeRate;
        exchangeRate = rate;
        emit ExchangeRateUpdated(oldRate, rate);
    }

    /// @notice 启用或禁用兑换
    /// @param enabled true 为启用，false 为禁用
    function setRedeemEnabled(bool enabled) external onlyRole(ADMIN_ROLE) {
        redeemEnabled = enabled;
        emit RedeemStatusUpdated(enabled);
    }

    /// @notice 设置每笔交易可兑换的最大积分
    /// @param max 最大积分（0 = 无限制）
    function setMaxRedeemPerTx(uint256 max) external onlyRole(ADMIN_ROLE) {
        uint256 oldMax = maxRedeemPerTx;
        maxRedeemPerTx = max;
        emit MaxRedeemPerTxUpdated(oldMax, max);
    }

    /// @notice 提取奖励代币（仅管理员，用于紧急情况或调整）
    /// @param to 接收者地址
    /// @param amount 要提取的数量
    function withdrawRewardTokens(address to, uint256 amount) external onlyRole(ADMIN_ROLE) {
        if (to == address(0)) revert ZeroAddress();
        if (address(rewardToken) == address(0)) revert RewardTokenNotSet();
        rewardToken.safeTransfer(to, amount);
    }

    // =============================================================================
    // 管理员函数 - 暂停
    // =============================================================================

    /// @notice 设置模块调用的 gas 限制
    /// @param limit 新的 gas 限制（0 表示使用默认值）
    function setModuleGasLimit(uint256 limit) external onlyRole(ADMIN_ROLE) {
        uint256 oldLimit = moduleGasLimit;
        moduleGasLimit = limit;
        emit ModuleGasLimitUpdated(oldLimit, limit);
    }

    /// @notice 暂停合约操作
    /// @dev 仅 ADMIN_ROLE 可调用
    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    /// @notice 恢复合约操作
    /// @dev 仅 ADMIN_ROLE 可调用
    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    /// @notice 获取合约版本
    /// @return 版本字符串
    function version() external pure returns (string memory) {
        return VERSION;
    }

    // =============================================================================
    // 存储间隙 - 为未来升级预留
    // =============================================================================

    /// @dev 预留的存储空间，以允许未来升级时更改布局
    uint256[50] private __gap;
}
