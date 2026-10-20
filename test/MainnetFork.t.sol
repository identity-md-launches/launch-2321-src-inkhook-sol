// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {PositionInfo, PositionInfoLibrary} from "v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {InkPortraits} from "../src/InkPortraits.sol";
import {InkVault} from "../src/InkVault.sol";
import {InkHook, IAgentPortraits, IInkVault} from "../src/InkHook.sol";
import {InkLiquidity} from "../src/InkLiquidity.sol";

/// The deployed Universal Router's swap structs (no minHopPriceX36, unlike the newer periphery in lib/).
struct ExactInSingle {
    PoolKey poolKey;
    bool zeroForOne;
    uint128 amountIn;
    uint128 amountOutMinimum;
    bytes hookData;
}

struct ExactOutSingle {
    PoolKey poolKey;
    bool zeroForOne;
    uint128 amountOut;
    uint128 amountInMaximum;
    bytes hookData;
}

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

/// Plain 1B token standing in for the INK the IMD launch mints (plain transfers, 18 decimals).
contract ForkInk {
    string public constant name = "INK";
    string public constant symbol = "INK";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(address to) {
        totalSupply = 1_000_000_000e18;
        balanceOf[to] = totalSupply;
        emit Transfer(address(0), to, totalSupply);
    }

    function approve(address s, uint256 v) external returns (bool) {
        allowance[msg.sender][s] = v;
        emit Approval(msg.sender, s, v);
        return true;
    }

    function transfer(address to, uint256 v) external returns (bool) {
        return _move(msg.sender, to, v);
    }

    function transferFrom(address f, address to, uint256 v) external returns (bool) {
        if (allowance[f][msg.sender] != type(uint256).max) allowance[f][msg.sender] -= v;
        return _move(f, to, v);
    }

    function _move(address f, address to, uint256 v) internal returns (bool) {
        balanceOf[f] -= v;
        balanceOf[to] += v;
        emit Transfer(f, to, v);
        return true;
    }
}

