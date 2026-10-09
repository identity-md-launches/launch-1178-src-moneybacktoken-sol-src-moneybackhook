// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// =================================================================================================
// Minimal Uniswap v4 core surface.
//
// These declarations are ABI-identical to Uniswap v4-core (types, struct layouts, function
// selectors and hook flag bits) so the hook builds with no vendored dependency and talks to the
// real PoolManager unchanged. Only what this hook uses is declared.
// =================================================================================================

/// @dev v4-core `Currency`: an ERC-20 address, or address(0) for native ETH.
type Currency is address;
/// @dev v4-core `PoolId`: keccak256(abi.encode(PoolKey)).
type PoolId is bytes32;
/// @dev v4-core `BalanceDelta`: amount0 in the upper 128 bits, amount1 in the lower 128 bits.
type BalanceDelta is int256;
/// @dev v4-core `BeforeSwapDelta`: deltaSpecified in the upper 128 bits, deltaUnspecified in the lower.
type BeforeSwapDelta is int256;

/// @dev v4-core `PoolKey`.
struct PoolKey {
    Currency currency0;
    Currency currency1;
    uint24 fee;
    int24 tickSpacing;
    IHooks hooks;
}

/// @dev v4-core `SwapParams`.
struct SwapParams {
    bool zeroForOne;
    int256 amountSpecified;
    uint160 sqrtPriceLimitX96;
}

/// @dev The three v4-core `IHooks` callbacks this hook implements (selectors match v4-core).
interface IHooks {
    function beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96) external returns (bytes4);

    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        external
        returns (bytes4, BeforeSwapDelta, uint24);

    function afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external returns (bytes4, int128);
}

/// @dev The v4-core `IPoolManager` functions this hook calls (selectors match v4-core).
interface IPoolManager {
    function unlock(bytes calldata data) external returns (bytes memory);
    function mint(address to, uint256 id, uint256 amount) external;
    function burn(address from, uint256 id, uint256 amount) external;
    function take(Currency currency, address to, uint256 amount) external;
    function balanceOf(address owner, uint256 id) external view returns (uint256);
}

/// @dev v4-core `IUnlockCallback`.
interface IUnlockCallback {
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}

/// @dev Hook permission flags and validation, mirroring v4-core `Hooks`.
library Hooks {
    uint160 internal constant ALL_HOOK_MASK = uint160((1 << 14) - 1);
    uint160 internal constant BEFORE_INITIALIZE_FLAG = 1 << 13;
    uint160 internal constant AFTER_INITIALIZE_FLAG = 1 << 12;
    uint160 internal constant BEFORE_ADD_LIQUIDITY_FLAG = 1 << 11;
    uint160 internal constant AFTER_ADD_LIQUIDITY_FLAG = 1 << 10;
    uint160 internal constant BEFORE_REMOVE_LIQUIDITY_FLAG = 1 << 9;
    uint160 internal constant AFTER_REMOVE_LIQUIDITY_FLAG = 1 << 8;
    uint160 internal constant BEFORE_SWAP_FLAG = 1 << 7;
    uint160 internal constant AFTER_SWAP_FLAG = 1 << 6;
    uint160 internal constant BEFORE_DONATE_FLAG = 1 << 5;
    uint160 internal constant AFTER_DONATE_FLAG = 1 << 4;
    uint160 internal constant BEFORE_SWAP_RETURNS_DELTA_FLAG = 1 << 3;
    uint160 internal constant AFTER_SWAP_RETURNS_DELTA_FLAG = 1 << 2;
    uint160 internal constant AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG = 1 << 1;
    uint160 internal constant AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG = 1 << 0;

    struct Permissions {
        bool beforeInitialize;
        bool afterInitialize;
        bool beforeAddLiquidity;
        bool afterAddLiquidity;
        bool beforeRemoveLiquidity;
        bool afterRemoveLiquidity;
        bool beforeSwap;
        bool afterSwap;
        bool beforeDonate;
        bool afterDonate;
        bool beforeSwapReturnDelta;
        bool afterSwapReturnDelta;
        bool afterAddLiquidityReturnDelta;
        bool afterRemoveLiquidityReturnDelta;
    }

    /// @notice Thrown when the hook's address bits do not encode exactly the declared permissions.
    error HookAddressNotValid(address hooks);

    /// @notice The flag bits a hook address must carry to encode `permissions` (and nothing else).
    function flags(Permissions memory permissions) internal pure returns (uint160 f) {
        if (permissions.beforeInitialize) f |= BEFORE_INITIALIZE_FLAG;
        if (permissions.afterInitialize) f |= AFTER_INITIALIZE_FLAG;
        if (permissions.beforeAddLiquidity) f |= BEFORE_ADD_LIQUIDITY_FLAG;
        if (permissions.afterAddLiquidity) f |= AFTER_ADD_LIQUIDITY_FLAG;
        if (permissions.beforeRemoveLiquidity) f |= BEFORE_REMOVE_LIQUIDITY_FLAG;
        if (permissions.afterRemoveLiquidity) f |= AFTER_REMOVE_LIQUIDITY_FLAG;
        if (permissions.beforeSwap) f |= BEFORE_SWAP_FLAG;
        if (permissions.afterSwap) f |= AFTER_SWAP_FLAG;
        if (permissions.beforeDonate) f |= BEFORE_DONATE_FLAG;
        if (permissions.afterDonate) f |= AFTER_DONATE_FLAG;
        if (permissions.beforeSwapReturnDelta) f |= BEFORE_SWAP_RETURNS_DELTA_FLAG;
        if (permissions.afterSwapReturnDelta) f |= AFTER_SWAP_RETURNS_DELTA_FLAG;
        if (permissions.afterAddLiquidityReturnDelta) f |= AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG;
        if (permissions.afterRemoveLiquidityReturnDelta) f |= AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG;
    }

    /// @notice Reverts unless the low 14 bits of `self` equal exactly the flags for `permissions`,
    ///         the same check v4-core performs.
    function validateHookPermissions(address self, Permissions memory permissions) internal pure {
        if ((uint160(self) & ALL_HOOK_MASK) != flags(permissions)) revert HookAddressNotValid(self);
    }
}

