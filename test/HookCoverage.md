# INK hook and token test additions

These tests supplement the accepted launch, vault and liquidity suites. Production
contracts, configuration, dependencies, deployment scripts and manifests are unchanged.

## Fixture and limits

`helpers/HookAccountingFixture.sol` executes the repository's unmodified InkHook,
LaunchToken, InkPortraits, InkVault, InkLiquidity, PoolManager and PositionManager.
The portraits, vault and liquidity instances occupy the addresses in the brief,
and the hook uses the specified treasury and 25 basis point fee. Only the external
IMD token and seat NFT are test doubles. LaunchToken is the real fixed-supply token.
Both sorted currency orderings are exercised.

The fixture supplies a deep two-sided position at parity so buys, sells and both
exactness settings remain reachable throughout a campaign. This is an accounting
fixture, not a simulation of mainnet opening price or deployed storage. The real
vault releases its unclaimed allocation through the real liquidity contract into
eight real positions. No test here forks, reads a fixture file, changes environment
variables, or requires new dependencies.

The paying wallet's pool-fee entitlement is launch-factory/manifest policy, outside
InkHook's fee ledger. These additions do not redirect it or deploy an InkFeeRouter.
They do not attest to current mainnet state or deployment configuration.

## Properties and independent observations

The supplied Pashov fizz and Trail of Bits property-testing references informed
the conservation, state-machine, boundary, round-trip and non-vacuity checks.
The tests are original Foundry implementations, with these SHOULD-HOLD properties:

| Property | Basis | Observation/model |
| --- | --- | --- |
| Hook accrual equals outstanding claims plus payouts | Every collected fee must retain its currency and fixed recipient | PoolManager's gross Swap event, actual wallet settlements, ERC6909 claims and recipient balances |
| Only the unspecified side pays 0.25% | Task's hook fee and InkHook's documented exact-input/output semantics | Explicit four-case currency table; one unit per complete 400 gross minor units |
| No time-only unlock or reopening | Task requires successful vault release, without fallback | Independent release and first-successful-swap ghosts |
| Only mature transaction origins qualify | Task's `portraits.isAgentHolder(tx.origin)` requirement | Separate portrait-count and holding-block ledger; independently selected payer and origin |
| INK supply and custody are conserved | Fixed 1e27 supply, no burn or fee conversion | Sum over every actor/custodian, plus vault backing before and after release |
| Token balances and allowances follow authorized actions | ERC20 transfers, approvals, finite/infinite allowance behavior | Closed four-actor ledger and approval matrix |
| Failed actions are atomic and retryable | EVM rollback and documented release/collection flows | Injected dependency failures, unchanged balances/claims/state, then successful retry |

`HookAccountingInvariants.t.sol` runs 256 sequences of 128 calls for each currency
ordering. Four actors interleave all four swap shapes, dust amounts, permissionless
collections, release/repeated release, time/block advancement and portrait transfers.
Fees are derived from PoolManager's pre-hook Swap record, never InkHook's fee event.
The deterministic handler sequence proves both fee currencies, all swap shapes,
locked swaps, charged swaps, waived swaps and repeated collections are reachable.

`LaunchTokenAccounting.t.sol` runs another 256 sequences of 128 calls. Transfers
include zero, one unit, full balance and self transfers. Approvals, delegated spends,
revocations and specific insufficient-balance/allowance failures are interleaved.
Failed delegated transfers must restore allowances as well as balances.

`HookFailurePaths.t.sol` checks every swap shape while locked, the exact release
deadline, atomic rollback if listing fails, rollback of both fee currencies when
the second payout fails, collection during an existing unlock, failed portrait
queries, same-block borrowing and return, continuously held portraits, constructor
guards, zero fees and the maximum accepted rate. Its partial-fill fuzz test uses a
tight real pool price limit and verifies fees against the executed amount.

All three invariant campaigns enable `fail-on-revert`; expected reverts use
specific errors rather than catch-all suppression. Stateless properties run
1,000 cases via inline Foundry settings. The added properties pass; the
second-seed run exposed a separate existing range-clamping failure described below.

