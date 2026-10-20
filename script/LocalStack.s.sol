// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {InkPortraits} from "../src/InkPortraits.sol";
import {InkVault} from "../src/InkVault.sol";
import {InkHook, IAgentPortraits, IInkVault} from "../src/InkHook.sol";
import {InkLiquidity} from "../src/InkLiquidity.sol";
import {InkRenderer} from "../src/InkRenderer.sol";
import {ForkInk} from "../test/MainnetFork.t.sol";
import {InkSteps} from "./InkSteps.sol";

/// @notice Puts the whole system on a LOCAL anvil fork of mainnet for the site and keeper end-to-end test
/// (scripts/src/chain-e2e.ts). Refuses to run on any chain but 31337, so it can't reach mainnet or a testnet:
///   anvil --fork-url https://ethereum-rpc.publicnode.com --chain-id 31337
///   forge script script/LocalStack.s.sol --rpc-url http://127.0.0.1:8545 --broadcast \
///     --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
/// Writes the addresses to out-preview/localstack.json.
contract LocalStack is InkSteps {
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    uint24 constant POOL_FEE = 12_500;
    int24 constant SPACING = 200;
    int24 constant OPEN_TICK = 129_000;

    InkPortraits portraits;
    InkVault vault;
    InkLiquidity liq;
    InkRenderer renderer;
    InkHook hook;
    ForkInk ink;
    PoolKey key;
    address owner;

    function run() external {
        require(block.chainid == 31337, "LocalStack only runs on a local anvil chain (chain id 31337)");
        vm.startBroadcast();
        (, owner,) = vm.readCallers();
        portraits = new InkPortraits(owner);
        vault = new InkVault(portraits, IERC721(SEATS), owner);
        liq = new InkLiquidity(MANAGER, IPositionManager(POSM), owner, owner);
        renderer = new InkRenderer(portraits, owner);
        stepConfigureNft(portraits, vault, renderer);
        hook = _deployHook(portraits, vault, owner);
        _launchPool();
        bytes32 root = vm.parseJsonBytes32(vm.readFile("test/fixtures/snapshot-sample.json"), ".root");
        stepOpenClaims(vault, liq, IERC20(address(ink)), key, root, uint64(block.timestamp + 30));
        vm.stopBroadcast();
        _write();
    }

    function _launchPool() internal {
        ink = new ForkInk(owner);
        bool inkIs0 = address(ink) < IMD;
        ink.transfer(address(vault), 800_000_000e18);
        key = PoolKey({
            currency0: Currency.wrap(inkIs0 ? address(ink) : IMD),
            currency1: Currency.wrap(inkIs0 ? IMD : address(ink)),
            fee: POOL_FEE,
            tickSpacing: SPACING,
            hooks: IHooks(address(hook))
        });
        MANAGER.initialize(key, TickMath.getSqrtPriceAtTick(inkIs0 ? -OPEN_TICK : OPEN_TICK));
        _seed(key, inkIs0, owner, ink);
    }

    function _write() internal {
        string memory o = "stack";
        vm.serializeAddress(o, "portraits", address(portraits));
        vm.serializeAddress(o, "vault", address(vault));
        vm.serializeAddress(o, "hook", address(hook));
        vm.serializeAddress(o, "liquidity", address(liq));
        vm.serializeAddress(o, "renderer", address(renderer));
        vm.serializeAddress(o, "seats", SEATS);
        vm.serializeUint(o, "fee", POOL_FEE);
        vm.serializeUint(o, "tickSpacing", uint256(int256(SPACING)));
        vm.serializeAddress(o, "owner", owner);
        string memory out = vm.serializeAddress(o, "ink", address(ink));
        vm.writeJson(out, "out-preview/localstack.json");
        console2.log("Local stack ready; addresses in out-preview/localstack.json");
    }

    function _deployHook(InkPortraits portraits, InkVault vault, address treasury)
        internal
        returns (InkHook)
    {
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        bytes memory init = abi.encodePacked(
            vm.getCode("InkHook.sol:InkHook"),
            abi.encode(
                MANAGER,
                IAgentPortraits(address(portraits)),
                IInkVault(address(vault)),
                Currency.wrap(IMD),
                treasury,
                uint16(25),
                owner // the broadcaster initializes the pool here, standing in for the launch factory
            )
        );
        bytes32 initHash = keccak256(init);
        bytes32 salt;
        address hookAddr;
        for (uint256 i;; i++) {
            salt = bytes32(i);
            hookAddr = vm.computeCreate2Address(salt, initHash, CREATE2_DEPLOYER);
            if (uint160(hookAddr) & Hooks.ALL_HOOK_MASK == flags && hookAddr.code.length == 0) break;
        }
        (bool ok,) = CREATE2_DEPLOYER.call(abi.encodePacked(salt, init));
        require(ok, "hook deploy");
        return InkHook(hookAddr);
    }

    function _seed(PoolKey memory key, bool inkIs0, address to, ForkInk ink) internal {
        int24 openTick = inkIs0 ? -OPEN_TICK : OPEN_TICK;
        (int24 lower, int24 upper) = inkIs0 ? (openTick, openTick + 46_000) : (openTick - 46_000, openTick);
        uint256 amount = 100_000_000e18;
        uint128 liqAmt = inkIs0
            ? LiquidityAmounts.getLiquidityForAmount0(
                TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), amount
            )
            : LiquidityAmounts.getLiquidityForAmount1(
                TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), amount
            );
        ink.approve(PERMIT2, type(uint256).max);
        IAllowanceTransfer(PERMIT2).approve(address(ink), POSM, type(uint160).max, type(uint48).max);
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            key, lower, upper, uint256(liqAmt), inkIs0 ? amount : 0, inkIs0 ? 0 : amount, to, bytes("")
        );
        params[1] = abi.encode(key.currency0, key.currency1);
        IPositionManager(POSM)
            .modifyLiquidities(
                abi.encode(
                    abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR)), params
                ),
                block.timestamp + 600
            );
    }
}
