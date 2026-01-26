// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {StakingModule} from "../src/StakingModule.sol";
import {PointsHub} from "../src/PointsHub.sol";

/// @title DeployStakingModule
/// @author Paimon Protocol
/// @notice Deployment script for StakingModule
/// @dev Run with:
///      forge script script/DeployStakingModule.s.sol:DeployStakingModule \
///        --rpc-url $RPC_URL --broadcast --verify -vvvv
contract DeployStakingModule is Script {
    // =============================================================================
    // Configuration - Set these before deployment
    // =============================================================================

    // Required addresses (must be set)
    address public ppt; // PPT token address
    address public admin; // Admin address
    address public keeper; // Keeper address
    address public upgrader; // Upgrader address (typically timelock)

    // Optional: PointsHub integration
    address public pointsHub; // Optional: PointsHub address for registration
    address public holdingModule; // Optional: HoldingModule to replace

    // Points rate configuration
    // Default: 0.001 points per second per boosted PPT (1e15)
    uint256 public pointsRatePerSecond = 1e15;

    // Deployed addresses (set after deployment)
    address public stakingModuleImpl;
    address public stakingModuleProxy;

    function setUp() public virtual {
        // Load configuration from environment variables
        ppt = vm.envOr("PPT_ADDRESS", address(0));
        admin = vm.envOr("ADMIN_ADDRESS", address(0));
        keeper = vm.envOr("KEEPER_ADDRESS", address(0));
        upgrader = vm.envOr("UPGRADER_ADDRESS", address(0));
        pointsHub = vm.envOr("POINTS_HUB_ADDRESS", address(0));
        holdingModule = vm.envOr("HOLDING_MODULE_ADDRESS", address(0));
        pointsRatePerSecond = vm.envOr("POINTS_RATE_PER_SECOND", uint256(1e15));
    }

    function run() public {
        // Validate required addresses
        require(ppt != address(0), "PPT_ADDRESS not set");
        require(admin != address(0), "ADMIN_ADDRESS not set");
        require(keeper != address(0), "KEEPER_ADDRESS not set");
        require(upgrader != address(0), "UPGRADER_ADDRESS not set");

        console.log("=== StakingModule Deployment ===");
        console.log("PPT:", ppt);
        console.log("Admin:", admin);
        console.log("Keeper:", keeper);
        console.log("Upgrader:", upgrader);
        console.log("Points Rate/Second:", pointsRatePerSecond);

        vm.startBroadcast();

        // 1. Deploy implementation
        StakingModule impl = new StakingModule();
        stakingModuleImpl = address(impl);
        console.log("StakingModule Implementation:", stakingModuleImpl);

        // 2. Deploy proxy with initialization
        bytes memory initData = abi.encodeWithSelector(
            StakingModule.initialize.selector, ppt, admin, keeper, upgrader, pointsRatePerSecond
        );

        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        stakingModuleProxy = address(proxy);
        console.log("StakingModule Proxy:", stakingModuleProxy);

        // 3. Optional: Register with PointsHub
        if (pointsHub != address(0)) {
            console.log("Registering with PointsHub:", pointsHub);
            PointsHub(pointsHub).registerModule(stakingModuleProxy);
            console.log("Registered StakingModule with PointsHub");
        }

        // 4. Optional: Remove HoldingModule (if replacing)
        if (holdingModule != address(0) && pointsHub != address(0)) {
            console.log("Removing HoldingModule:", holdingModule);
            PointsHub(pointsHub).removeModule(holdingModule);
            console.log("Removed HoldingModule from PointsHub");
        }

        vm.stopBroadcast();

        // Log deployment summary
        console.log("");
        console.log("=== Deployment Summary ===");
        console.log("Implementation:", stakingModuleImpl);
        console.log("Proxy:", stakingModuleProxy);

        // Verify deployment
        StakingModule deployed = StakingModule(stakingModuleProxy);
        require(address(deployed.ppt()) == ppt, "PPT mismatch");
        require(deployed.hasRole(deployed.ADMIN_ROLE(), admin), "Admin role not set");
        require(deployed.hasRole(deployed.KEEPER_ROLE(), keeper), "Keeper role not set");
        require(deployed.hasRole(deployed.UPGRADER_ROLE(), upgrader), "Upgrader role not set");
        require(deployed.active(), "Module not active");

        console.log("Deployment verified successfully!");
    }

    /// @notice Deploy to a local Anvil instance for testing
    function runLocal() public {
        // Use Anvil's default accounts
        ppt = address(0x1); // Placeholder - replace with actual
        admin = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
        keeper = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
        upgrader = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;

        run();
    }
}

/// @title DeployStakingModuleTestnet
/// @notice Convenience script for testnet deployment
contract DeployStakingModuleTestnet is DeployStakingModule {
    function setUp() public override {
        super.setUp();

        // Override with testnet-specific defaults if not set
        if (ppt == address(0)) {
            ppt = vm.envAddress("TESTNET_PPT_ADDRESS");
        }
        if (pointsHub == address(0)) {
            pointsHub = vm.envOr("TESTNET_POINTS_HUB_ADDRESS", address(0));
        }
    }
}

/// @title DeployStakingModuleMainnet
/// @notice Convenience script for mainnet deployment
contract DeployStakingModuleMainnet is DeployStakingModule {
    function setUp() public override {
        super.setUp();

        // Override with mainnet-specific defaults if not set
        if (ppt == address(0)) {
            ppt = vm.envAddress("MAINNET_PPT_ADDRESS");
        }
        if (pointsHub == address(0)) {
            pointsHub = vm.envOr("MAINNET_POINTS_HUB_ADDRESS", address(0));
        }
    }
}
