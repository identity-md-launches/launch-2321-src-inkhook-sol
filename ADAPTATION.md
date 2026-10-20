# INK hook launch adaptation (Ethereum)

This section records the second launch: the INK token and the InkHook on an INK/IMD Uniswap v4 pool
on Ethereum (chain id 1). The four application contracts are already live (InkPortraits
`0x54fa3515848440ddde2aefe45a382bd868cacd15`, InkVault `0x33c85714c7d78fdb253fe1cf761d2d5c3c12d747`,
InkLiquidity `0xa53a3b0521e471f69c0351d9e6620848e749f37d`, InkRenderer
`0x9853b489003add907ff0849d899f5cb44e8c17d2`) and are not changed or redeployed; this tree is their
exact source (`SOURCE_PROVENANCE.json`). The earlier contracts-only adaptation follows below, unchanged.

## What the launch deploys

| Order | Solidity contract | Constructor arguments, in order |
| --- | --- | --- |
| 1 | `LaunchToken` (`src/LaunchToken.sol`) | none |
| 2 | `InkHook` (`src/InkHook.sol`) | `$poolManager`, `0x54fa3515848440ddde2aefe45a382bd868cacd15` (portraits), `0x33c85714c7d78fdb253fe1cf761d2d5c3c12d747` (vault), `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7` (imd, the pool's paired currency), `0xbc10b3662231c830d2ee10bc6359db17bea4b3d4` (treasury), `25` (feeBps), `$factory` |

Hook permissions, validated against the address bits in the constructor: `beforeInitialize`,
`beforeSwap`, `afterSwap`, `afterSwapReturnDelta`. The pool: INK/IMD, fee 12500, tick spacing 60; the
hook accepts any fee tier and spacing and learns INK from the key in `beforeInitialize`. Neither
constructor calls another contract, so both run on an empty chain (`test/InkHookLaunch.t.sol`,
`InkHookFactoryLaunchTest`). No owner, admin or upgrade role exists on either contract and none was
added; `$owner` appears in no argument. The hook's `beforeRemoveLiquidity` / `afterRemoveLiquidity`
permissions are off, so the factory's zero-change fee collection on its position never reaches the hook.

## Changes

### `src/LaunchToken.sol` (new): the launch token

Required by the launch kind: a fixed-supply ERC-20 with no constructor arguments, 18 decimals, exactly
1,000,000,000 INK (10^27 minor units) minted once to `msg.sender`, the factory. Name and symbol are the
brief's (`INK` / `INK`). OpenZeppelin `ERC20` (vendored 5.1.0) with nothing else: no mint, burn, owner,
pause, blocklist, fee or upgrade function. The factory's 80% remainder, 800,000,000 INK, equals the
vault's `SEATS * PORTRAIT` funding requirement exactly, so `setInk` can succeed (audit finding
73ee013031 below). Tests: `test_tokenIsFixedSupplyInk` (supply, decimals, transfer, no mint/owner),
`test_constructorsNeedNoLiveDependency`, `test_runtimeSizeAndOpcodes`.

### `src/InkHook.sol`: `beforeInitialize` accepts only the launch factory (audit dcacbade3b53, medium)

Reproduced: both supplied proof tests failed on the imported code (a stranger's `initialize` of an
ETH/IMD pool with fee 0 and spacing 1, or of the right pair at a wrong fee tier and price, was accepted
and bound the single-use hook). Fix, within the stated design and the launch reference's pattern: a
seventh constructor argument `address factory_` (the manifest writes `$factory`), stored in the
immutable `factory`, and `beforeInitialize` reverts `NotFactory()` unless its `sender` is that address.
A zero factory reverts `ZeroAddress()`. Everything else in the hook is as written: the lock, the fee,
the `tx.origin` waiver, the payout paths, the absence of any owner. Tests:
`test/InkHookLaunch.t.sol` (`test_strangerCannotBindHookToWrongPoolBeforeFactory`,
`test_strangerCannotFixWrongFeeAndPriceBeforeFactory`, the two proofs adapted;
`test_factoryInitializesExactlyOnePoolPairedWithImd`; `test_factoryBindsThePoolOthersCannot` through a
CREATE2 deployer that then initializes) and `test/InkSystem.t.sol` (`test_onlyTheFactoryCanInitialize`,
plus the zero-factory guard in `test_guards`).

