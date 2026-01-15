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
    string public constant VERSION = "1.2.0";

    /// @notice Maximum batch size for claims
    uint256 public constant MAX_BATCH_SIZE = 100;

    /// @notice Time delay before a new Merkle root becomes effective (anti-frontrun)
    uint256 public constant ROOT_DELAY = 24 hours;

    /// @notice Maximum number of roots to keep in history
    uint256 public constant MAX_ROOT_HISTORY = 100;

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

    /// @notice Pending Merkle root (waiting for delay period)
    bytes32 public pendingRoot;

    /// @notice Timestamp when pending root becomes effective
    uint256 public pendingRootEffectiveTime;

    /// @notice Pending epoch number
    uint256 public pendingEpoch;

    /// @notice Pending epoch label
    string public pendingEpochLabel;

    // =============================================================================
    // Events
    // =============================================================================

    event MerkleRootQueued(
        bytes32 indexed newRoot,
        uint256 epoch,
        string label,
        uint256 effectiveTime
    );

    event MerkleRootActivated(
        bytes32 indexed oldRoot,
        bytes32 indexed newRoot,
        uint256 epoch,
        uint256 timestamp
    );

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
    error ArrayLengthMismatch();
    error BatchTooLarge(uint256 size, uint256 max);
    error IndexOutOfBounds(uint256 index, uint256 length);
    error PendingRootNotReady(uint256 currentTime, uint256 effectiveTime);
    error NoPendingRoot();

    // =============================================================================
    // Additional Events
    // =============================================================================

    event UserClaimedReset(address indexed user, uint256 previousAmount, uint256 newAmount, address indexed admin);

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
        if (index >= rootHistory.length) revert IndexOutOfBounds(index, rootHistory.length);
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
        if (len != totalEarnedAmounts.length || len != proofs.length) revert ArrayLengthMismatch();
        if (len > MAX_BATCH_SIZE) revert BatchTooLarge(len, MAX_BATCH_SIZE);

        for (uint256 i = 0; i < len; ) {
            address user = users[i];
            uint256 totalEarned = totalEarnedAmounts[i];
            bytes32[] calldata proof = proofs[i];

            // Verify proof
            bytes32 leaf = _computeLeaf(user, totalEarned);
            if (!MerkleProof.verify(proof, merkleRoot, leaf)) {
                emit BatchClaimSkipped(user, "InvalidProof");
                unchecked { ++i; }
                continue;
            }

            // Calculate claimable
            uint256 alreadyClaimed = claimedPoints[user];
            if (totalEarned <= alreadyClaimed) {
                emit BatchClaimSkipped(user, "NothingToClaim");
                unchecked { ++i; }
                continue;
            }

            uint256 toClaim = totalEarned - alreadyClaimed;
            claimedPoints[user] = totalEarned;

            emit PointsClaimed(user, toClaim, totalEarned, currentEpoch);
            unchecked { ++i; }
        }
    }

    // =============================================================================
    // Keeper Functions
    // =============================================================================

    /// @notice Internal function to activate a pending root
    function _activateRoot() internal {
        bytes32 oldRoot = merkleRoot;
        merkleRoot = pendingRoot;

        // Limit root history growth
        if (rootHistory.length >= MAX_ROOT_HISTORY) {
            // Delete oldest root timestamp to free storage
            delete rootTimestamp[rootHistory[0]];
            // Shift array (gas intensive but maintains history order)
            for (uint256 i = 0; i < rootHistory.length - 1; ) {
                rootHistory[i] = rootHistory[i + 1];
                unchecked { ++i; }
            }
            rootHistory.pop();
        }

        rootHistory.push(pendingRoot);
        rootTimestamp[pendingRoot] = block.timestamp;

        currentEpoch = pendingEpoch;
        currentEpochLabel = pendingEpochLabel;

        emit MerkleRootActivated(oldRoot, pendingRoot, pendingEpoch, block.timestamp);
        emit MerkleRootUpdated(oldRoot, pendingRoot, pendingEpoch, pendingEpochLabel, block.timestamp);

        // Clear pending state
        pendingRoot = bytes32(0);
        pendingRootEffectiveTime = 0;
    }

    /// @notice Queue a new Merkle root (will be effective after ROOT_DELAY)
    /// @param newRoot New Merkle root
    /// @param label Description of this epoch
    function updateMerkleRoot(
        bytes32 newRoot,
        string calldata label
    ) external onlyRole(KEEPER_ROLE) {
        // If there's a pending root that's ready, activate it first
        if (pendingRoot != bytes32(0) && block.timestamp >= pendingRootEffectiveTime) {
            _activateRoot();
        }

        pendingRoot = newRoot;
        pendingEpoch = currentEpoch + 1;
        pendingEpochLabel = label;
        pendingRootEffectiveTime = block.timestamp + ROOT_DELAY;

        emit MerkleRootQueued(newRoot, pendingEpoch, label, pendingRootEffectiveTime);
    }

    /// @notice Queue Merkle root with specific epoch number
    function updateMerkleRootWithEpoch(
        bytes32 newRoot,
        uint256 epoch,
        string calldata label
    ) external onlyRole(KEEPER_ROLE) {
        if (pendingRoot != bytes32(0) && block.timestamp >= pendingRootEffectiveTime) {
            _activateRoot();
        }

        pendingRoot = newRoot;
        pendingEpoch = epoch;
        pendingEpochLabel = label;
        pendingRootEffectiveTime = block.timestamp + ROOT_DELAY;

        emit MerkleRootQueued(newRoot, epoch, label, pendingRootEffectiveTime);
    }

    /// @notice Activate a pending root after the delay period
    function activateRoot() external {
        if (pendingRoot == bytes32(0)) revert NoPendingRoot();
        if (block.timestamp < pendingRootEffectiveTime) {
            revert PendingRootNotReady(block.timestamp, pendingRootEffectiveTime);
        }
        _activateRoot();
    }

    /// @notice Emergency: Immediately activate root (admin only, bypass delay)
    /// @dev Use only in emergencies where delay would cause issues
    function emergencyActivateRoot() external onlyRole(ADMIN_ROLE) {
        if (pendingRoot == bytes32(0)) revert NoPendingRoot();
        _activateRoot();
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
        uint256 previousAmount = claimedPoints[user];
        claimedPoints[user] = newAmount;
        emit UserClaimedReset(user, previousAmount, newAmount, msg.sender);
    }

    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

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
