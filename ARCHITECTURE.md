# Architecture

This document explains how the exchange is built, why it is built that way, and exactly how a batch is cleared. For setup and usage see [`README.md`](README.md). For the test strategy see [`TESTING.md`](TESTING.md).

## 1. Scope

- One token pair per deployment: `baseToken` and `quoteToken`, both immutable.
- Single chain, spot trading only. No AMM, no bridge, no leverage, no derivatives, no protocol token.
- Orders are signed off-chain (EIP-712) and settled in batches at a uniform clearing price.

## 2. Components

| File | Responsibility |
|---|---|
| `contracts/src/BatchAuction.sol` | Escrow (deposit, withdraw), order cancellation, batch settlement, owner administration, EIP-712 domain |
| `contracts/src/OrderTypes.sol` | `Side`, `Order`, `SignedOrder`, and `OrderLib.hash` with the EIP-712 type hash |
| `contracts/src/libraries/ClearMath.sol` | The clearing algorithm as **pure functions**: no storage, no tokens, no signatures |
| `contracts/src/libraries/OrderValidation.sol` | Field-level order checks that need no storage |

Settlement logic (`BatchAuction`) and the price algorithm (`ClearMath`) are deliberately separate, so the algorithm can be read, fuzzed and reproduced without any deployment state.

Inherited building blocks (OpenZeppelin v5.1.0): `EIP712`, `Ownable2Step`, `Pausable`, `ReentrancyGuard`, `SafeERC20`, `SignatureChecker`, `Math`.

## 3. Actors and permissions

| Actor | Can | Cannot |
|---|---|---|
| Trader | `deposit`, `withdraw`, `cancelOrder`, sign orders | Settle batches |
| Solver (allowlisted) | `settleBatch` for an ended epoch | Set a price, set fills, move balances outside the clearing rules |
| Owner (`Ownable2Step`) | `setSolver`, `setTreasury`, `pause`, `unpause` | Move, freeze or redirect any user balance. Block `withdraw` or `cancelOrder` |
| Treasury | Receives rounding dust as an internal balance | Anything beyond a normal account |

## 4. Data model

```text
balances[account][token]   internal escrow, in token base units
nonceUsed[trader][nonce]   true once a nonce is cancelled or settled; never reset
epochSettled[epoch]        true once an epoch has settled; never reset
isSolver[address]          solver allowlist
treasury                   receives rounding dust
```

### The order (EIP-712)

Domain: `name = "BatchAuction"`, `version = "1"`, `chainId`, `verifyingContract`.

| Field | Type | Meaning |
|---|---|---|
| `trader` | address | Signer; escrow is debited from this account |
| `side` | uint8 | 0 = Buy (buys base, pays quote), 1 = Sell (sells base, receives quote) |
| `baseAmount` | uint128 | Maximum base amount to trade |
| `limitPrice` | uint128 | Buy: maximum price. Sell: minimum price. Quote per base, scaled by 1e18 |
| `epoch` | uint64 | The one epoch in which this order may settle |
| `expiry` | uint64 | Last timestamp at which settlement may include it |
| `nonce` | uint256 | Unique per trader; burned on settlement or cancellation |
| `recipient` | address | Receives the proceeds as an internal balance |

The type string is exactly:

```text
Order(address trader,uint8 side,uint128 baseAmount,uint128 limitPrice,uint64 epoch,uint64 expiry,uint256 nonce,address recipient)
```

`side` is `uint8` in the type string because Solidity enums are `uint8` in the ABI. EIP-712 type strings contain **no spaces after commas**. A client must produce the identical string, or every signature will be rejected on-chain.

**Replay protection.** The signature binds the exact order fields (via the struct hash) and this contract on this chain (via the domain separator). On top of that, an order is bound to one epoch, each epoch settles once, and each nonce can be used once.

### Price and amounts

`quoteAmount = baseAmount * price / 1e18`. All amounts are integers in token base units, and `Math.mulDiv` performs the multiplication with a 512-bit intermediate so even `type(uint128).max` inputs cannot overflow.

## 5. Epochs

`epoch = block.timestamp / epochDuration`. Epoch `e` covers `[e * D, (e + 1) * D)`. `epochEnd(e) = (e + 1) * D` is the first moment at which epoch `e` can be settled. `currentEpoch()` reports the live epoch.

## 6. Lifecycle

```
sequenceDiagram
    participant T as Trader
    participant X as BatchAuction
    participant S as Solver
    T->>X: deposit(token, amount)
    T->>S: signed Order (off-chain)
    opt before settlement
        T->>X: cancelOrder(nonce)
    end
    Note over X: epoch ends
    S->>X: settleBatch(epoch, buys, sells)
    X->>X: validate, burn nonces, clear, move balances
    T->>X: withdraw(token, amount)
```

## 7. Settlement, step by step

