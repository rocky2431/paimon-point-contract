# Paimon Points System

A modular on-chain points system for the Paimon Protocol, built with Solidity 0.8.24 and Foundry.

## Overview

The Paimon Points System rewards users for various activities including PPT holding, LP providing, and trading. Points can be redeemed for tokens based on configurable exchange rates.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                        PointsHub                            │
│              (Central Aggregation & Redemption)             │
└─────────────────────────────────────────────────────────────┘
        │              │              │              │
        ▼              ▼              ▼              ▼
┌─────────────┐ ┌─────────────┐ ┌─────────────┐ ┌─────────────┐
│  Holding    │ │     LP      │ │  Activity   │ │   Penalty   │
│   Module    │ │   Module    │ │   Module    │ │   Module    │
│             │ │             │ │             │ │             │
│ PPT Holding │ │ LP Rewards  │ │  Trading    │ │ Redemption  │
│   Rewards   │ │ Multi-Pool  │ │  Rewards    │ │  Penalties  │
└─────────────┘ └─────────────┘ └─────────────┘ └─────────────┘
```

## Contracts

| Contract | Description |
|----------|-------------|
| `PointsHub.sol` | Central hub for aggregating points from all modules and handling redemption |
| `HoldingModule.sol` | Rewards for holding PPT tokens (Synthetix-style algorithm) |
| `LPModule.sol` | Rewards for providing liquidity (multi-pool support with multipliers) |
| `ActivityModule.sol` | Rewards for trading activities (Merkle proof verification) |
| `PenaltyModule.sol` | Tracks redemption penalties (Merkle proof verification) |

## Features

- **UUPS Upgradeable**: All contracts use OpenZeppelin's UUPS proxy pattern
- **Role-Based Access**: Admin, Keeper, and Upgrader roles for secure operations
- **Gas Efficient**: Checkpoint mechanism for batch updates
- **Merkle Proofs**: Off-chain computation with on-chain verification
- **Multi-Pool LP**: Support for multiple LP pools with different multipliers

## Installation

```bash
# Clone with submodules
git clone --recursive https://github.com/rocky2431/paimon-point-contract.git
cd paimon-point-contract

# Or if already cloned without submodules
git submodule update --init --recursive

# Build
forge build

# Test
forge test

# Gas report
forge test --gas-report
```

## Dependencies

- [OpenZeppelin Contracts v5.0.2](https://github.com/OpenZeppelin/openzeppelin-contracts)
- [OpenZeppelin Contracts Upgradeable v5.0.2](https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable)
- [Forge Std](https://github.com/foundry-rs/forge-std)

## Usage

### Deployment Order

1. Deploy implementation contracts
2. Deploy proxy contracts pointing to implementations
3. Initialize each module with appropriate roles
4. Register modules in PointsHub
5. Configure parameters (rates, multipliers, etc.)

### Roles

| Role | Permissions |
|------|-------------|
| `ADMIN_ROLE` | Configure parameters, pause/unpause, register modules |
| `KEEPER_ROLE` | Update Merkle roots, trigger checkpoints |
| `UPGRADER_ROLE` | Upgrade contract implementations |

### Points Calculation

**Holding Module** (Synthetix-style):
```
userPoints = balance × (currentPointsPerShare - userPointsPerSharePaid)
```

**LP Module**:
```
poolPoints = lpBalance × (pointsPerLP - userPointsPerLPPaid) × multiplier
```

**Activity Module**: Computed off-chain, verified via Merkle proof

### Redemption

```solidity
// Check claimable points
uint256 claimable = pointsHub.getClaimablePoints(user);

// Redeem points for tokens
pointsHub.redeem(pointsAmount);
```

## Configuration

### foundry.toml

```toml
[profile.default]
src = "src"
out = "out"
libs = ["lib"]
solc_version = "0.8.24"
optimizer = true
optimizer_runs = 200
```

### Environment Variables

```bash
# For deployment scripts
PRIVATE_KEY=your_private_key
RPC_URL=your_rpc_url
ETHERSCAN_API_KEY=your_api_key
```

## Security

- All contracts are upgradeable with proper access control
- Keeper functions are rate-limited by role
- Merkle proofs prevent unauthorized claims
- Reentrancy protection on all state-changing functions

## License

MIT

## Links

- [Design Documentation](./POINTS_SYSTEM_DESIGN.md)
- [Paimon Protocol](https://paimon.finance)
