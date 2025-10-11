# Yearn V3 Yield Basis Strategies

Yearn V3 integration with Yield Basis protocol, providing leveraged BTC liquidity positions without impermanent loss.

## Overview

This repository contains two complementary Yearn V3 strategies for the Yield Basis protocol:

- **YBRouterStrategy**: Converts BTC → LT tokens and deposits into LT Vault
- **YBGaugeStrategy**: Stakes LT tokens in gauges to earn YB emissions

### Architecture

```
BTC Vault (User-Facing)
    ↓
YBRouterStrategy: BTC → LT → LT Vault
    ↓
LT Vault (Internal)
    ↓
YBGaugeStrategy: LT → Gauge Staking → YB Rewards
```

**Key Benefits**:
- 2x leveraged BTC exposure without IL
- Tracks BTC price 1:1
- Earns Curve trading fees
- Earns YB governance token emissions

## Documentation

- **[YIELD_BASIS_ARCHITECTURE.md](./YIELD_BASIS_ARCHITECTURE.md)** - Complete architecture guide
  - Nested vault design
  - Strategy implementations
  - Deployment guide
  - Testing guide

- **[CLAUDE.md](./CLAUDE.md)** - General Yearn V3 strategy development guidelines

---

## Quick Start

### Requirements

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- [Node.js](https://nodejs.org/en/download/package-manager/)

NOTE: If you are on a windows machine it is recommended to use [WSL](https://learn.microsoft.com/en-us/windows/wsl/install)

### Clone & Install

```sh
git clone --recursive https://github.com/yearn/tokenized-strategy-foundry-mix
cd tokenized-strategy-foundry-mix
yarn
```

### Environment Setup

1. Copy `.env.example` to `.env`
2. Add your `ETH_RPC_URL` (e.g., from [Ankr](https://www.ankr.com/rpc/) or [Infura](https://infura.io/))

```sh
cp .env.example .env
# Edit .env and add your RPC URL
```

### Build

```sh
make build
```

### Test

```sh
# Run all tests
make test

# Run with traces (useful for debugging)
make trace

# Run specific test file
make test-contract contract=GaugeStrategyTest

# Generate coverage report
make coverage
make coverage-html  # Requires lcov
```

## Contracts

### Strategies

- **YBRouterStrategy** (`src/YBRouterStrategy.sol`)
  - Handles BTC → LT conversion with decimal scaling
  - Manages vault deposits/withdrawals
  - Slippage protection on LT operations

- **YBGaugeStrategy** (`src/YBGaugeStrategy.sol`)
  - Simple LT → Gauge staking
  - Claims and sells YB rewards
  - Supports auction or direct swap

### Factory

- **YBVaultFactory** (`src/YBVaultFactory.sol`)
  - Deploys both strategy types
  - Configures management, fees, keepers
  - Tracks deployments

### Supporting

- **RewardsSwapper** (`src/RewardsSwapper.sol`)
  - Direct DEX swaps for reward tokens
  - Configurable routes per token

## Deployment

See [YIELD_BASIS_ARCHITECTURE.md - Deployment Guide](./YIELD_BASIS_ARCHITECTURE.md#deployment-guide) for complete deployment instructions.

### Quick Deploy Steps

1. Deploy YBVaultFactory
2. For each BTC asset (WBTC, cbBTC, tBTC):
   - Deploy LT Vault
   - Deploy Gauge Strategy → attach to LT Vault
   - Deploy BTC Vault
   - Deploy Router Strategy → attach to BTC Vault

## Supported Assets

| Asset | LT Token | Gauge | Status |
|-------|----------|-------|--------|
| WBTC  | yb-WBTC  | WBTC Staker | ✅ Ready |
| cbBTC | yb-cbBTC | cbBTC Staker | ✅ Ready |
| tBTC  | yb-tBTC  | tBTC Staker | ✅ Ready |

## Testing

### Test Files
- ✅ `GaugeStrategy.t.sol` - LT staking and rewards
- 🚧 `RouterStrategy.t.sol` - BTC/LT conversion (TODO)
- ✅ Factory deployment tests
- ✅ Reward swapper tests

All tests run against mainnet fork for real contract compatibility.

### Testing Tips

Due to the permissionless nature of tokenized strategies, all tests are written without integration with any meta vault. The strategies utilize the ERC-4626 standard and can be plugged into any vault with the same `asset`.

Example test pattern:
```solidity
Strategy _strategy = new Strategy(asset, name);
IStrategyInterface strategy = IStrategyInterface(address(_strategy));
```

See [Foundry Testing Tips](https://book.getfoundry.sh/forge/tests.html) for more information.

## Security Considerations

### Slippage Protection
- Router strategy: 0.5% default on LT deposits/withdrawals
- Accounts for Curve pool fees and dynamic admin fees

### Emergency Procedures
- LT can be "killed" by Yield Basis governance
- `emergency_withdraw()` available when killed
- Strategies block deposits/reports when killed

### Access Control
- **Management**: Configuration changes
- **Keeper**: Report triggers, auction kicking
- **Emergency Admin**: Shutdown procedures

## Audit Status

⚠️ **Not Yet Audited** - Do not use in production without audit.

## CI/CD

This repo uses [GitHub Actions](.github/workflows):
- **Lint**: Code style checks
- **Test**: Full test suite on fork
- **Slither**: Static analysis
- **Coverage**: Test coverage reporting

### Setup CI
1. Add `ETH_RPC_URL` secret to GitHub repo
2. Add `GH_TOKEN` for coverage PR comments (optional)

See [GitHub Actions docs](https://docs.github.com/en/codespaces/managing-codespaces-for-your-organization/managing-encrypted-secrets-for-your-repository-and-organization-for-github-codespaces#adding-secrets-for-a-repository) for setup.

### Suppress Slither Warnings
Add comment before issue: `//slither-disable-next-line DETECTOR_NAME`

See [Slither Detector Docs](https://github.com/crytic/slither/wiki/Detector-Documentation) for detector names.

## Contract Verification

After deployment, verify TokenizedStrategy proxy functions:

1. Navigate to contract on Etherscan
2. Click "More Options" → "is this a proxy?"
3. Click "Verify" → "Save"

This adds external `TokenizedStrategy` functions to the contract interface.

## Resources

- [Yield Basis Documentation](https://docs.yieldbasis.com/)
- [Yearn V3 Documentation](https://docs.yearn.fi/developers/v3/overview)
- [Yearn V3 Strategy Writing Guide](https://docs.yearn.fi/developers/v3/strategy_writing_guide)
- [TokenizedStrategy Repo](https://github.com/yearn/tokenized-strategy)

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Add tests
5. Submit a pull request

## License

AGPL-3.0

## Support

For questions or issues:
- Create a GitHub issue
- Join Yearn Discord: https://discord.yearn.fi
