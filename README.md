# Ink & Inference — portable launch source

> **Deployed source (20 Oct 2026).** `src/`, `script/`, `test/` and `foundry.toml` here are byte-identical to IMD launch 2305's
> delivered tree (identity-md-launches/launch-2305-deploy-nft-vault-liquidity @5797023), which deployed InkPortraits
> 0x54fa…cd15, InkVault 0x33c8…d747, InkLiquidity 0xa53a…f37d and InkRenderer 0x9853…17d2 on Ethereum mainnet
> (Sourcify: exact match). `SHA256SUMS`, `BYTECODE_HASHES.json` and `SOURCE_PROVENANCE.json` were regenerated for this
> tree. This commit is the source for the INK hook launch (`src/InkHook.sol`).

## The INK hook launch

The launch deploys two contracts, in this order, and nothing else (the four application contracts above
are live and unchanged):

- `src/LaunchToken.sol`: INK (symbol `INK`), a plain fixed-supply ERC-20, 1,000,000,000 tokens at 18
  decimals minted once to the launch factory, which splits it 10% swarm / 10% pool / 80% InkVault. It has
  no mint, burn, owner, pause, blocklist, fee or upgrade function. The brief's hook fee and trading lock
  live in the hook, not the token.
- `src/InkHook.sol`: the hook on the INK/IMD pool (pool fee 1.25%, the launch policy's tier; tick spacing
  60). Constructor: `$poolManager`, InkPortraits, InkVault, IMD, the treasury
  `0xbc10b3662231c830d2ee10bc6359db17bea4b3d4`, `25`, `$factory`. It has no owner, admin or upgrade role.

Callbacks the hook enables: `beforeInitialize` (only the launch factory may bind the hook to a pool, and
only once, paired with IMD; this is the audit fix dcacbade3b53, see ADAPTATION.md), `beforeSwap` (the
trading lock: every swap reverts until `InkVault.released()`; no time-based fallback) and `afterSwap`
with `afterSwapReturnDelta` (the hook fee). All other callbacks are off, so the factory's zero-change fee
collection on its liquidity position never involves the hook.

The hook fee is 0.25% of the side the swapper does not fix: the output of an exact-input swap, the
input of an exact-output swap, in whichever currency that is. It is waived when `tx.origin` has held an
agent portrait since an earlier block. Fees are held as Uniswap claims and paid out by `collectFees()`,
callable by anyone: IMD to the treasury, INK to `InkVault.liquidity()` (the live InkLiquidity), which
adds it back to the pool. The fee is **not** settled in ETH and nothing is burned: the requester's brief
says "do not sell hook fees for ETH", which overrides the generic hook reference's ETH settlement. The
pool's own 1.25% trading-fee share goes to the wallet that paid for the launch,
`0x824e12b38cff2d3e7ad9607a0212f7f9eb6a06e3`, through the factory.

`test/InkHookLaunch.t.sol` tests the token, the factory-only binding, every callback's guard, the lock,
the fee on a buy and a sell at exact input and exact output, the payout and the waiver, and rehearses
both constructors on an empty chain.

This is launch source. Original packaging did not audit, upload, pay for or deploy these
contracts. The package does not include the real snapshot, private cutoff, keys,
RPC credentials or confirmed deployed application addresses.

The Ethereum contracts-only adaptation is documented in [ADAPTATION.md](ADAPTATION.md),
including the supplied owner, the four-contract deployment order, reproduced audit fixes,
and validation results. INK and its hook/pool belong to the later launch; the owner deploys
InkFeeRouter separately. Original packaging fingerprints (`SHA256SUMS`,
`BYTECODE_HASHES.json`, `SOURCE_PROVENANCE.json`, `VALIDATION.txt`) describe the imported
baseline, not this adapted source.

## Included

- All five production contracts and the test-only TestSeats helper.
- Every current Foundry test, fixed trait cases and synthetic snapshot proofs.
- Exact installed Solidity dependencies and available license/config metadata.
- `art/original-art.js`: the original algorithm, byte-for-byte, NOT replacement artwork.
- `script/UploadRenderer.s.sol`: uploads that file after stripping its module export line.
- `launch/`: draft Sepolia/Ethereum request bodies and deployment-order notes.
- `SETUP.md`, audit brief, provenance, hashes and isolated validation results.

This directory is the root of a self-contained Foundry repository. No sibling web app
or other workspace directory is needed. No unpinned dependency install script is used.

## Build and test

Install Foundry using https://getfoundry.sh/ and use the version recorded in VALIDATION.txt.
Run at this directory's root:

```sh
forge build
FOUNDRY_FUZZ_SEED=0x5ba4a490487a4af407fdbe3b9c8ca3151a1870567475ec05d2caa23cfe03a32d forge test -vv
```

Solidity 0.8.26 may be downloaded by Foundry if not already installed. No RPC, wallet,
real metrics, Node dependencies or funded account is required to build/test.
The default profile is read-only. `FOUNDRY_PROFILE=preview forge test --mt test_writeTokenURIs` also writes
the rendered tokenURIs to `out-preview/` to open by eye; it is ignored and excluded from the archive.

The build uses Cancun, optimizer 200, no via-IR and bytecode_hash none, as in the source project.
Imported production bytecode was compared across two clean builds; see the historical BYTECODE_HASHES.json.
Renderer/preview tests use the real original art; snapshot tests use invented metrics.
Do not claim this validates the actual mainnet snapshot or original snapshot-fetching pipeline.

## Publication and ownership

Publishing this directory makes the original art algorithm public, as well as contracts,
tests, dependency source and launch drafts. Review this boundary before GitHub upload.
Review owner-authored source licensing separately; no blanket project license was invented.
Retain dependency licenses. Do not deploy TestSeats on mainnet.

Read SETUP.md before signing anything. Read PACKAGING.md for portability changes.
The website/API and marketplace image-hosting service are not included in this package.
