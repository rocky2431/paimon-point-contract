// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {PointsHub} from "../src/PointsHub.sol";
import {HoldingModule} from "../src/HoldingModule.sol";
import {LPModule} from "../src/LPModule.sol";
import {ActivityModule} from "../src/ActivityModule.sol";
import {PenaltyModule} from "../src/PenaltyModule.sol";

import {MockPPT} from "./mocks/MockPPT.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

abstract contract BaseTest is Test {
    // Contracts
    PointsHub public pointsHub;
    HoldingModule public holdingModule;
    LPModule public lpModule;
    ActivityModule public activityModule;
    PenaltyModule public penaltyModule;

    // Mocks
    MockPPT public ppt;
    MockERC20 public rewardToken;
    MockERC20 public lpToken1;
    MockERC20 public lpToken2;

    // Addresses
    address public admin = makeAddr("admin");
    address public keeper = makeAddr("keeper");
    address public upgrader = makeAddr("upgrader");
    address public user1 = makeAddr("user1");
    address public user2 = makeAddr("user2");
    address public user3 = makeAddr("user3");

    // Constants
    uint256 public constant PRECISION = 1e18;
    uint256 public constant POINTS_RATE_PER_SECOND = 1e15; // 0.001 points per second per PPT
    uint256 public constant LP_BASE_RATE = 1e15;
    uint256 public constant EXCHANGE_RATE = 1e18; // 1:1
    uint256 public constant PENALTY_RATE_BPS = 1000; // 10%

    function setUp() public virtual {
        // Deploy mocks
        ppt = new MockPPT();
        rewardToken = new MockERC20("Reward Token", "RWD", 18);
        lpToken1 = new MockERC20("LP Token 1", "LP1", 18);
        lpToken2 = new MockERC20("LP Token 2", "LP2", 18);

        // Deploy and initialize PointsHub
        PointsHub hubImpl = new PointsHub();
        bytes memory hubData = abi.encodeWithSelector(PointsHub.initialize.selector, admin, upgrader);
        pointsHub = PointsHub(address(new ERC1967Proxy(address(hubImpl), hubData)));

        // Deploy and initialize HoldingModule
        HoldingModule holdingImpl = new HoldingModule();
        bytes memory holdingData = abi.encodeWithSelector(
            HoldingModule.initialize.selector, address(ppt), admin, keeper, upgrader, POINTS_RATE_PER_SECOND
        );
        holdingModule = HoldingModule(address(new ERC1967Proxy(address(holdingImpl), holdingData)));

        // Deploy and initialize LPModule
        LPModule lpImpl = new LPModule();
        bytes memory lpData =
            abi.encodeWithSelector(LPModule.initialize.selector, admin, keeper, upgrader, LP_BASE_RATE);
        lpModule = LPModule(address(new ERC1967Proxy(address(lpImpl), lpData)));

        // Deploy and initialize ActivityModule
        ActivityModule activityImpl = new ActivityModule();
        bytes memory activityData = abi.encodeWithSelector(ActivityModule.initialize.selector, admin, keeper, upgrader);
        activityModule = ActivityModule(address(new ERC1967Proxy(address(activityImpl), activityData)));

        // Deploy and initialize PenaltyModule
        PenaltyModule penaltyImpl = new PenaltyModule();
        bytes memory penaltyData =
            abi.encodeWithSelector(PenaltyModule.initialize.selector, admin, keeper, upgrader, PENALTY_RATE_BPS);
        penaltyModule = PenaltyModule(address(new ERC1967Proxy(address(penaltyImpl), penaltyData)));

        // Setup PointsHub - register modules
        vm.startPrank(admin);
        pointsHub.registerModule(address(holdingModule));
        pointsHub.registerModule(address(lpModule));
        pointsHub.registerModule(address(activityModule));
        pointsHub.setPenaltyModule(address(penaltyModule));
        pointsHub.setRewardToken(address(rewardToken));
        pointsHub.setExchangeRate(EXCHANGE_RATE);
        vm.stopPrank();

        // Setup LPModule - add pools
        vm.startPrank(admin);
        lpModule.addPool(address(lpToken1), 100, "LP Pool 1"); // 1x multiplier
        lpModule.addPool(address(lpToken2), 200, "LP Pool 2"); // 2x multiplier
        vm.stopPrank();

        // Mint reward tokens to PointsHub
        rewardToken.mint(address(pointsHub), 1_000_000 * 1e18);
    }

    // Helper function to generate Merkle tree for testing
    function _generateMerkleProof(address user, uint256 amount, address[] memory allUsers, uint256[] memory allAmounts)
        internal
        pure
        returns (bytes32 root, bytes32[] memory proof)
    {
        require(allUsers.length == allAmounts.length, "Length mismatch");

        // Find user index
        uint256 userIndex = type(uint256).max;
        for (uint256 i = 0; i < allUsers.length; i++) {
            if (allUsers[i] == user) {
                userIndex = i;
                break;
            }
        }
        require(userIndex != type(uint256).max, "User not found");

        // Generate leaves
        bytes32[] memory leaves = new bytes32[](allUsers.length);
        for (uint256 i = 0; i < allUsers.length; i++) {
            leaves[i] = keccak256(bytes.concat(keccak256(abi.encode(allUsers[i], allAmounts[i]))));
        }

        // For simplicity, implement a basic Merkle tree (works for 1-4 leaves)
        if (allUsers.length == 1) {
            root = leaves[0];
            proof = new bytes32[](0);
        } else if (allUsers.length == 2) {
            root = _hashPair(leaves[0], leaves[1]);
            proof = new bytes32[](1);
            proof[0] = leaves[1 - userIndex];
        } else if (allUsers.length <= 4) {
            // Pad to 4 leaves
            bytes32[] memory paddedLeaves = new bytes32[](4);
            for (uint256 i = 0; i < 4; i++) {
                paddedLeaves[i] = i < leaves.length ? leaves[i] : bytes32(0);
            }

            bytes32 h01 = _hashPair(paddedLeaves[0], paddedLeaves[1]);
            bytes32 h23 = _hashPair(paddedLeaves[2], paddedLeaves[3]);
            root = _hashPair(h01, h23);

            proof = new bytes32[](2);
            if (userIndex < 2) {
                proof[0] = paddedLeaves[1 - userIndex];
                proof[1] = h23;
            } else {
                proof[0] = paddedLeaves[userIndex == 2 ? 3 : 2];
                proof[1] = h01;
            }
        } else {
            revert("Too many users for simple implementation");
        }
    }

    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    // Helper to advance time
    function _advanceTime(uint256 seconds_) internal {
        vm.warp(block.timestamp + seconds_);
    }

    // Helper to advance blocks
    function _advanceBlocks(uint256 blocks_) internal {
        vm.roll(block.number + blocks_);
    }

    // Helper to set ActivityModule Merkle root with timelock
    function _setActivityMerkleRoot(bytes32 root, string memory label) internal {
        vm.prank(keeper);
        activityModule.updateMerkleRoot(root, label);
        // Advance time past ROOT_DELAY (24 hours)
        _advanceTime(24 hours + 1);
        // Activate the root
        activityModule.activateRoot();
    }

    // Helper to set PenaltyModule Merkle root with timelock
    function _setPenaltyMerkleRoot(bytes32 root) internal {
        vm.prank(keeper);
        penaltyModule.updatePenaltyRoot(root);
        // Advance time past ROOT_DELAY (24 hours)
        _advanceTime(24 hours + 1);
        // Activate the root
        penaltyModule.activateRoot();
    }
}
