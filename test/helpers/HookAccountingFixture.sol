// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/libraries/CustomRevert.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {PositionManager} from "v4-periphery/src/PositionManager.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {IPositionDescriptor} from "v4-periphery/src/interfaces/IPositionDescriptor.sol";
import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {InkHook} from "src/InkHook.sol";
import {InkVault} from "src/InkVault.sol";
import {InkPortraits} from "src/InkPortraits.sol";
import {InkLiquidity} from "src/InkLiquidity.sol";
import {LaunchToken} from "src/LaunchToken.sol";

contract HookAccountingSeats is ERC721("Fixture seats", "SEAT") {
    function mint(address to, uint256 id) external {
        _mint(to, id);
    }
}

/// Offline source-level fixture, not a fork or a production deployment script.
/// The live applications' unmodified constructors/runtime are installed at the brief's addresses.
/// Only external IMD and seat NFTs are doubles. PoolManager, PositionManager, INK, hook,
/// portraits, vault and liquidity all execute their real code.
abstract contract HookAccountingFixture is Test {
    address internal constant PORTRAITS = 0x54Fa3515848440dDde2Aefe45A382bd868caCd15;
    address internal constant VAULT = 0x33c85714C7D78FDB253fe1cf761D2D5C3c12d747;
    address internal constant LIQUIDITY = 0xa53A3b0521e471f69C0351D9e6620848e749F37d;
    address internal constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address internal constant TREASURY = 0xbc10B3662231c830d2ee10bc6359dB17bEa4b3d4;
    uint256 internal constant PORTRAIT_BACKING = 400_000e18;
    uint160 internal constant HOOK_FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
        | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

    LaunchToken internal ink;
    MockERC20 internal imd;
    InkHook internal hook;
    InkVault internal vault;
    InkPortraits internal portraits;
    InkLiquidity internal liquidity;
    IPoolManager internal manager;
    IPositionManager internal posm;
    PoolSwapTest internal router;
    PoolModifyLiquidityTest internal lpRouter;
    PoolKey internal key;
    address[4] internal actors;
    bool internal inkIs0;

    function _setUpHook(bool inkFirst) internal {
        vm.chainId(1);
        vm.roll(100);
        vm.warp(1_800_000_000);
        inkIs0 = inkFirst;
        for (uint256 i; i < 4; i++) {
            actors[i] = makeAddr(string(abi.encodePacked("hook accounting actor ", bytes1(uint8(i)))));
        }
        manager = new PoolManager(address(this));
        // InkLiquidity prefunds PositionManager; this path never invokes Permit2/WETH/descriptor.
        posm = new PositionManager(
            manager,
            IAllowanceTransfer(address(0)),
            100_000,
            IPositionDescriptor(address(0)),
            IWETH9(address(0))
        );
        router = new PoolSwapTest(manager);
        lpRouter = new PoolModifyLiquidityTest(manager);
        HookAccountingSeats seats = new HookAccountingSeats();
        deployCodeTo("src/InkPortraits.sol:InkPortraits", abi.encode(address(this)), PORTRAITS);
        portraits = InkPortraits(PORTRAITS);
        deployCodeTo("src/InkVault.sol:InkVault", abi.encode(portraits, seats, address(this)), VAULT);
        vault = InkVault(VAULT);
        deployCodeTo(
            "src/InkLiquidity.sol:InkLiquidity", abi.encode(manager, posm, address(this), TREASURY), LIQUIDITY
        );
        liquidity = InkLiquidity(LIQUIDITY);
        portraits.setVault(VAULT);
        deployCodeTo("MockERC20.sol:MockERC20", abi.encode("Identity.md", "IMD", uint8(18)), IMD);
        imd = MockERC20(IMD);
        // Exercise both sorted-currency layouts without replacing LaunchToken with a mintable mock.
        address inkAddress = address(inkFirst ? uint160(IMD) - 1 : uint160(IMD) + 1);
        deployCodeTo("src/LaunchToken.sol:LaunchToken", inkAddress);
        ink = LaunchToken(inkAddress);
        assertEq(ink.balanceOf(address(this)), 1e27);
        address hookAddress = address(uint160((0x5555 << 144) | HOOK_FLAGS));
        deployCodeTo(
            "src/InkHook.sol:InkHook",
            abi.encode(manager, PORTRAITS, VAULT, IMD, TREASURY, uint16(25), address(this)),
            hookAddress
        );
        hook = InkHook(hookAddress);
        key = PoolKey({
            currency0: Currency.wrap(inkFirst ? inkAddress : IMD),
            currency1: Currency.wrap(inkFirst ? IMD : inkAddress),
            fee: 12_500,
            tickSpacing: 200,
            hooks: IHooks(hookAddress)
        });
        // A deep, two-sided test position at parity isolates hook accounting in all four swap shapes.
        // This is deliberately not a model of mainnet launch pricing.
        manager.initialize(key, TickMath.getSqrtPriceAtTick(0));
        imd.mint(address(this), 200_000_000e18);
        ink.approve(address(lpRouter), type(uint256).max);
        imd.approve(address(lpRouter), type(uint256).max);
        lpRouter.modifyLiquidity(key, ModifyLiquidityParams(-60_000, 60_000, 1e26, bytes32(0)), "");
        ink.transfer(VAULT, 2_000 * PORTRAIT_BACKING);
        vault.setInk(IERC20(address(ink)));
        liquidity.setPool(key, IERC20(address(ink)));
        _claimTwoPortraits(seats);
        for (uint256 i; i < 4; i++) {
            ink.transfer(actors[i], 10_000_000e18);
            imd.transfer(actors[i], 10_000_000e18);
            vm.startPrank(actors[i], actors[i]);
            ink.approve(address(router), type(uint256).max);
            imd.approve(address(router), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _claimTwoPortraits(HookAccountingSeats seats) private {
        InkPortraits.AgentStats memory stats = InkPortraits.AgentStats(1, 10_000, 2, 3, false);
        bytes32 a = keccak256(bytes.concat(keccak256(abi.encode(uint256(7), stats))));
        bytes32 b = keccak256(bytes.concat(keccak256(abi.encode(uint256(280), stats))));
        bytes32 root = a < b ? keccak256(abi.encode(a, b)) : keccak256(abi.encode(b, a));
        vault.setup(root, uint64(block.timestamp), LIQUIDITY);
        seats.mint(actors[0], 7);
        seats.mint(actors[1], 280);
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = b;
        vm.prank(actors[0]);
        vault.claim(7, stats, proof);
        proof[0] = a;
        vm.prank(actors[1]);
        vault.claim(280, stats, proof);
    }

    function _release() internal {
        vm.warp(vault.claimEnd());
        vm.prank(actors[3]);
        vault.release();
    }

    /// mode: 0 buy exact input; 1 buy exact output; 2 sell exact input; 3 sell exact output.
    function _params(uint8 mode, uint256 amount) internal view returns (SwapParams memory) {
        bool buy = mode < 2;
        bool zeroForOne = buy ? !inkIs0 : inkIs0;
        return SwapParams(
            zeroForOne,
            mode % 2 == 0 ? -int256(amount) : int256(amount),
            zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
    }

    function _swap(address payer, address origin, uint8 mode, uint256 amount)
        internal
        returns (BalanceDelta)
    {
        vm.prank(payer, origin);
        return router.swap(key, _params(mode, amount), PoolSwapTest.TestSettings(false, false), "");
    }

    function _wrapped(bytes4 callback, bytes4 reason) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            callback,
            abi.encodeWithSelector(reason),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }
}
