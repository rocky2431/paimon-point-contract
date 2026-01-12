// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

import {IPenaltyModule} from "./interfaces/IPointsModule.sol";

/// @title PenaltyModule
/// @author Paimon Protocol
/// @notice Module for tracking redemption penalties
/// @dev Uses Merkle tree for off-chain penalty calculation
///      Penalties are calculated off-chain based on RedemptionSettled events
contract PenaltyModule is
    IPenaltyModule,
    Initializable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    // =============================================================================
    // Constants & Roles
    // =============================================================================

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    uint256 public constant BASIS_POINTS = 10000;

    // =============================================================================
    // State Variables
    // =============================================================================

    /// @notice Current Merkle root for penalty data
    bytes32 public penaltyRoot;

    /// @notice Confirmed penalty amounts per user
    /// @dev Updated via Merkle proof verification
    mapping(address => uint256) public confirmedPenalty;

    /// @notice Penalty rate in basis points (e.g., 1000 = 10%)
    /// @dev Used for off-chain calculation reference, actual calculation is off-chain
    uint256 public penaltyRateBps;

    /// @notice History of penalty roots
    bytes32[] public rootHistory;

    /// @notice Root to timestamp mapping
    mapping(bytes32 => uint256) public rootTimestamp;

    /// @notice Current epoch number
    uint256 public currentEpoch;

    // =============================================================================
    // Events
    // =============================================================================

    event PenaltyRootUpdated(
        bytes32 indexed oldRoot,
        bytes32 indexed newRoot,
        uint256 epoch,
        uint256 timestamp
    );
    event PenaltyConfirmed(
        address indexed user,
        uint256 previousPenalty,
        uint256 newPenalty,
        uint256 epoch
    );
    event PenaltyRateUpdated(uint256 oldRate, uint256 newRate);
    event PenaltyModuleUpgraded(address indexed newImplementation, uint256 timestamp);
    event BatchSyncSkipped(address indexed user, string reason);

    // =============================================================================
    // Errors
    // =============================================================================

    error ZeroAddress();
    error InvalidProof();
    error PenaltyRootNotSet();
    error InvalidPenaltyRate();

    // =============================================================================
    // Constructor & Initializer
    // =============================================================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the contract
    /// @param admin Admin address
    /// @param keeper Keeper address
    /// @param upgrader Upgrader address
    /// @param _penaltyRateBps Initial penalty rate in basis points
    function initialize(
        address admin,
        address keeper,
        address upgrader,
        uint256 _penaltyRateBps
    ) external initializer {
        if (admin == address(0) || keeper == address(0) || upgrader == address(0)) revert ZeroAddress();
        if (_penaltyRateBps > BASIS_POINTS) revert InvalidPenaltyRate();

        __AccessControl_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        penaltyRateBps = _penaltyRateBps;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);
        _grantRole(KEEPER_ROLE, keeper);
        _grantRole(UPGRADER_ROLE, upgrader);
    }

    // =============================================================================
    // UUPS Upgrade
    // =============================================================================

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {
        emit PenaltyModuleUpgraded(newImplementation, block.timestamp);
    }

    // =============================================================================
    // Internal Helper Functions
    // =============================================================================

    /// @notice Compute Merkle leaf for a user's penalty
    /// @param user User address
    /// @param totalPenalty Total cumulative penalty
    /// @return Merkle leaf hash
    function _computeLeaf(address user, uint256 totalPenalty) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(user, totalPenalty))));
    }

    // =============================================================================
    // View Functions - IPenaltyModule Implementation
    // =============================================================================

    /// @notice Get penalty points for a user
    /// @param user User address
    /// @return Confirmed penalty points
    function getPenalty(address user) external view override returns (uint256) {
        return confirmedPenalty[user];
    }

    // =============================================================================
    // View Functions - Additional
    // =============================================================================

    /// @notice Verify a penalty proof
    /// @param user User address
    /// @param totalPenalty Total cumulative penalty
    /// @param proof Merkle proof
    /// @return valid Whether proof is valid
    function verifyPenalty(
        address user,
        uint256 totalPenalty,
        bytes32[] calldata proof
    ) public view returns (bool valid) {
        if (penaltyRoot == bytes32(0)) return false;

        bytes32 leaf = _computeLeaf(user, totalPenalty);
        return MerkleProof.verify(proof, penaltyRoot, leaf);
    }

    /// @notice Get root history length
    function getRootHistoryLength() external view returns (uint256) {
        return rootHistory.length;
    }

    /// @notice Calculate penalty for a redemption amount (reference only)
    /// @param redemptionAmount Redemption amount in base units
    /// @return Penalty amount
    function calculatePenalty(uint256 redemptionAmount) external view returns (uint256) {
        return (redemptionAmount * penaltyRateBps) / BASIS_POINTS;
    }

    // =============================================================================
    // Sync Functions
    // =============================================================================

    /// @notice Sync user's penalty using Merkle proof
    /// @dev Can be called by keeper or user themselves
    /// @param user User address
    /// @param totalPenalty Total cumulative penalty from Merkle tree
    /// @param proof Merkle proof
    function syncPenalty(
        address user,
        uint256 totalPenalty,
        bytes32[] calldata proof
    ) external whenNotPaused {
        if (penaltyRoot == bytes32(0)) revert PenaltyRootNotSet();

        // Verify proof
        bytes32 leaf = _computeLeaf(user, totalPenalty);
        if (!MerkleProof.verify(proof, penaltyRoot, leaf)) {
            revert InvalidProof();
        }

        // Only update if new penalty is higher (penalties only increase)
        if (totalPenalty > confirmedPenalty[user]) {
            uint256 previousPenalty = confirmedPenalty[user];
            confirmedPenalty[user] = totalPenalty;

            emit PenaltyConfirmed(user, previousPenalty, totalPenalty, currentEpoch);
        }
    }

    /// @notice Batch sync penalties for multiple users
    /// @param users Array of user addresses
    /// @param totalPenalties Array of total penalties
    /// @param proofs Array of Merkle proofs
    function batchSyncPenalty(
        address[] calldata users,
        uint256[] calldata totalPenalties,
        bytes32[][] calldata proofs
    ) external onlyRole(KEEPER_ROLE) whenNotPaused {
        if (penaltyRoot == bytes32(0)) revert PenaltyRootNotSet();

        uint256 len = users.length;
        require(len == totalPenalties.length && len == proofs.length, "Length mismatch");

        for (uint256 i = 0; i < len; i++) {
            address user = users[i];
            uint256 totalPenalty = totalPenalties[i];
            bytes32[] calldata proof = proofs[i];

            // Verify proof
            bytes32 leaf = _computeLeaf(user, totalPenalty);
            if (!MerkleProof.verify(proof, penaltyRoot, leaf)) {
                emit BatchSyncSkipped(user, "InvalidProof");
                continue;
            }

            // Only update if higher
            if (totalPenalty > confirmedPenalty[user]) {
                uint256 previousPenalty = confirmedPenalty[user];
                confirmedPenalty[user] = totalPenalty;

                emit PenaltyConfirmed(user, previousPenalty, totalPenalty, currentEpoch);
            } else {
                emit BatchSyncSkipped(user, "PenaltyNotHigher");
            }
        }
    }

    // =============================================================================
    // Keeper Functions
    // =============================================================================

    /// @notice Update penalty Merkle root
    /// @param newRoot New Merkle root
    function updatePenaltyRoot(bytes32 newRoot) external onlyRole(KEEPER_ROLE) {
        bytes32 oldRoot = penaltyRoot;
        penaltyRoot = newRoot;

        rootHistory.push(newRoot);
        rootTimestamp[newRoot] = block.timestamp;
        currentEpoch++;

        emit PenaltyRootUpdated(oldRoot, newRoot, currentEpoch, block.timestamp);
    }

    // =============================================================================
    // Admin Functions
    // =============================================================================

    /// @notice Set penalty rate
    /// @param newRateBps New rate in basis points (max 10000 = 100%)
    function setPenaltyRate(uint256 newRateBps) external onlyRole(ADMIN_ROLE) {
        if (newRateBps > BASIS_POINTS) revert InvalidPenaltyRate();

        uint256 oldRate = penaltyRateBps;
        penaltyRateBps = newRateBps;

        emit PenaltyRateUpdated(oldRate, newRateBps);
    }

    /// @notice Admin override: Set user's confirmed penalty
    /// @dev Use with caution, only for fixing errors
    function setUserPenalty(address user, uint256 penalty) external onlyRole(ADMIN_ROLE) {
        uint256 previousPenalty = confirmedPenalty[user];
        confirmedPenalty[user] = penalty;

        emit PenaltyConfirmed(user, previousPenalty, penalty, currentEpoch);
    }

    /// @notice Batch set penalties (admin function for migration/fixing)
    function batchSetPenalties(
        address[] calldata users,
        uint256[] calldata penalties
    ) external onlyRole(ADMIN_ROLE) {
        uint256 len = users.length;
        require(len == penalties.length, "Length mismatch");

        for (uint256 i = 0; i < len; i++) {
            uint256 previousPenalty = confirmedPenalty[users[i]];
            confirmedPenalty[users[i]] = penalties[i];

            emit PenaltyConfirmed(users[i], previousPenalty, penalties[i], currentEpoch);
        }
    }

    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }
}