/// @notice The whole system against the real Ethereum mainnet contracts: Uniswap v4 PoolManager,
/// PositionManager, Permit2 and Universal Router, the real IMD token and the real identity.md seats with
/// their real owners, claiming with proofs from the rehearsal snapshot. Swaps go through the deployed
/// Universal Router exactly as a wallet would send them.
/// Runs only with FORK_RPC_URL set (any mainnet RPC); nothing is broadcast, it's an in-memory fork.
///   FORK_RPC_URL=https://ethereum-rpc.publicnode.com forge test --mc MainnetFork -vv
abstract contract MainnetForkSetup is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using PositionInfoLibrary for PositionInfo;

    IPoolManager constant MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    IPositionManager constant POSM = IPositionManager(0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e);
    IUniversalRouter constant ROUTER = IUniversalRouter(0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af);
    IAllowanceTransfer constant PERMIT2 = IAllowanceTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3);
    IERC20 constant IMD = IERC20(0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7);
    IERC721 constant SEATS = IERC721(0x0000eC93127BAA929E58E97dd0095A2BFb38ec1D);

    uint256 constant PORTRAIT = 400_000e18;
    uint256 constant SUPPLY = 1_000_000_000e18;
    uint24 constant POOL_FEE = 12_500;
    int24 constant SPACING = 200;
    int24 constant OPEN_TICK = 129_000; // ≈ 2,500 IMD market cap
    int24 constant RANGE = 46_000;
    uint8 constant V4_SWAP = 0x10;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    address owner = makeAddr("owner");
    address treasury = makeAddr("treasury");
    address swarm = makeAddr("swarm");
    address buyer = makeAddr("buyer");
    address buyer2 = makeAddr("buyer2");

    ForkInk ink;
    InkPortraits portraits;
    InkVault vault;
    InkHook hook;
    InkLiquidity liq;
    PoolKey key;
    bool inkIs0;
    bool forked;
    string json;

    /// Where to put INK: below IMD's address (INK = currency0) or above it (INK = currency1).
    function _inkAddress() internal pure virtual returns (address);

    /// Where released INK starts above the opening price, in ticks: the launch setting (5x), as in
    /// InkSteps.RELEASE_PREMIUM. The start-price comparison overrides it.
    function _premium() internal view virtual returns (int24) {
        return 16_000;
    }

    function setUp() public {
        string memory rpc = vm.envOr("FORK_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        // FORK_BLOCK pins a block (needs an archive RPC once it's old); by default the latest block.
        uint256 pinned = vm.envOr("FORK_BLOCK", uint256(0));
        if (pinned == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, pinned);
        forked = true;
        json = vm.readFile("test/fixtures/snapshot-sample.json");

        // Contracts launch.
        portraits = new InkPortraits(owner);
        vault = new InkVault(portraits, SEATS, owner);
        liq = new InkLiquidity(MANAGER, POSM, owner, treasury);
        vm.prank(owner);
        portraits.setVault(address(vault));

        // Hook launch: the hook at a mined address, INK minted, 10/80/10 split, single-sided pool seeded.
        address hookAddr = address(
            uint160(
                Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                    | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
            ) ^ (0x1111 << 144)
        );
        deployCodeTo(
            "InkHook.sol:InkHook",
            abi.encode(
                MANAGER,
                IAgentPortraits(address(portraits)),
                IInkVault(address(vault)),
                Currency.wrap(address(IMD)),
                treasury,
                uint16(25),
                address(this) // the test initializes the pool, as the launch factory does
            ),
            hookAddr
        );
        hook = InkHook(hookAddr);
        deployCodeTo("MainnetFork.t.sol:ForkInk", abi.encode(address(this)), _inkAddress());
        ink = ForkInk(_inkAddress());
        inkIs0 = address(ink) < address(IMD);

        ink.transfer(swarm, SUPPLY / 10);
        ink.transfer(address(vault), 2000 * PORTRAIT);
        key = PoolKey({
            currency0: Currency.wrap(inkIs0 ? address(ink) : address(IMD)),
            currency1: Currency.wrap(inkIs0 ? address(IMD) : address(ink)),
            fee: POOL_FEE,
            tickSpacing: SPACING,
            hooks: IHooks(hookAddr)
        });
        int24 openTick = inkIs0 ? -OPEN_TICK : OPEN_TICK;
        MANAGER.initialize(key, TickMath.getSqrtPriceAtTick(openTick));
        _seedLaunchPool(openTick, SUPPLY / 10);

        // Owner wires INK and opens claims with the rehearsal snapshot root.
        vm.startPrank(owner);
        vault.setInk(IERC20(address(ink)));
        if (_premium() != 0) liq.setPremium(_premium());
        liq.setPool(key, IERC20(address(ink)));
        vault.setup(vm.parseJsonBytes32(json, ".root"), uint64(block.timestamp), address(liq));
        vm.stopPrank();

        deal(address(IMD), buyer, 1_000_000e18);
        deal(address(IMD), buyer2, 1_000_000e18);
        _approveRouter(buyer);
        _approveRouter(buyer2);
        _approveRouter(swarm);
    }

    modifier onlyFork() {
        if (!forked) {
            vm.skip(true);
            return;
        }
        _;
    }

    // ---------------------------------------------------------------- helpers

    function _seedLaunchPool(int24 openTick, uint256 amount) internal {
        (int24 lower, int24 upper) = inkIs0 ? (openTick, openTick + RANGE) : (openTick - RANGE, openTick);
        uint128 l = inkIs0
            ? LiquidityAmounts.getLiquidityForAmount0(
                TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), amount
            )
            : LiquidityAmounts.getLiquidityForAmount1(
                TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), amount
            );
        ink.approve(address(PERMIT2), type(uint256).max);
        PERMIT2.approve(address(ink), address(POSM), type(uint160).max, type(uint48).max);
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            key, lower, upper, uint256(l), inkIs0 ? amount : 0, inkIs0 ? 0 : amount, address(this), bytes("")
        );
        params[1] = abi.encode(key.currency0, key.currency1);
        POSM.modifyLiquidities(
            abi.encode(abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR)), params),
            block.timestamp
        );
    }

    function _approveRouter(address who) internal {
        vm.startPrank(who);
        IMD.approve(address(PERMIT2), type(uint256).max);
        ink.approve(address(PERMIT2), type(uint256).max);
        PERMIT2.approve(address(IMD), address(ROUTER), type(uint160).max, type(uint48).max);
        PERMIT2.approve(address(ink), address(ROUTER), type(uint160).max, type(uint48).max);
        vm.stopPrank();
    }

    /// Exact-input single swap through the deployed Universal Router (its ExactInputSingleParams has no
    /// minHopPriceX36 field, unlike the newer periphery in lib/).
    function _swapExactIn(address who, bool buyInk, uint128 amountIn) internal {
        bool zeroForOne = buyInk ? !inkIs0 : inkIs0;
        (Currency cin, Currency cout) =
            zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(ExactInSingle(key, zeroForOne, amountIn, 0, bytes("")));
        params[1] = abi.encode(cin, uint256(amountIn));
        params[2] = abi.encode(cout, uint256(0));
        _execute(
            who,
            abi.encodePacked(
                uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL)
            ),
            params
        );
    }

    function _swapExactOut(address who, bool buyInk, uint128 amountOut) internal {
        bool zeroForOne = buyInk ? !inkIs0 : inkIs0;
        (Currency cin, Currency cout) =
            zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(ExactOutSingle(key, zeroForOne, amountOut, type(uint128).max, bytes("")));
        params[1] = abi.encode(cin, type(uint256).max);
        params[2] = abi.encode(cout, uint256(amountOut));
        _execute(
            who,
            abi.encodePacked(
                uint8(Actions.SWAP_EXACT_OUT_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL)
            ),
            params
        );
    }

    function _execute(address who, bytes memory actions, bytes[] memory params) internal {
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);
        vm.prank(who, who);
        ROUTER.execute(abi.encodePacked(V4_SWAP), inputs, block.timestamp);
    }

    function _entry(uint256 i)
        internal
        view
        returns (uint256 seat, InkPortraits.AgentStats memory s, bytes32[] memory proof)
    {
        string memory p = string.concat(".entries[", vm.toString(i), "]");
        seat = vm.parseJsonUint(json, string.concat(p, ".seat"));
        s = InkPortraits.AgentStats({
            accepted: uint32(vm.parseJsonUint(json, string.concat(p, ".accepted"))),
            rateBps: uint16(vm.parseJsonUint(json, string.concat(p, ".rateBps"))),
            turns: uint32(vm.parseJsonUint(json, string.concat(p, ".turns"))),
            hoursTenths: uint32(vm.parseJsonUint(json, string.concat(p, ".hoursTenths"))),
            outdated: vm.parseJsonBool(json, string.concat(p, ".outdated"))
        });
        proof = vm.parseJsonBytes32Array(json, string.concat(p, ".proof"));
    }

    /// The real owner of the i-th fixture seat claims its portrait. Returns the owner.
    function _claimReal(uint256 i) internal returns (address seatOwner, uint256 seat) {
        InkPortraits.AgentStats memory s;
        bytes32[] memory proof;
        (seat, s, proof) = _entry(i);
        seatOwner = SEATS.ownerOf(seat);
        vm.prank(seatOwner);
        vault.claim(seat, s, proof);
    }

    /// Release, then a first small buy.
    function _releaseAndTrade() internal {
        _release();
        _swapExactIn(buyer2, true, 1e17);
    }

    function _release() internal {
        vm.warp(vault.claimEnd());
        uint256 g = gasleft();
        vault.release();
        console2.log("release() gas on mainnet PositionManager:", g - gasleft());
    }

    function _tick() internal view returns (int24 t) {
        (, t,,) = MANAGER.getSlot0(key.toId());
    }

    function _pullAndReveal(address who) internal returns (uint256 tokenId) {
        vm.startPrank(who);
        ink.approve(address(vault), type(uint256).max);
        uint256 pullId = vault.pull(1);
        vm.stopPrank();
        (, uint64 bn,) = vault.pulls(pullId);
        vm.roll(uint256(bn) + 2);
        vm.setBlockhash(uint256(bn) + 1, keccak256(abi.encode("fork entropy", pullId)));
        assertTrue(vault.reveal(pullId));
        uint256 n = portraits.swarmMinted();
        for (uint256 id = 10_000; id < 10_000 + n; id++) {
            if (portraits.ownerOf(id) == who) return id;
        }
    }

    /// IMD per 400,000 INK at the pool's current price, in thousandths.
    function _imdPerPortrait() internal view returns (uint256) {
        (uint160 sqrtP,,,) = MANAGER.getSlot0(key.toId());
        // price = currency1 per currency0, scaled by 2^192
        uint256 p = uint256(sqrtP) * uint256(sqrtP) / (1 << 96);
        // IMD per INK × 1e18
        uint256 imdPerInkE18 = inkIs0 ? p * 1e18 / (1 << 96) : (uint256(1) << 96) * 1e18 / p;
        return imdPerInkE18 * 400_000 * 1000 / 1e18;
    }
}