`settleBatch(epoch, buys, sells)` is one function. Any failed check reverts **everything**, including burned nonces, so a solver can fix a batch and resubmit.

1. **Access and timing.** The caller must be an allowlisted solver (`NotSolver`). The epoch must have ended (`EpochNotEnded`) and not already be settled (`EpochAlreadySettled`). Each side may hold at most 32 orders (`TooManyOrders`). The function is `nonReentrant` and `whenNotPaused`.
2. **Load both books** (`_loadBook`), for each order in order:
   1. `OrderValidation.validateFields`: right side, non-zero trader / recipient / amount / price, right epoch, not expired (`block.timestamp <= expiry`).
   2. Signature check through `SignatureChecker.isValidSignatureNow` (ECDSA for EOAs, ERC-1271 for contract wallets), else `InvalidSignature`.
   3. Nonce check and burn: if `nonceUsed`, revert `NonceAlreadyUsed`, otherwise mark it used. This one mechanism blocks cancelled orders, already-settled orders and duplicates inside a batch.
3. **Check ordering.** `ClearMath.assertSorted` requires each book to be **strictly** sorted by priority. Strictness also rejects duplicates.
4. **Clear.** `ClearMath.clear` returns the price, the volume and the fill for every order. If the volume is zero the call reverts with `NoTrade` and does **not** consume the epoch.
5. **Apply.** Mark the epoch settled. For each buy fill, the buyer's quote balance is debited `ceil(fill * price / 1e18)` and the recipient's base balance is credited the fill. For each sell fill, the seller's base balance is debited the fill and the recipient's quote balance is credited `floor(fill * price / 1e18)`. A shortfall reverts with `InsufficientBalance`.
6. **Defence in depth.** Each filled order is re-checked against its own limit (`PriceLimitViolated`). Then conservation is checked: base bought equals base sold equals the volume, and quote paid is at least quote received (`ConservationViolated`). The clearing library already guarantees these. They exist so that a future bug cannot silently move funds.
7. **Dust and events.** The rounding difference is credited to the treasury. The contract emits `OrderFilled` per filled order and one `BatchSettled`, enough for an indexer to rebuild the result.

Settlement makes **no token transfers and no calls to untrusted code**, apart from the read-only ERC-1271 `staticcall` during signature validation. That removes reentrancy and malicious-token risk from the settlement path.

## 8. The clearing algorithm

Implemented in `ClearMath.clear`. Inputs are two sorted books of entries `(base, limit, id)`, where `id` is the order's EIP-712 digest.

**Priority.** Buys: highest `limit` first. Sells: lowest `limit` first. Equal limits: lowest `id` first. The solver sends each book already in this order, and the contract only *verifies* it with one pass over adjacent pairs, which is much cheaper than sorting on-chain.

**Definitions.** For a candidate price `p`:

- `D(p)` = total `base` of buys with `limit >= p` (demand)
- `S(p)` = total `base` of sells with `limit <= p` (supply)
- `V(p) = min(D(p), S(p))` and `imbalance(p) = |D(p) - S(p)|`

**Step 1: choose the price.** The candidates are all submitted limit prices. Choose the one with (1) the largest `V`, then (2) the smallest imbalance, then (3) the lowest price. If the best `V` is zero, there is no trade. Volume is always maximised at a limit price, because between two limit prices it can never exceed the volume at either neighbour.

**Step 2: allocate fills.** Walk each eligible list (buys with `limit >= p`, sells with `limit <= p`) in priority order and give each entry `min(base, remaining)`, with `remaining` starting at `V`. The shorter side fills completely. The longer side is rationed by priority, so at most one entry is partially filled.

**Step 3: amounts.** For a fill of `f`: the buyer pays `ceil(f * p / 1e18)` and the seller receives `floor(f * p / 1e18)`. Total paid is never less than total received, so rounding can never make the exchange insolvent. The difference is the dust.

**Complexity.** Price selection scans both books for every candidate, which is O((n + m)^2). With the 32-per-side cap that is roughly 4,000 simple loop steps.

### Worked examples (18-decimal tokens; amounts shown in whole tokens)

| # | Orders | Result |
|---|---|---|
| 1 | Buy 5 @ 90, Sell 5 @ 100 | `V = 0` at every price. No trade (`NoTrade`) |
| 2 | Buy 10 @ 102, Sell 10 @ 98 | `V = 10` at both 98 and 102 with imbalance 0, so the lowest price wins: **price 98**. Buyer pays 980 |
| 3 | Buys A 10 @ 105 and C 10 @ 100, Sell 15 @ 95 | `V = 15`, imbalance 5, at both 100 and 95, so **price 95**. A fills 10, C fills 5 (partial). A pays 950, C pays 475, seller receives 1425 |
| 4 | Buy 6 @ 100, Sells S1 5 @ 90 and S2 5 @ 95 | **Price 95**, `V = 6`. S1 fills 5 and S2 fills 1 (lowest limit first). Buyer pays 570 |
| 5 | Buy 3 units @ `5e17`, Sell 3 units @ `5e17` | Buyer pays `ceil(1.5) = 2`, seller receives `floor(1.5) = 1`, **dust 1** goes to the treasury |

