// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/libraries/CustomRevert.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {InkHook} from "src/InkHook.sol";
import {InkPortraits} from "src/InkPortraits.sol";
import {InkVault} from "src/InkVault.sol";
import {InkLiquidity} from "src/InkLiquidity.sol";
import {LaunchToken} from "src/LaunchToken.sol";
import {HookAccountingFixture} from "./helpers/HookAccountingFixture.sol";

/// Tracks fees from the PoolManager's gross Swap event, not from InkHook's FeeTaken event.
/// Eligibility has its own ownership/block ledger; the hook's isAgentHolder query is not the oracle.
contract HookAccountingHandler is Test {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    struct Snapshot {
        int256 payer0;
        int256 payer1;
        uint256 claim0;
        uint256 claim1;
    }

    struct ExpectedSwap {
        int128 gross0;
        int128 gross1;
        uint256 fee0;
        uint256 fee1;
    }

    bytes32 internal constant SWAP_EVENT =
        keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
    InkHook public hook;
    InkVault public vault;
    InkPortraits public portraits;
    InkLiquidity public liquidity;
    LaunchToken public ink;
    IERC20 public imd;
    IPoolManager public manager;
    PoolSwapTest public router;
    PoolKey internal key;
    address[4] public actors;
    bool internal inkIs0;

    uint256 public accruedInk;
    uint256 public accruedImd;
    uint256 public paidInk;
    uint256 public paidImd;
    uint256 public releaseDust;
    uint256 public openedAt;
    bool public didRelease;
    uint256 public lockedAttempts;
    uint256 public chargedSwaps;
    uint256 public waivedSwaps;
    uint256[4] public swapShapes;
    mapping(address => uint256) public agentCount;
    mapping(address => uint256) public holderSince;

    constructor(InkHook hook_, PoolSwapTest router_, PoolKey memory key_, address[4] memory actors_) {
        hook = hook_;
        manager = hook.poolManager();
        vault = InkVault(address(hook.vault()));
        portraits = InkPortraits(address(hook.portraits()));
        liquidity = InkLiquidity(vault.liquidity());
        ink = LaunchToken(Currency.unwrap(hook.ink()));
        imd = IERC20(Currency.unwrap(hook.imd()));
        router = router_;
        key = key_;
        actors = actors_;
        inkIs0 = Currency.unwrap(key.currency0) == address(ink);
        agentCount[actors[0]] = 1;
        agentCount[actors[1]] = 1;
        holderSince[actors[0]] = block.number;
        holderSince[actors[1]] = block.number;
    }

    function eligible(address who) public view returns (bool) {
        return agentCount[who] != 0 && holderSince[who] < block.number;
    }

    /// All four modes, separate payer and origin, and a dust-biased amount range.
    /// Actors start with 10M of each token; even 128 maximum trades cannot exhaust their funding.
    function trade(uint256 payerSeed, uint256 originSeed, uint256 rawAmount, uint8 rawMode, bool dust)
        public
    {
        uint8 mode = rawMode % 4;
        uint256 amount = bound(rawAmount, 1, dust ? 800 : 1_000e18);
        address payer = actors[payerSeed % 4];
        address origin = actors[originSeed % 4];
        bool zeroForOne = mode < 2 ? !inkIs0 : inkIs0;
        SwapParams memory params = SwapParams(
            zeroForOne,
            mode % 2 == 0 ? -int256(amount) : int256(amount),
            zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
        Snapshot memory before_ = _snapshot(payer);
        if (!didRelease) {
            vm.prank(payer, origin);
            vm.expectRevert(
                abi.encodeWithSelector(
                    CustomRevert.WrappedError.selector,
                    address(hook),
                    IHooks.beforeSwap.selector,
                    abi.encodeWithSelector(InkHook.TradingNotOpen.selector),
                    abi.encodeWithSelector(Hooks.HookCallFailed.selector)
                )
            );
            router.swap(key, params, PoolSwapTest.TestSettings(false, false), "");
            Snapshot memory after_ = _snapshot(payer);
            assertEq(keccak256(abi.encode(after_)), keccak256(abi.encode(before_)), "locked swap moved value");
            lockedAttempts++;
            return;
        }

        vm.recordLogs();
        vm.prank(payer, origin);
        BalanceDelta net = router.swap(key, params, PoolSwapTest.TestSettings(false, false), "");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        _checkSwap(logs, before_, net, payer, origin, mode);
        if (openedAt == 0) openedAt = block.timestamp;
        swapShapes[mode]++;
    }

    function _snapshot(address payer) internal view returns (Snapshot memory s) {
        s.payer0 = int256(IERC20(Currency.unwrap(key.currency0)).balanceOf(payer));
        s.payer1 = int256(IERC20(Currency.unwrap(key.currency1)).balanceOf(payer));
        s.claim0 = manager.balanceOf(address(hook), key.currency0.toId());
        s.claim1 = manager.balanceOf(address(hook), key.currency1.toId());
    }

    function _grossAmounts(Vm.Log[] memory logs) internal view returns (int128 gross0, int128 gross1) {
        uint256 found;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(manager) || logs[i].topics[0] != SWAP_EVENT) continue;
            assertEq(logs[i].topics[1], PoolId.unwrap(key.toId()), "wrong pool's swap");
            assertEq(address(uint160(uint256(logs[i].topics[2]))), address(router));
            uint24 poolFee;
            (gross0, gross1,,,, poolFee) =
                abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
            assertEq(poolFee, 12_500, "the hook does not replace the pool's fee");
            found++;
        }
        assertEq(found, 1, "the independent gross-delta oracle must be exercised");
    }

    function _checkSwap(
        Vm.Log[] memory logs,
        Snapshot memory before_,
        BalanceDelta net,
        address payer,
        address origin,
        uint8 mode
    ) internal {
        ExpectedSwap memory expected = _expectedSwap(logs, origin, mode);
        assertEq(
            int256(net.amount0()), int256(expected.gross0) - int256(expected.fee0), "currency0 hook debit"
        );
        assertEq(
            int256(net.amount1()), int256(expected.gross1) - int256(expected.fee1), "currency1 hook debit"
        );
        Snapshot memory after_ = _snapshot(payer);
        assertEq(after_.payer0 - before_.payer0, int256(net.amount0()), "currency0 actually settled");
        assertEq(after_.payer1 - before_.payer1, int256(net.amount1()), "currency1 actually settled");
        assertEq(after_.claim0 - before_.claim0, expected.fee0, "currency0 backed fee claim");
        assertEq(after_.claim1 - before_.claim1, expected.fee1, "currency1 backed fee claim");
    }

    function _expectedSwap(Vm.Log[] memory logs, address origin, uint8 mode)
        internal
        returns (ExpectedSwap memory expected)
    {
        (expected.gross0, expected.gross1) = _grossAmounts(logs);
        // Explicit truth table from the specification: buy-input/sell-output charge INK;
        // buy-output/sell-input charge IMD. Never infer the currency from the hook's mint.
        bool feeInInk = mode == 0 || mode == 3;
        bool feeIs0 = feeInInk == inkIs0;
        int256 grossUnspecified = feeIs0 ? int256(expected.gross0) : int256(expected.gross1);
        uint256 magnitude = uint256(grossUnspecified < 0 ? -grossUnspecified : grossUnspecified);
        uint256 fee;
        if (eligible(origin)) {
            waivedSwaps++;
        } else {
            // 25 basis points = one minor unit for every complete 400 gross minor units.
            fee = magnitude / 400;
            chargedSwaps++;
        }
        expected.fee0 = feeIs0 ? fee : 0;
        expected.fee1 = feeIs0 ? 0 : fee;
        if (feeInInk) accruedInk += fee;
        else accruedImd += fee;
    }

    function collect(uint256 callerSeed) public {
        uint256 expectedImd = accruedImd - paidImd;
        uint256 expectedInk = accruedInk - paidInk;
        uint256 imdBefore = imd.balanceOf(hook.treasury());
        uint256 inkBefore = ink.balanceOf(address(liquidity));
        vm.prank(actors[callerSeed % 4]);
        (uint256 a, uint256 b) = hook.collectFees();
        assertEq(a, expectedImd, "collection must drain every accrued IMD claim");
        assertEq(b, expectedInk, "collection must drain every accrued INK claim");
        assertEq(imd.balanceOf(hook.treasury()) - imdBefore, a, "only the fixed treasury receives IMD");
        assertEq(ink.balanceOf(address(liquidity)) - inkBefore, b, "only vault.liquidity receives INK");
        paidImd += a;
        paidInk += b;
    }

    function release(uint256 callerSeed) public {
        if (didRelease) {
            vm.prank(actors[callerSeed % 4]);
            vm.expectRevert(InkVault.AlreadyReleased.selector);
            vault.release();
            return;
        }
        if (block.timestamp < vault.claimEnd()) vm.warp(vault.claimEnd());
        uint256 before_ = ink.balanceOf(address(manager));
        vm.prank(actors[callerSeed % 4]);
        uint256 released = vault.release();
        assertEq(released, 1_998 * 400_000e18);
        assertEq(liquidity.positionCount(), 8, "release lists the full ladder atomically");
        releaseDust = ink.balanceOf(address(liquidity));
        assertEq(ink.balanceOf(address(manager)) - before_ + releaseDust, released);
        didRelease = true;
    }

    function advance(uint256 secondsSeed, uint256 blocksSeed) public {
        vm.warp(block.timestamp + bound(secondsSeed, 0, 3 days));
        vm.roll(block.number + bound(blocksSeed, 0, 4));
    }

    function movePortrait(uint256 idSeed, uint256 toSeed) public {
        uint256 id = idSeed % 2 == 0 ? 7 : 280;
        address from = portraits.ownerOf(id);
        uint256 index = toSeed % 4;
        if (actors[index] == from) index = (index + 1) % 4;
        address to = actors[index];
        vm.prank(from);
        portraits.transferFrom(from, to, id);
        agentCount[from]--;
        if (agentCount[to] == 0) holderSince[to] = block.number;
        agentCount[to]++;
    }
}

