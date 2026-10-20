// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {PositionManager} from "v4-periphery/src/PositionManager.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {IPositionDescriptor} from "v4-periphery/src/interfaces/IPositionDescriptor.sol";
import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";
import {PositionInfo, PositionInfoLibrary} from "v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {InkPortraits} from "src/InkPortraits.sol";
import {InkVault} from "src/InkVault.sol";
import {InkLiquidity} from "src/InkLiquidity.sol";
import {InkRenderer} from "src/InkRenderer.sol";
import {InkHook, IAgentPortraits, IInkVault} from "src/InkHook.sol";

/// Exercises production liquidity code against the bundled Uniswap core and periphery, without RPC.
/// Token minting is confined to setup; every subsequent donation and trade spends an actor's balance.
contract LiquidityCustodyHandler is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    InkLiquidity public immutable liquidity;
    InkHook public immutable hook;
    MockERC20 public immutable ink;
    MockERC20 public immutable imd;
    PoolSwapTest public immutable router;
    PoolKey internal key;
    address public immutable owner;
    address[4] public actors;
    uint256 public initialDust;
    uint256 public donated;
    uint256 public compounded;
    uint256 public inkFees;
    uint256 public imdFees;
    uint256 public swaps;
    uint256 public additions;
    mapping(uint256 => uint128) public lockedLiquidity;

    constructor(InkLiquidity l, InkHook h, MockERC20 i, MockERC20 m, PoolSwapTest r, PoolKey memory k) {
        liquidity = l;
        hook = h;
        ink = i;
        imd = m;
        router = r;
        key = k;
        owner = l.owner();
        initialDust = i.balanceOf(address(l));
        for (uint256 n; n < 4; n++) {
            actors[n] = makeAddr(string.concat("custody trader ", vm.toString(n)));
            vm.startPrank(actors[n]);
            i.approve(address(r), type(uint256).max);
            m.approve(address(r), type(uint256).max);
            vm.stopPrank();
        }
        _recordPositions(0);
    }

    function _recordPositions(uint256 from) internal {
        IPositionManager pm = liquidity.positionManager();
        for (uint256 n = from; n < liquidity.positionCount(); n++) {
            uint256 id = liquidity.positions(n);
            uint128 amount = pm.getPositionLiquidity(id);
            assertGt(amount, 0, "new positions must hold liquidity");
            lockedLiquidity[id] = amount;
        }
    }

    function donate(uint256 actorSeed, uint256 amount) external {
        address actor = actors[actorSeed % 4];
        uint256 balance = ink.balanceOf(actor);
        if (balance == 0) return;
        amount = bound(amount, 1, balance < 1_600_000e18 ? balance : 1_600_000e18);
        vm.prank(actor);
        ink.transfer(address(liquidity), amount);
        donated += amount;
    }

    function add(uint256 callerSeed) external {
        uint256 beforeBalance = ink.balanceOf(address(liquidity));
        uint256 beforeCount = liquidity.positionCount();
        uint256 minimum = liquidity.MIN_ADD();
        vm.prank(actors[callerSeed % 4]);
        if (beforeBalance < minimum) {
            vm.expectRevert(
                beforeBalance == 0 ? InkLiquidity.NothingToAdd.selector : InkLiquidity.BelowMinAdd.selector
            );
            liquidity.addLiquidity();
            return;
        }
        uint256 first = liquidity.addLiquidity();
        assertEq(first, liquidity.positions(beforeCount));
        assertGt(liquidity.positionCount(), beforeCount);
        compounded += beforeBalance - ink.balanceOf(address(liquidity));
        additions++;
        _recordPositions(beforeCount);
    }

    function collect(uint256 callerSeed, uint256 from, uint256 count) external {
        uint256 n = liquidity.positionCount();
        from = bound(from, 0, n - 1);
        count = bound(count, 1, n - from);
        uint256 inkBefore = ink.balanceOf(address(liquidity));
        uint256 imdBefore = imd.balanceOf(liquidity.treasury());
        vm.prank(actors[callerSeed % 4]);
        (uint256 paid, uint256 retained) = liquidity.collectFees(from, from + count);
        assertEq(imd.balanceOf(liquidity.treasury()) - imdBefore, paid);
        assertEq(ink.balanceOf(address(liquidity)) - inkBefore, retained);
        inkFees += retained;
        imdFees += paid;
    }

    function collectHook(uint256 callerSeed) external {
        uint256 inkBefore = ink.balanceOf(address(liquidity));
        uint256 imdBefore = imd.balanceOf(liquidity.treasury());
        vm.prank(actors[callerSeed % 4]);
        (uint256 paid, uint256 retained) = hook.collectFees();
        assertEq(imd.balanceOf(liquidity.treasury()) - imdBefore, paid);
        assertEq(ink.balanceOf(address(liquidity)) - inkBefore, retained);
        inkFees += retained;
        imdFees += paid;
    }

    function trade(uint256 actorSeed, bool buy, uint256 amount) external {
        address actor = actors[actorSeed % 4];
        bool inkIs0 = Currency.unwrap(key.currency0) == address(ink);
        // Keep spot within the launch ladder, so both buys and sells remain meaningful.
        int24 limitTick =
            buy ? (inkIs0 ? int24(-84_000) : int24(84_000)) : (inkIs0 ? int24(-129_000) : int24(129_000));
        uint160 limit = TickMath.getSqrtPriceAtTick(limitTick);
        (uint160 spot,,,) = hook.poolManager().getSlot0(key.toId());
        bool zeroForOne = buy ? !inkIs0 : inkIs0;
        if (zeroForOne ? spot <= limit : spot >= limit) return;
        uint256 balance = buy ? imd.balanceOf(actor) : ink.balanceOf(actor);
        if (balance == 0) return;
        uint256 cap = buy ? 10e18 : 2_000_000e18;
        amount = bound(amount, 1, balance < cap ? balance : cap);
        vm.prank(actor, actor);
        router.swap(
            key, SwapParams(zeroForOne, -int256(amount), limit), PoolSwapTest.TestSettings(false, false), ""
        );
        swaps++;
    }

    function changeWidth(uint256 widthSeed) external {
        vm.prank(owner);
        liquidity.setWidth(int24(int256(bound(widthSeed, 200, 40_000))));
    }

    function rejectTheft(uint256 actorSeed, uint256 positionSeed) external {
        address actor = actors[actorSeed % 4];
        uint256 id = liquidity.positions(positionSeed % liquidity.positionCount());
        IERC721 nft = IERC721(address(liquidity.positionManager()));
        vm.prank(actor);
        vm.expectRevert();
        nft.transferFrom(address(liquidity), actor, id);
        vm.prank(actor);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, actor));
        liquidity.setPremium(0);
    }
}

