# Batch Auction Exchange

An on-chain **intent-based batch auction** for a single ERC-20 token pair. Traders sign EIP-712 orders off-chain. After each fixed time window (an *epoch*), a solver submits the orders and the contract settles every trade **atomically at one uniform clearing price** that the contract itself computes.

> **Status: unaudited.** This is a portfolio-grade implementation with a thorough test suite. A testnet deployment is a demonstration, not a security audit. Do not use it with real funds.

## Why a batch auction?

In a continuous order book, whoever's transaction lands first gets the better price, which rewards racing and ordering games. Here, orders collect during an epoch and clear together at one price, so position inside the batch stops mattering. Batching changes execution incentives; it does **not** remove every ordering or censorship risk (see [Known limitations](#known-limitations)).

## How it works

1. **Deposit.** A trader deposits base or quote tokens into the exchange. They are held as an internal balance.
2. **Sign.** The trader signs an EIP-712 `Order` off-chain (side, base amount, limit price, epoch, expiry, nonce, recipient) and hands it to a solver.
3. **Cancel (optional).** Until settlement, the trader can burn an order's nonce on-chain with `cancelOrder(nonce)`.
4. **Settle.** After the epoch ends, an allowlisted solver calls `settleBatch(epoch, buys, sells)` with two canonically sorted lists of signed orders.
5. **Clear.** The contract validates every order, derives the clearing price and each fill itself, moves internal balances, and either does all of it or reverts.
6. **Withdraw.** Traders withdraw whatever they hold, including escrow that was not filled. Withdrawals are never paused.

The solver supplies **only a set of signed orders**. It supplies no price, no fills and no totals, so there is nothing for it to misreport.

### The clearing rule (short version)

Candidate prices are the submitted limit prices. The contract picks the one with **maximum tradable volume**, then **minimum imbalance**, then the **lowest price**. Everyone who trades gets that price. Fills go in priority order: best limit first, ties broken by the order's EIP-712 digest. Buyers pay rounded **up**, sellers receive rounded **down**, and the rounding dust goes to the treasury. The full algorithm with worked examples is in [`ARCHITECTURE.md`](ARCHITECTURE.md).

## Repository layout

```text
contracts/
  src/
    BatchAuction.sol            escrow, cancellation, settlement, admin
    OrderTypes.sol              Order / SignedOrder structs, EIP-712 type hash
    libraries/
      ClearMath.sol             pure clearing algorithm (no storage, no tokens)
      OrderValidation.sol       field-level order checks
  script/
    Deploy.s.sol                deploys the exchange (env-driven)
    DeployMocks.s.sol           deploys two mock tokens (testnet only)
  test/
    unit/  fuzz/  invariant/  adversarial/  helpers/  mocks/
.github/workflows/ci.yml        build, test, coverage, static analysis
slither.config.json
```

## Quick start

Requirements: [Foundry](https://book.getfoundry.sh/) (forge), git, and Solidity 0.8.24 (fetched by Foundry).

```bash
git clone --recurse-submodules <your-repo-url>
cd batch_action_exchange

forge build
forge test                      # whole suite (the invariant tests take about a minute)
```

Coverage needs a special flag:

```bash
forge coverage --ir-minimum --no-match-coverage "contracts/(test|script)"
```

Why `--ir-minimum`? Plain `forge coverage` disables the compiler's `via_ir` pipeline, and `settleBatch` then fails with "stack too deep".

More detail on the tests is in [`TESTING.md`](TESTING.md).

## Supported assumptions

**Tokens.** Plain ERC-20s only. The exchange rejects tokens that are not the configured pair and rejects fee-on-transfer tokens at deposit (the received amount must equal the requested amount). Rebasing tokens and tokens with admin blocklists are **not supported** and must not be used.

**Prices.** `price` is quote base units per one base base unit, scaled by `1e18`. With two 18-decimal tokens, `98e18` means 98 quote tokens per 1 base token.

**Solver.** The solver is a permissioned role, managed by the owner. This choice is deliberate for the first release and is documented as a limitation.

## Admin powers

The owner (`Ownable2Step`) can add or remove solvers, change the treasury address, and pause or unpause. There is **no function that moves, freezes or redirects a user's balance**. Pausing blocks `deposit` and `settleBatch` only, and `withdraw` and `cancelOrder` always work. In any real deployment the owner should be a multisig.

## Deployment

Both scripts read their parameters from environment variables. Use an encrypted keystore (`cast wallet import deployer --interactive`), never a private key in `.env`.

`.env`:

```bash
SEPOLIA_RPC_URL=
ETHERSCAN_API_KEY=
BASE_TOKEN=
QUOTE_TOKEN=
OWNER=
TREASURY=
SOLVER=
EPOCH_DURATION=300
```

```bash
source .env

# 1) testnet mock tokens (skip if you already have a token pair)
forge script contracts/script/DeployMocks.s.sol \
  --rpc-url $SEPOLIA_RPC_URL --account deployer --broadcast

# put the two printed addresses in BASE_TOKEN and QUOTE_TOKEN, then: source .env

# 2) the exchange
forge script contracts/script/Deploy.s.sol \
  --rpc-url $SEPOLIA_RPC_URL --account deployer --broadcast \
  --verify --etherscan-api-key $ETHERSCAN_API_KEY
```

If `OWNER` is the deploying account, the script also allowlists `SOLVER`. Otherwise the owner must call `setSolver(solver, true)` afterwards.

### Deployed addresses

| Network | Contract | Address |
|---|---|---|
| Sepolia | BatchAuction | _not yet deployed_ |
| Sepolia | Base token (mock) | _not yet deployed_ |
| Sepolia | Quote token (mock) | _not yet deployed_ |

## Known limitations

- **Solver censorship.** A permissioned solver can omit or delay valid orders, and because the price depends on which orders are in the batch, omission can move the price. It can never violate a signed limit or create unbacked balances. This is demonstrated in `Adversarial.t.sol` and not prevented.
- **Tie-break grinding.** Equal-limit orders are prioritised by EIP-712 digest. A trader can vary a nonce to obtain a lower digest.
- **Escrow griefing.** A trader can withdraw escrow after signing, which makes a batch containing their order revert. The solver simulates first and leaves the order out.
- **One settlement per epoch, no carry-forward.** Orders are bound to one epoch. Unfilled escrow stays withdrawable and the trader signs a new order for a later epoch.
- **Maximum 32 orders per side per batch**, which keeps the quadratic price search and the signature checks within a predictable gas bound.
- **ERC-1271 wallets** are supported through OpenZeppelin's `SignatureChecker`. A contract wallet can make a batch fail but cannot change state during validation (it is a `staticcall`).
- **No MEV claims.** This design reduces ordering games inside a batch. It does not eliminate MEV, censorship or timing risk.

## License

MIT
