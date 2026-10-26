# Precursor contracts

The Solidity contracts behind Precursor, the platform private companies use to issue their shares as tokens on Robinhood Chain.

A company deploys its contracts once and then issues each share class as a Precursor Share Token. The class carries its own transfer rules, and every movement of the token is checked against them before it settles. The same contract set handles offerings, Liquidity Windows, signed quotes between holders, distributions, votes and disclosures. Every state change emits an event, so a company's full history is public and anyone can verify it, while the identities of the people involved stay off-chain.

The product documentation is at [docs.useprecursor.xyz](https://docs.useprecursor.xyz). This README is about the code.

| | |
| --- | --- |
| Network | Robinhood Chain, an Arbitrum chain that settles to Ethereum. Testnet today, mainnet next |
| Toolchain | Foundry, Solidity 0.8.26, via-IR, Cancun |
| Dependencies | OpenZeppelin Contracts 5.2.0 and forge-std 1.9.7, installed with Soldeer |
| Tests | 67 unit and integration tests |

## How it's put together

`PrecursorFactory` deploys a separate set of contracts for each company, and a token, rule engine, modules and valuation oracle for each of its share classes.

```
PrecursorFactory (owner: Precursor)
 └── per company
      ├── IssuerTimelock        M-of-N multi-sig with per-function delays. DEFAULT_ADMIN on everything below
      ├── TrustedVerifiers      which identity providers may sign which claim topics
      ├── IdentityRegistry      wallet to identity, plus signed claims (no personal data)
      ├── OfferingVault         primary offerings: escrow, pro-rata allocation, mint at close, refunds
      ├── LiquidityWindow       uniform-price batch auctions and fixed-price tenders, with ROFR priority
      ├── RFQSettlement         EIP-712 signed quotes between eligible holders, settled atomically
      ├── DistributionVault     dividends and proceeds by record block, claimed by each holder
      ├── Governance            snapshot votes across share classes, with checkpointed delegation
      ├── DisclosureRegistry    SHA-256 fingerprints of company documents
      └── per share class
           ├── PrecursorShareToken   ERC-20 with the ERC-3643 surface and an ERC-8056 multiplier, UUPS proxy
           ├── RuleEngine ──► modules (clones, one set per class)
           ├── ValuationOracle       Reference Valuation, compatible with Chainlink's AggregatorV3
           └── PoolGate              optional, for permissioned AMM pools
```

Company contracts and modules are EIP-1167 clones of shared implementations. Share tokens are ERC1967 proxies, so a company can upgrade its own token, but only through its timelock and only after a seven-day delay. The factory keeps no role on anything it deploys.

### How a transfer is checked

`canTransfer(from, to, amount)` runs these checks in order and stops at the first one that fails:

1. **The token.** Paused (`TOKEN_PAUSED`), wallet under recovery or partly frozen (`FROZEN`), not enough unlocked balance (`INSUFFICIENT_UNLOCKED_BALANCE`).
2. **Identity.** Each party that isn't an agent needs a registered identity with valid `IDENTITY_VERIFIED` and `SCREENED` claims (`SENDER_NOT_VERIFIED`, `RECIPIENT_NOT_VERIFIED`, `CLAIM_EXPIRED`).
3. **Modules**, in the order the company configured them. The first failing reason code is the one returned.

If the check fails, `transfer`, `transferFrom` and `mint` revert with `TransferNotAllowed(reasonCode)`. Reason codes are left-aligned `bytes32` strings, all listed in `src/libraries/ReasonCodes.sol`.

**Agents.** The company's `LiquidityWindow` is an agent, and so is any contract holding a valid `VENUE` claim for the token, such as an approved pool. Identity checks skip the agent's side of a transfer, and modules skip their sender or recipient check for it. The rules apply to the people at each end of a trade, never to the escrow in between.

### Rule modules

| Module id | Contract | Config (`abi.encode`) | Reason code |
| --- | --- | --- | --- |
| `REGION` | `RegionModule` | `(uint8 mode, bytes2[] regions)`, where 0 is an allow list and 1 a block list | `REGION_BLOCKED` |
| `ELIGIBILITY` | `EligibilityModule` | `(uint8 minimumTier, bool exemptEmployees)` | `NOT_ELIGIBLE` |
| `HOLDING_PERIOD` | `HoldingPeriodModule` | `(uint32 period, bytes32[] sources, uint32[] periods, address[] operators, bytes32[] operatorSources)` | `HOLDING_PERIOD_ACTIVE` |
| `HOLDER_CAP` | `HolderCapModule` | `(uint32 maxHolders)` | `HOLDER_CAP_REACHED` |
| `TRANSFER_WINDOW` | `TransferWindowModule` | `(Window[] windows, bool allowDuringLiquidityWindows, address liquidityWindow)` | `WINDOW_CLOSED` |
| `ROFR` | `ROFRModule` | `(address holder, uint32 noticePeriod, address[] exemptVenues)` | `ROFR_PENDING` |
| `MAX_OWNERSHIP` | `MaxOwnershipModule` | `(uint16 maxBps, bool applyToMints, address[] exemptIdentities)` | `MAX_OWNERSHIP_EXCEEDED` |
| `EMPLOYEE_VESTING` | `EmployeeVestingModule` | `(uint8 action, bytes payload)`, with grants added by the registrar through `addGrants` | `UNVESTED` |

Holding periods are tracked as **lots** per wallet and used up oldest first. Holder caps, ownership caps and vesting are tracked **per identity**, so add those modules when the share class is created, before anything is minted.

### Roles and delays

| Role | Held by | Can |
| --- | --- | --- |
| `DEFAULT_ADMIN_ROLE` | `IssuerTimelock` | Change modules, upgrade, change verifiers, set fees and agents, grant roles |
| `ISSUER_ADMIN` | The company's multi-sig | Run offerings, windows, distributions and proposals, schedule multipliers, anchor documents, publish valuations |
| `REGISTRAR` | The registrar | Mint, burn, freeze, carry out recoveries, add vesting grants |
| `OPERATOR` | Precursor's relayer for the company | Register identities, co-approve recoveries |
| `PAUSER` | Issuer admin and registrar | Pause and unpause immediately |
| `MINTER` | `OfferingVault` | Mint when an offering closes |

The timelock enforces minimum delays. A company can make them longer but never shorter.

| Action | Minimum delay |
| --- | --- |
| Token upgrade (`upgradeToAndCall`) | 7 days |
| Adding, removing or configuring a module | 24 hours |
| Anything else that goes through the timelock | 48 hours |
| Multiplier change, scheduled on the token | 48 hours |
| Wallet recovery (2 of issuer, registrar and operator, then the delay) | 72 hours by default, never under 48 |

### Snapshots on Arbitrum

On Arbitrum chains `block.number` follows the L1 block number, which moves much more slowly than L2 blocks. Record blocks and vote snapshots use the L2 block number from the ArbSys precompile instead (`src/libraries/Clock.sol`), and fall back to `block.number` everywhere else, including local tests.

## Building and testing

```sh
forge soldeer install        # fetch dependencies into dependencies/
forge build
forge test
forge test -vvv --match-path test/LiquidityWindow.t.sol
```

`test/LiquidityWindow.t.sol::test_DocumentedAuctionExample` replays the worked example from the Liquidity Windows docs, so if the contract and the docs ever disagree, the test fails.

## Deploying to testnet

```sh
cp .env.example .env         # PRIVATE_KEY is the only required value
source .env

# Dry run against a fork of testnet, nothing is sent
forge script script/Deploy.s.sol --rpc-url robinhood_testnet

# Deploy and verify on Blockscout
forge script script/Deploy.s.sol --rpc-url robinhood_testnet --broadcast --verify
```

The script deploys every implementation and the factory, registers the eight modules, sets the default verifier and writes every address to `deployments/<chain id>.json`. The most recent testnet run used about 40M gas.

Unless `DEPLOY_DEMO=false`, it also creates **Northwind Labs**, a made-up company where the deployer plays every role:

* `COMMON` blocks sanctioned regions, requires eligibility tier 1 with employees exempt, caps holders at 2,000 and locks offering allocations for 90 days.
* `SERIES_B` requires tier 2 and caps any single holder at 25% on transfers.
* The deployer is verified and holds 1,000,000 Common and 250,000 Series B, and a Series B offering at 25 USDG a share stays open for 30 days.

If `USDG` is left blank, the script deploys a 6-decimal test stablecoin that anyone can mint. It's only for testing, and the script refuses to deploy it on mainnet.

## Layout

```
src/
  PrecursorFactory.sol       PrecursorShareToken.sol   IdentityRegistry.sol   TrustedVerifiers.sol
  RuleEngine.sol             OfferingVault.sol         LiquidityWindow.sol    RFQSettlement.sol
  DistributionVault.sol      Governance.sol            DisclosureRegistry.sol ValuationOracle.sol
  IssuerTimelock.sol         PoolGate.sol
  modules/                   BaseModule.sol and the eight rule modules
  interfaces/                public interfaces for integrators
  libraries/                 ReasonCodes, Topics, Roles, Clock
  mocks/                     MockStablecoin, testnet only
script/Deploy.s.sol
test/                        a shared fixture and one suite per area
deployments/                 addresses for each chain, written by the deploy script
```

## What's still open

This is the first complete version of the contracts. Before mainnet:

* **Audit.** Nothing here has been audited yet.
* **Bounded loops.** An offering takes at most 500 subscribers and a window 200 orders, so each one settles in a single transaction. Settling in batches would remove those limits.
* **Identity changes.** Modules that count balances per identity assume a wallet keeps the same identity while it holds tokens. Linking a funded wallet to a new identity will throw off holder counts and ownership caps.
* **Vote multipliers.** `Governance` reads each class's display multiplier when a proposal is created, not at the snapshot block.
* **Buyback budget.** A company buyback in a window is placed as an ordinary bid from the treasury. There's no separate budget setting.
* **Gas sponsorship.** Investors and employees don't pay gas, but that's handled off-chain by Precursor's relayers and account abstraction, not by these contracts.
