// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {CustomRevert} from "v4-core/libraries/CustomRevert.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {InkHook, IAgentPortraits, IInkVault} from "src/InkHook.sol";
import {InkVault} from "src/InkVault.sol";
import {HookAccountingFixture} from "./helpers/HookAccountingFixture.sol";

contract NestedHookCollection is IUnlockCallback {
    IPoolManager internal immutable manager;
    InkHook internal immutable hook;

    constructor(IPoolManager manager_, InkHook hook_) {
        manager = manager_;
        hook = hook_;
    }

    function collectWhileUnlocked() external {
        manager.unlock("");
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        require(msg.sender == address(manager));
        hook.collectFees();
        return "";
    }
}

abstract contract HookFailurePathsBase is HookAccountingFixture {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    function _inkFirst() internal pure virtual returns (bool);

    function setUp() public {
        _setUpHook(_inkFirst());
    }

    function _claims() internal view returns (uint256 imdClaim, uint256 inkClaim) {
        imdClaim = manager.balanceOf(address(hook), Currency.wrap(IMD).toId());
        inkClaim = manager.balanceOf(address(hook), Currency.wrap(address(ink)).toId());
    }

    function _accrueBoth() internal {
        _release();
        _swap(actors[2], actors[2], 0, 1e18);
        _swap(actors[2], actors[2], 2, 1e18);
        (uint256 a, uint256 b) = _claims();
        assertGt(a, 0);
        assertGt(b, 0);
    }

    function test_everySwapShapeRemainsLockedLongAfterTheClaimWindow() public {
        vm.warp(vault.claimEnd() + 365 days);
        uint256 inkBefore = ink.balanceOf(actors[0]);
        uint256 imdBefore = imd.balanceOf(actors[0]);
        vm.roll(block.number + 1);
        assertTrue(portraits.isAgentHolder(actors[0]), "even a mature holder cannot bypass the lock");
        for (uint8 mode; mode < 4; mode++) {
            SwapParams memory params = _params(mode, 1e18);
            vm.prank(actors[0], actors[0]);
            vm.expectRevert(_wrapped(IHooks.beforeSwap.selector, InkHook.TradingNotOpen.selector));
            router.swap(key, params, PoolSwapTest.TestSettings(false, false), "");
        }
        assertFalse(hook.tradingOpen());
        assertEq(hook.tradingOpenedAt(), 0);
        assertEq(ink.balanceOf(actors[0]), inkBefore);
        assertEq(imd.balanceOf(actors[0]), imdBefore);
        (uint256 a, uint256 b) = _claims();
        assertEq(a + b, 0);
    }

    function test_releaseBoundaryAndFailedListingAreAtomic() public {
        uint256 deadline = vault.claimEnd();
        vm.warp(deadline - 1);
        vm.expectRevert(InkVault.ClaimStillOpen.selector);
        vault.release();
        vm.warp(deadline);
        uint256 vaultBefore = ink.balanceOf(VAULT);
        uint256 managerBefore = ink.balanceOf(address(manager));
        bytes memory reason = abi.encodeWithSignature("PositionSettlementUnavailable()");
        vm.mockCallRevert(address(posm), abi.encodeWithSelector(posm.modifyLiquidities.selector), reason);
        vm.prank(actors[3]);
        vm.expectRevert(reason);
        vault.release();
        assertFalse(vault.released());
        assertFalse(hook.tradingOpen(), "failed listing must not open trading");
        assertEq(ink.balanceOf(VAULT), vaultBefore);
        assertEq(ink.balanceOf(address(manager)), managerBefore);
        assertEq(ink.balanceOf(LIQUIDITY), 0);
        assertEq(ink.balanceOf(address(posm)), 0);
        assertEq(liquidity.positionCount(), 0);
        vm.clearMockedCalls();
        vm.prank(actors[3]);
        assertEq(vault.release(), 1_998 * PORTRAIT_BACKING);
        assertTrue(hook.tradingOpen());
        assertEq(hook.tradingOpenedAt(), 0, "release alone is not the first swap");
        assertEq(liquidity.positionCount(), 8);
        assertEq(ink.balanceOf(VAULT), 2 * PORTRAIT_BACKING);
        vm.expectRevert(InkVault.AlreadyReleased.selector);
        vault.release();
    }

    function test_failedInkPayoutRollsBackBothCurrenciesAndCanBeRetried() public {
        _accrueBoth();
        (uint256 imdFee, uint256 inkFee) = _claims();
        uint256 liquidityBefore = ink.balanceOf(LIQUIDITY);
        uint256 imdBefore = imd.balanceOf(address(manager));
        uint256 inkBefore = ink.balanceOf(address(manager));
        bytes memory reason = abi.encodeWithSignature("RecipientTransferUnavailable()");
        vm.mockCallRevert(address(ink), abi.encodeCall(IERC20.transfer, (LIQUIDITY, inkFee)), reason);
        vm.prank(actors[3]);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(ink),
                IERC20.transfer.selector,
                reason,
                abi.encodeWithSelector(CurrencyLibrary.ERC20TransferFailed.selector)
            )
        );
        hook.collectFees();
        (uint256 a, uint256 b) = _claims();
        assertEq(a, imdFee, "the earlier IMD claim burn must also roll back");
        assertEq(b, inkFee);
        assertEq(imd.balanceOf(TREASURY), 0, "no partial payout");
        assertEq(ink.balanceOf(LIQUIDITY), liquidityBefore);
        assertEq(imd.balanceOf(address(manager)), imdBefore);
        assertEq(ink.balanceOf(address(manager)), inkBefore);
        vm.clearMockedCalls();
        vm.prank(actors[1]);
        (a, b) = hook.collectFees();
        assertEq(a, imdFee);
        assertEq(b, inkFee);
        assertEq(imd.balanceOf(TREASURY), imdFee);
        assertEq(ink.balanceOf(LIQUIDITY), liquidityBefore + inkFee);
        (a, b) = hook.collectFees();
        assertEq(a + b, 0, "a retry cannot collect a second time");
    }

    function test_nestedCollectionCannotConsumeClaimsOrPoisonTheNextCollection() public {
        _accrueBoth();
        (uint256 a, uint256 b) = _claims();
        NestedHookCollection probe = new NestedHookCollection(manager, hook);
        vm.expectRevert(IPoolManager.AlreadyUnlocked.selector);
        probe.collectWhileUnlocked();
        (uint256 afterA, uint256 afterB) = _claims();
        assertEq(afterA, a);
        assertEq(afterB, b);
        (afterA, afterB) = hook.collectFees();
        assertEq(afterA, a);
        assertEq(afterB, b);
    }

    function test_failedPortraitQueryRollsBackTheFirstTradeAndItsPrice() public {
        _release();
        (uint160 priceBefore,,,) = manager.getSlot0(key.toId());
        bytes memory reason = abi.encodeWithSignature("PortraitQueryUnavailable()");
        vm.mockCallRevert(PORTRAITS, abi.encodeCall(IAgentPortraits.isAgentHolder, (actors[2])), reason);
        uint256 beforeInk = ink.balanceOf(actors[2]);
        uint256 beforeImd = imd.balanceOf(actors[2]);
        SwapParams memory params = _params(0, 1e18);
        vm.prank(actors[2], actors[2]);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.afterSwap.selector,
                reason,
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        router.swap(key, params, PoolSwapTest.TestSettings(false, false), "");
        (uint160 priceAfter,,,) = manager.getSlot0(key.toId());
        assertEq(priceAfter, priceBefore);
        assertEq(hook.tradingOpenedAt(), 0);
        assertEq(ink.balanceOf(actors[2]), beforeInk);
        assertEq(imd.balanceOf(actors[2]), beforeImd);
        (uint256 a, uint256 b) = _claims();
        assertEq(a + b, 0);
        vm.clearMockedCalls();
        _swap(actors[2], actors[2], 0, 1e18);
        assertEq(hook.tradingOpenedAt(), block.timestamp);
    }

    function test_portraitWaiverFollowsOriginAndRequiresAnEarlierBlock() public {
        _release(); // no block advance: both claimed portraits are still immature
        _swap(actors[0], actors[0], 0, 1e18);
        (, uint256 fee) = _claims();
        assertGt(fee, 0, "a portrait claimed this block pays");
        vm.roll(block.number + 1);
        _swap(actors[2], actors[0], 0, 1e18);
        (, uint256 nextFee) = _claims();
        assertEq(nextFee, fee, "mature origin waives fees even for a different payer");
        _swap(actors[0], actors[2], 0, 1e18);
        (, nextFee) = _claims();
        assertGt(nextFee, fee, "a holder payer does not waive a non-holder origin's fee");
        fee = nextFee;
        vm.prank(actors[0]);
        portraits.transferFrom(actors[0], actors[2], 7);
        _swap(actors[2], actors[2], 0, 1e18);
        (, nextFee) = _claims();
        assertGt(nextFee, fee, "newly borrowed portrait is not mature");
        fee = nextFee;
        vm.prank(actors[2]);
        portraits.transferFrom(actors[2], actors[0], 7);
        _swap(actors[0], actors[0], 0, 1e18);
        (, nextFee) = _claims();
        assertGt(nextFee, fee, "returning a borrowed portrait does not restore the earlier holding period");
        vm.roll(block.number + 1);
        fee = nextFee;
        _swap(actors[0], actors[0], 0, 1e18);
        (, nextFee) = _claims();
        assertEq(nextFee, fee);
    }

    function test_receivingAnotherPortraitDoesNotResetAnExistingHoldingPeriod() public {
        _release();
        vm.roll(block.number + 1);
        vm.prank(actors[0]);
        portraits.transferFrom(actors[0], actors[1], 7);
        assertTrue(portraits.isAgentHolder(actors[1]));
        assertFalse(portraits.isAgentHolder(actors[0]));
        _swap(actors[2], actors[1], 0, 1e18);
        (, uint256 fee) = _claims();
        assertEq(fee, 0, "continuous ownership preserves the waiver");
    }

    /// A tight price limit forces a partial fill. Charge only the executed unspecified amount,
    /// never the large requested amount, in either direction and with either exactness setting.
    function testFuzz_partialFillFeesUseExecutedAmounts(uint8 rawMode, uint256 requested) public {
        _release();
        uint8 mode = rawMode % 4;
        requested = bound(requested, 100_000e18, 1_000_000e18);
        SwapParams memory params = _params(mode, requested);
        params.sqrtPriceLimitX96 = TickMath.getSqrtPriceAtTick(params.zeroForOne ? int24(-1) : int24(1));
        vm.recordLogs();
        vm.prank(actors[2], actors[2]);
        BalanceDelta net = router.swap(key, params, PoolSwapTest.TestSettings(false, false), "");
        BalanceDelta gross = _gross(vm.getRecordedLogs());
        bool feeInInk = mode == 0 || mode == 3;
        bool feeIs0 = feeInInk == inkIs0;
        int256 unspecified = feeIs0 ? int256(gross.amount0()) : int256(gross.amount1());
        uint256 magnitude = uint256(unspecified < 0 ? -unspecified : unspecified);
        uint256 expectedFee = magnitude / 400;
        assertGt(expectedFee, 0);
        (uint256 imdFee, uint256 inkFee) = _claims();
        assertEq(inkFee, feeInInk ? expectedFee : 0);
        assertEq(imdFee, feeInInk ? 0 : expectedFee);
        assertEq(int256(net.amount0()), int256(gross.amount0()) - int256(feeIs0 ? expectedFee : 0));
        assertEq(int256(net.amount1()), int256(gross.amount1()) - int256(feeIs0 ? 0 : expectedFee));
        int256 specified = feeIs0 ? int256(net.amount1()) : int256(net.amount0());
        uint256 executed = uint256(specified < 0 ? -specified : specified);
        assertGt(executed, 0);
        assertLt(executed, requested, "the test must actually reach the partial-fill path");
    }

    function _gross(Vm.Log[] memory logs) internal view returns (BalanceDelta) {
        bytes32 signature = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(manager) && logs[i].topics[0] == signature) {
                (int128 a, int128 b,,,,) =
                    abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                return toBalanceDelta(a, b);
            }
        }
        revert("missing PoolManager swap");
    }
}

