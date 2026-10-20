// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "v4-core-test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/libraries/CustomRevert.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";

import {InkHook, IAgentPortraits, IInkVault} from "../src/InkHook.sol";
import {LaunchToken} from "../src/LaunchToken.sol";

contract StubPortraits {
    mapping(address => bool) public agent;

    function setAgent(address holder, bool isAgent) external {
        agent[holder] = isAgent;
    }

    function isAgentHolder(address holder) external view returns (bool) {
        return agent[holder];
    }
}

contract StubVault {
    bool public released;
    address public liquidity;

    function set(bool released_, address liquidity_) external {
        released = released_;
        liquidity = liquidity_;
    }
}

/// Stands in for IMD's launch factory: deploys from init code with CREATE2 and initializes the pool, so the
/// hook's beforeInitialize sees the factory as the sender.
contract LaunchProbe {
    function deploy(bytes memory code, bytes32 salt) external returns (address created) {
        assembly ("memory-safe") {
            created := create2(0, add(code, 32), mload(code), salt)
        }
        require(created != address(0), "constructor failed");
    }

    function initialize(IPoolManager manager, PoolKey memory key, uint160 sqrtPriceX96) external {
        manager.initialize(key, sqrtPriceX96);
    }
}

/// The INK hook launch: the token and the hook the factory deploys, the pool it initializes, the trading
/// lock, the hook fee on every swap shape, the agent-holder waiver, and the audit fix that lets only the
/// factory bind the hook to a pool (finding dcacbade3b53).
contract InkHookLaunchTest is Test, Deployers {
    using CurrencyLibrary for Currency;

    uint24 constant POOL_FEE = 12_500; // the launch policy's 1.25%
    int24 constant SPACING = 60; // the launch's tick spacing
    uint16 constant HOOK_FEE_BPS = 25;

    InkHook hook;
    LaunchToken ink;
    MockERC20 imd;
    StubPortraits portraits;
    StubVault vault;
    PoolKey poolKey;
    bool inkIs0;

    address treasury = makeAddr("treasury");
    address liquidity = makeAddr("liquidity");
    address attacker = makeAddr("attacker");
    address buyer = makeAddr("buyer");
    address agent = makeAddr("agent");

    function setUp() public {
        deployFreshManagerAndRouters();
        imd = new MockERC20("Identity.md", "IMD", 18);
        portraits = new StubPortraits();
        vault = new StubVault();
        vault.set(false, liquidity);
        // The factory deploys the token just before the hook, so this test (the factory here) holds the supply.
        ink = new LaunchToken();
        address hookAddr = address(
            uint160(
                Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                    | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
            ) ^ (0x4444 << 144)
        );
        deployCodeTo(
            "InkHook.sol:InkHook",
            abi.encode(
                manager,
                IAgentPortraits(address(portraits)),
                IInkVault(address(vault)),
                Currency.wrap(address(imd)),
                treasury,
                HOOK_FEE_BPS,
                address(this) // the launch factory, which initializes the pool
            ),
            hookAddr
        );
        hook = InkHook(hookAddr);
        inkIs0 = address(ink) < address(imd);
        poolKey = PoolKey({
            currency0: Currency.wrap(inkIs0 ? address(ink) : address(imd)),
            currency1: Currency.wrap(inkIs0 ? address(imd) : address(ink)),
            fee: POOL_FEE,
            tickSpacing: SPACING,
            hooks: IHooks(hookAddr)
        });
    }

    // ---------------------------------------------------------------- helpers

    function _hookRevert(bytes4 fn, bytes4 reason) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            fn,
            abi.encodeWithSelector(reason),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    /// The factory initializes the pool one to one and seeds it on both sides so every swap shape has a path.
    function _openPool() internal {
        manager.initialize(poolKey, TickMath.getSqrtPriceAtTick(0));
        imd.mint(address(this), 1_000_000_000e18);
        ink.approve(address(modifyLiquidityRouter), type(uint256).max);
        imd.approve(address(modifyLiquidityRouter), type(uint256).max);
        modifyLiquidityRouter.modifyLiquidity(
            poolKey, ModifyLiquidityParams(-60_000, 60_000, int256(1e23), bytes32(0)), ""
        );
    }

    function _fund(address who) internal {
        ink.transfer(who, 1_000_000e18);
        imd.mint(who, 1_000_000e18);
        vm.startPrank(who, who);
        ink.approve(address(swapRouter), type(uint256).max);
        imd.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    /// amountSpecified < 0 is exact input, > 0 exact output; buyInk pays IMD for INK.
    function _swap(address who, bool buyInk, int256 amountSpecified) internal returns (BalanceDelta delta) {
        bool zeroForOne = buyInk ? !inkIs0 : inkIs0;
        vm.prank(who, who);
        delta = swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _claim(Currency c) internal view returns (uint256) {
        return manager.balanceOf(address(hook), c.toId());
    }

    function _inkDelta(BalanceDelta d) internal view returns (int128) {
        return inkIs0 ? d.amount0() : d.amount1();
    }

    function _imdDelta(BalanceDelta d) internal view returns (int128) {
        return inkIs0 ? d.amount1() : d.amount0();
    }

    // ---------------------------------------------------------------- the token

    function test_tokenIsFixedSupplyInk() public {
        assertEq(ink.name(), "INK");
        assertEq(ink.symbol(), "INK");
        assertEq(ink.decimals(), 18);
        assertEq(ink.totalSupply(), 1_000_000_000e18);
        assertEq(ink.totalSupply(), 1e27);
        assertEq(ink.balanceOf(address(this)), ink.totalSupply(), "minted once to the deployer");
        // 80% of the supply is exactly the vault's 2,000 x 400,000 INK funding requirement.
        assertEq(ink.totalSupply() * 8_000 / 10_000, 2_000 * 400_000e18);

        ink.transfer(buyer, 5e18);
        assertEq(ink.balanceOf(buyer), 5e18);
        vm.prank(buyer);
        ink.transfer(attacker, 2e18);
        assertEq(ink.balanceOf(buyer), 3e18);
        assertEq(ink.balanceOf(attacker), 2e18);
        assertEq(ink.totalSupply(), 1e27, "nothing mints or burns");

        (bool ok,) = address(ink).call(abi.encodeWithSignature("mint(address,uint256)", buyer, 1));
        assertFalse(ok, "no mint");
        (ok,) = address(ink).call(abi.encodeWithSignature("owner()"));
        assertFalse(ok, "no owner");
    }

    // ---------------------------------------------------------------- binding the pool

    /// Finding dcacbade3b53, proof 1: a stranger tries to bind the hook to an ETH/IMD pool before the factory.
    function test_strangerCannotBindHookToWrongPoolBeforeFactory() public {
        PoolKey memory wrong = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(imd)),
            fee: 0,
            tickSpacing: 1,
            hooks: IHooks(address(hook))
        });
        vm.prank(attacker, attacker);
        vm.expectRevert(_hookRevert(IHooks.beforeInitialize.selector, InkHook.NotFactory.selector));
        manager.initialize(wrong, TickMath.getSqrtPriceAtTick(0));
        assertFalse(hook.poolCreated());

        manager.initialize(poolKey, TickMath.getSqrtPriceAtTick(0));
        assertTrue(hook.poolCreated());
        assertEq(Currency.unwrap(hook.ink()), address(ink));
    }

    /// Finding dcacbade3b53, proof 2: the right pair, but a stranger's fee tier, spacing and opening price.
    function test_strangerCannotFixWrongFeeAndPriceBeforeFactory() public {
        PoolKey memory k = poolKey;
        k.fee = 0;
        k.tickSpacing = 1;
        vm.prank(attacker, attacker);
        vm.expectRevert(_hookRevert(IHooks.beforeInitialize.selector, InkHook.NotFactory.selector));
        manager.initialize(k, TickMath.getSqrtPriceAtTick(TickMath.MAX_TICK - 1));

        manager.initialize(poolKey, TickMath.getSqrtPriceAtTick(0));
        assertTrue(hook.poolCreated());
    }

    function test_factoryInitializesExactlyOnePoolPairedWithImd() public {
        PoolKey memory notImd = poolKey;
        (notImd.currency0, notImd.currency1) = inkIs0
            ? (Currency.wrap(address(ink)), Currency.wrap(address(new MockERC20("X", "X", 18))))
            : (Currency.wrap(address(0)), Currency.wrap(address(ink)));
        vm.expectRevert(_hookRevert(IHooks.beforeInitialize.selector, InkHook.WrongPool.selector));
        manager.initialize(notImd, TickMath.getSqrtPriceAtTick(0));

        vm.expectEmit(true, true, true, true, address(hook));
        emit InkHook.PoolOpened(Currency.wrap(address(ink)));
        manager.initialize(poolKey, TickMath.getSqrtPriceAtTick(0));
        assertEq(hook.poolOpenedAt(), block.timestamp);
        assertEq(hook.factory(), address(this));

        PoolKey memory second = poolKey;
        second.fee = 3_000;
        vm.expectRevert(_hookRevert(IHooks.beforeInitialize.selector, InkHook.PoolAlreadyCreated.selector));
        manager.initialize(second, TickMath.getSqrtPriceAtTick(0));
    }

    function test_callbacksRefuseEveryoneButThePoolManager() public {
        _openPool();
        SwapParams memory p = SwapParams(true, -1, 0);
        BalanceDelta zero = BalanceDelta.wrap(0);
        ModifyLiquidityParams memory m = ModifyLiquidityParams(0, 0, 0, bytes32(0));
        address[2] memory callers = [address(this), attacker];
        for (uint256 i; i < 2; i++) {
            vm.startPrank(callers[i], callers[i]);
            vm.expectRevert(InkHook.NotPoolManager.selector);
            hook.beforeInitialize(callers[i], poolKey, 0);
            vm.expectRevert(InkHook.NotPoolManager.selector);
            hook.beforeSwap(callers[i], poolKey, p, "");
            vm.expectRevert(InkHook.NotPoolManager.selector);
            hook.afterSwap(callers[i], poolKey, p, zero, "");
            vm.expectRevert(InkHook.NotPoolManager.selector);
            hook.unlockCallback("");
            vm.expectRevert(InkHook.HookNotImplemented.selector);
            hook.afterInitialize(callers[i], poolKey, 0, 0);
            vm.expectRevert(InkHook.HookNotImplemented.selector);
            hook.beforeAddLiquidity(callers[i], poolKey, m, "");
            vm.expectRevert(InkHook.HookNotImplemented.selector);
            hook.afterAddLiquidity(callers[i], poolKey, m, zero, zero, "");
            vm.expectRevert(InkHook.HookNotImplemented.selector);
            hook.beforeRemoveLiquidity(callers[i], poolKey, m, "");
            vm.expectRevert(InkHook.HookNotImplemented.selector);
            hook.afterRemoveLiquidity(callers[i], poolKey, m, zero, zero, "");
            vm.expectRevert(InkHook.HookNotImplemented.selector);
            hook.beforeDonate(callers[i], poolKey, 0, 0, "");
            vm.expectRevert(InkHook.HookNotImplemented.selector);
            hook.afterDonate(callers[i], poolKey, 0, 0, "");
            vm.stopPrank();
        }
        // No owner, admin or upgrade surface exists to call.
        (bool ok,) = address(hook).call(abi.encodeWithSignature("owner()"));
        assertFalse(ok);
        (ok,) = address(hook).call(abi.encodeWithSignature("transferOwnership(address)", attacker));
        assertFalse(ok);
    }

    // ---------------------------------------------------------------- the lock

    function test_noSwapUntilTheVaultReleases() public {
        _openPool();
        _fund(buyer);
        assertFalse(hook.tradingOpen());
        vm.prank(buyer, buyer);
        vm.expectRevert(_hookRevert(IHooks.beforeSwap.selector, InkHook.TradingNotOpen.selector));
        swapRouter.swap(
            poolKey,
            SwapParams(!inkIs0, -1e18, !inkIs0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        // The factory's liquidity position is untouched by the lock: adding and removing works before release.
        modifyLiquidityRouter.modifyLiquidity(
            poolKey, ModifyLiquidityParams(-60_000, 60_000, -1e22, bytes32(0)), ""
        );
        modifyLiquidityRouter.modifyLiquidity(
            poolKey, ModifyLiquidityParams(-60_000, 60_000, 1e22, bytes32(0)), ""
        );

        vault.set(true, liquidity);
        assertTrue(hook.tradingOpen());
        vm.expectEmit(true, true, true, true, address(hook));
        emit InkHook.TradingOpened(uint64(block.timestamp));
        _swap(buyer, true, -1e18);
        assertEq(hook.tradingOpenedAt(), block.timestamp);
        // Once open, stays open regardless of the vault.
        vault.set(false, liquidity);
        assertTrue(hook.tradingOpen());
        _swap(buyer, true, -1e18);
    }

    // ---------------------------------------------------------------- the fee

    /// A buy, exact input: IMD fixed, the INK output is the unspecified side and carries the 0.25% fee.
    function test_feeOnBuyExactInput() public {
        _openPool();
        vault.set(true, liquidity);
        _fund(buyer);
        uint256 before = ink.balanceOf(buyer);
        BalanceDelta d = _swap(buyer, true, -1e18);
        assertEq(_imdDelta(d), -1e18, "exact IMD in");
        uint256 net = uint256(uint128(_inkDelta(d)));
        uint256 fee = _claim(Currency.wrap(address(ink)));
        assertGt(fee, 0);
        assertEq(fee, (net + fee) * HOOK_FEE_BPS / 10_000, "0.25% of the gross INK output");
        assertEq(ink.balanceOf(buyer) - before, net, "buyer receives the output net of the fee");
        assertEq(_claim(Currency.wrap(address(imd))), 0, "nothing taken from the specified side");
    }

    /// A buy, exact output: INK fixed, the IMD input is the unspecified side and carries the fee.
    function test_feeOnBuyExactOutput() public {
        _openPool();
        vault.set(true, liquidity);
        _fund(buyer);
        uint256 before = imd.balanceOf(buyer);
        BalanceDelta d = _swap(buyer, true, 1e18);
        assertEq(_inkDelta(d), 1e18, "exact INK out");
        uint256 paid = uint256(uint128(-_imdDelta(d)));
        uint256 fee = _claim(Currency.wrap(address(imd)));
        assertGt(fee, 0);
        assertEq(fee, (paid - fee) * HOOK_FEE_BPS / 10_000, "0.25% of the pool's IMD input, paid on top");
        assertEq(before - imd.balanceOf(buyer), paid, "buyer pays input plus fee");
        assertEq(_claim(Currency.wrap(address(ink))), 0);
    }

    /// A sell, exact input: INK fixed, the IMD output carries the fee.
    function test_feeOnSellExactInput() public {
        _openPool();
        vault.set(true, liquidity);
        _fund(buyer);
        BalanceDelta d = _swap(buyer, false, -1e18);
        assertEq(_inkDelta(d), -1e18, "exact INK in");
        uint256 net = uint256(uint128(_imdDelta(d)));
        uint256 fee = _claim(Currency.wrap(address(imd)));
        assertGt(fee, 0);
        assertEq(fee, (net + fee) * HOOK_FEE_BPS / 10_000, "0.25% of the gross IMD output");
        assertEq(_claim(Currency.wrap(address(ink))), 0);
    }

    /// A sell, exact output: IMD fixed, the INK input carries the fee.
    function test_feeOnSellExactOutput() public {
        _openPool();
        vault.set(true, liquidity);
        _fund(buyer);
        BalanceDelta d = _swap(buyer, false, 1e18);
        assertEq(_imdDelta(d), 1e18, "exact IMD out");
        uint256 paid = uint256(uint128(-_inkDelta(d)));
        uint256 fee = _claim(Currency.wrap(address(ink)));
        assertGt(fee, 0);
        assertEq(fee, (paid - fee) * HOOK_FEE_BPS / 10_000, "0.25% of the pool's INK input, paid on top");
        assertEq(_claim(Currency.wrap(address(imd))), 0);
    }

    /// Fees stay in their own currency: IMD goes to the treasury, INK to the vault's liquidity contract.
    /// Nothing is sold for ETH and nothing is burned.
    function test_collectFeesPaysImdToTreasuryAndInkToLiquidity() public {
        _openPool();
        vault.set(true, liquidity);
        _fund(buyer);
        _swap(buyer, true, -1e18); // INK fee
        _swap(buyer, false, -1e18); // IMD fee
        uint256 inkFee = _claim(Currency.wrap(address(ink)));
        uint256 imdFee = _claim(Currency.wrap(address(imd)));
        assertGt(inkFee, 0);
        assertGt(imdFee, 0);
        uint256 supply = ink.totalSupply();

        vm.prank(attacker); // anyone
        (uint256 imdPaid, uint256 inkPaid) = hook.collectFees();
        assertEq(imdPaid, imdFee);
        assertEq(inkPaid, inkFee);
        assertEq(imd.balanceOf(treasury), imdFee);
        assertEq(ink.balanceOf(liquidity), inkFee);
        assertEq(ink.balanceOf(address(hook)), 0);
        assertEq(imd.balanceOf(address(hook)), 0);
        assertEq(address(hook).balance, 0, "no ETH");
        assertEq(_claim(Currency.wrap(address(ink))), 0);
        assertEq(_claim(Currency.wrap(address(imd))), 0);
        assertEq(ink.totalSupply(), supply, "nothing burned");
        (uint256 a, uint256 b) = hook.collectFees();
        assertEq(a + b, 0, "nothing left");
    }

    /// The waiver follows tx.origin, and only once the portrait has been held since an earlier block
    /// (the live InkPortraits enforces that; the stub answers for the given origin).
    function test_agentHolderPaysNoHookFee() public {
        _openPool();
        vault.set(true, liquidity);
        _fund(agent);
        _fund(buyer);
        portraits.setAgent(agent, true);
        BalanceDelta d = _swap(agent, true, -1e18);
        assertEq(_claim(Currency.wrap(address(ink))), 0, "no fee for an agent holder");
        uint256 agentOut = uint256(uint128(_inkDelta(d)));
        BalanceDelta e = _swap(buyer, true, -1e18);
        assertGt(_claim(Currency.wrap(address(ink))), 0, "a non-holder pays");
        assertLt(uint256(uint128(_inkDelta(e))), agentOut, "and receives less for the same input");
    }

    function test_feeRateAndBindingsAreImmutable() public view {
        assertEq(hook.feeBps(), 25);
        assertEq(hook.MAX_FEE_BPS(), 100);
        assertEq(address(hook.poolManager()), address(manager));
        assertEq(address(hook.portraits()), address(portraits));
        assertEq(address(hook.vault()), address(vault));
        assertEq(Currency.unwrap(hook.imd()), address(imd));
        assertEq(hook.treasury(), treasury);
        assertEq(hook.factory(), address(this));
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeInitialize && p.beforeSwap && p.afterSwap && p.afterSwapReturnDelta);
        assertFalse(
            p.afterInitialize || p.beforeAddLiquidity || p.afterAddLiquidity || p.beforeRemoveLiquidity
                || p.afterRemoveLiquidity || p.beforeDonate || p.afterDonate || p.beforeSwapReturnDelta
                || p.afterAddLiquidityReturnDelta || p.afterRemoveLiquidityReturnDelta
        );
    }
}

