# Yield Basis Strategy Architecture

This document describes the Yield Basis integration for Yearn V3, including the nested vault architecture and both Router and Gauge strategies.

## Table of Contents
1. [Overview](#overview)
2. [Architecture Design](#architecture-design)
3. [YBRouterStrategy](#ybrouterstrategy)
4. [YBGaugeStrategy](#ybgaugestrategy)
5. [Factory Deployment](#factory-deployment)
6. [Testing](#testing)
7. [Deployment Guide](#deployment-guide)

---

## Overview

### What is Yield Basis?

Yield Basis is a DeFi protocol that provides leveraged liquidity positions without impermanent loss. Key components:

- **LT Tokens (Liquidity Tokens)**: ERC4626-like tokens that represent leveraged exposure to Curve LP positions
  - 2x leverage on BTC/crvUSD Curve pools
  - Tracks BTC price 1:1
  - Earns trading fees from the Curve pool
  - 18 decimals (regardless of underlying asset)

- **Liquidity Gauges**: Staking contracts for LT tokens
  - Stake LT tokens to earn YB governance token emissions
  - ERC4626-compatible interface

- **Dynamic Admin Fees**: Fee structure based on staking ratio
  - More staking → higher admin fee → lower yield for unstaked
  - Less staking → lower admin fee → higher yield for unstaked

### Yearn Integration Strategy

**Nested Vault Architecture** - Two-tier system for maximum composability:

```
┌─────────────────────────────────────────────────────────────┐
│                        BTC VAULT                            │
│                     (User-Facing)                           │
│                                                             │
│  Users deposit: WBTC, cbBTC, tBTC                          │
│         │                                                   │
│         ▼                                                   │
│  ┌──────────────────────────────┐                         │
│  │   YBRouterStrategy           │                         │
│  │   - Converts BTC → LT        │                         │
│  │   - Deposits LT to LT Vault  │                         │
│  └──────────────────────────────┘                         │
│         │                                                   │
│         ▼                                                   │
└─────────────────────────────────────────────────────────────┘
         │
         ▼
┌─────────────────────────────────────────────────────────────┐
│                         LT VAULT                            │
│                      (Internal)                             │
│                                                             │
│  Holds: yb-WBTC (LT tokens)                                │
│         │                                                   │
│         ▼                                                   │
│  ┌──────────────────────────────┐                         │
│  │   YBGaugeStrategy            │                         │
│  │   - Stakes LT in Gauge       │                         │
│  │   - Earns YB emissions       │                         │
│  │   - Sells YB for more LT     │                         │
│  └──────────────────────────────┘                         │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

**Why This Architecture?**

1. **Separation of Concerns**:
   - Router Strategy handles BTC ↔ LT conversion complexity
   - Gauge Strategy focuses purely on LT staking and YB rewards

2. **Composability**:
   - BTC Vault exposes familiar BTC interface to users
   - LT Vault can be used by other strategies or directly

3. **Decimal Handling**:
   - Router Strategy manages BTC (8 decimals) ↔ LT (18 decimals) conversion
   - Gauge Strategy operates entirely in 18 decimals (LT)

4. **Independent Yield Sources**:
   - Trading fees accrue via LT price appreciation
   - YB emissions from gauge staking

---

## Architecture Design

### Key Differences from Traditional Strategies

**Traditional Single-Vault Approach** (NOT used):
```
BTC Vault
  ├─ LT Strategy (holds LT, earns fees)
  └─ Gauge Strategy (stakes LT, earns YB)
```

**Our Nested-Vault Approach**:
```
BTC Vault → Router Strategy → LT Vault → Gauge Strategy
```

**Why Nested?**

1. **Asset Type Mismatch**: Router works with BTC, Gauge works with LT
2. **Capital Efficiency**: All LT goes to gauge staking (no idle LT)
3. **Simplified Logic**: Each strategy handles one asset type
4. **Testing**: Independent test suites for each strategy type

### Flow Diagrams

#### Deposit Flow
```
User deposits 1 WBTC into BTC Vault
         ↓
BTC Vault mints shares, calls Router Strategy
         ↓
Router Strategy._deployFunds(1 WBTC)
  1. Calculate debt needed (≈ 1 WBTC worth of crvUSD)
  2. Call LT.deposit(1 WBTC, debt, minShares) → receive ~1e18 LT
  3. Call yVault.deposit(1e18 LT) → receive vault shares
         ↓
LT Vault receives LT, calls Gauge Strategy
         ↓
Gauge Strategy._deployFunds(1e18 LT)
  1. Call gauge.deposit(1e18 LT) → stake in gauge
```

#### Withdrawal Flow
```
User withdraws from BTC Vault
         ↓
BTC Vault burns shares, calls Router Strategy
         ↓
Router Strategy._freeFunds(amount)
  1. Calculate vault shares needed
  2. Call yVault.redeem(shares) → receive LT
  3. Call LT.withdraw(ltAmount, minAssets) → receive WBTC
         ↓
LT Vault redeems, calls Gauge Strategy
         ↓
Gauge Strategy._freeFunds(ltAmount)
  1. Call gauge.redeem(shares) → unstake from gauge
```

#### Harvest Flow
```
Keeper calls BTC Vault.report()
         ↓
Router Strategy._harvestAndReport()
  1. Check yVault balance → convert to BTC value
  2. Return totalAssets (vault BTC value + loose BTC)
         ↓
LT Vault harvests
         ↓
Gauge Strategy._harvestAndReport()
  1. Claim YB rewards from gauge
  2. Sell YB for LT (via auction or swapper)
  3. Return totalAssets (gauge LT + loose LT)
```

---

## YBRouterStrategy

### Purpose

Converts BTC deposits into LT tokens and deposits them into an LT Vault (ERC4626).

**Asset**: BTC (WBTC, cbBTC, tBTC) - variable decimals (8 for WBTC)
**Destination**: LT Vault (ERC4626) holding LT tokens
**Complexity**: Handles decimal conversion, debt calculation, vault interactions

### Key Components

```solidity
contract YBRouterStrategy is BaseHealthCheck {
    // Immutable references
    ILT public immutable ltToken;           // e.g., yb-WBTC
    ERC4626 public immutable yVault;        // LT Vault
    ICurveCryptoPool public immutable cryptopool;

    // Configuration
    uint256 public maxDepositSlippage;      // 0.5% default
    uint256 public maxWithdrawSlippage;     // 0.5% default

    // Decimals handling
    uint8 public immutable assetDecimals;   // 8 for WBTC
}
```

### Core Functions

#### `_deployFunds(uint256 _amount)`

Deploys BTC into LT token and then into the LT Vault.

```solidity
function _deployFunds(uint256 _amount) internal override {
    if (TokenizedStrategy.isShutdown()) return;

    // 1. Calculate debt needed (approximately equal USD value)
    uint256 debtNeeded = _calculateDebtForDeposit(_amount);

    // 2. Calculate expected LT shares with slippage protection
    uint256 expectedShares = assetToLt(_amount);
    uint256 minShares = (expectedShares * (MAX_BPS - maxDepositSlippage)) / MAX_BPS;

    // 3. Deposit BTC to LT token
    ltToken.deposit(_amount, debtNeeded, minShares, address(this));

    // 4. Deposit LT to yVault
    uint256 ltBalance = ltToken.balanceOf(address(this));
    yVault.deposit(ltBalance, address(this));
}
```

**Critical Points**:
- Trading fees are charged on LT deposit (Curve pool fees + admin fees)
- `debtNeeded` calculated from pool balance ratio
- LT is immediately deposited to vault (no idle LT)

#### `_freeFunds(uint256 _amount)`

Withdraws BTC by redeeming from vault then withdrawing from LT.

```solidity
function _freeFunds(uint256 _amount) internal override {
    require(!ltToken.is_killed(), "LT is Killed");

    uint256 vaultBalance = yVault.balanceOf(address(this));
    if (vaultBalance == 0) return;

    // Step 1: Calculate vault shares needed
    uint256 vaultSharesToRedeem = _calculateVaultSharesToWithdraw(_amount, vaultBalance);

    // Step 2: Redeem from yVault to get LT back
    uint256 ltReceived = yVault.redeem(vaultSharesToRedeem, address(this), address(this));

    // Step 3: Withdraw BTC from LT token
    uint256 expectedAssets = ltToken.preview_withdraw(ltReceived);
    uint256 minAssets = (expectedAssets * (MAX_BPS - maxWithdrawSlippage)) / MAX_BPS;

    ltToken.withdraw(ltReceived, minAssets, address(this));
}
```

**Critical Points**:
- Must redeem from vault BEFORE withdrawing from LT
- Trading fees charged on LT withdrawal
- Slippage protection on both steps

#### `_harvestAndReport()`

Reports total BTC value held via the LT Vault.

```solidity
function _harvestAndReport() internal override returns (uint256 _totalAssets) {
    require(!ltToken.is_killed(), "LT is Killed");

    // Check vault shares (our LT is in the vault)
    uint256 vaultShares = yVault.balanceOf(address(this));
    uint256 ltInVault = yVault.convertToAssets(vaultShares);

    // Convert LT amount to BTC value
    uint256 btcValueInVault = ltToAsset(ltInVault);

    _totalAssets = btcValueInVault + asset.balanceOf(address(this));
}
```

**Critical Points**:
- LT is in vault, not held directly by strategy
- Must convert: vault shares → LT amount → BTC value
- Includes loose BTC in total

### Decimal Conversion Helpers

```solidity
/**
 * Convert LT (18 decimals) to BTC (asset decimals)
 */
function ltToAsset(uint256 _ltAmount) public view returns (uint256) {
    return (_ltAmount * ltToken.pricePerShare()) / (10 ** (36 - assetDecimals));
}

/**
 * Convert BTC (asset decimals) to LT (18 decimals)
 */
function assetToLt(uint256 _assetAmount) public view returns (uint256) {
    uint256 pricePerShare = ltToken.pricePerShare();
    if (pricePerShare == 0) return 0;
    return (_assetAmount * (10 ** (36 - assetDecimals))) / pricePerShare;
}
```

**Formula Breakdown**:
- `pricePerShare`: 18 decimal ratio (1e18 = 1.0)
- For WBTC (8 decimals): scaling factor = 10^(36-8) = 10^28
- Example: 1 WBTC (1e8) → ~1e18 LT (at 1:1 price)

### Debt Calculation

```solidity
function _calculateDebtForDeposit(uint256 _assetAmount) internal view returns (uint256 debtAmount) {
    uint256 crvUsdBalance = cryptopool.balances(0); // crvUSD
    uint256 btcBalance = cryptopool.balances(1);    // BTC

    // Debt should equal asset USD value for balanced add_liquidity
    if (btcBalance > 0) {
        debtAmount = (_assetAmount * crvUsdBalance) / btcBalance;
    } else {
        debtAmount = _assetAmount; // Fallback
    }
}
```

**Why This Works**:
- LT.deposit() adds liquidity to Curve pool
- Balanced add requires equal USD values of both tokens
- Current pool ratio approximates the exchange rate

---

## YBGaugeStrategy

### Purpose

Stakes LT tokens in Yield Basis gauge to earn YB governance token emissions.

**Asset**: LT tokens (18 decimals)
**Destination**: Liquidity Gauge (ERC4626-compatible)
**Complexity**: Minimal - direct staking, reward claiming, selling

### Key Components

```solidity
contract YBGaugeStrategy is BaseHealthCheck {
    // Immutable references
    ILiquidityGauge public immutable gauge;
    ERC20 public immutable ybToken;
    IGaugeController public immutable gaugeController;

    // Reward configuration
    RewardsSwapper public rewardsSwapper;
    address public auction;
    mapping(address => RewardTokenConfig) public rewardTokenConfigs;
}
```

### Core Functions

#### `_deployFunds(uint256 _amount)`

Direct LT → Gauge staking.

```solidity
function _deployFunds(uint256 _amount) internal override {
    if (TokenizedStrategy.isShutdown()) return;
    if (_amount == 0) return;

    // Direct stake: LT → Gauge
    gauge.deposit(_amount, address(this));
}
```

**Simplicity**: No debt calculation, no decimal conversion, no slippage protection needed.

#### `_freeFunds(uint256 _amount)`

Direct Gauge → LT unstaking.

```solidity
function _freeFunds(uint256 _amount) internal override {
    uint256 gaugeShares = gauge.balanceOf(address(this));
    if (gaugeShares == 0) return;

    // Calculate gauge shares needed
    uint256 sharesToRedeem = gauge.convertToShares(_amount);
    sharesToRedeem = sharesToRedeem > gaugeShares ? gaugeShares : sharesToRedeem;

    // Unstake from gauge
    gauge.redeem(sharesToRedeem, address(this), address(this));
}
```

#### `_harvestAndReport()`

Claim YB rewards, sell for LT, report total LT.

```solidity
function _harvestAndReport() internal override returns (uint256 _totalAssets) {
    // Claim and sell YB rewards
    if (!TokenizedStrategy.isShutdown()) {
        _harvestRewards();
    }

    // Convert gauge shares to LT equivalent
    uint256 gaugeShares = gauge.balanceOf(address(this));
    uint256 ltInGauge = gauge.convertToAssets(gaugeShares);

    _totalAssets = ltInGauge + asset.balanceOf(address(this));
}
```

### Reward Handling

```solidity
function _harvestRewards() internal {
    for (uint256 i = 0; i < allRewardTokens.length; i++) {
        address token = allRewardTokens[i];
        RewardTokenConfig memory config = rewardTokenConfigs[token];

        // Claim if configured
        if (config.shouldClaim) {
            gauge.claim(token, address(this));
        }

        uint256 amount = ERC20(token).balanceOf(address(this));

        // Sell if above minimum
        if (config.swapType != SwapType.NULL && amount > config.minAmountToSell) {
            _swapRewardForAsset(token, amount);
        }
    }
}
```

**Reward Types**:
- **YB Token**: Primary reward from gauge emissions
- **Future Tokens**: Extensible via `addRewardToken()`

**Sell Methods**:
- **AUCTION**: Dutch auction for better price discovery
- **SWAP**: Direct DEX swap via RewardsSwapper

---

## Factory Deployment

### YBVaultFactory

The factory supports deploying both strategy types independently.

```solidity
contract YBVaultFactory {
    // Deploy Router Strategy for BTC Vault
    function deployRouterStrategy(
        address _asset,        // WBTC, cbBTC, etc.
        address _ltToken,      // yb-WBTC
        address _ltVault       // LT Vault (ERC4626)
    ) external returns (address strategy);

    // Deploy Gauge Strategy for LT Vault
    function deployGaugeStrategy(
        address _ltToken,      // LT is the asset!
        address _gauge         // Liquidity Gauge
    ) external returns (address strategy);
}
```

### Deployment Flow

#### Step 1: Deploy LT Vault

First, deploy a Yearn V3 vault for the LT token:

```solidity
// Using Yearn V3 VaultFactory
address ltVault = vaultFactory.deploy_new_vault(
    ltToken,           // yb-WBTC
    "yb-WBTC Vault",
    "yvLT-WBTC",
    management,
    PROFIT_MAX_UNLOCK_TIME
);
```

#### Step 2: Deploy Gauge Strategy

Deploy and attach gauge strategy to LT Vault:

```solidity
address gaugeStrategy = ybFactory.deployGaugeStrategy(
    ltToken,  // yb-WBTC (LT is the asset!)
    gauge     // WBTC Liquidity Gauge
);

// Attach to LT Vault
IVault(ltVault).add_strategy(gaugeStrategy);
```

#### Step 3: Deploy BTC Vault

Deploy Yearn V3 vault for BTC:

```solidity
address btcVault = vaultFactory.deploy_new_vault(
    wbtc,              // WBTC
    "WBTC YB Vault",
    "yvWBTC-YB",
    management,
    PROFIT_MAX_UNLOCK_TIME
);
```

#### Step 4: Deploy Router Strategy

Deploy and attach router strategy to BTC Vault:

```solidity
address routerStrategy = ybFactory.deployRouterStrategy(
    wbtc,      // WBTC
    ltToken,   // yb-WBTC
    ltVault    // LT Vault address from Step 1
);

// Attach to BTC Vault
IVault(btcVault).add_strategy(routerStrategy);
```

### Complete Example

```solidity
// Constants
address WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
address WBTC_LT = 0x...; // yb-WBTC
address WBTC_GAUGE = 0x...; // WBTC Liquidity Gauge

// 1. Deploy LT Vault
address ltVault = vaultFactory.deploy_new_vault(
    WBTC_LT, "yb-WBTC Vault", "yvLT-WBTC", management, 7 days
);

// 2. Deploy Gauge Strategy → attach to LT Vault
address gaugeStrategy = ybFactory.deployGaugeStrategy(WBTC_LT, WBTC_GAUGE);
IVault(ltVault).add_strategy(gaugeStrategy);
IVault(ltVault).update_max_debt_for_strategy(gaugeStrategy, type(uint256).max);

// 3. Deploy BTC Vault
address btcVault = vaultFactory.deploy_new_vault(
    WBTC, "WBTC YB Vault", "yvWBTC-YB", management, 7 days
);

// 4. Deploy Router Strategy → attach to BTC Vault
address routerStrategy = ybFactory.deployRouterStrategy(WBTC, WBTC_LT, ltVault);
IVault(btcVault).add_strategy(routerStrategy);
IVault(btcVault).update_max_debt_for_strategy(routerStrategy, type(uint256).max);
```

---

## Testing

### Test Architecture

Each strategy has independent test suites (no shared functionality):

```
src/test/
  ├── GaugeStrategy.t.sol      # LT-based tests
  ├── utils/
  │   ├── YieldBasisSetup.sol  # Minimal shared setup
  │   └── Constants.sol         # Mainnet addresses
  └── ...
```

### Router Strategy Tests

**TODO**: Create `RouterStrategy.t.sol` with tests for:
- BTC → LT conversion with decimal handling
- Vault deposit/redeem flows
- Emergency withdraw when LT is killed
- Slippage protection on deposits/withdrawals

### Gauge Strategy Tests

Key test scenarios in `GaugeStrategy.t.sol`:

```solidity
// Basic staking
test_gaugeStrategy_stakesInGauge()       // LT → Gauge
test_gaugeStrategy_unstakesOnWithdraw()  // Gauge → LT

// Rewards
test_gaugeStrategy_claimsYBRewards()     // YB claiming
test_gaugeStrategy_rewardTokenConfig()   // Reward configuration

// Management
test_gaugeStrategy_addRewardToken()      // Add new rewards
test_gaugeStrategy_removeRewardToken()   // Remove rewards
```

### Running Tests

```bash
# Run all tests
forge test

# Run specific test file
forge test --match-path src/test/GaugeStrategy.t.sol

# Run with gas reporting
forge test --gas-report

# Run with mainnet fork
forge test --fork-url $ETH_RPC_URL
```

---

## Deployment Guide

### Prerequisites

1. **Mainnet Addresses** (defined in `Constants.sol`):
   ```solidity
   address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
   address constant WBTC_LT = 0x...; // yb-WBTC
   address constant WBTC_STAKER = 0x...; // Gauge
   address constant WBTC_POOL = 0x...; // Curve Pool
   ```

2. **Yearn V3 Contracts**:
   - VaultFactory
   - RoleManager
   - Accountant

3. **Management Setup**:
   - Management multisig
   - Performance fee recipient
   - Keeper address
   - Emergency admin

### Deployment Steps

#### 1. Deploy YBVaultFactory

```solidity
YBVaultFactory factory = new YBVaultFactory(
    management,
    performanceFeeRecipient,
    keeper,
    emergencyAdmin,
    swapRouter  // Optional: default swap router
);
```

#### 2. For Each BTC Asset (WBTC, cbBTC, tBTC)

Follow the 4-step deployment flow:

**A. Deploy LT Vault**
```bash
cast send $VAULT_FACTORY "deploy_new_vault(address,string,string,address,uint256)" \
  $WBTC_LT "yb-WBTC Vault" "yvLT-WBTC" $MANAGEMENT 604800
```

**B. Deploy Gauge Strategy**
```bash
cast send $YB_FACTORY "deployGaugeStrategy(address,address)" \
  $WBTC_LT $WBTC_GAUGE
```

**C. Deploy BTC Vault**
```bash
cast send $VAULT_FACTORY "deploy_new_vault(address,string,string,address,uint256)" \
  $WBTC "WBTC YB Vault" "yvWBTC-YB" $MANAGEMENT 604800
```

**D. Deploy Router Strategy**
```bash
cast send $YB_FACTORY "deployRouterStrategy(address,address,address)" \
  $WBTC $WBTC_LT $LT_VAULT
```

#### 3. Configure Strategies

```bash
# Set max debt for gauge strategy
cast send $LT_VAULT "update_max_debt_for_strategy(address,uint256)" \
  $GAUGE_STRATEGY $(cast max-uint)

# Set max debt for router strategy
cast send $BTC_VAULT "update_max_debt_for_strategy(address,uint256)" \
  $ROUTER_STRATEGY $(cast max-uint)

# Configure performance fees (5% default)
cast send $GAUGE_STRATEGY "setPerformanceFee(uint256)" 500
cast send $ROUTER_STRATEGY "setPerformanceFee(uint256)" 500
```

#### 4. Set Up Reward Selling

**Option A: Auction (Recommended)**
```bash
# Deploy Auction contract for YB → LT swaps
AUCTION=$(cast send $AUCTION_FACTORY "createAuction(...)")

# Set auction in gauge strategy
cast send $GAUGE_STRATEGY "setAuction(address)" $AUCTION
```

**Option B: Direct Swap**
```bash
# Deploy RewardsSwapper
SWAPPER=$(cast send $FACTORY "deployRewardsSwapper(address,address)" $LT $MANAGEMENT)

# Already set by factory, but can update:
cast send $GAUGE_STRATEGY "setRewardsSwapper(address)" $SWAPPER
```

### Post-Deployment Checklist

- [ ] Verify all contracts on Etherscan
- [ ] Test small deposit/withdraw on BTC Vault
- [ ] Verify LT Vault receives LT from router
- [ ] Verify Gauge Strategy stakes LT
- [ ] Test reward claiming and selling
- [ ] Set appropriate debt ratios
- [ ] Add vaults to Yearn registry
- [ ] Set up monitoring/alerts

---

## Appendix

### Trading Fees on LT Operations

From Yield Basis documentation, LT deposits and withdrawals incur:

1. **Curve Pool Trading Fees**: 0.04% - 0.4% (dynamic)
2. **Dynamic Admin Fees**: Based on staking ratio
3. **Borrower Fee Distribution**: Partial rebate to borrowers

**Typical Total**: ~0.5% - 1% round-trip

This explains why tests use `RELATIVE_APPROX = 5e2` (0.5% tolerance).

### LT Token Interface

```solidity
interface ILT {
    // Deposit asset, receive LT shares
    function deposit(
        uint256 assets,
        uint256 debt,
        uint256 min_shares,
        address receiver
    ) external returns (uint256 shares);

    // Withdraw asset, burn LT shares
    function withdraw(
        uint256 shares,
        uint256 min_assets,
        address receiver
    ) external returns (uint256 crypto_received);

    // Emergency withdraw when AMM is killed
    function emergency_withdraw(
        uint256 shares,
        address receiver,
        address owner
    ) external returns (uint256 asset_amount, int256 stables_amount);

    // Price per share (18 decimals)
    function pricePerShare() external view returns (uint256);

    // Check if killed
    function is_killed() external view returns (bool);
}
```

### Gauge Interface

```solidity
interface ILiquidityGauge {
    // ERC4626-compatible staking
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);

    // View functions
    function balanceOf(address account) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function convertToShares(uint256 assets) external view returns (uint256);

    // Rewards
    function claim(address token, address receiver) external;
    function YB() external view returns (address);
}
```

### Constants Reference

From `src/test/utils/Constants.sol`:

```solidity
// Assets
address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
address constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
address constant TBTC = 0x18084fbA666a33d37592fA2633fD49a74DD93a88;
address constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;

// Yield Basis Protocol
address constant YB_FACTORY = 0x4FD71457Ef9bD9C267743C818fC2BAA1Df4C8Fc4;
address constant GAUGE_CONTROLLER = 0x8Bb9FbAb0E3e8e45A7c92Db90B35e65E87d3b9Ee;

// WBTC Market
address constant WBTC_LT = 0x...; // yb-WBTC
address constant WBTC_STAKER = 0x...; // WBTC Gauge
address constant WBTC_POOL = 0x...; // Curve BTC/crvUSD Pool

// cbBTC Market
address constant CBBTC_LT = 0x...;
address constant CBBTC_STAKER = 0x...;
address constant CBBTC_POOL = 0x...;

// tBTC Market
address constant TBTC_LT = 0x...;
address constant TBTC_STAKER = 0x...;
address constant TBTC_POOL = 0x...;
```

---

**Last Updated**: 2025-10-08
**Architecture Version**: Nested Vault v1.0