// =================================================================================================
// MoneyBackHook
// =================================================================================================

/// @title IMD Money Back hook
/// @notice Uniswap v4 hook for the single MONEYBACK / IMD pool (static LP fee 12500 = 1.25%,
///         tickSpacing 60). On every swap it takes a hook fee in IMD, on top of the pool's LP fee,
///         and accrues it as PoolManager ERC-6909 claims owned by this contract. Anyone can call
///         `sweep()` to move everything accrued to the immutable `payout` address (RoundPayout).
///
/// @dev FEE MATHS (all integer, all rounded down, all in IMD, never in MONEYBACK)
///
///      baseFee      = floor(imdLeg * 425 / 10_000)                          every swap, both directions
///      surcharge    = floor(imdLeg * currentSurchargeBps() / 10_000)        sells only (MONEYBACK -> IMD)
///      hookFee      = baseFee + surcharge
///      surchargeBps = 2000 * max(0, 1800 - (block.timestamp - initializedAt)) / 1800
///
///      Because the two parts are floored separately, hookFee can be 1 wei below
///      floor(imdLeg * (425 + surchargeBps) / 10_000). The LP fee is never overridden: the pool
///      charges its own 1.25% on the input side inside the swap as usual.
///
///      THE FOUR SWAP CASES. "imdLeg" is the IMD amount the hook fee is applied to:
///
///      1. exact-input BUY  (IMD in, amountSpecified < 0, IMD is the specified currency):
///         handled in beforeSwap via beforeSwapReturnDelta. imdLeg = the IMD the swapper pays
///         (|amountSpecified|). The hook keeps hookFee of it; the pool swaps the remainder.
///         The swapper pays exactly |amountSpecified| IMD.
///      2. exact-output BUY (MONEYBACK out, amountSpecified > 0, IMD is the unspecified currency):
///         handled in afterSwap via afterSwapReturnDelta. imdLeg = the IMD the pool actually
///         moved (|delta| on the IMD side). The swapper pays imdLeg + hookFee IMD.
///      3. exact-input SELL (MONEYBACK in, amountSpecified < 0, IMD is the unspecified currency):
///         handled in afterSwap via afterSwapReturnDelta. imdLeg = the IMD the pool actually
///         paid out. The swapper receives imdLeg - hookFee IMD (surcharge applies).
///      4. exact-output SELL (IMD out, amountSpecified > 0, IMD is the specified currency):
///         handled in beforeSwap via beforeSwapReturnDelta, because the delta a hook returns from
///         afterSwap can only touch the unspecified currency (MONEYBACK) and the fee must be
///         taken in IMD. imdLeg = the IMD the swapper asked for (amountSpecified). The pool is
///         asked for imdLeg + hookFee, the hook keeps hookFee, the swapper receives exactly
///         amountSpecified IMD (surcharge applies).
///
///      In short: IMD specified (cases 1 and 4) -> beforeSwapReturnDelta on the specified
///      currency; IMD unspecified (cases 2 and 3) -> afterSwapReturnDelta on the unspecified
///      currency. Each swap is charged in exactly one of the two callbacks, never both.
///
///      Invariants:
///      - The hook never returns a non-zero delta on the MONEYBACK side and never mints
///        MONEYBACK claims. The only ERC-6909 id it ever mints or burns is IMD's.
///      - pending() == sum(FeeAccrued.baseFeeImd + FeeAccrued.surchargeImd) - sum(Swept.imdAmount),
///        as long as nobody transfers ERC-6909 IMD claims to the hook from outside.
///      - sweep() can only ever send IMD to `payout`; no function moves funds anywhere else.
///      - Inside a callback the hook calls nothing but the PoolManager (mint). It makes no
///        token transfers.
///      - No owner, no setter, no pause, no upgrade, no selfdestruct.
contract MoneyBackHook is IHooks, IUnlockCallback {
    using Hooks for address;

    // ---------------------------------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------------------------------

    /// @notice IMD on Robinhood Chain (chainId 4663), the paired currency. 18 decimals.
    address public constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;

    /// @notice Hook base fee: 425 bps (4.25%) of the IMD leg of every swap, in basis points of 10_000.
    uint256 public constant BASE_FEE_BPS = 425;
    /// @notice Basis-point denominator.
    uint256 public constant BPS = 10_000;
    /// @notice Sell surcharge at pool initialization: 2000 bps (20%) of the IMD leg.
    uint256 public constant SURCHARGE_START_BPS = 2000;
    /// @notice The surcharge decays linearly to 0 over this many seconds after initialization.
    uint256 public constant SURCHARGE_DURATION = 1800;

    /// @notice The only LP fee the bound pool may have (12500 = 1.25%).
    uint24 public constant POOL_FEE = 12_500;
    /// @notice The only tick spacing the bound pool may have.
    int24 public constant POOL_TICK_SPACING = 60;

    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    // ---------------------------------------------------------------------------------------------
    // Immutables
    // ---------------------------------------------------------------------------------------------

    /// @notice The Uniswap v4 PoolManager.
    IPoolManager public immutable poolManager;
    /// @notice The MONEYBACK token.
    address public immutable launchToken;
    /// @notice Where sweep() sends accrued IMD (the RoundPayout contract). Fixed forever.
    address public immutable payout;

    /// @dev ERC-6909 claim id of IMD inside the PoolManager (uint256(uint160(IMD))).
    uint256 private immutable _imdId;

    // ---------------------------------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------------------------------

    PoolKey private _poolKey;
    /// @notice Id of the bound pool (zero until beforeInitialize has run).
    PoolId public poolId;
    /// @notice block.timestamp at which the pool was initialized; zero until then.
    uint256 public initializedAt;
    /// @dev True when IMD is currency0 of the bound pool (false when it is currency1).
    bool private _imdIsCurrency0;
    /// @dev Reentrancy lock for sweep(); also gates unlockCallback to a sweep in progress.
    uint256 private _status = _NOT_ENTERED;

    // ---------------------------------------------------------------------------------------------
    // Events and errors
    // ---------------------------------------------------------------------------------------------

    /// @notice A hook fee was taken on a swap. imdLeg is the IMD amount the fee was computed on.
    event FeeAccrued(bool indexed isSell, uint256 baseFeeImd, uint256 surchargeImd, uint256 imdLeg);
    /// @notice Accrued IMD was taken from the PoolManager to `to` (always `payout`).
    event Swept(uint256 imdAmount, address indexed to);
    /// @notice The single pool this hook serves was initialized.
    event PoolBound(PoolId indexed id, uint256 initializedAt);

    error NotPoolManager();
    error ZeroAddress();
    error AlreadyBound();
    error NotBoundPool();
    error WrongPairedCurrency();
    error WrongLaunchToken();
    error WrongPoolFee();
    error WrongTickSpacing();
    error WrongHook();
    error Reentrancy();
    error AmountOverflow();

    // ---------------------------------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------------------------------

    /// @param manager      The Uniswap v4 PoolManager ($poolManager).
    /// @param launchToken_ The MONEYBACK token ($token).
    /// @param payout_      The RoundPayout contract that receives swept IMD ($owner).
    /// @dev Makes no external calls and accepts no ETH. Reverts unless this contract's address
    ///      carries exactly the permission flag bits (CREATE2 salt mining is the deployer's job).
    constructor(IPoolManager manager, address launchToken_, address payout_) {
        if (address(manager) == address(0) || launchToken_ == address(0) || payout_ == address(0)) {
            revert ZeroAddress();
        }
        if (launchToken_ == IMD) revert WrongLaunchToken();
        address(this).validateHookPermissions(getHookPermissions());
        poolManager = manager;
        launchToken = launchToken_;
        payout = payout_;
        _imdId = uint256(uint160(IMD));
    }

    // ---------------------------------------------------------------------------------------------
    // Permissions
    // ---------------------------------------------------------------------------------------------

    /// @notice Exactly: beforeInitialize, beforeSwap, afterSwap, beforeSwapReturnDelta, afterSwapReturnDelta.
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
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @notice The flag bits the hook address must end with: 0x20CC
    ///         (BEFORE_INITIALIZE | BEFORE_SWAP | AFTER_SWAP | BEFORE_SWAP_RETURNS_DELTA | AFTER_SWAP_RETURNS_DELTA).
    function requiredFlags() external pure returns (uint160) {
        return Hooks.flags(getHookPermissions());
    }

    // ---------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------

    /// @notice The bound pool's key (all-zero until the pool is initialized).
    function poolKey() external view returns (PoolKey memory) {
        return _poolKey;
    }

    /// @notice IMD accrued and not yet swept: the hook's ERC-6909 IMD claim balance in the PoolManager.
    function pending() public view returns (uint256) {
        return poolManager.balanceOf(address(this), _imdId);
    }

    /// @notice 425.
    function baseFeeBps() external pure returns (uint256) {
        return BASE_FEE_BPS;
    }

    /// @notice Sell surcharge right now, in bps: 2000 * max(0, 1800 - elapsed) / 1800, integer math.
    ///         2000 at initialization, 1000 at +900 s, 0 at +1800 s and forever after.
    ///         0 before the pool is initialized (there is nothing to surcharge yet).
    function currentSurchargeBps() public view returns (uint256) {
        uint256 start = initializedAt;
        if (start == 0) return 0;
        uint256 elapsed = block.timestamp - start;
        if (elapsed >= SURCHARGE_DURATION) return 0;
        return SURCHARGE_START_BPS * (SURCHARGE_DURATION - elapsed) / SURCHARGE_DURATION;
    }

    // ---------------------------------------------------------------------------------------------
    // Hook callbacks (PoolManager only)
    // ---------------------------------------------------------------------------------------------

    /// @notice Binds the one and only pool: {MONEYBACK, IMD} in address order, fee 12500,
    ///         tickSpacing 60, this hook. Any other key reverts. Records `initializedAt`.
    function beforeInitialize(address, PoolKey calldata key, uint160) external returns (bytes4) {
        _onlyPoolManager();
        if (initializedAt != 0) revert AlreadyBound();
        if (address(key.hooks) != address(this)) revert WrongHook();
        if (key.fee != POOL_FEE) revert WrongPoolFee();
        if (key.tickSpacing != POOL_TICK_SPACING) revert WrongTickSpacing();

        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        bool imdIsCurrency0;
        if (c0 == IMD) {
            imdIsCurrency0 = true;
            if (c1 != launchToken) revert WrongLaunchToken();
        } else if (c1 == IMD) {
            if (c0 != launchToken) revert WrongLaunchToken();
        } else {
            revert WrongPairedCurrency();
        }

        PoolId id = PoolId.wrap(keccak256(abi.encode(key)));
        _poolKey = key;
        poolId = id;
        _imdIsCurrency0 = imdIsCurrency0;
        initializedAt = block.timestamp;
        emit PoolBound(id, block.timestamp);
        return IHooks.beforeInitialize.selector;
    }

    /// @notice Cases 1 and 4 (IMD is the specified currency): takes the hook fee out of the
    ///         specified amount via a positive deltaSpecified. Cases 2 and 3 return a zero delta
    ///         and are charged in afterSwap. Never overrides the LP fee (returns 0).
    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _onlyPoolManager();
        _onlyBoundPool(key);

        bool isSell = _isSell(params.zeroForOne);
        bool exactInput = params.amountSpecified < 0;
        // IMD is specified iff (exact input and IMD is the input) or (exact output and IMD is the output).
        if (exactInput == isSell) return (IHooks.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);

        uint256 imdLeg = exactInput ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        uint256 hookFee = _accrue(isSell, imdLeg);
        return (IHooks.beforeSwap.selector, _toBeforeSwapDelta(_toInt128(hookFee), 0), 0);
    }

    /// @notice Cases 2 and 3 (IMD is the unspecified currency): takes the hook fee on the IMD the
    ///         pool actually moved, via a positive unspecified delta. Cases 1 and 4 return 0 here
    ///         because they were charged in beforeSwap.
    function afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        returns (bytes4, int128)
    {
        _onlyPoolManager();
        _onlyBoundPool(key);

        bool isSell = _isSell(params.zeroForOne);
        bool exactInput = params.amountSpecified < 0;
        if (exactInput != isSell) return (IHooks.afterSwap.selector, 0);

        int256 imdDelta = _imdIsCurrency0 ? _amount0(delta) : _amount1(delta);
        uint256 imdLeg = imdDelta < 0 ? uint256(-imdDelta) : uint256(imdDelta);
        uint256 hookFee = _accrue(isSell, imdLeg);
        return (IHooks.afterSwap.selector, _toInt128(hookFee));
    }

    // ---------------------------------------------------------------------------------------------
    // Sweep (permissionless)
    // ---------------------------------------------------------------------------------------------

    /// @notice Takes ALL of the hook's IMD claims out of the PoolManager and sends them to `payout`.
    ///         Anyone may call. Succeeds (and emits Swept with 0) when nothing is pending.
    function sweep() external {
        if (_status == _ENTERED) revert Reentrancy();
        _status = _ENTERED;
        poolManager.unlock("");
        _status = _NOT_ENTERED;
    }

    /// @notice PoolManager callback for sweep(): burn every IMD claim, take the IMD to `payout`.
    function unlockCallback(bytes calldata) external returns (bytes memory) {
        _onlyPoolManager();
        if (_status != _ENTERED) revert Reentrancy();

        uint256 amount = poolManager.balanceOf(address(this), _imdId);
        if (amount != 0) {
            poolManager.burn(address(this), _imdId, amount);
            poolManager.take(Currency.wrap(IMD), payout, amount);
        }
        emit Swept(amount, payout);
        return "";
    }

    // ---------------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------------

    function _onlyPoolManager() private view {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
    }

    function _onlyBoundPool(PoolKey calldata key) private view {
        if (initializedAt == 0 || keccak256(abi.encode(key)) != PoolId.unwrap(poolId)) revert NotBoundPool();
    }

    /// @dev A sell moves MONEYBACK into the pool and IMD out: zeroForOne when MONEYBACK is
    ///      currency0, oneForZero when IMD is currency0.
    function _isSell(bool zeroForOne) private view returns (bool) {
        return zeroForOne != _imdIsCurrency0;
    }

    /// @dev Computes base fee and surcharge on `imdLeg` (each floored), mints the total as IMD
    ///      claims to this hook, emits FeeAccrued, returns the total.
    function _accrue(bool isSell, uint256 imdLeg) private returns (uint256 hookFee) {
        uint256 baseFee = imdLeg * BASE_FEE_BPS / BPS;
        uint256 surcharge = isSell ? imdLeg * currentSurchargeBps() / BPS : 0;
        hookFee = baseFee + surcharge;
        if (hookFee != 0) poolManager.mint(address(this), _imdId, hookFee);
        emit FeeAccrued(isSell, baseFee, surcharge, imdLeg);
    }

    function _toInt128(uint256 x) private pure returns (int128) {
        if (x > uint256(uint128(type(int128).max))) revert AmountOverflow();
        return int128(uint128(x));
    }

    function _toBeforeSwapDelta(int128 deltaSpecified, int128 deltaUnspecified)
        private
        pure
        returns (BeforeSwapDelta d)
    {
        assembly ("memory-safe") {
            d := or(shl(128, deltaSpecified), and(sub(shl(128, 1), 1), deltaUnspecified))
        }
    }

    function _amount0(BalanceDelta d) private pure returns (int256 a) {
        assembly ("memory-safe") {
            a := sar(128, d)
        }
    }

    function _amount1(BalanceDelta d) private pure returns (int256 a) {
        assembly ("memory-safe") {
            a := signextend(15, d)
        }
    }
}
