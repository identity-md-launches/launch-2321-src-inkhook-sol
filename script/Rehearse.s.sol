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

/// @notice Dress rehearsal of the whole launch on an in-memory mainnet fork: both IMD launches (simulated),
/// every owner step from InkSteps, real seat owners claiming with the rehearsal snapshot, release into the
/// real PositionManager, then a tokenURI read. Logs the gas of each owner step and what it would cost.
/// It never calls vm.broadcast, so nothing can be sent even with --broadcast.
///
///   forge script script/Rehearse.s.sol --fork-url https://ethereum-rpc.publicnode.com
///   GAS_GWEI=2 ETH_USD=4000 forge script script/Rehearse.s.sol --fork-url …
contract Rehearse is InkSteps {
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    uint24 constant POOL_FEE = 12_500;
    int24 constant SPACING = 200;
    int24 constant OPEN_TICK = 129_000;

    address owner = makeAddr("rehearsal-owner");
    address treasury;
    uint256 gasGwei;
    uint256 ethUsd;
    uint256 ownerGas;

    struct Launch {
        InkPortraits portraits;
        InkVault vault;
        InkLiquidity liq;
        InkRenderer renderer;
        InkHook hook;
        IERC20 ink;
        PoolKey key;
    }

    function _step(string memory name, uint256 gasUsed, uint256 txs) internal {
        // gasleft() deltas leave out each transaction's 21,000 base cost; add it back.
        uint256 total = gasUsed + txs * 21_000;
        ownerGas += total;
        uint256 weiCost = total * gasGwei * 1e9;
        console2.log(string.concat(name, " | gas ", vm.toString(total), " | txs ", vm.toString(txs)));
        console2.log(string.concat("    ~ ", _eth(weiCost), " ETH ~ $", vm.toString(weiCost * ethUsd / 1e18)));
    }

    function _eth(uint256 w) internal pure returns (string memory) {
        uint256 milli = w / 1e15;
        return string.concat(vm.toString(milli / 1000), ".", _pad3(milli % 1000));
    }

    function _pad3(uint256 x) internal pure returns (string memory) {
        return x < 10
            ? string.concat("00", vm.toString(x))
            : x < 100 ? string.concat("0", vm.toString(x)) : vm.toString(x);
    }

    function run() external {
        gasGwei = vm.envOr("GAS_GWEI", uint256(2));
        ethUsd = vm.envOr("ETH_USD", uint256(4000));
        treasury = TREASURY;
        console2.log("Rehearsal on mainnet fork at block", block.number);
        console2.log("Gas price (gwei) / ETH (USD):", gasGwei, ethUsd);
        Launch memory l;

        // 1. Contracts launch (the swarm deploys; owner roles go to the owner).
        uint256 g = gasleft();
        vm.startPrank(makeAddr("swarm-deployer"));
        l.portraits = new InkPortraits(owner);
        l.vault = new InkVault(l.portraits, IERC721(SEATS), owner);
        l.liq = new InkLiquidity(MANAGER, IPositionManager(POSM), owner, treasury);
        l.renderer = new InkRenderer(l.portraits, owner);
        vm.stopPrank();
        _step("1. contracts launch (paid by the swarm job, shown for reference)", g - gasleft(), 4);
        ownerGas = 0;
        checkContractsLaunch(l.portraits, l.vault, l.liq, l.renderer, owner);

        // 2. Owner wires the NFT and uploads the art.
        uint256 chunks = (artScript().length + l.renderer.MAX_CHUNK() - 1) / l.renderer.MAX_CHUNK();
        g = gasleft();
        vm.startPrank(owner);
        stepConfigureNft(l.portraits, l.vault, l.renderer);
        vm.stopPrank();
        _step("2. setVault + setRenderer + art upload", g - gasleft(), 2 + chunks);

        // 3. Hook launch (simulated: IMD mints INK, mines the hook address, seeds 10% single-sided).
        _simulateHookLaunch(l);
        checkHookLaunch(l.hook, l.portraits, l.vault, treasury, l.ink, l.key);
        console2.log("3. hook launch simulated; hook at", address(l.hook));

        // 4. Owner opens claims with the rehearsal snapshot.
        string memory json = vm.readFile("test/fixtures/snapshot-sample.json");
        g = gasleft();
        vm.startPrank(owner);
        stepOpenClaims(
            l.vault, l.liq, l.ink, l.key, vm.parseJsonBytes32(json, ".root"), uint64(block.timestamp)
        );
        vm.stopPrank();
        _step("4. setInk + setPool + setPremium + setup", g - gasleft(), 4);

        // 5. Real seat owners claim.
        uint256 claimGas;
        uint256 n;
        while (n < 5 && vm.keyExistsJson(json, string.concat(".entries[", vm.toString(n), "]"))) {
            (uint256 seat, InkPortraits.AgentStats memory s, bytes32[] memory proof) = _entry(json, n);
            address seatOwner = IERC721(SEATS).ownerOf(seat);
            g = gasleft();
            vm.prank(seatOwner);
            l.vault.claim(seat, s, proof);
            claimGas += g - gasleft();
            n++;
        }
        console2.log("5. claims by real seat owners:", n, "avg gas per claim:", claimGas / n + 21_000);

        // 6. Release after 24 hours (anyone calls it).
        vm.warp(l.vault.claimEnd());
        g = gasleft();
        l.vault.release();
        console2.log("6. release() gas (anyone, once):", g - gasleft() + 21_000);
        require(l.hook.tradingOpen(), "trading open");
        require(l.portraits.agentMinted() + l.vault.swarmSlots() == 2000, "2,000 portraits");
        require(
            IERC20(l.ink).balanceOf(address(l.vault)) == n * PORTRAIT, "vault backs the claimed portraits"
        );

        // 7. Metadata reads like a marketplace would.
        g = gasleft();
        string memory uri = l.portraits.tokenURI(_entrySeat(json, 0));
        console2.log("7. tokenURI bytes / gas:", bytes(uri).length, g - gasleft());

        console2.log("--------");
        console2.log(
            string.concat(
                "Owner total: gas ", vm.toString(ownerGas), " ~ ", _eth(ownerGas * gasGwei * 1e9), " ETH"
            )
        );
        console2.log("Rehearsal passed. Nothing was broadcast.");
    }

    // ---------------------------------------------------------------- simulated IMD hook launch

    function _simulateHookLaunch(Launch memory l) internal {
        address imdLauncher = makeAddr("imd-launcher");
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        bytes memory init = abi.encodePacked(
            vm.getCode("InkHook.sol:InkHook"),
            abi.encode(
                MANAGER,
                IAgentPortraits(address(l.portraits)),
                IInkVault(address(l.vault)),
                Currency.wrap(IMD),
                treasury,
                uint16(25),
                imdLauncher // initializes the pool below, as the launch factory does
            )
        );
        bytes32 initHash = keccak256(init);
        bytes32 salt;
        address hookAddr;
        for (uint256 i;; i++) {
            salt = bytes32(i);
            hookAddr = vm.computeCreate2Address(salt, initHash, CREATE2_DEPLOYER);
            if (uint160(hookAddr) & Hooks.ALL_HOOK_MASK == flags) break;
        }
        vm.prank(imdLauncher);
        (bool ok,) = CREATE2_DEPLOYER.call(abi.encodePacked(salt, init));
        require(ok && hookAddr.code.length > 0, "hook deploy");
        l.hook = InkHook(hookAddr);

        vm.startPrank(imdLauncher);
        ForkInk ink = new ForkInk(imdLauncher);
        l.ink = IERC20(address(ink));
        bool inkIs0 = address(ink) < IMD;
        ink.transfer(makeAddr("swarm-distributor"), 100_000_000e18);
        ink.transfer(address(l.vault), 800_000_000e18);
        l.key = PoolKey({
            currency0: Currency.wrap(inkIs0 ? address(ink) : IMD),
            currency1: Currency.wrap(inkIs0 ? IMD : address(ink)),
            fee: POOL_FEE,
            tickSpacing: SPACING,
            hooks: IHooks(hookAddr)
        });
        MANAGER.initialize(l.key, TickMath.getSqrtPriceAtTick(inkIs0 ? -OPEN_TICK : OPEN_TICK));
        _seed(l.key, inkIs0, imdLauncher, ink);
        vm.stopPrank();
    }

    /// IMD's launch seeds 10% of supply single-sided from the opening price.
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
                block.timestamp
            );
    }

    // ---------------------------------------------------------------- snapshot fixture

    function _entrySeat(string memory json, uint256 i) internal pure returns (uint256) {
        return vm.parseJsonUint(json, string.concat(".entries[", vm.toString(i), "].seat"));
    }

    function _entry(string memory json, uint256 i)
        internal
        pure
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
}