/// forge-config: default.fuzz.runs = 1000
contract HookFailurePathsInk0Test is HookFailurePathsBase {
    function _inkFirst() internal pure override returns (bool) {
        return true;
    }

    function test_constructorRejectsEachRequiredZeroAddress() public {
        for (uint8 i; i < 4; i++) {
            vm.expectRevert(InkHook.ZeroAddress.selector);
            new InkHook(
                manager,
                IAgentPortraits(i == 0 ? address(0) : PORTRAITS),
                IInkVault(i == 1 ? address(0) : VAULT),
                Currency.wrap(IMD),
                i == 2 ? address(0) : TREASURY,
                25,
                i == 3 ? address(0) : address(this)
            );
        }
    }

    function testFuzz_constructorRejectsFeesAboveCap(uint16 rawFee) public {
        uint16 fee = uint16(bound(rawFee, 101, type(uint16).max));
        vm.expectRevert(InkHook.FeeTooHigh.selector);
        new InkHook(
            manager,
            IAgentPortraits(PORTRAITS),
            IInkVault(VAULT),
            Currency.wrap(IMD),
            TREASURY,
            fee,
            address(this)
        );
    }

    function test_zeroFeeSkipsPortraitLookupAndMaximumFeeIsAccepted() public {
        address zeroAddress = address(uint160((0x6666 << 144) | HOOK_FLAGS));
        address maxAddress = address(uint160((0x7777 << 144) | HOOK_FLAGS));
        deployCodeTo(
            "src/InkHook.sol:InkHook",
            abi.encode(manager, PORTRAITS, VAULT, IMD, TREASURY, uint16(0), address(this)),
            zeroAddress
        );
        deployCodeTo(
            "src/InkHook.sol:InkHook",
            abi.encode(manager, PORTRAITS, VAULT, IMD, TREASURY, uint16(100), address(this)),
            maxAddress
        );
        assertEq(InkHook(maxAddress).feeBps(), 100);
        vm.mockCallRevert(
            PORTRAITS,
            abi.encodeWithSelector(IAgentPortraits.isAgentHolder.selector),
            abi.encodeWithSignature("UnexpectedPortraitLookup()")
        );
        PoolKey memory zeroKey = key;
        zeroKey.hooks = IHooks(zeroAddress);
        SwapParams memory params = _params(0, 1e18);
        vm.prank(address(manager), actors[2]);
        (bytes4 selector, int128 fee) =
            InkHook(zeroAddress).afterSwap(actors[2], zeroKey, params, toBalanceDelta(-1e18, 1e18), "");
        assertEq(selector, IHooks.afterSwap.selector);
        assertEq(fee, 0);
        vm.clearMockedCalls();
    }
}

/// forge-config: default.fuzz.runs = 1000
contract HookFailurePathsInk1Test is HookFailurePathsBase {
    function _inkFirst() internal pure override returns (bool) {
        return false;
    }
}
