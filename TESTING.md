# Testing

This document explains how the exchange is tested, what each layer proves, and how to run it. For the design being tested see [`ARCHITECTURE.md`](ARCHITECTURE.md).

## Running the tests

```bash
forge build
forge test                                   # everything (about a minute, mostly the invariant tests)
forge test -vv                               # show logs
forge test --match-path "contracts/test/unit/*"
forge test --match-path "contracts/test/fuzz/*"
forge test --match-path "contracts/test/invariant/*"
forge test --match-path "contracts/test/adversarial/*"
forge test --match-test test_fullCross -vvvv # one test, with a full trace
forge test --gas-report
```

Foundry settings (`foundry.toml`): fuzz runs = 1000, invariant runs = 256 at depth 64, `fail_on_revert = false`, and `via_ir = true` (needed to avoid "stack too deep").

### Coverage

```bash
forge coverage --ir-minimum --no-match-coverage "contracts/(test|script)"
```

`--ir-minimum` is required. Plain `forge coverage` disables the compiler's `via_ir` pipeline and then fails with "stack too deep" inside `settleBatch`. Because `--ir-minimum` changes how code is compiled, treat the percentages as a good approximation, not an exact measurement.

## Current results

At the time of writing: **72 tests, all passing** (Foundry stable 1.5.1, Solidity 0.8.24, OpenZeppelin v5.1.0).

| Suite | File | Tests | Focus |
|---|---|---|---|
| Unit | `unit/Escrow.t.sol` | 11 | Deposit, withdraw, cancel, pause, access control, fee-on-transfer and unsupported-token rejection |
| Unit | `unit/OrderSignature.t.sol` | 5 | EIP-712 digest vs an independent computation, signature recovery, per-field sensitivity, chain and deployment separation |
| Unit | `unit/ClearMath.t.sol` | 8 | The five worked clearing examples, tie-break, sortedness checks |
| Unit | `unit/Settlement.t.sol` | 24 | Happy paths, rationing, dust, ties, maximum values, access, timing, expiry boundaries, signatures, cancellation races, duplicates, ordering, escrow shortfall |
| Unit | `unit/Admin.t.sol` | 4 | `setTreasury`, `unpause`, `currentEpoch`, constructor validation |
| Unit | `unit/DeployScript.t.sol` | 4 | Both deployment scripts run end to end inside the Foundry EVM |
| Unit | `unit/Smoke.t.sol` | 2 | The mock tokens behave as intended |
| Fuzz | `fuzz/ClearMath.fuzz.t.sol` | 1 | Eight properties over random books |
| Invariant | `invariant/BatchAuction.invariant.t.sol` | 6 | Properties that must hold after any sequence of actions |
| Adversarial | `adversarial/Adversarial.t.sol` | 7 | Reentrancy, replay, censorship, pause |

Measured coverage of the contracts in `src/` (using `--ir-minimum`):

| File | Lines | Statements | Branches | Functions |
|---|---|---|---|---|
| `BatchAuction.sol` | 97.27% | 95.30% | 79.17% | 100% |
| `ClearMath.sol` | 97.96% | 97.18% | 87.50% | 100% |
| `OrderValidation.sol` | 83.33% | 92.86% | 75.00% | 100% |
| `OrderTypes.sol` | 100% | 100% | 100% | 100% |
| **Total** | **97.01%** | **95.76%** | **80.56%** | **100%** |

The remaining gaps are small and understood:

- `revert BatchAuction__ConservationViolated()` is **intentionally unreachable**. It is defence in depth behind the clearing library, which already guarantees conservation. It exists so a future bug cannot silently move funds.
- `OrderValidation__InvalidOrder` (an order with a zero trader, recipient, amount or price) has no dedicated test yet. A one-line test with `baseAmount = 0` closes it.
- Two lines inside `pause()` / `unpause()` and one in `ClearMath._allocate` show as uncovered although the functions are called by passing tests. This is most likely a line-attribution artifact of the `--ir-minimum` compile, not missing coverage.

## What each layer proves

### Unit tests: specific behaviour, exact numbers

Every worked example in `ARCHITECTURE.md` is a test with exact expected balances. The settlement tests cover the cases the design calls out: crossing and non-crossing books, no-match epochs, partial fills on the buy side and the sell side, rounding dust going to the treasury, equal-limit tie-breaking by digest, maximum values (`type(uint128).max` for both amount and price), cancellation races in both directions, the expiry boundary on both sides (`expiry == block.timestamp` is valid, one second later is not), invalid and tampered signatures, duplicate orders, unsorted books, and a trader without escrow.