/// The fork tests, run with INK on each side of IMD.
abstract contract MainnetForkBase is MainnetForkSetup {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using PositionInfoLibrary for PositionInfo;

    // ---------------------------------------------------------------- tests

    function test_fork_fullLifecycle() public onlyFork {
        // Real seat owners claim with real snapshot proofs.
        (address a0, uint256 s0) = _claimReal(0);
        (, uint256 s1) = _claimReal(1);
        assertEq(portraits.ownerOf(s0), a0);
        assertEq(portraits.agentMinted(), 2);

        // Locked through the real router during the window.
        vm.expectRevert();
        _swapExactIn(buyer, true, 100e18);

        // Release mints a real, permanent single-sided position on the mainnet PositionManager.
        int24 tickBefore = _tick();
        _release();
        assertEq(liq.positionCount(), liq.LADDER_BANDS());
        assertEq(IERC721(address(POSM)).ownerOf(liq.positions(0)), address(liq));
        assertEq(ink.balanceOf(address(vault)), 2 * PORTRAIT);
        assertEq(_tick(), tickBefore, "adding single-sided liquidity doesn't move the price");

        // Buy one portrait's worth exactly, then pull, reveal, hand back.
        _swapExactOut(buyer, true, uint128(PORTRAIT));
        assertEq(ink.balanceOf(buyer), PORTRAIT, "exact output delivered");
        assertGt(hook.tradingOpenedAt(), 0);
        uint256 t = _pullAndReveal(buyer);
        assertEq(portraits.ownerOf(t), buyer);
        uint256[] memory ids = new uint256[](1);
        ids[0] = t;
        uint256 liqBefore = ink.balanceOf(address(liq));
        vm.startPrank(buyer);
        portraits.approve(address(vault), t);
        vault.deposit(ids, PORTRAIT * 99 / 100);
        vm.stopPrank();
        assertEq(ink.balanceOf(buyer), PORTRAIT * 99 / 100);
        assertEq(
            ink.balanceOf(address(liq)) - liqBefore, PORTRAIT / 100, "the 1% hand-back fee goes to liquidity"
        );
        assertEq(ink.balanceOf(DEAD), 0, "nothing is burned");

        // Hook fees pay out: IMD to the treasury (exact-output buy pays the fee in IMD).
        (uint256 imdPaid,) = hook.collectFees();
        assertGt(imdPaid, 0);
        assertEq(IMD.balanceOf(treasury), imdPaid);
        s1;
    }

    function test_fork_hookFeeExactInBuyIsInkToLiquidity() public onlyFork {
        _release();
        uint128 amountIn = 1e18; // ≈ 400,000 INK at the opening price, inside the first-hour cap
        _swapExactIn(buyer, true, amountIn);
        uint256 received = ink.balanceOf(buyer);
        uint256 fee = MANAGER.balanceOf(address(hook), uint256(uint160(address(ink))));
        assertGt(fee, 0);
        assertEq(fee, (received + fee) * 25 / 10_000, "0.25% of the pool's output");
        uint256 liqBefore = ink.balanceOf(address(liq));
        (uint256 imdPaid, uint256 toLiq) = hook.collectFees();
        assertEq(imdPaid, 0);
        assertEq(toLiq, fee);
        assertEq(ink.balanceOf(address(liq)) - liqBefore, fee, "INK fee goes to the liquidity contract");
        assertEq(ink.balanceOf(DEAD), 0, "nothing is burned");
    }

    function test_fork_sellsPayFeesBothWays() public onlyFork {
        _releaseAndTrade();
        _swapExactIn(buyer, true, 1_000e18); // buyers first, so there's IMD in the pool to sell into
        // Swarm members sell INK: exact-in (fee in IMD, to treasury) and exact-out (fee in INK, to liquidity).
        _swapExactIn(swarm, false, uint128(PORTRAIT));
        _swapExactOut(swarm, false, 10e18);
        (uint256 imdPaid, uint256 toLiq) = hook.collectFees();
        assertGt(imdPaid, 0);
        assertGt(toLiq, 0);
    }

    function test_fork_agentHolderPaysNoHookFee() public onlyFork {
        (address a0,) = _claimReal(0);
        vm.roll(block.number + 1);
        _release();
        deal(address(IMD), a0, 10_000e18);
        _approveRouter(a0);
        _swapExactIn(a0, true, 1e18);
        assertEq(
            MANAGER.balanceOf(address(hook), uint256(uint160(address(ink)))), 0, "no fee for agent holders"
        );
    }

    /// No time-based fallback: a month after the window, with nobody having called release, the real
    /// router still can't trade (not even a dust sell). Release then lists the unclaimed INK above the
    /// opening price.
    function test_fork_lockedUntilReleaseHoweverLong() public onlyFork {
        int24 open = _tick();
        vm.warp(vault.claimEnd() + 30 days);
        vm.expectRevert();
        _swapExactIn(swarm, false, 1e18);
        vm.expectRevert();
        _swapExactIn(buyer, true, 1e18);
        _release();
        assertEq(_tick(), open, "nothing moved the price before release");
        PositionInfoLike memory info = _positionTicks(liq.positions(0));
        if (inkIs0) assertGe(info.lower, open, "released INK listed at or above the opening price");
        else assertLe(info.upper, open, "released INK listed at or above the opening price");
        uint256 before = ink.balanceOf(buyer2);
        _swapExactIn(buyer2, true, 1_000e18);
        console2.log("INK for 1,000 IMD right after release:", (ink.balanceOf(buyer2) - before) / 1e18);
    }

    /// Launch sniping: a bot splits its buying across N fresh wallets, each taking three portraits' worth
    /// right after release. Logs how much of the supply it gets and what it pays, for several N.
    function test_fork_sybilFirstHour() public onlyFork {
        (address a0,) = _claimReal(0);
        a0;
        _release();
        uint256 open = _imdPerPortrait();
        console2.log("opening price, milli-IMD per portrait:", open);
        uint256[4] memory sizes = [uint256(10), 50, 200, 600];
        for (uint256 k; k < sizes.length; k++) {
            uint256 snap = vm.snapshotState();
            uint256 n = sizes[k];
            uint256 imdSpent;
            uint256 inkTaken;
            for (uint256 i; i < n; i++) {
                address w = address(uint160(uint256(keccak256(abi.encode("sybil", i)))));
                deal(address(IMD), w, 1_000_000e18);
                _approveRouter(w);
                uint256 before = IMD.balanceOf(w);
                _swapExactOut(w, true, uint128(3 * PORTRAIT));
                imdSpent += before - IMD.balanceOf(w);
                inkTaken += ink.balanceOf(w);
            }
            console2.log("---- wallets:", n);
            console2.log("  INK taken (millions):", inkTaken / 1e24);
            console2.log("  share of supply (basis points):", inkTaken * 10_000 / SUPPLY);
            console2.log("  IMD spent:", imdSpent / 1e18);
            console2.log("  avg milli-IMD per portrait:", imdSpent * 1000 / (inkTaken / PORTRAIT) / 1e18);
            console2.log("  price after, milli-IMD per portrait:", _imdPerPortrait());
            vm.revertToState(snap);
        }
    }

    struct PositionInfoLike {
        int24 lower;
        int24 upper;
    }

    function _positionTicks(uint256 tokenId) internal view returns (PositionInfoLike memory p) {
        (, PositionInfo info) = POSM.getPoolAndPositionInfo(tokenId);
        p.lower = info.tickLower();
        p.upper = info.tickUpper();
    }

    /// A whale tries to buy far more than the pool's launch INK right after release.
    function test_fork_bigBuyAfterRelease() public onlyFork {
        _releaseAndTrade();
        // Buying from both the launch seed and the released position.
        deal(address(IMD), buyer, 10_000_000e18);
        _swapExactIn(buyer, true, 5_000_000e18);
        console2.log("INK bought with 5M IMD:", ink.balanceOf(buyer) / 1e18);
        assertGt(ink.balanceOf(buyer), 100_000_000e18, "deep enough to cross into the released liquidity");

        // The released position earned its share of the pool's 1.25%; the real PositionManager pays it out.
        uint256 before = IMD.balanceOf(treasury);
        (uint256 imdOut,) = liq.collectFees(0, type(uint256).max);
        console2.log("IMD fees collected from the released position:", imdOut / 1e18);
        assertGt(imdOut, 0, "released position earned IMD fees");
        assertEq(IMD.balanceOf(treasury) - before, imdOut, "to the treasury");
        assertEq(IMD.balanceOf(address(liq)), 0, "nothing stranded");
    }
}

contract MainnetForkInkIs0Test is MainnetForkBase {
    function _inkAddress() internal pure override returns (address) {
        return address(0x00000000000000000000000000000000000111Aa);
    }
}

contract MainnetForkInkIs1Test is MainnetForkBase {
    function _inkAddress() internal pure override returns (address) {
        return address(0xffFfFFfFfFFfFfffFFFFfffFFffFFFfFfFFf1111);
    }
}