abstract contract LiquidityCustodyBase is Test {
    using PositionInfoLibrary for PositionInfo;
    uint256 internal constant PORTRAIT = 400_000e18;
    address internal owner = makeAddr("custody owner");
    address internal constant TREASURY = 0xbc10B3662231c830d2ee10bc6359dB17bEa4b3d4;
    address internal constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    MockERC20 internal ink;
    MockERC20 internal imd;
    InkVault internal vault;
    InkPortraits internal portraits;
    InkLiquidity internal liquidity;
    InkRenderer internal renderer;
    InkHook internal hook;
    IPoolManager internal manager;
    IPositionManager internal posm;
    PoolSwapTest internal router;
    PoolKey internal key;
    LiquidityCustodyHandler internal handler;

    function _inkIs0() internal pure virtual returns (bool);

    function setUp() public {
        vm.chainId(1);
        vm.warp(1_800_000_000);
        manager = new PoolManager(owner);
        // These tests settle from prefunded PositionManager balances, exactly as InkLiquidity does.
        // Permit2, WETH and the descriptor are never invoked on this path.
        posm = new PositionManager(
            manager,
            IAllowanceTransfer(address(0)),
            100_000,
            IPositionDescriptor(address(0)),
            IWETH9(address(0))
        );
        router = new PoolSwapTest(manager);
        portraits = new InkPortraits(owner);
        vault = new InkVault(portraits, IERC721(0x0000eC93127BAA929E58E97dd0095A2BFb38ec1D), owner);
        liquidity = new InkLiquidity(manager, posm, owner, TREASURY);
        renderer = new InkRenderer(portraits, owner);
        vm.prank(owner);
        portraits.setVault(address(vault));
        // Only the two external ERC20s are stand-ins. Managers and application contracts are unmodified.
        deployCodeTo("MockERC20.sol:MockERC20", abi.encode("IMD", "IMD", uint8(18)), IMD);
        address inkAddress = address(uint160(IMD) + (_inkIs0() ? uint160(0) : uint160(2)) - 1);
        deployCodeTo("MockERC20.sol:MockERC20", abi.encode("INK", "INK", uint8(18)), inkAddress);
        ink = MockERC20(inkAddress);
        imd = MockERC20(IMD);
        address hookAddress = address(
            uint160(
                (0x4444 << 144) | Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
                    | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
            )
        );
        deployCodeTo(
            "InkHook.sol:InkHook",
            abi.encode(
                manager,
                IAgentPortraits(address(portraits)),
                IInkVault(address(vault)),
                Currency.wrap(IMD),
                TREASURY,
                uint16(25),
                address(this) // the test initializes the pool, as the launch factory does
            ),
            hookAddress
        );
        hook = InkHook(hookAddress);
        key = PoolKey(
            Currency.wrap(_inkIs0() ? inkAddress : IMD),
            Currency.wrap(_inkIs0() ? IMD : inkAddress),
            12_500,
            200,
            IHooks(hookAddress)
        );
        manager.initialize(key, TickMath.getSqrtPriceAtTick(_inkIs0() ? int24(-129_000) : int24(129_000)));
        ink.mint(address(vault), 2000 * PORTRAIT);
        vm.startPrank(owner);
        vault.setInk(IERC20(address(ink)));
        liquidity.setPool(key, IERC20(address(ink)));
        vault.setup(
            keccak256("no agent claims in this campaign"), uint64(block.timestamp), address(liquidity)
        );
        portraits.setRenderer(address(renderer));
        vm.stopPrank();
        vm.warp(vault.claimEnd());
        vault.release();
        handler = new LiquidityCustodyHandler(liquidity, hook, ink, imd, router, key);
        for (uint256 n; n < 4; n++) {
            ink.mint(handler.actors(n), 50_000_000e18);
            imd.mint(handler.actors(n), 100_000e18);
        }
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = handler.donate.selector;
        selectors[1] = handler.add.selector;
        selectors[2] = handler.collect.selector;
        selectors[3] = handler.collectHook.selector;
        selectors[4] = handler.trade.selector;
        selectors[5] = handler.changeWidth.selector;
        selectors[6] = handler.rejectTheft.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_positionsStayLockedAndFullyLiquid() public view {
        uint256 n = liquidity.positionCount();
        assertGe(n, 8, "release creates eight positions");
        assertEq(IERC721(address(posm)).balanceOf(address(liquidity)), n);
        for (uint256 i; i < n; i++) {
            uint256 id = liquidity.positions(i);
            assertEq(IERC721(address(posm)).ownerOf(id), address(liquidity));
            assertEq(IERC721(address(posm)).getApproved(id), address(0));
            assertEq(posm.getPositionLiquidity(id), handler.lockedLiquidity(id), "principal never removed");
            (PoolKey memory positionKey, PositionInfo info) = posm.getPoolAndPositionInfo(id);
            assertEq(keccak256(abi.encode(positionKey)), keccak256(abi.encode(key)));
            assertLt(info.tickLower(), info.tickUpper());
            assertEq(info.tickLower() % 200, 0);
            assertEq(info.tickUpper() % 200, 0);
            if (_inkIs0()) assertGe(info.tickLower(), liquidity.releaseStartTick());
            else assertLe(info.tickUpper(), liquidity.releaseStartTick());
            if (i != 0) assertGt(id, liquidity.positions(i - 1), "position IDs are unique");
        }
        for (uint256 i; i < 4; i++) {
            assertFalse(IERC721(address(posm)).isApprovedForAll(address(liquidity), handler.actors(i)));
        }
    }

    function _sumBalances(MockERC20 token) internal view returns (uint256 sum) {
        sum = token.balanceOf(address(manager)) + token.balanceOf(address(posm))
            + token.balanceOf(address(liquidity)) + token.balanceOf(address(vault))
            + token.balanceOf(TREASURY) + token.balanceOf(address(router)) + token.balanceOf(address(hook));
        for (uint256 n; n < 4; n++) {
            sum += token.balanceOf(handler.actors(n));
        }
    }

    function invariant_conservationAndFeeDestinations() public view {
        assertEq(ink.totalSupply(), 1_000_000_000e18);
        assertEq(imd.totalSupply(), 400_000e18);
        assertEq(_sumBalances(ink), ink.totalSupply());
        assertEq(_sumBalances(imd), imd.totalSupply());
        assertEq(
            ink.balanceOf(address(liquidity)) + handler.compounded(),
            handler.initialDust() + handler.donated() + handler.inkFees()
        );
        assertEq(imd.balanceOf(TREASURY), handler.imdFees());
        assertEq(ink.balanceOf(TREASURY), 0, "treasury receives IMD only");
        assertEq(imd.balanceOf(address(liquidity)), 0);
        assertEq(ink.balanceOf(address(posm)), 0, "settle and sweep leave no prefunding stranded");
        assertEq(ink.balanceOf(owner) + imd.balanceOf(owner), 0, "ownership has no fee entitlement");
    }

    function invariant_configurationAndBackingStayIntact() public view {
        assertEq(liquidity.owner(), owner);
        assertEq(vault.owner(), owner);
        assertEq(portraits.owner(), owner);
        assertEq(renderer.owner(), owner);
        (address receiver, uint256 royalty) = portraits.royaltyInfo(0, type(uint128).max);
        assertEq(receiver, owner);
        assertEq(royalty, 0);
        assertTrue(vault.released());
        assertEq(vault.liquidity(), address(liquidity));
        assertEq(vault.pullCount(), 0);
        assertEq(portraits.totalSupply(), 0);
        assertEq(ink.balanceOf(address(vault)), 0, "all unclaimed backing was released");
        assertEq(liquidity.treasury(), TREASURY);
        assertEq(address(liquidity.poolManager()), address(manager));
        assertEq(address(liquidity.positionManager()), address(posm));
    }

    // A deterministic sequence proves the random handlers reach both fee currencies and compounding.
    function test_roundTripCollectAndCompound() public {
        handler.trade(0, true, 10e18);
        handler.trade(0, false, 2_000_000e18);
        handler.collect(1, 0, 8);
        handler.collectHook(2);
        assertGt(handler.inkFees(), 0);
        assertGt(handler.imdFees(), 0);
        handler.donate(3, 1_600_000e18);
        handler.add(1);
        assertEq(handler.additions(), 1);
        handler.rejectTheft(0, type(uint256).max);
        invariant_positionsStayLockedAndFullyLiquid();
        invariant_conservationAndFeeDestinations();
    }

    function test_minimumAddBoundaryAndEmptyCollectionRanges() public {
        uint256 minimum = liquidity.MIN_ADD();
        uint256 dust = ink.balanceOf(address(liquidity));
        assertLt(dust, minimum - 1);
        handler.donate(0, minimum - 1 - dust);
        uint256 n = liquidity.positionCount();
        vm.expectRevert(InkLiquidity.BelowMinAdd.selector);
        liquidity.addLiquidity();
        assertEq(liquidity.positionCount(), n);
        assertEq(ink.balanceOf(address(liquidity)), minimum - 1);
        handler.donate(0, 1);
        handler.add(3);
        assertEq(liquidity.positionCount(), n + 8, "one wei reaches the listing threshold");
        vm.expectRevert(InkLiquidity.NothingToCollect.selector);
        liquidity.collectFees(0, 0);
        vm.expectRevert(InkLiquidity.NothingToCollect.selector);
        liquidity.collectFees(type(uint256).max, type(uint256).max);
        vm.expectRevert(InkLiquidity.NothingToCollect.selector);
        liquidity.collectFees(2, 1);
        (uint256 imdOut, uint256 inkOut) = liquidity.collectFees(0, type(uint256).max);
        assertEq(imdOut, 0, "no trades means no LP fees");
        assertEq(inkOut, 0);
        invariant_positionsStayLockedAndFullyLiquid();
        invariant_conservationAndFeeDestinations();
    }

    function test_positionManagerFailureRollsBackPrefundingAndCanBeRetried() public {
        handler.donate(0, PORTRAIT);
        uint256 balance = ink.balanceOf(address(liquidity));
        uint256 managerBalance = ink.balanceOf(address(manager));
        uint256 count = liquidity.positionCount();
        uint256 nextId = posm.nextTokenId();
        // Inject only the outside protocol failure, after InkLiquidity has prefunded PositionManager.
        bytes memory reason = abi.encodeWithSignature("SettlementUnavailable()");
        vm.mockCallRevert(address(posm), abi.encodeWithSelector(posm.modifyLiquidities.selector), reason);
        vm.expectRevert(reason);
        handler.add(0);
        vm.clearMockedCalls();
        assertEq(ink.balanceOf(address(liquidity)), balance, "prefunding returned on revert");
        assertEq(ink.balanceOf(address(posm)), 0);
        assertEq(ink.balanceOf(address(manager)), managerBalance);
        assertEq(posm.nextTokenId(), nextId);
        assertEq(liquidity.positionCount(), count);
        handler.add(1);
        assertGt(liquidity.positionCount(), count, "failure did not strand the INK");
        invariant_positionsStayLockedAndFullyLiquid();
        invariant_conservationAndFeeDestinations();
    }
}

/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract LiquidityCustodyInk0Test is LiquidityCustodyBase {
    function _inkIs0() internal pure override returns (bool) {
        return true;
    }
}

/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract LiquidityCustodyInk1Test is LiquidityCustodyBase {
    function _inkIs0() internal pure override returns (bool) {
        return false;
    }
}