**EIP-712 is verified independently.** `test_digest_matchesIndependentEip712Computation` rebuilds the type hash, domain separator and digest *by hand* and compares them with the contract. This matters: every other test signs with the contract's own `orderDigest`, which would agree with itself even if the type string were wrong. An independent recomputation is the only test that catches a type-string mistake such as a typo or a stray space, and a real wallet or `viem` hashes the standard string.

### Fuzz test: the clearing math over random books

`testFuzz_clear_properties` builds random sorted books (coarse prices, so ties are common) and asserts, for every one:

1. the sum of buy fills equals the sum of sell fills equals the reported volume;
2. every fill is at most the order's `baseAmount`;
3. every filled buy has `limit >= price`, and every filled sell has `limit <= price`;
4. **maximality**: no candidate price would trade more volume than the chosen one;
5. **priority**: if an entry is not completely filled, every lower-priority entry on that side received nothing;
6. rounding never makes the exchange insolvent: buyers pay at least what sellers receive;
7. the generated books are themselves canonical (so the test fails loudly if the generator or `assertSorted` regresses).

### Invariant tests: properties after any sequence of actions

`AuctionHandler` wraps the exchange with bounded actions (`deposit`, `withdraw`, `cancel`, `settle`) over five signing actors, and records **ghost variables**, which are facts the contract does not store. Foundry calls random sequences of these actions (256 runs of depth 64, about 16,000 calls per invariant), and after every call it checks:

| Invariant | Meaning |
|---|---|
| `invariant_solvency` | For each token, the exchange's real token balance equals the sum of all internal balances (actors plus treasury) |
| `invariant_fillsRespectBoundsAndLimits` | No fill exceeds the signed amount. No buyer pays more than `ceil(fill * limit)` and no seller receives less than `floor(fill * limit)` |
| `invariant_everyBatchConserves` | In every settled batch, base bought equals base sold and quote paid is at least quote received |
| `invariant_noEpochSettlesTwice` | After a successful settlement, a second settlement of the same epoch always reverts |
| `invariant_settledEpochsStaySettled` | An epoch that settled never becomes unsettled |
| `invariant_usedNonceStaysUsed` | A cancelled or settled nonce is never reusable |

Solvency is the strongest check. Settlement moves only internal numbers, so any code path that created or destroyed value would make the sum drift away from the real token balance.

`afterInvariant` prints the number of successful settlements. **Check this once with `-vv`.** An invariant suite that never actually settles anything proves nothing.

### Adversarial tests: deliberate attacks

- A token that calls back into the exchange in the middle of `deposit` is stopped by the reentrancy guard.
- An order signed for a different deployment, or for a different chain ID, is rejected with `InvalidSignature`.
- An order for an old epoch cannot be replayed in a new epoch. A settled order cannot be reused.
- **Solver censorship is demonstrated, not prevented.** A solver that leaves a buyer's order out of the batch moves the price and the buyer gets nothing, yet no one's limit is violated. This test documents a known limitation honestly.
- After a pause, a user can still withdraw.

### Deploy-script tests

`DeployScript.t.sol` runs `DeployMocks` and `Deploy` inside the Foundry EVM, reading their configuration from environment variables set with `vm.setEnv`. It checks that the exchange comes out configured as asked, that a token address with no code is refused, and that `base == quote` is refused. This is the "deployment-script check" without needing a node (no Anvil).

## Continuous integration

`.github/workflows/ci.yml` runs on every push and pull request:

- **build and test**: `forge build --sizes` and `forge test -vv` (all suites, including the deploy-script tests).
- **coverage**: `forge coverage --ir-minimum`, with `lcov.info` uploaded as an artifact.
- **static analysis**: Slither with `slither.config.json`. It is non-blocking until you have triaged its findings. Write one line per finding saying *fixed* or *accepted, because...*, then switch `fail-on` to `medium`.

## What is not covered yet

- Testing against a **real token** such as a USDT-style token without a return value, and an **ERC-1271 contract wallet** as a trader. Both are supported by the design but have no test.
- A **fork test** on a live network.
- **Gas ceilings.** Measure `settleBatch` with 32 orders on each side (`forge test --gas-report`) and record the number, because the 32-order cap is a gas decision.
- A **TypeScript client** that signs with `viem`. It would independently check that real wallet signatures verify on-chain, which is the best end-to-end check of the EIP-712 type string.