Because the argument was appended, the first six arguments keep their previous order. Every fixture
and script that constructs the hook passes the account that goes on to call `PoolManager.initialize`
in that fixture: `test/InkSystem.t.sol`, `test/AuditRegression.t.sol`,
`test/LiquidityCustodyInvariants.t.sol`, `test/MainnetFork.t.sol` (the test contract),
`script/Rehearse.s.sol` (the simulated IMD launcher), `script/LocalStack.s.sol` (the broadcaster).

### `test/InkHookLaunch.t.sol` (new): launch tests

Required by the launch reference (initialization and unauthorized-callback tests; fee on a buy and a
sell, exact input and exact output; token supply and transfer; constructors on an empty chain). Covers
the lock (`test_noSwapUntilTheVaultReleases`, including that the position can still be modified before
release), the four fee shapes with the 0.25% taken from the unspecified side only, the payout (IMD to
the treasury, INK to `vault.liquidity()`, no ETH, nothing burned), the `tx.origin` waiver, the
immutables and permission set, every callback's `NotPoolManager` / `HookNotImplemented` guard, the
absence of an owner surface, and a CREATE2 rehearsal on chain id 1 with the live dependency addresses
holding no code (runtime sizes below EIP-170, no DELEGATECALL / CALLCODE / SELFDESTRUCT).

### `launch/mainnet-2-hook.json`

The portraits and vault placeholders are filled with the live addresses. It remains a request draft,
not the manifest; `launch.json` is the manifest step's.

### `README.md`

Documents the hook launch: what the fee is, that it is not settled in ETH and why, where each fee goes,
which callbacks the hook enables, and what the brief asked that the token does not do.

## Imported audit findings for this launch

- **dcacbade3b53 (factory-only `beforeInitialize`, medium)**: reproduced and fixed, above.
- **73ee013031 (trading lock has no fallback, low)**: reproduces as described and is what the
  requester asked for ("there is no time-based fallback"), so it stays as a trust assumption. The
  states that keep the pool locked: the vault never funded with 800,000,000 INK, `setInk` / `setup`
  never called by the owner, or key loss. For this launch the supply is 10^27 and `remainderTo` is
  the live vault, so the vault receives exactly 800,000,000 INK and `setInk` is satisfiable
  (`test_tokenIsFixedSupplyInk` pins the arithmetic). The owner's steps remain the owner's.
- **a63665098a41 (waiver keyed to `tx.origin`, low)**: reproduces as described and is what the
  requester specified ("requires `portraits.isAgentHolder(tx.origin)`"), documented in the hook's
  own comment: a relayer or bundler EOA holding an agent portrait exempts every swap it sends, and
  smart-contract wallets never get the waiver. Not changed.
