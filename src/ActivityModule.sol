// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

import {IPointsModule} from "./interfaces/IPointsModule.sol";

/// @title ActivityModule
/// @author Paimon Protocol
/// @notice Points module for trading and activity rewards
/// @dev Uses Merkle tree for off-chain computation verification
///      Points are calculated off-chain and users claim with proofs
contract ActivityModule is
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

    string public constant MODULE_NAME = "Trading & Activity";

    // =============================================================================
    // State Variables
    // =============================================================================

    /// @notice Current Merkle root for points claims
    bytes32 public merkleRoot;

    /// @notice Mapping of user address to claimed cumulative points
    mapping(address => uint256) public claimedPoints;

    /// @notice Whether the module is active
    bool public active;

    /// @notice History of Merkle roots for auditing
    bytes32[] public rootHistory;

    /// @notice Mapping of root to timestamp when it was set
    mapping(bytes32 => uint256) public rootTimestamp;

    /// @notice Current epoch/period number
    uint256 public currentEpoch;

    /// @notice Description/label for current epoch
    string public currentEpochLabel;

    // =============================================================================
    // Events
    // =============================================================================

    event MerkleRootUpdated(
        bytes32 indexed oldRoot,
        bytes32 indexed newRoot,
        uint256 epoch,
        string label,
        uint256 timestamp
    );
    event PointsClaimed(
        address indexed user,
        uint256 claimedAmount,
        uint256 totalClaimed,
        uint256 epoch
    );
    event ModuleActiveStatusUpdated(bool active);
    event ActivityModuleUpgraded(address indexed newImplementation, uint256 timestamp);
    event BatchClaimSkipped(address indexed user, string reason);

    // =============================================================================
    // Errors
    // =============================================================================

    error ZeroAddress();
    error InvalidProof();
    error NothingToClaim();
    error MerkleRootNotSet();
    error ClaimExceedsMerkleAmount(uint256 claimed, uint256 merkleAmount);

    // =============================================================================
    // Constructor & Initializer
    // =============================================================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the contract
    /// @param admin Admin address
    /// @param keeper Keeper address (for updating Merkle roots)
    /// @param upgrader Upgrader address
    function initialize(
        address admin,
        address keeper,
        address upgrader
    ) external initializer {
        if (admin == address(0) || keeper == address(0) || upgrader == address(0)) revert ZeroAddress();

        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        active = true;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);
        _grantRole(KEEPER_ROLE, keeper);
        _grantRole(UPGRADER_ROLE, upgrader);
    }

    // =============================================================================
    // UUPS Upgrade
    // =============================================================================

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {
        emit ActivityModuleUpgraded(newImplementation, block.timestamp);
    }

    // =============================================================================
    // Internal Helper Functions
    // =============================================================================

    /// @notice Compute Merkle leaf for a user's earned points
    /// @param user User address
    /// @param totalEarned Total cumulative earned points
    /// @return Merkle leaf hash
    function _computeLeaf(address user, uint256 totalEarned) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(user, totalEarned))));
    }

    // =============================================================================
    // View Functions - IPointsModule Implementation
    // =============================================================================

    /// @notice Get points for a user
    /// @dev Returns only claimed points; unclaimed points require off-chain query
    /// @param user User address
    /// @return Claimed points
    function getPoints(address user) external view override returns (uint256) {
        return claimedPoints[user];
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

    /// @notice Verify a claim without executing it
    /// @param user User address
    /// @param totalEarned Total cumulative earned points in Merkle tree
    /// @param proof Merkle proof
    /// @return valid Whether the proof is valid
    /// @return claimable Amount that can be claimed
    function verifyClaim(
        address user,
        uint256 totalEarned,
        bytes32[] calldata proof
    ) public view returns (bool valid, uint256 claimable) {
        if (merkleRoot == bytes32(0)) return (false, 0);

        bytes32 leaf = _computeLeaf(user, totalEarned);
        valid = MerkleProof.verify(proof, merkleRoot, leaf);

        if (valid && totalEarned > claimedPoints[user]) {
            claimable = totalEarned - claimedPoints[user];
        }
    }

    /// @notice Get root history length
    function getRootHistoryLength() external view returns (uint256) {
        return rootHistory.length;
    }

    /// @notice Get root at specific index
    function getRootAt(uint256 index) external view returns (bytes32 root, uint256 timestamp) {
        root = rootHistory[index];
        timestamp = rootTimestamp[root];
    }

    /// @notice Get user's claim status
    /// @param user User address
    /// @return claimed Amount already claimed
    /// @return lastClaimTime Timestamp (approximated from root updates)
    function getUserClaimStatus(address user)
        external
        view
        returns (uint256 claimed, uint256 lastClaimTime)
    {
        claimed = claimedPoints[user];
        // Note: We don't track individual claim times, return root timestamp as approximation
        if (merkleRoot != bytes32(0)) {
            lastClaimTime = rootTimestamp[merkleRoot];
        }
    }

    // =============================================================================
    // User Functions
    // =============================================================================

    /// @notice Claim points using Merkle proof
    /// @param totalEarned Total cumulative earned points (from Merkle tree)
    /// @param proof Merkle proof
    function claim(
        uint256 totalEarned,
        bytes32[] calldata proof
    ) external nonReentrant whenNotPaused {
        if (merkleRoot == bytes32(0)) revert MerkleRootNotSet();

        // Verify proof
        bytes32 leaf = _computeLeaf(msg.sender, totalEarned);
        if (!MerkleProof.verify(proof, merkleRoot, leaf)) {
            revert InvalidProof();
        }

        // Calculate claimable amount
        uint256 alreadyClaimed = claimedPoints[msg.sender];
        if (totalEarned <= alreadyClaimed) {
            revert NothingToClaim();
        }

        uint256 toClaim = totalEarned - alreadyClaimed;

        // Update claimed amount
        claimedPoints[msg.sender] = totalEarned;

        emit PointsClaimed(msg.sender, toClaim, totalEarned, currentEpoch);
    }

    /// @notice Batch claim for multiple users (keeper can help users claim)
    /// @dev Users must have signed off-chain or this is for airdrop scenarios
    /// @param users Array of user addresses
    /// @param totalEarnedAmounts Array of total earned amounts
    /// @param proofs Array of Merkle proofs
    function batchClaim(
        address[] calldata users,
        uint256[] calldata totalEarnedAmounts,
        bytes32[][] calldata proofs
    ) external onlyRole(KEEPER_ROLE) whenNotPaused {
        if (merkleRoot == bytes32(0)) revert MerkleRootNotSet();

        uint256 len = users.length;
        require(len == totalEarnedAmounts.length && len == proofs.length, "Length mismatch");

        for (uint256 i = 0; i < len; i++) {
            address user = users[i];
            uint256 totalEarned = totalEarnedAmounts[i];
            bytes32[] calldata proof = proofs[i];

            // Verify proof
            bytes32 leaf = _computeLeaf(user, totalEarned);
            if (!MerkleProof.verify(proof, merkleRoot, leaf)) {
                emit BatchClaimSkipped(user, "InvalidProof");
                continue;
            }

            // Calculate claimable
            uint256 alreadyClaimed = claimedPoints[user];
            if (totalEarned <= alreadyClaimed) {
                emit BatchClaimSkipped(user, "NothingToClaim");
                continue;
            }

            uint256 toClaim = totalEarned - alreadyClaimed;
            claimedPoints[user] = totalEarned;

            emit PointsClaimed(user, toClaim, totalEarned, currentEpoch);
        }
    }

    // =============================================================================
    // Keeper Functions
    // =============================================================================

    /// @notice Internal function to update Merkle root
    function _updateRoot(bytes32 newRoot, uint256 epoch, string calldata label) internal {
        bytes32 oldRoot = merkleRoot;
        merkleRoot = newRoot;

        rootHistory.push(newRoot);
        rootTimestamp[newRoot] = block.timestamp;

        currentEpoch = epoch;
        currentEpochLabel = label;

        emit MerkleRootUpdated(oldRoot, newRoot, epoch, label, block.timestamp);
    }

    /// @notice Update Merkle root (weekly update by keeper)
    /// @param newRoot New Merkle root
    /// @param label Description of this epoch (e.g., "Week 1", "2024-W01")
    function updateMerkleRoot(
        bytes32 newRoot,
        string calldata label
    ) external onlyRole(KEEPER_ROLE) {
        _updateRoot(newRoot, currentEpoch + 1, label);
    }

    /// @notice Update Merkle root with epoch number (for precise control)
    function updateMerkleRootWithEpoch(
        bytes32 newRoot,
        uint256 epoch,
        string calldata label
    ) external onlyRole(KEEPER_ROLE) {
        _updateRoot(newRoot, epoch, label);
    }

    // =============================================================================
    // Admin Functions
    // =============================================================================

    /// @notice Set module active status
    function setActive(bool _active) external onlyRole(ADMIN_ROLE) {
        active = _active;
        emit ModuleActiveStatusUpdated(_active);
    }

    /// @notice Emergency: Reset a user's claimed amount (admin only)
    /// @dev Use with caution, only for fixing errors
    function resetUserClaimed(address user, uint256 newAmount) external onlyRole(ADMIN_ROLE) {
        claimedPoints[user] = newAmount;
    }

    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }
}