/// Rehearses the factory's launch on an empty chain: both contracts are deployed from their init code by a
/// CREATE2 deployer, with the live mainnet dependency addresses that have no code here, and then the factory
/// initializes the pool.
contract InkHookFactoryLaunchTest is Test {
    address constant PORTRAITS = 0x54Fa3515848440dDde2Aefe45A382bd868caCd15;
    address constant VAULT = 0x33c85714C7D78FDB253fe1cf761D2D5C3c12d747;
    address constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address constant TREASURY = 0xbc10B3662231c830d2ee10bc6359dB17bEa4b3d4;
    address constant PM = 0x000000000004444c5dc75cB358380D2e3dE08A90;

    LaunchProbe factory;
    LaunchToken ink;
    InkHook hook;

    function _predict(bytes32 initHash, bytes32 salt) internal view returns (address) {
        return address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(factory), salt, initHash))))
        );
    }

    function setUp() public {
        vm.chainId(1);
        assertEq(PORTRAITS.code.length, 0);
        assertEq(VAULT.code.length, 0);
        assertEq(IMD.code.length, 0);
        assertEq(PM.code.length, 0);
        factory = new LaunchProbe();

        bytes memory tokenCode = vm.getCode("src/LaunchToken.sol:LaunchToken");
        assertLe(tokenCode.length, 49_152);
        ink = LaunchToken(factory.deploy(tokenCode, bytes32(0)));

        bytes memory hookCode = abi.encodePacked(
            vm.getCode("src/InkHook.sol:InkHook"),
            abi.encode(PM, PORTRAITS, VAULT, IMD, TREASURY, uint16(25), address(factory))
        );
        assertLe(hookCode.length, 49_152);
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        bytes32 initHash = keccak256(hookCode);
        bytes32 salt;
        for (uint256 i = 1;; i++) {
            salt = bytes32(i);
            if (uint160(_predict(initHash, salt)) & Hooks.ALL_HOOK_MASK == flags) break;
        }
        hook = InkHook(factory.deploy(hookCode, salt));
        assertEq(address(hook), _predict(initHash, salt));
    }

    function test_constructorsNeedNoLiveDependency() public view {
        assertEq(ink.totalSupply(), 1e27);
        assertEq(ink.balanceOf(address(factory)), 1e27, "minted to the factory");
        assertEq(address(hook.poolManager()), PM);
        assertEq(address(hook.portraits()), PORTRAITS);
        assertEq(address(hook.vault()), VAULT);
        assertEq(Currency.unwrap(hook.imd()), IMD);
        assertEq(hook.treasury(), TREASURY);
        assertEq(hook.feeBps(), 25);
        assertEq(hook.factory(), address(factory));
        assertFalse(hook.poolCreated());
        assertEq(address(hook).balance, 0);
    }

    function test_runtimeSizeAndOpcodes() public view {
        address[2] memory apps = [address(ink), address(hook)];
        for (uint256 i; i < 2; i++) {
            bytes memory code = apps[i].code;
            assertGt(code.length, 0);
            assertLe(code.length, 24_576);
            for (uint256 pc; pc < code.length; pc++) {
                uint8 op = uint8(code[pc]);
                if (op >= 0x60 && op <= 0x7f) {
                    pc += op - 0x5f;
                    continue;
                }
                assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden runtime opcode");
            }
        }
    }

    /// With a real PoolManager in place, the factory binds the pool and nobody else can.
    function test_factoryBindsThePoolOthersCannot() public {
        deployCodeTo("PoolManager.sol:PoolManager", abi.encode(address(this)), PM);
        deployCodeTo("MockERC20.sol:MockERC20", abi.encode("Identity.md", "IMD", uint8(18)), IMD);
        bool inkIs0 = address(ink) < IMD;
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(inkIs0 ? address(ink) : IMD),
            currency1: Currency.wrap(inkIs0 ? IMD : address(ink)),
            fee: 12_500,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        vm.prank(makeAddr("stranger"), makeAddr("stranger"));
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(InkHook.NotFactory.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        IPoolManager(PM).initialize(key, TickMath.getSqrtPriceAtTick(0));
        assertFalse(hook.poolCreated());

        factory.initialize(IPoolManager(PM), key, TickMath.getSqrtPriceAtTick(0));
        assertTrue(hook.poolCreated());
        assertEq(Currency.unwrap(hook.ink()), address(ink));
    }
}
