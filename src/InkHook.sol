// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";

interface IAgentPortraits {
    function isAgentHolder(address holder) external view returns (bool);
}

interface IInkVault {
    function released() external view returns (bool);
    function liquidity() external view returns (address);
}

/// @title Ink hook for the INK/IMD Uniswap v4 pool
/// @notice Launched through the IMD swarm, which creates INK and seeds this pool single-sided. The pool's
/// own 1.25% trading fee is set by IMD's launch policy. This hook adds:
/// - A lock: no swaps at all until the vault has released the unclaimed seats' INK into the pool. There is
///   no time-based fallback: anyone can call release() once the 24-hour claim window ends (a keeper does it
///   right away), and no trade can happen before it, so nothing can move the price the released INK is
///   listed at.
/// - An extra fee of `feeBps` on every swap, waived for holders of an agent portrait. It's taken from
///   the side the swapper doesn't fix (the output of an exact-input swap, the input of an exact-output
///   swap), held as a Uniswap claim, and paid out by collectFees(): IMD to the treasury, INK to the vault's
///   liquidity contract, which adds it back to the pool as permanent liquidity.
/// Nothing can be changed after deployment; the hook has no owner.
/// Only the launch factory, which deploys this hook and initializes its pool, can bind the hook to a pool:
/// beforeInitialize refuses every other sender, so nobody can front-run the launch and bind the one-pool hook
/// to a pool with the wrong token, fee tier, tick spacing or opening price (audit finding dcacbade3b53).
/// @dev The swapper is tx.origin, because routers sit between the wallet and the pool. Smart-contract
/// wallets therefore don't get the discount, and conversely every swap in a transaction an agent-holder
/// EOA sends for others (a bundler, relayer or searcher) is exempt: the exemption follows the transaction
/// sender, not the party whose order is filled. The discount needs the agent portrait to have been
/// held since an earlier block, so it can't be borrowed for a single swap.
contract InkHook is IHooks, IUnlockCallback {
    using CurrencyLibrary for Currency;

    uint16 public constant MAX_FEE_BPS = 100;

    IPoolManager public immutable poolManager;
    IAgentPortraits public immutable portraits;
    IInkVault public immutable vault;
    Currency public immutable imd;
    address public immutable treasury;
    uint16 public immutable feeBps;
    /// @notice The launch factory: the only sender beforeInitialize accepts.
    address public immutable factory;

    /// @notice INK, learned when the pool opens.
    Currency public ink;
    uint64 public poolOpenedAt;
    /// @notice When the first swap after release went through.
    uint64 public tradingOpenedAt;
    bool public poolCreated;

    event PoolOpened(Currency ink);
    event TradingOpened(uint64 at);
    event FeeTaken(address indexed swapper, Currency indexed currency, uint256 amount);
    event FeesPaid(Currency indexed currency, address indexed to, uint256 amount);

    error NotPoolManager();
    error NotFactory();
    error HookNotImplemented();
    error PoolAlreadyCreated();
    error WrongPool();
    error FeeTooHigh();
    error ZeroAddress();
    error TradingNotOpen();

    constructor(
        IPoolManager poolManager_,
        IAgentPortraits portraits_,
        IInkVault vault_,
        Currency imd_,
        address treasury_,
        uint16 feeBps_,
        address factory_
    ) {
        if (
            treasury_ == address(0) || address(portraits_) == address(0) || address(vault_) == address(0)
                || factory_ == address(0)
        ) {
            revert ZeroAddress();
        }
        if (feeBps_ > MAX_FEE_BPS) revert FeeTooHigh();
        poolManager = poolManager_;
        portraits = portraits_;
        vault = vault_;
        imd = imd_;
        treasury = treasury_;
        feeBps = feeBps_;
        factory = factory_;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    // ---------------------------------------------------------------- hooks

    /// @dev One pool only: INK paired with IMD, with this hook, created by the launch factory. The launch
    /// window starts here.
    function beforeInitialize(address sender, PoolKey calldata key, uint160)
        external
        onlyPoolManager
        returns (bytes4)
    {
        if (sender != factory) revert NotFactory();
        if (poolCreated) revert PoolAlreadyCreated();
        if (address(key.hooks) != address(this)) revert WrongPool();
        if (key.currency0 == imd) ink = key.currency1;
        else if (key.currency1 == imd) ink = key.currency0;
        else revert WrongPool();
        poolCreated = true;
        poolOpenedAt = uint64(block.timestamp);
        emit PoolOpened(ink);
        return IHooks.beforeInitialize.selector;
    }

    /// @notice Whether swaps are allowed: only once the vault has released the unclaimed INK into the pool.
    function tradingOpen() public view returns (bool) {
        return tradingOpenedAt != 0 || vault.released();
    }

    function beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (tradingOpenedAt == 0) {
            if (!vault.released()) revert TradingNotOpen();
            tradingOpenedAt = uint64(block.timestamp);
            emit TradingOpened(tradingOpenedAt);
        }
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, int128) {
        address swapper = tx.origin;

        if (feeBps == 0 || portraits.isAgentHolder(swapper)) return (IHooks.afterSwap.selector, 0);

        bool specifiedIs0 = (params.amountSpecified < 0) == params.zeroForOne;
        (Currency feeCurrency, int128 amount) =
            specifiedIs0 ? (key.currency1, delta.amount1()) : (key.currency0, delta.amount0());
        if (amount < 0) amount = -amount;
        uint256 fee = (uint256(uint128(amount)) * feeBps) / 10_000;
        if (fee == 0) return (IHooks.afterSwap.selector, 0);

        // The input side may not be paid in yet, so book the fee as a claim and pay it out later.
        poolManager.mint(address(this), feeCurrency.toId(), fee);
        emit FeeTaken(swapper, feeCurrency, fee);
        return (IHooks.afterSwap.selector, int128(int256(fee)));
    }

    // ---------------------------------------------------------------- paying out fees

    /// @notice Pays out collected hook fees: IMD to the treasury, INK to the liquidity contract (set once in the
    /// vault's setup, which trading can't open without), to be added back to the pool. Anyone can call.
    function collectFees() external returns (uint256 imdPaid, uint256 inkToLiquidity) {
        (imdPaid, inkToLiquidity) = abi.decode(poolManager.unlock(""), (uint256, uint256));
    }

    function unlockCallback(bytes calldata) external onlyPoolManager returns (bytes memory) {
        return abi.encode(_payOut(imd, treasury), _payOut(ink, vault.liquidity()));
    }

    function _payOut(Currency currency, address to) internal returns (uint256 amount) {
        amount = poolManager.balanceOf(address(this), currency.toId());
        if (amount == 0) return 0;
        poolManager.burn(address(this), currency.toId(), amount);
        poolManager.take(currency, to, amount);
        emit FeesPaid(currency, to, amount);
    }

    // ---------------------------------------------------------------- unused hooks

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }
}