Choosing the lowest price on a tie favours buyers when several prices are equally good. A midpoint rule is a possible later change.

## 9. Escrow design

Traders deposit once and the contract keeps `balances[account][token]`. Settlement only moves numbers between these balances. This gives three properties:

1. **Atomicity is simple.** A batch is one function that changes storage or reverts.
2. **No external calls during settlement.** There is nothing for a malicious token to reenter.
3. **Solvency is one equation.** For each token, the contract's real token balance must equal the sum of all internal balances. The invariant test checks exactly this.

`deposit` measures the contract's balance before and after the transfer and reverts (`TransferAmountMismatch`) if the received amount differs from the requested amount. That rejects fee-on-transfer tokens, since crediting the requested amount would make the contract insolvent. `SafeERC20` handles tokens that do not return a boolean.

`withdraw` updates the balance before sending tokens (checks-effects-interactions) and is also `nonReentrant`.

## 10. Order policy

Orders are epoch-bound and do not carry forward. Whatever is not filled stays in the trader's internal balance, withdrawable at any time. To trade in a later epoch the trader signs a new order. To amend an order, cancel nonce `n` and sign a new order with a different nonce.

## 11. Pause policy

`pause()` blocks `deposit` and `settleBatch`. `withdraw` and `cancelOrder` are never paused, so no user is ever locked out of their funds or unable to cancel.

## 12. Security properties and where they are enforced

| Property | Enforced by | Tested in |
|---|---|---|
| A signature is valid only for this exchange, chain and exact order fields | EIP-712 domain and struct hash | `OrderSignature.t.sol`, `Adversarial.t.sol` |
| An order cannot be filled beyond its signed maximum | `PriceLimitViolated` check; clearing allocation | fuzz and invariant tests |
| An order cannot be reused after cancel, expiry or settlement | `nonceUsed`, `epochSettled`, expiry check, epoch binding | `Settlement.t.sol`, `Adversarial.t.sol`, invariants |
| Cross-chain and cross-deployment replay fails | Domain separator | `Adversarial.t.sol` |
| No batch violates a limit or creates unbacked balances | Clearing rules, `PriceLimitViolated`, `ConservationViolated`, solvency | fuzz and invariant tests |
| Every batch is atomic and conserves value | Single-function settlement, internal balances | invariants |
| Reentrancy and malicious token behaviour | `nonReentrant`, no calls in settlement, balance-diff deposit | `Adversarial.t.sol`, `Escrow.t.sol` |
| Pause never traps funds | `withdraw` and `cancelOrder` are not pausable | `Escrow.t.sol`, `Adversarial.t.sol` |
| The owner cannot touch balances | No such function exists | Review of the external surface |

## 13. Trust assumptions

- **The solver.** It can censor or delay (omit orders from the batch) and so influence the price by choosing the set. It cannot change an order, a price or a total. Mitigation in v1: the allowlist is owner-managed and the choice is documented.
- **The owner.** It can pause, change solvers and change the treasury. It cannot touch balances. It should be a multisig.
- **Tokens.** Must be well-behaved ERC-20s. Rebasing and blocklisting tokens are unsupported.
- **Contract-wallet signers (ERC-1271).** Validation is a `staticcall`, so it cannot change state, but a wallet can revert or burn gas and cause a batch to fail. The solver then omits that order.
- **Time.** Epochs last minutes, so the few seconds a validator can shift a timestamp are immaterial.

## 14. Error reference

- `BatchAuction__ZeroAddress`, `__InvalidConfig`, `__ZeroAmount`, `__UnsupportedToken`, `__TransferAmountMismatch`, `__InsufficientBalance`, `__NonceAlreadyUsed`, `__NotSolver`, `__EpochNotEnded`, `__EpochAlreadySettled`, `__TooManyOrders`, `__InvalidSignature`, `__NoTrade`, `__PriceLimitViolated`, `__ConservationViolated`
- `ClearMath__NotSorted`
- `OrderValidation__WrongSide`, `__WrongEpoch`, `__Expired`, `__InvalidOrder`

## 15. Events

`Deposited`, `Withdrawn`, `OrderCancelled`, `SolverUpdated`, `TreasuryUpdated`, `OrderFilled(epoch, orderId, trader, side, nonce, baseFilled, quoteAmount)`, `BatchSettled(epoch, clearingPrice, baseVolume, quoteVolume, dust, buyOrders, sellOrders)`

An indexer can rebuild a settled epoch from `OrderFilled` and `BatchSettled` alone. The orders themselves are available in the `settleBatch` calldata, which lets anyone recompute the result independently with the algorithm.