abstract contract HookAccountingInvariantBase is HookAccountingFixture {
    using CurrencyLibrary for Currency;

    HookAccountingHandler internal handler;
    function _inkFirst() internal pure virtual returns (bool);

    function setUp() public {
        _setUpHook(_inkFirst());
        handler = new HookAccountingHandler(hook, router, key, actors);
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = handler.trade.selector;
        selectors[1] = handler.collect.selector;
        selectors[2] = handler.release.selector;
        selectors[3] = handler.advance.selector;
        selectors[4] = handler.movePortrait.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    /// SHOULD-HOLD: every gross swap fee is either still a claim or paid to its immutable recipient.
    function invariant_accrualEqualsClaimsPlusPayouts() public view {
        assertEq(
            manager.balanceOf(address(hook), Currency.wrap(address(ink)).toId()) + handler.paidInk(),
            handler.accruedInk()
        );
        assertEq(
            manager.balanceOf(address(hook), Currency.wrap(IMD).toId()) + handler.paidImd(),
            handler.accruedImd()
        );
        assertEq(imd.balanceOf(TREASURY), handler.paidImd());
        assertEq(ink.balanceOf(LIQUIDITY), handler.releaseDust() + handler.paidInk());
        assertEq(ink.balanceOf(TREASURY), 0);
        assertEq(imd.balanceOf(LIQUIDITY), 0);
        assertEq(ink.balanceOf(address(hook)) + imd.balanceOf(address(hook)), 0);
        assertEq(address(hook).balance, 0);
    }

    /// SHOULD-HOLD: ERC20 conservation over every custodian, no mint/burn/ETH conversion during fees.
    function invariant_fixedSupplyAndCustody() public view {
        assertEq(ink.totalSupply(), 1e27);
        assertEq(imd.totalSupply(), 200_000_000e18);
        assertEq(_sum(IERC20(address(ink))), ink.totalSupply());
        assertEq(_sum(IERC20(IMD)), imd.totalSupply());
        uint256 backing = handler.didRelease() ? 2 * PORTRAIT_BACKING : 2_000 * PORTRAIT_BACKING;
        assertEq(ink.balanceOf(VAULT), backing);
        assertEq(ink.balanceOf(address(posm)), 0);
    }

    function _sum(IERC20 token) internal view returns (uint256 total) {
        total = token.balanceOf(address(this)) + token.balanceOf(address(manager)) + token.balanceOf(VAULT)
            + token.balanceOf(LIQUIDITY) + token.balanceOf(TREASURY) + token.balanceOf(address(hook))
            + token.balanceOf(address(router)) + token.balanceOf(address(lpRouter))
            + token.balanceOf(address(posm)) + token.balanceOf(address(handler));
        for (uint256 i; i < 4; i++) {
            total += token.balanceOf(actors[i]);
        }
    }

    /// SHOULD-HOLD: time cannot unlock trading; release is final and the first swap timestamp is stable.
    function invariant_releaseAndFirstTradeAreMonotonic() public view {
        assertEq(vault.released(), handler.didRelease());
        assertEq(hook.tradingOpen(), handler.didRelease());
        assertEq(hook.tradingOpenedAt(), handler.openedAt());
        assertEq(hook.poolOpenedAt(), 1_800_000_000);
        assertTrue(hook.poolCreated());
        assertEq(address(hook.portraits()), PORTRAITS);
        assertEq(address(hook.vault()), VAULT);
        assertEq(Currency.unwrap(hook.imd()), IMD);
        assertEq(Currency.unwrap(hook.ink()), address(ink));
        assertEq(hook.treasury(), TREASURY);
        assertEq(hook.feeBps(), 25);
        assertEq(hook.factory(), address(this));
    }

    /// SHOULD-HOLD: independently tracked portrait transfers determine eligibility, not router/payer.
    function invariant_portraitEligibilityMatchesOwnershipHistory() public view {
        uint256 total;
        for (uint256 i; i < 4; i++) {
            assertEq(portraits.agentBalanceOf(actors[i]), handler.agentCount(actors[i]));
            assertEq(portraits.isAgentHolder(actors[i]), handler.eligible(actors[i]));
            total += handler.agentCount(actors[i]);
        }
        assertEq(total, 2);
        assertEq(portraits.totalSupply(), 2);
    }

    /// Demonstrates that no random property relies on an unreachable path or an empty fee bucket.
    function test_handlerReachesLocksAllSwapShapesWaiversAndRepeatedCollections() public {
        handler.advance(10 days, 0);
        handler.trade(2, 2, 1e18, 0, false);
        assertEq(handler.lockedAttempts(), 1, "time alone cannot open trading");
        handler.release(3);
        for (uint8 mode; mode < 4; mode++) {
            handler.trade(2, 2, 1e18, mode, false);
        }
        assertGt(handler.accruedInk(), 0);
        assertGt(handler.accruedImd(), 0);
        handler.advance(0, 1);
        for (uint8 mode; mode < 4; mode++) {
            handler.trade(2, 0, 1e18, mode, false);
        }
        assertEq(handler.chargedSwaps(), 4);
        assertEq(handler.waivedSwaps(), 4);
        for (uint8 mode; mode < 4; mode++) {
            assertEq(handler.swapShapes(mode), 2);
        }
        handler.movePortrait(0, 2);
        handler.trade(2, 2, 1e18, 0, false); // newly received portrait is not mature
        handler.advance(0, 1);
        handler.trade(0, 2, 1e18, 0, false); // origin qualifies although payer no longer does
        handler.collect(3);
        handler.collect(0);
        handler.release(2);
        invariant_accrualEqualsClaimsPlusPayouts();
        invariant_fixedSupplyAndCustody();
        invariant_releaseAndFirstTradeAreMonotonic();
        invariant_portraitEligibilityMatchesOwnershipHistory();
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 128
/// forge-config: default.invariant.fail-on-revert = true
contract HookAccountingInk0Test is HookAccountingInvariantBase {
    function _inkFirst() internal pure override returns (bool) {
        return true;
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 128
/// forge-config: default.invariant.fail-on-revert = true
contract HookAccountingInk1Test is HookAccountingInvariantBase {
    function _inkFirst() internal pure override returns (bool) {
        return false;
    }
}