- **ea9b327d8f6f (fee INK listed at the caller's spot tick, low)**: in the live InkLiquidity, which
  this launch cannot change; already the recorded design assumption 942e691ce965. Mitigation is
  operational (a keeper calls `addLiquidity()` promptly). Not changed.
- **0927ef1c0cd2 (coverage, info)** and **f4f552cea499 (manifest notes, info)**: no defect; noted. The
  manifest notes' constructor list now has the seventh `$factory` argument. The brief's "sell hook
  fees for ETH" rule from the generic hook reference does not apply: the requester wrote "do not sell
  hook fees for ETH", and the hook settles each fee in its own currency.

## Verification

Forge 1.8.3, Solidity 0.8.26, the project's own `foundry.toml`. The imported suite passed before any
change (117 passed, 28 skipped). The supplied proof `Proof_dcacbade3b53.t.sol`, run from `test/scratch`
against the unchanged tree, failed both tests ("next call did not revert as expected"), reproducing the
finding. After the changes, with
`FOUNDRY_FUZZ_SEED=0x6c42b4a49d6986a4b7c227279743f9a84e24af6f705d598448757175f7e37a8f`:
`forge build` passes; `forge test` passes with **134 passed, 0 failed, 28 skipped** across 23 suites
(the skips are the existing optional fork and snapshot tests, which need an RPC). `forge build --sizes`:
InkHook runtime 6,246 bytes, LaunchToken 1,752 bytes. No Slither or Mythril run is claimed. No
dependency was added; no protected path was touched; nothing was deployed or signed.

---

# Ethereum contracts-only launch adaptation

## Deployment handoff

This assignment prepares the sources for the later IMD factory deployment. No transaction
was signed or broadcast. No `launch.json` is supplied: that belongs to the manifest step.

Chain: Ethereum, chain ID **1**. `$owner` resolves to
**0x824e12b38cff2d3e7ad9607a0212f7f9eb6a06e3**.

| Order | Solidity contract | Constructor arguments, in order |
| --- | --- | --- |
| 1 | `InkPortraits` | `$owner` |
| 2 | `InkVault` | `$contract:InkPortraits`, `0x0000ec93127baa929e58e97dd0095a2bfb38ec1d`, `$owner` |
| 3 | `InkLiquidity` | `0x000000000004444c5dc75cb358380d2e3de08a90`, `0xbd216513d74c8cf14cf4747e6aaa6420ff64ee9e`, `$owner`, `0xbc10b3662231c830d2ee10bc6359db17bea4b3d4` |
| 4 | `InkRenderer` | `$contract:InkPortraits`, `$owner` |

These existing constructors already satisfy the required order, static argument types,
nonpayability and explicit ownership. None calls a dependency or requires dependency code
during construction. They need no constructor adaptation. All four remain direct deployments,
with no proxy, initializer, upgrade role or linked external library.

The treasury receives IMD fees only. It has no owner/admin role; royalty information still
names `$owner` at the existing **0%** rate. The factory and transaction origin receive no role.
Do not deploy `InkFeeRouter`, `InkHook`, `src/testnet`, or a new ERC-20 in this launch.
The owner deploys the existing fee router separately; the later hook launch creates INK and its pool.

The manager addresses agree with the Ethereum entry in
[Uniswap's official deployment reference](https://developers.uniswap.org/docs/protocols/v4/deployments).
Ethereum RPC reads at block **26,234,564**, using the task's Ethereum provider
(public source: `https://ethereum-rpc.publicnode.com`), confirmed:

- PoolManager: 24,009 bytes of code.
- PositionManager: 23,877 bytes; `poolManager()` returns the above PoolManager.
- The supplied seat contract: 5,231 bytes; `name()` returns `identity.md`.
- IMD `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7`: 22,990 bytes;
  `name()` returns `Identity.md`.

No address was substituted for the future INK token, hook, pool, snapshot root or deployed
application addresses. Those remain the existing owner-configured values.

## Imported audit findings

### 7a54cd1bfe87 — free replacement draws after expiry (medium): reproduced and fixed

Both supplied proof tests failed on the imported code: a trait reroll renewed at a later
block without a second fee, then applied a different seed for that same payment.
A separate test against an unchanged copy also reproduced the analogous pull renewal.

Changes in `src/InkVault.sol`:

- An expired trait reroll now clears the pending request, retains the old seed and emits
  `TraitRerollExpired`. The paid fee remains with liquidity. A further draw requires a new
  `rerollTraits` payment. Anyone can clear the expired request and its transfer lock.
- A pull never receives a replacement entropy block. If its original hash expires before
  being recorded, it closes, releases its reservation, returns its 400,000 INK backing minus
  the existing reroll fee, and sends that fee to liquidity. This gives a discarded draw the
  same cost as returning an unwanted swarm portrait. The fee and agent-holder discount are
  fixed at purchase, so later owner fee changes cannot alter an outstanding pull's refund.
  No new fee rate, price or fee recipient was introduced.
- If a reveal begins while the original hash is available, that hash is saved across bounded
  admission batches. Delaying the remaining batches cannot change the draw. Deposit cutoffs
  remain the original request block.
- `PullExpired`, `pullExpired(id)` and `pullExpiryFee(id)` expose the outcome. `pulls(id).done`
  means the request is closed, including expiry. `reveal(id)` returns false on expiry;
  `revealNext(max)` processes at most `max` requests and returns only the number of portraits
  revealed. Keepers must use `nextReveal < pullCount` to identify remaining work, rather than
  treating a zero reveal count as an empty queue.

For a request in block `b`, its hash is usable from `b + 2` through `b + 257`, inclusive.
Without a saved hash, `b + 258` expires it. An owner-chosen zero reroll fee still means zero
cost, as in the original fee policy; the fix does not override that choice.

Tests: `test/LaunchSafety.t.sol` covers paid retry, exact expiry boundaries, discounted and
changing fees, refund/backing conservation, batch limits and a live pull behind an expired one.
`test/AuditRegression.t.sol` retains admission/candidate-set tests and now expects closure or
the recorded original draw instead of renewal. `test/InkSystem.t.sol` updates the expired-trait
expectation. `test/VaultInvariants.t.sol` accounts for expiry fees independently.

### 8ff058a5ba34 — invalid irreversible configuration (medium): reproduced and fixed

Both supplied setter proofs failed on the imported code: a code-free vault became permanent,
and a code-free INK address stranded the funded vault. Additional tests against unchanged
source confirmed that a hookless native-currency pool was accepted, setup accepted unconfigured
liquidity, and all four owners could renounce before configuration.

Changes:

- `src/InkPortraits.sol`: `setVault` and `setRenderer` require deployed code and a `portraits()`
  reference to this collection. The vault must expose a nonzero seat contract, and the renderer
  must expose its chunk count, so accidentally swapping the two addresses also fails.
  Failed checks leave the setter usable. Renunciation requires both references to be configured.
- `src/InkVault.sol`: `setInk` requires token code and at least `SEATS * PORTRAIT`
  (**800,000,000 INK**) already in the vault. `setup` additionally requires liquidity configured
  for that same INK and `poolSet() == true`. Renunciation requires completed setup.
- `src/InkLiquidity.sol`: `setPool` retains its initialized-pool check and validates the hook's
  recorded token, paired currency, manager, treasury, collection and vault bindings. The vault
  must use the same INK, point back from its collection, and share the liquidity owner's address.
  On chain 1, the other currency must be the verified IMD address (`MAINNET_IMD`). PositionManager
  must report the same PoolManager. All validation precedes the permanent pool/floor assignment.
  Renunciation requires a configured pool.
- `src/InkRenderer.sol`: renunciation requires at least one nonempty art chunk. Empty chunks
  are rejected so they cannot bypass that readiness check or the existing empty-art lock check.

The bindings check consistency and obvious configuration mistakes, not the honesty of arbitrary
contracts that intentionally impersonate those interfaces. The owner must still verify the actual
later launch addresses, snapshot, art bytes and schedule. No owner privilege was added.

Tests: `test/LaunchSafety.t.sol`, `test/InkSystem.t.sol` and `test/AuditRegression.t.sol` exercise
wrong/code-free/unfunded dependencies, wrong collection/token/hook/treasury/manager bindings,
mainnet currency enforcement, uninitialized and zero-tick pools, failure recovery, and guarded
renunciation. `test/helpers/ConfiguredLiquidity.sol` is a token-bound test double used only by
vault-focused tests. Existing renderer, snapshot, preview and invariant fixtures were updated
to use that double; direct mint unit tests now use an actual bound vault.

### f6efe85d4b38 — portraits lost through direct transfers (low): reproduced and fixed

Against unchanged source, a plain `transferFrom` left a portrait owned by the vault without
changing its inventory, paying INK or providing an exit. A safe transfer to InkLiquidity
was also accepted and stranded the portrait.

- `src/InkPortraits.sol`: `_update` rejects transfers into the vault unless the vault is the
  caller, allowing the accounted `deposit` path. It also rejects transfers into the configured
  liquidity address, for both agent and swarm portraits.
- `src/InkLiquidity.sol`: `onERC721Received` accepts only the configured PositionManager,
  preserving intended position custody while rejecting unrelated safe NFT transfers.

Tests: `test/LaunchSafety.t.sol` covers plain transfers, both safe-transfer overloads, approved
operators, both portrait types, unchanged custody/balances on failure, and successful deposits.
`test/InkSystem.t.sol` checks rejection of an unrelated NFT and continued custody of real
PositionManager positions. Existing safe-transfer tests now expect rejection at the NFT layer.
Arbitrary third-party NFTs can still bypass their receiver with their own unsafe transfer
functions; no general rescue or seizure power was added.

### 5a7763c36197 — coverage note (informational)

This was not a defect and required no behavior change. The original constructors already
met the factory requirements. The required two-stage launch cannot know INK, its hook/pool,
the final snapshot or uploaded art during this four-contract deployment. The existing owner
wiring remains, with the validation above, and is not called by the factory. No reported
defect was rejected as non-reproducible.

Existing assumptions remain: plain 18-decimal INK transfers; builder-influenceable blockhash
randomness; permissionless liquidity placement at spot subject to the existing floor; owner
control over bounded fees, liquidity parameters and presentation until the existing locks;
and no time fallback if the owner never completes setup. These were not redesigned.

## Revision: independent review findings

An independent reviewer reopened the accepted work with one reproducible finding and nine
advisory ones. Each was reproduced before anything changed. `.imd-responses.json` carries the
verdicts; this section records what changed and why.

### 16c7464acc9e — reroll discount resold through an agent-holding contract (medium): reproduced and fixed

The supplied proof failed on the accepted tree (a non-holder paid 2,000 instead of 4,000 INK by
handing a swarm portrait in through a contract that parks one agent portrait). The cause: the
discount was priced from `isAgentHolder(msg.sender)`, which says who is calling, not whose
portrait is being handed in. Any check on the caller alone (a "held since an earlier block"
rule on the swarm portrait, a code-length check) still leaves a standing custodial contract able to
extend the discount with a one-block delay, so the fix keys the discount to the portrait's own
history instead:

- `src/InkPortraits.sol`: `_update` records `heldFromVault(tokenId)` for swarm portraits: true while
  the current holder received the portrait straight from the vault (a pull's mint or a revealed
  inventory portrait) and has not moved it since; any other transfer clears it. A trait reroll
  changes no owner, so it keeps the flag. `hasRerollDiscount(holder, tokenId)` combines it with
  ownership and the existing `isAgentHolder` rule. `isAgentHolder` is now `public` so the view can
  reuse it; its ABI is unchanged.
- `src/InkVault.sol`: `deposit()` prices a swarm portrait at `agentRerollFeeBps` only when the
  caller is an agent holder **and** `heldFromVault` is true for that portrait (read before the
  vault's own transfer, which would set it); `rerollTraits()` uses `hasRerollDiscount`. Agent
  portraits still return exactly 400,000 INK. `pull()` is unchanged: the expiry fee is fixed for the
  puller, who is also the recipient, so there is no third party to price it for.

Effect on honest holders: an agent-portrait holder pays half on the swarm portraits it pulled and
still holds (its own luck), which is the reroll the discount was for. A swarm portrait bought on a
marketplace or received from another wallet pays the full fee, even for an agent holder; this is
the same flow the proxy used (the proxy "bought" the portrait for the payout), so it cannot be
exempted without reopening the finding. The residual delegation left is a custodial wrapper that
pulls on users' behalf and keeps the portraits in its own custody; it cannot reach portraits held
in users' wallets, which is the delegation the finding described.

No fee rate, recipient or owner power changed. Tests: `test/LaunchSafety.t.sol` reproduces the
proof's proxy for `deposit()` and `rerollTraits()` and expects the full fee, and checks the
discount on own pulls, its loss on received or moved portraits, repaint keeping it, and non-holders
unchanged. `test/InkSystem.t.sol`'s existing half-price tests still pass (they pull and hand back).

### 68252bb4caa5 — one-step `transferOwnership` reaches the unrecoverable state (low): reproduced and fixed

Confirmed against the accepted tree: `transferOwnership(0xdEaD)` succeeded on every contract
while `renounceOwnership()` was guarded. All four launched contracts now inherit OpenZeppelin
`Ownable2Step` (vendored 5.1.0): a transfer only takes effect once the new owner calls
`acceptOwnership()`, so a wrong address never obtains ownership and the current owner can
correct a pending transfer. Constructors still take `$owner`; no role was added; the
`renounceOwnership` readiness guards are unchanged. `test/InkSystem.t.sol`'s hook-binding test,
which hands the vault's ownership back and forth, now accepts each step. Tests:
`test/LaunchSafety.t.sol` (portraits, vault, renderer) and `test/InkSystem.t.sol` (liquidity).

### b22beff1453b — premium locked by a permissionless `addLiquidity()` before release (low): reproduced and fixed

Confirmed on the system fixture: with `setPool()` done and `setPremium()` pending, anyone holding
400,000 INK could list a zero-premium ladder and every later `setPremium()` reverted. There is
nothing to list before release (the pool is swap-locked and no fee INK exists), so
`src/InkLiquidity.sol` now records the vault the hook is bound to in `setPool()` (`vault()`, taken
from the bindings it already validates) and `addLiquidity()` reverts `NotReleased` until
`InkVault.released()`. `release()` sets that flag before it calls `addLiquidity()`, so the release
path is unchanged. The documented order (premium, then pool) still works and is no longer
load-bearing; the comment in `script/InkSteps.sol` says so. Tests: `test/InkSystem.t.sol`
(`test_premiumCannotBeLockedByListingBeforeRelease`, and the guard test now expects `NotReleased`
before release).

### 96b69dd541d1 — `_rangeFrom` overflow with a width near `type(int24).max` (info): reproduced and fixed

Confirmed by unit test: with INK as currency0 and a non-negative tick, `lower + w` panicked before
the clamp. `_rangeFrom` now widens in `int256` and clamps to the usable tick range; `setWidth` keeps
its existing lower bound only. `test/RangeMath.t.sol` primes a harness with both token orderings,
checks the clamp at the maximum width, fuzzes every width and tick, and pins an ordinary range.

### Advisory findings left unchanged

- **70ff8571d323 (trait-reroll free option, low)**: reproduces as described and is the documented
  residual of accepted fix 7a54cd1bfe87. The two ways to remove it are a forced reveal paid from
  the fee (a keeper bounty, which splits the requester's fee rate) or an expiry seed derived from a
  request-time value, which the holder can also compute and so only changes which two seeds the
  holder chooses between. Neither is a smaller change than the current one; the cost of the abort
  path is a 256-block transfer lock, and the fee is spent either way. Left for the owner.
- **942e691ce965 (fee INK listed at the caller's spot tick, low)**: unchanged, as the retained
  design assumption already recorded above; the release floor bounds it.
- **27491bae6b86 (hook exemption keyed to `tx.origin`, low)**: `InkHook` is not deployed by this
  launch. Its comment now states the converse (a transaction an agent-holder EOA sends for others
  is exempt as a whole) next to the existing smart-wallet note; no logic changed.
- **c6e22ac0d422 (`pull()` has no fee bound, info)**: the expiry fee is bounded by
  `MAX_FEE_BPS`, is only paid if nobody reveals within 256 blocks (the puller can always reveal),
  and the owner is trusted for fee changes; `pull(uint256)`'s signature is left as the project's
  tests and scripts use it.
- **8c199ec1fbb9 (INK above outstanding backing is stranded, info)**: every path moves exact
  portrait multiples by design; forwarding a surplus would add a payout path the brief did not ask
  for. Documented: send exactly the allocation.
- **e507b4d5ebe7 (hook fee rounds to zero below 100 wei, info)**: not deployed here; a fee-free
  band of 1e-16 of a token per swap, no change.

## Other changed files and reasons

- `test/MainnetContractsLaunch.t.sol`: rehearses exactly the four requested deployments in
  one CREATE2 factory call on an empty chain, checks references, owners, royalties, unauthorized
  administrative calls, init/runtime sizes and forbidden runtime opcodes.
- `test/InkRenderer.t.sol`, `test/SnapshotProofs.t.sol`, `test/SnapshotAllSeats.t.sol`,
  `test/TokenURIPreview.t.sol`: replace previously unconstrained liquidity/vault fixtures with
  valid bindings required by the setter fix. Their art/trait/proof assertions are retained.
- `launch/mainnet-1-contracts.json`: removes the old fifth fee-router deployment from the
  request draft and explicitly leaves it to the owner, matching this assignment.
- `README.md`, `SETUP.md`, `launch/README.md`: record the current scope, correct owner/treasury
  distinction, configuration order, expiry semantics and validation entry point.
- `script/InkSteps.sol`: corrects only the treasury and premium-order comments; it does not change
  script logic.
- `test/RangeMath.t.sol`: range-arithmetic harness for the width clamp (revision).
- `ADAPTATION.md`: this change log and deployment handoff.

The existing build configuration, dependencies, artwork, hook and fee-router logic remain
unchanged. Packaging fingerprints in the imported repository remain historical evidence of
that baseline, not fingerprints of this adaptation. No dependency was installed or added.

## Verification

Toolchain: Forge **1.8.3**, Solidity **0.8.26**, original Cancun/optimizer-200/non-via-IR
configuration with `bytecode_hash = "none"`. Seed:
`0x5ba4a490487a4af407fdbe3b9c8ca3151a1870567475ec05d2caa23cfe03a32d`.

The imported suite passed before changes: **75 passed, 0 failed, 28 skipped**. The supplied
audit proofs then produced **4 expected failures**; six additional exploit assertions
against unchanged source passed. Those temporary reproductions were confined to scratch
and are not part of the deliverable.

After the revision, `forge build --sizes` reports runtimes of **9,307 / 12,400 / 12,437 / 12,991
bytes** (InkPortraits, InkVault, InkLiquidity, InkRenderer), each below EIP-170. All init codes
including arguments fit EIP-3860.
No bytecode contains an external library link; the deployed runtime scan passes for
DELEGATECALL, CALLCODE and SELFDESTRUCT exclusions.

Final `forge build` passed, including a clean rebuild during validation. Compiler warnings
are the existing uint128 shift in the liquidity ladder and shadowed names in `LocalStack.s.sol`.

The final full seeded `forge test` run after the revision passed: **107 passed, 0 failed,
28 skipped** across 19 suites (plus the reviewer's proof and the remaining audit setter proof,
run from scratch: both pass). Fuzz tests ran 256 cases each; the original seven vault invariants passed at
64 runs × 120 calls with zero handler reverts. Skips are the existing optional fork/snapshot
tests; no new regression or factory test skips. The default suite remains network-independent.

The mainnet integration command uses the same seed, `FORK_BLOCK=26234564` and
`--match-contract 'MainnetForkInkIs[01]Test'`. It covers both token orderings with the actual
PoolManager, PositionManager, Permit2, Universal Router, seat contract and IMD.
The final fork run passed: **14 passed, 0 failed, 0 skipped**. The two suites exercised
both token orderings, including full lifecycle, trading lock, fee routing and router swaps.
These are local fork simulations; no live transaction was submitted.

`git diff --check` passed. A changed-path check confirmed that no protected build,
dependency, environment or repository-control path was modified. The updated request
draft parses as JSON and names exactly the four contracts in the required order.

No Slither or Mythril run is claimed. Tests are local evidence, not a replacement for the
assignment's independent review. Deployment, source verification and real snapshot/art
configuration remain with the later deployer and owner.