## Reproduction

```sh
forge build --offline
forge test --offline --fuzz-seed 0x6c42b4a49d6986a4b7c227279743f9a84e24af6f705d598448757175f7e37a8f
forge fmt --check
```

The existing optional RPC/full-snapshot tests remain optional; the new tests have
no skips. Existing vault and liquidity-custody invariants continue to cover their
broader pull/reveal/deposit and permanent-position lifecycles.

## Validation results and existing check failures

The clean source export plus these additions compiled 194 files offline and passed
the supplied verifier seed: **162 passed, 0 failed, 28 existing optional skips**.
The three new invariant campaigns each completed 32,768 calls with no unexpected
reverts or discarded inputs. All new Solidity files pass `forge fmt --check`.
Git staging was unavailable because the repository index is read-only, so the
clean-tree check used `git archive HEAD` with the five new test files overlaid.

The second full-suite command was:

```sh
forge test --offline --fuzz-seed 0x2305 --fuzz-runs 2048
```

It produced **161 passed, 1 failed, 28 existing optional skips**. All additions
passed, including another 32,768 calls per new invariant campaign. Inline fuzz
settings take precedence over the command-line default: the added stateless tests
retained 1,000 cases, while unannotated existing properties used 2,048.

The failure was `RangeMathTest.testFuzz_rangeNeverRevertsAndStaysUsable` with
`tick=887270, w=-1, inkIs0=true`. The existing harness bounds the width to its
accepted interval. A direct minimal reproduction needs only spacing 60, width 60,
floor/premium 0 and tick 887270: `InkLiquidity._rangeFrom` returns lower 887280,
upper 887220. At tick -887270 with INK as currency1, it returns lower -887220,
upper -887280. Both are inverted; the outer endpoint also exceeds TickMath's
supported range. The existing unit test permits an empty terminal range, which
does not justify an inverted one.

This low-severity boundary defect is reported in `.imd-findings.json` with a
self-contained two-case proof, executed under `test/scratch/` and confirmed to fail
at `assertLe(lower, upper)` in both cases. Its source is embedded in the report;
the failing scratch file was removed from the runnable suite. Neither production
code nor the existing range property was changed, filtered or weakened. A fix
requires the implementation owner; the passing verifier-seed result does not
establish that this pre-existing property passes every seed.

Repository-wide `forge fmt --check` fails on existing formatting in
`test/SybilOptions.t.sol`, `test/LaunchDay.t.sol`, `script/UploadRenderer.s.sol`
and `script/Configure.s.sol`. These files were not changed. In particular, the
script differences cannot be repaired within the permitted test-only scope.

The required high-severity Slither command exits nonzero with **five results in
unchanged production/dependency code**:

| Detector | Location | Assessment |
| --- | --- | --- |
| `weak-prng` | `src/InkVault.sol:347` | The existing draw deliberately uses a later block hash. The detector result remains; these tests do not establish resistance to block-producer manipulation. |
| `incorrect-exp` (two results) | OpenZeppelin `Math.sol:205`; v4 `FullMath.sol:82` | Both XORs are intentional modular-inverse seeds, as the surrounding algorithm documents. Replacing them with exponentiation would change the algorithm. |
| `incorrect-shift` (two results) | v4 `BitMath.sol:22` and `:40` | These are the dependency's existing bit-position lookup algorithms. No new counterexample was established; dependencies are protected. |

The pass including medium severities reports 50 total results. The additional
categories are `divide-before-multiply`, `incorrect-equality`, `reentrancy-no-eth`,
`uninitialized-local`, `unused-return`, and `write-after-write`. Source-level
review found intended tick alignment and word/group rounding, empty-balance and
same-block checks, zero-initialized accumulators, deliberately unused return
fields, and discarded renderer PRNG outputs. The deposit reentrancy report is
on a `nonReentrant` entry point calling the bound portrait's ordinary
`transferFrom`, with no ERC721 receiver callback. This is a limited disposition,
not a clean static-analysis result or a full audit of the protected dependencies.
No detector configuration or implementation was changed to suppress results.
