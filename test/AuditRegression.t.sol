// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ConfiguredLiquidity} from "./helpers/ConfiguredLiquidity.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {InkPortraits} from "../src/InkPortraits.sol";
import {InkVault} from "../src/InkVault.sol";
import {InkLiquidity} from "../src/InkLiquidity.sol";
import {InkRenderer} from "../src/InkRenderer.sol";
import {InkHook, IAgentPortraits, IInkVault} from "../src/InkHook.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";

contract PoolManagerView {
    IPoolManager public immutable poolManager;

    constructor(IPoolManager manager) {
        poolManager = manager;
    }
}
import {TestSeats} from "../src/testnet/TestSeats.sol";

contract AuditRegressionTest is Test {
    uint256 internal constant PORTRAIT = 400_000e18;
    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal buyer = makeAddr("buyer");
    InkPortraits internal portraits;
    InkVault internal vault;
    MockERC20 internal ink;
    TestSeats internal seats;
    ConfiguredLiquidity internal sink;

    function setUp() public {
        vm.roll(100);
        seats = new TestSeats();
        portraits = new InkPortraits(owner);
        vault = new InkVault(portraits, seats, owner);
        ink = new MockERC20("INK", "INK", 18);
        sink = new ConfiguredLiquidity(IERC20(address(ink)));
        ink.mint(address(vault), 2000 * PORTRAIT);
        vm.startPrank(owner);
        portraits.setVault(address(vault));
        vault.setInk(IERC20(address(ink)));
        vault.setup(keccak256("audit fixture"), uint64(block.timestamp), address(sink));
        vm.stopPrank();
        vm.warp(vault.claimEnd());
        vault.release();
        vm.prank(alice);
        portraits.setApprovalForAll(address(vault), true);
    }

    function _pull(address who, uint256 n) internal returns (uint256 first) {
        ink.mint(who, n * PORTRAIT);
        vm.startPrank(who);
        ink.approve(address(vault), n * PORTRAIT);
        first = vault.pull(n);
        vm.stopPrank();
    }

    function _mature() internal {
        uint256 entropyBlock = block.number + 1;
        vm.roll(block.number + 2);
        vm.setBlockhash(entropyBlock, keccak256(abi.encode("audit entropy", entropyBlock)));
    }

    function _mintPortraits(uint256 n) internal {
        for (uint256 i; i < n; i += 100) {
            _pull(alice, n - i < 100 ? n - i : 100);
        }
        _mature();
        for (uint256 i; i < n; i += 100) {
            assertEq(vault.revealNext(100), n - i < 100 ? n - i : 100);
        }
    }

    function _depositRange(uint256 start, uint256 n) internal {
        uint256[] memory ids = new uint256[](n);
        for (uint256 i; i < n; i++) {
            ids[i] = 10_000 + start + i;
        }
        vm.prank(alice);
        vault.deposit(ids, 0);
    }

    function test_largeAdmissionQueueMakesProgressWithinGasBudget() public {
        _mintPortraits(2000);
        vm.roll(block.number + 1);
        for (uint256 i; i < 2000; i += 100) {
            _depositRange(i, 100);
        }
        vm.roll(block.number + 1);
        uint256 first = _pull(buyer, 2);
        _mature();
        uint256 largestStep;
        for (uint256 attempt; attempt < 21 && vault.nextReveal() == first; attempt++) {
            uint256 waiting = vault.waitingCount();
            vm.cool(address(vault));
            uint256 gasBefore = gasleft();
            (bool ok,) = address(vault).call{gas: 5_000_000}(abi.encodeCall(vault.reveal, (first)));
            uint256 used = gasBefore - gasleft();
            if (used > largestStep) largestStep = used;
            assertTrue(ok, "one reveal step must fit in 5M gas even with all 2,000 portraits pending");
            assertLt(vault.waitingCount(), waiting, "admission must persist between calls");
        }
        assertEq(vault.nextReveal(), first + 1);
        assertTrue(vault.reveal(first + 1), "later pullers remain live");
        assertEq(portraits.balanceOf(buyer), 2);
        assertEq(vault.heldCount(), 1998);
        assertEq(ink.balanceOf(address(vault)), 2 * PORTRAIT);
        emit log_named_uint("largest admission/reveal step gas (including call overhead)", largestStep);
    }

    function test_safeTransferToVaultIsRejected() public {
        _mintPortraits(1);
        uint256 before = ink.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(InkPortraits.UseDeposit.selector);
        portraits.safeTransferFrom(alice, address(vault), 10_000);
        assertEq(portraits.ownerOf(10_000), alice);
        assertEq(ink.balanceOf(alice), before);
        assertEq(vault.heldCount(), 0);
    }

    function _poolFixture(PoolManager manager) internal returns (InkLiquidity liquidity, PoolKey memory key) {
        address treasury = makeAddr("treasury");
        liquidity = new InkLiquidity(
            manager, IPositionManager(address(new PoolManagerView(manager))), owner, treasury
        );
        address hookAddress = address(
            uint160(
                Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                    | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
            ) ^ (0x5555 << 144)
        );
        deployCodeTo(
            "src/InkHook.sol:InkHook",
            abi.encode(
                manager,
                IAgentPortraits(address(portraits)),
                IInkVault(address(vault)),
                Currency.wrap(address(0)),
                treasury,
                uint16(25),
                address(this) // the test initializes the pool, as the launch factory does
            ),
            hookAddress
        );
        key =
            PoolKey(Currency.wrap(address(0)), Currency.wrap(address(ink)), 12_500, 200, IHooks(hookAddress));
    }

    function test_uninitializedPoolCannotSetPermanentFloor() public {
        PoolManager manager = new PoolManager(owner);
        (InkLiquidity liquidity, PoolKey memory key) = _poolFixture(manager);
        vm.prank(owner);
        vm.expectRevert(InkLiquidity.PoolNotInitialized.selector);
        liquidity.setPool(key, IERC20(address(ink)));
        assertFalse(liquidity.poolSet());
        assertEq(address(liquidity.ink()), address(0));
        manager.initialize(key, TickMath.getSqrtPriceAtTick(129_000));
        vm.prank(owner);
        liquidity.setPool(key, IERC20(address(ink)));
        assertTrue(liquidity.poolSet(), "failed setup must remain retryable");
        assertEq(liquidity.floorTick(), 129_000);
        vm.prank(owner);
        vm.expectRevert(InkLiquidity.PoolAlreadySet.selector);
        liquidity.setPool(key, IERC20(address(ink)));
    }

    function test_pendingRerollCannotBeSoldWithOldTraits() public {
        _mintPortraits(1);
        ink.mint(alice, PORTRAIT / 100);
        vm.startPrank(alice);
        ink.approve(address(vault), PORTRAIT / 100);
        vault.rerollTraits(10_000, PORTRAIT / 100);
        vm.stopPrank();
        _mature();
        vm.prank(alice);
        vm.expectRevert(InkPortraits.RerollPending.selector);
        portraits.transferFrom(alice, buyer, 10_000);
        assertTrue(vault.revealTraits(10_000));
        vm.prank(alice);
        portraits.transferFrom(alice, buyer, 10_000);
        assertEq(portraits.ownerOf(10_000), buyer);
    }

    function test_initializedPoolAtZeroTickIsValid() public {
        PoolManager manager = new PoolManager(owner);
        (InkLiquidity liquidity, PoolKey memory key) = _poolFixture(manager);
        manager.initialize(key, TickMath.getSqrtPriceAtTick(0));
        vm.prank(owner);
        liquidity.setPool(key, IERC20(address(ink)));
        assertTrue(liquidity.poolSet(), "zero tick is a valid initialized price");
        assertEq(liquidity.floorTick(), 0);
    }

    function test_partialAdmissionPreservesDrawAndExcludesSameBlockAndLaterDeposits() public {
        _mintPortraits(103);
        vm.roll(block.number + 1);
        _depositRange(0, 101);
        vm.roll(block.number + 1);
        uint256 first = _pull(buyer, 1);
        uint64 pullBlock = uint64(block.number);
        _depositRange(101, 1); // Same block as the pull: not eligible.
        _mature();
        _depositRange(102, 1); // Entropy already known: not eligible either.
        bytes32 entropy = blockhash(uint256(pullBlock) + 1);
        uint256 pick = uint256(keccak256(abi.encode(entropy, first))) % 1998;

        vm.expectEmit(address(vault));
        emit InkVault.AdmissionProgress(first, 100);
        assertEq(vault.revealNext(1000), 0, "partial admission is not a reveal");
        assertEq(vault.nextReveal(), first);
        assertEq(vault.inventorySize(), 100);
        assertEq(vault.waitingCount(), 3);
        (, uint64 unchanged, bool done) = vault.pulls(first);
        assertEq(unchanged, pullBlock, "batching must not renew or change entropy");
        assertFalse(done);
        assertEq(portraits.balanceOf(buyer), 0);

        assertTrue(vault.reveal(first));
        assertEq(portraits.ownerOf(pick < 101 ? 10_000 + pick : 10_103), buyer);
        assertEq(portraits.ownerOf(10_101), address(vault));
        assertEq(portraits.ownerOf(10_102), address(vault));
        assertEq(vault.waitingCount(), 2);
        assertEq(vault.heldCount(), pick < 101 ? 102 : 103);
    }

    function test_hashExpiryDuringAdmissionKeepsOriginalDraw() public {
        _mintPortraits(201);
        vm.roll(block.number + 1);
        _depositRange(0, 201);
        vm.roll(block.number + 1);
        uint256 first = _pull(buyer, 1);
        uint256 made = block.number;
        _mature();
        bytes32 entropy = blockhash(made + 1);
        uint256 pick = uint256(keccak256(abi.encode(entropy, first))) % 2000;
        assertFalse(vault.reveal(first));
        assertEq(vault.waitingCount(), 101);
        vm.roll(block.number + 300);
        assertEq(vault.revealNext(1), 0, "second admission batch");
        assertTrue(vault.reveal(first), "recorded entropy survives expiry");
        assertFalse(vault.pullExpired(first));
        assertEq(vault.pullBlock(first), made);
        assertEq(vault.waitingCount(), 0);
        assertEq(portraits.ownerOf(pick < 201 ? 10_000 + pick : 10_201), buyer);
        assertEq(portraits.balanceOf(buyer), 1);
    }

    /// Review 4ca49345: expiring the head pull must not admit hand-ins made after a queued pull's block into
    /// that pull's draw, since its block hash is already public.
    function test_expiredHeadPullNeverWidensALaterPullsDraw() public {
        _mintPortraits(2);
        vm.roll(1000);
        uint256 pullA = _pull(alice, 1);
        vm.roll(1003);
        uint256 pullB = _pull(buyer, 1);
        vm.roll(1010);
        assertTrue(blockhash(1004) != bytes32(0), "pull B's entropy is public");
        _depositRange(0, 2);
        assertEq(vault.waitingCount(), 2);

        vm.roll(1258);
        assertEq(blockhash(1001), bytes32(0), "pull A's hash expired");
        assertFalse(vault.reveal(pullA));
        (, uint64 entropyBlock,) = vault.pulls(pullA);
        assertEq(entropyBlock, 1000, "expiry never replaces entropy");
        assertTrue(vault.pullExpired(pullA));
        assertEq(vault.pullBlock(pullA), 1000, "expiry keeps the admission cutoff");
        assertEq(vault.waitingCount(), 2, "expiry admits nothing");

        vm.roll(1260);
        assertTrue(vault.reveal(pullB));
        (, uint64 bBlock, bool bDone) = vault.pulls(pullB);
        assertTrue(bDone);
        assertEq(bBlock, 1003);
        assertEq(vault.pullBlock(pullB), 1003);
        assertEq(vault.waitingCount(), 2, "hand-ins after both pulls' blocks stay out of their draws");
        assertEq(vault.inventorySize(), 0);
        assertEq(portraits.balanceOf(alice), 0);
        assertEq(portraits.balanceOf(buyer), 1);

        // A pull made after the hand-ins admits them, as documented.
        uint256 pullC = _pull(buyer, 1);
        assertEq(vault.pullBlock(pullC), 1260);
        _mature();
        assertTrue(vault.reveal(pullC));
        assertEq(vault.waitingCount(), 0, "the draw covered both hand-ins");
        assertEq(vault.inventorySize(), vault.heldCount());
        assertEq(portraits.balanceOf(buyer), 2);
        vm.expectRevert(InkVault.UnknownPull.selector);
        vault.pullBlock(pullC + 1);
    }

    /// Expiring both pulls keeps later deposits waiting for a genuinely new paid request.
    function test_expiredPullsCloseWithoutWideningDrawsOrRenewing() public {
        _mintPortraits(1);
        vm.roll(1000);
        uint256 pullA = _pull(buyer, 1);
        vm.roll(1005);
        _depositRange(0, 1);
        vm.roll(1010);
        uint256 pullB = _pull(buyer, 1);
        vm.roll(1300);
        assertEq(vault.revealNext(1), 0, "expired, no portrait revealed");
        assertEq(vault.nextReveal(), pullA + 1);
        assertTrue(vault.pullExpired(pullA));
        vm.roll(1600);
        assertEq(vault.revealNext(1), 0);
        assertEq(vault.nextReveal(), pullB + 1);
        assertTrue(vault.pullExpired(pullB));
        assertEq(vault.pullBlock(pullA), 1000);
        assertEq(vault.pullBlock(pullB), 1010);
        assertEq(vault.waitingCount(), 1);
        assertEq(portraits.balanceOf(buyer), 0);
        assertEq(ink.balanceOf(buyer), 2 * (PORTRAIT - PORTRAIT / 100));
        vm.expectRevert(InkVault.AlreadyRevealed.selector);
        vault.reveal(pullA);
    }

    /// Review 4ca49345: a pull can't count hand-ins from its own block, since its fixed cutoff never admits
    /// them; otherwise, with everything else drawn, it could never be revealed.
    function test_sameBlockHandInsDoNotCountForPullsMadeNow() public {
        _mintPortraits(2000);
        assertEq(vault.available(), 0);
        vm.roll(block.number + 1);
        _depositRange(0, 1);
        assertEq(vault.waitingCount(), 1);
        assertEq(vault.waitingBefore(), 0, "handed in this block");
        ink.mint(buyer, 2 * PORTRAIT);
        vm.startPrank(buyer);
        ink.approve(address(vault), 2 * PORTRAIT);
        vm.expectRevert(InkVault.NoneAvailable.selector);
        vault.pull(1);
        vm.stopPrank();

        vm.roll(block.number + 1);
        assertEq(vault.waitingBefore(), 1, "counts from the next block on");
        _depositRange(1, 1);
        assertEq(vault.waitingCount(), 2);
        assertEq(vault.waitingBefore(), 1);
        vm.startPrank(buyer);
        vm.expectRevert(InkVault.NoneAvailable.selector);
        vault.pull(2);
        uint256 first = vault.pull(1);
        vm.stopPrank();
        _mature();
        assertTrue(vault.reveal(first), "the pull it counted is admitted and drawn, never renewed");
        assertEq(portraits.ownerOf(10_000), buyer);
        assertEq(vault.waitingCount(), 1);
        assertEq(vault.waitingBefore(), 1);
        assertEq(vault.inventorySize(), 0);
    }

    /// Review 71ef9819: setup() is the one-shot that release() depends on, so a liquidity address without
    /// code is rejected while the owner can still correct it.
    function test_setupRejectsLiquidityWithoutCode() public {
        InkVault fresh = new InkVault(portraits, seats, owner);
        ink.mint(address(fresh), 2000 * PORTRAIT);
        vm.startPrank(owner);
        fresh.setInk(IERC20(address(ink)));
        vm.expectRevert(InkVault.BadSetup.selector);
        fresh.setup(keccak256("root"), uint64(block.timestamp), makeAddr("not a contract"));
        vm.expectRevert(InkVault.BadSetup.selector);
        fresh.setup(keccak256("root"), uint64(block.timestamp), address(0));
        assertEq(fresh.statsRoot(), bytes32(0), "still correctable");
        fresh.setup(keccak256("root"), uint64(block.timestamp), address(sink));
        vm.stopPrank();
        assertEq(fresh.liquidity(), address(sink));
    }

    function testFuzz_admissionCompletesWithBothRevealEntryPoints(uint16 rawCount, bool useRevealNext)
        public
    {
        uint256 n = bound(uint256(rawCount), 1, 301);
        _mintPortraits(n);
        vm.roll(block.number + 1);
        _depositRange(0, n);
        vm.roll(block.number + 1);
        uint256 first = _pull(buyer, 1);
        _mature();
        uint256 expectedSteps = (n + vault.MAX_ADMISSIONS() - 1) / vault.MAX_ADMISSIONS();
        for (uint256 i; i < expectedSteps; i++) {
            bool done = useRevealNext ? vault.revealNext(1) == 1 : vault.reveal(first);
            assertEq(done, i + 1 == expectedSteps);
            assertEq(vault.waitingCount(), n > (i + 1) * 100 ? n - (i + 1) * 100 : 0);
        }
        assertEq(vault.nextReveal(), first + 1);
        assertEq(portraits.balanceOf(buyer), 1);
        assertEq(ink.balanceOf(address(vault)), PORTRAIT);
    }

    function test_directSafeTransfersRejectedForBothOverloadsAndOtherNFTs() public {
        _mintPortraits(1);
        vm.startPrank(alice);
        vm.expectRevert(InkPortraits.UseDeposit.selector);
        portraits.safeTransferFrom(alice, address(vault), 10_000, "deposit");
        seats.mint(7);
        vm.expectRevert(InkVault.UseDeposit.selector);
        seats.safeTransferFrom(alice, address(vault), 7);
        vm.stopPrank();
        assertEq(seats.ownerOf(7), alice);
        _depositRange(0, 1);
        assertEq(portraits.ownerOf(10_000), address(vault));
        assertEq(ink.balanceOf(alice), PORTRAIT * 99 / 100, "deposit still pays the existing fee schedule");
        assertEq(vault.waitingCount(), 1);
        assertEq(vault.heldCount(), 1);
    }

    function test_pendingRerollBlocksApprovedOperatorsUntilExpiry() public {
        _mintPortraits(1);
        InkRenderer renderer = new InkRenderer(portraits, owner);
        assertEq(vm.parseJsonUint(renderer.tokenJSON(10_000), ".traitRerollBlock"), 0);
        bytes32 oldSeed = portraits.swarmSeed(10_000);
        ink.mint(alice, PORTRAIT / 100);
        vm.startPrank(alice);
        portraits.approve(buyer, 10_000);
        ink.approve(address(vault), PORTRAIT / 100);
        vault.rerollTraits(10_000, PORTRAIT / 100);
        vm.stopPrank();
        assertEq(vm.parseJsonUint(renderer.tokenJSON(10_000), ".traitRerollBlock"), block.number);
        _mature();
        vm.startPrank(buyer);
        vm.expectRevert(InkPortraits.RerollPending.selector);
        portraits.transferFrom(alice, buyer, 10_000);
        vm.expectRevert(InkPortraits.RerollPending.selector);
        portraits.safeTransferFrom(alice, buyer, 10_000);
        vm.expectRevert(InkPortraits.RerollPending.selector);
        portraits.safeTransferFrom(alice, buyer, 10_000, "");
        vm.stopPrank();
        vm.roll(block.number + 300);
        assertFalse(vault.revealTraits(10_000));
        assertEq(vm.parseJsonUint(renderer.tokenJSON(10_000), ".traitRerollBlock"), 0);
        assertEq(portraits.swarmSeed(10_000), oldSeed);
        _mature();
        vm.expectRevert(InkVault.NoRerollPending.selector);
        vault.revealTraits(10_000);
        assertEq(portraits.getApproved(10_000), buyer, "failed transfers do not consume approval");
        vm.prank(buyer);
        portraits.safeTransferFrom(alice, buyer, 10_000);
        assertEq(portraits.ownerOf(10_000), buyer);
    }

    function test_setupRefusesUnconfiguredLiquidityBeforeCommitting() public {
        PoolManager manager = new PoolManager(owner);
        InkLiquidity liquidity = new InkLiquidity(
            manager, IPositionManager(makeAddr("unused position manager")), owner, makeAddr("treasury")
        );
        InkPortraits p = new InkPortraits(owner);
        InkVault v = new InkVault(p, seats, owner);
        ink.mint(address(v), 2000 * PORTRAIT);
        vm.startPrank(owner);
        p.setVault(address(v));
        v.setInk(IERC20(address(ink)));
        vm.expectRevert(InkVault.BadSetup.selector);
        v.setup(keccak256("unconfigured liquidity fixture"), uint64(block.timestamp), address(liquidity));
        vm.stopPrank();
        assertEq(v.statsRoot(), bytes32(0));
        vm.expectRevert(InkVault.InkNotSet.selector);
        v.release();
        assertFalse(v.released());
        assertEq(ink.balanceOf(address(v)), 2000 * PORTRAIT);
        assertEq(ink.balanceOf(address(liquidity)), 0);
        vm.expectRevert(InkVault.NotReleased.selector);
        v.pull(1);
    }
}
