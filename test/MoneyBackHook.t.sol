// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {
    MoneyBackHook,
    Hooks,
    IHooks,
    IPoolManager,
    IUnlockCallback,
    PoolKey,
    PoolId,
    SwapParams,
    Currency,
    BalanceDelta,
    BeforeSwapDelta
} from "src/MoneyBackHook.sol";
import {MoneyBackToken} from "src/MoneyBackToken.sol";

// No forge-std is vendored and the test paths may not add a lib/, so this suite talks to the
// Foundry cheatcode address through the minimal interface below. A failing assertion reverts.
interface VmHook {
    function prank(address) external;
    function startPrank(address) external;
    function stopPrank() external;
    function warp(uint256) external;
    function etch(address, bytes calldata) external;
    function expectRevert(bytes calldata) external;
    function expectRevert() external;
    function expectEmit(bool, bool, bool, bool) external;
    function assume(bool) external pure;
}

address constant IMD_ADDR = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
uint160 constant EXPECTED_FLAGS = 0x20CC;

// =================================================================================================
// IMD stand-in (etched at the hardcoded IMD address; no immutables so the runtime code is etchable)
// =================================================================================================

contract MockIMD {
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;
    // Optional reentrancy probe: when `attacker` is set, every transfer to `watch` calls
    // attacker.onImdTransfer() and records whether that nested call succeeded.
    address public attacker;
    address public watch;
    bool public nestedCallReverted;
    bytes public nestedReason;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function armReentry(address attacker_, address watch_) external {
        attacker = attacker_;
        watch = watch_;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "IMD balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        if (attacker != address(0) && to == watch) {
            (bool ok, bytes memory ret) = attacker.call(abi.encodeWithSignature("onImdTransfer()"));
            nestedCallReverted = !ok;
            nestedReason = ret;
        }
        return true;
    }
}

/// @dev Reenters hook.sweep() from inside the IMD transfer that sweep() itself triggers.
contract SweepReenterer {
    MoneyBackHook public hook;

    constructor(MoneyBackHook _hook) {
        hook = _hook;
    }

    function onImdTransfer() external {
        hook.sweep();
    }
}

/// @dev Unlocks the PoolManager itself and tries to run sweep() inside its own callback.
contract NestedUnlocker is IUnlockCallback {
    MockPoolManager public pm;
    MoneyBackHook public hook;
    bytes public innerRevert;

    constructor(MockPoolManager _pm, MoneyBackHook _hook) {
        pm = _pm;
        hook = _hook;
    }

    function run() external {
        pm.unlock("");
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        (bool ok, bytes memory ret) = address(hook).call(abi.encodeCall(MoneyBackHook.sweep, ()));
        require(!ok, "nested sweep must not succeed");
        innerRevert = ret;
        return "";
    }
}

// =================================================================================================
// PoolManager stand-in
// =================================================================================================

/// @dev Reproduces the parts of Uniswap v4 PoolManager the hook depends on:
///      - unlock / unlockCallback with AlreadyUnlocked, and a settlement check on the caller;
///      - ERC-6909 claims: mint / burn / balanceOf, only while unlocked, each moving the caller's delta;
///      - take: moves the caller's delta and pays real ERC-20 out;
///      - initialize: calls beforeInitialize on the key's hook;
///      - swap: calls beforeSwap, applies the hook's specified delta exactly as v4 Hooks.beforeSwap
///        does (HookDeltaExceedsSwapAmount), runs a constant-price 1:1 pool charging the key's LP fee
///        on the input side, calls afterSwap, applies the unspecified delta, accounts the hook's
///        delta and requires the hook to have settled it (CurrencyNotSettled).
///      Everything the swap did is returned so tests can assert fee maths and swapper amounts.
contract MockPoolManager is IPoolManager {
    error AlreadyUnlocked();
    error ManagerLocked();
    error CurrencyNotSettled(address account, address currency, int256 delta);
    error HookDeltaExceedsSwapAmount();
    error SwapAmountCannotBeZero();
    error InvalidHookResponse();
    error PoolNotInitialized();
    error PoolAlreadyInitialized();

    struct SwapResult {
        int256 pool0; // the pool's own delta for the swapper, before hook deltas
        int256 pool1;
        int256 hook0; // what the hook took on each side (positive = owed to hook)
        int256 hook1;
        int256 swapper0; // final swapper delta
        int256 swapper1;
        uint24 lpFeeOverride;
        int128 beforeUnspecified; // unspecified delta returned from beforeSwap (must be 0)
        int128 afterUnspecified;
        int128 beforeSpecified;
    }

    mapping(address owner => mapping(uint256 id => uint256)) public balanceOf;
    mapping(address account => mapping(address currency => int256)) public currencyDelta;
    mapping(bytes32 => bool) public initialized;
    bool public unlocked;
    uint256 public swaps;

    function unlock(bytes calldata data) external returns (bytes memory result) {
        if (unlocked) revert AlreadyUnlocked();
        unlocked = true;
        result = IUnlockCallback(msg.sender).unlockCallback(data);
        unlocked = false;
        _requireSettled(msg.sender, IMD_ADDR);
    }

    function mint(address to, uint256 id, uint256 amount) external {
        if (!unlocked) revert ManagerLocked();
        balanceOf[to][id] += amount;
        _accountDelta(address(uint160(id)), -int256(amount), msg.sender);
    }

    function burn(address from, uint256 id, uint256 amount) external {
        if (!unlocked) revert ManagerLocked();
        require(from == msg.sender, "mock: burn from self only");
        require(balanceOf[from][id] >= amount, "mock: burn exceeds balance");
        balanceOf[from][id] -= amount;
        _accountDelta(address(uint160(id)), int256(amount), msg.sender);
    }

    function take(Currency currency, address to, uint256 amount) external {
        if (!unlocked) revert ManagerLocked();
        _accountDelta(Currency.unwrap(currency), -int256(amount), msg.sender);
        require(MockIMD(Currency.unwrap(currency)).transfer(to, amount), "mock: take transfer");
    }

    /// @dev Test helper: pretend an unlock is in progress.
    function setUnlocked(bool v) external {
        unlocked = v;
    }

    /// @dev Lets a test hand ERC-6909 claims to any address (what an outsider could do on v4).
    function giftClaims(address to, uint256 id, uint256 amount) external {
        balanceOf[to][id] += amount;
    }

    function initialize(PoolKey memory key, uint160 sqrtPriceX96) external {
        bytes32 id = keccak256(abi.encode(key));
        if (initialized[id]) revert PoolAlreadyInitialized();
        if (address(key.hooks) != address(0)) {
            bytes4 sel = key.hooks.beforeInitialize(msg.sender, key, sqrtPriceX96);
            if (sel != IHooks.beforeInitialize.selector) revert InvalidHookResponse();
        }
        initialized[id] = true;
    }

    function swap(PoolKey memory key, SwapParams memory params) external returns (SwapResult memory r) {
        if (params.amountSpecified == 0) revert SwapAmountCannotBeZero();
        if (!initialized[keccak256(abi.encode(key))]) revert PoolNotInitialized();
        bool wasUnlocked = unlocked;
        unlocked = true; // a real swap runs inside the router's unlock
        swaps++;

        int256 amountToSwap = params.amountSpecified;
        int256 hookSpecified;
        int256 hookUnspecified;
        {
            (bytes4 sel, BeforeSwapDelta bsd, uint24 lpFeeOverride) = key.hooks.beforeSwap(msg.sender, key, params, "");
            if (sel != IHooks.beforeSwap.selector) revert InvalidHookResponse();
            r.lpFeeOverride = lpFeeOverride;
            r.beforeSpecified = _specified(bsd);
            r.beforeUnspecified = _unspecified(bsd);
            hookSpecified = r.beforeSpecified;
            hookUnspecified = r.beforeUnspecified;
            if (hookSpecified != 0) {
                bool exactInput = amountToSwap < 0;
                amountToSwap += hookSpecified;
                if (exactInput ? amountToSwap > 0 : amountToSwap < 0) revert HookDeltaExceedsSwapAmount();
            }
        }
        (r.pool0, r.pool1) = _pool(key.fee, params.zeroForOne, amountToSwap);
        {
            (bytes4 sel, int128 afterUnspecified) =
                key.hooks.afterSwap(msg.sender, key, params, _toBalanceDelta(r.pool0, r.pool1), "");
            if (sel != IHooks.afterSwap.selector) revert InvalidHookResponse();
            r.afterUnspecified = afterUnspecified;
            hookUnspecified += afterUnspecified;
        }
        bool specifiedIs0 = (params.amountSpecified < 0) == params.zeroForOne;
        (r.hook0, r.hook1) = specifiedIs0 ? (hookSpecified, hookUnspecified) : (hookUnspecified, hookSpecified);
        r.swapper0 = r.pool0 - r.hook0;
        r.swapper1 = r.pool1 - r.hook1;
        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        _accountDelta(c0, r.hook0, address(key.hooks));
        _accountDelta(c1, r.hook1, address(key.hooks));
        // The hook must have settled whatever it took (v4 checks this when the unlock ends).
        _requireSettled(address(key.hooks), c0);
        _requireSettled(address(key.hooks), c1);
        unlocked = wasUnlocked;
    }

    /// @dev Constant-price pool at 1:1 charging `fee` pips on the input. Exact input: out = in*(1e6-fee)/1e6.
    ///      Exact output: in = ceil(out*1e6/(1e6-fee)).
    function _pool(uint24 fee, bool zeroForOne, int256 amountToSwap) internal pure returns (int256 a0, int256 a1) {
        int256 inAmt;
        int256 outAmt;
        if (amountToSwap < 0) {
            inAmt = -amountToSwap;
            outAmt = inAmt * int256(1_000_000 - uint256(fee)) / 1_000_000;
        } else {
            outAmt = amountToSwap;
            uint256 denom = 1_000_000 - uint256(fee);
            inAmt = int256((uint256(outAmt) * 1_000_000 + denom - 1) / denom);
        }
        if (zeroForOne) {
            a0 = -inAmt;
            a1 = outAmt;
        } else {
            a0 = outAmt;
            a1 = -inAmt;
        }
    }

    function _accountDelta(address currency, int256 delta, address account) internal {
        if (delta == 0) return;
        currencyDelta[account][currency] += delta;
    }

    function _requireSettled(address account, address currency) internal view {
        int256 d = currencyDelta[account][currency];
        if (d != 0) revert CurrencyNotSettled(account, currency, d);
    }

    function _specified(BeforeSwapDelta d) internal pure returns (int128 s) {
        assembly ("memory-safe") {
            s := sar(128, d)
        }
    }

    function _unspecified(BeforeSwapDelta d) internal pure returns (int128 u) {
        assembly ("memory-safe") {
            u := signextend(15, d)
        }
    }

    function _toBalanceDelta(int256 a0, int256 a1) internal pure returns (BalanceDelta d) {
        assembly ("memory-safe") {
            d := or(shl(128, a0), and(sub(shl(128, 1), 1), a1))
        }
    }
}

// =================================================================================================
// Shared fixture
// =================================================================================================

abstract contract HookFixture {
    VmHook constant vm = VmHook(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint256 constant BPS = 10_000;
    uint256 constant BASE = 425;
    uint24 constant FEE = 12_500;
    int24 constant TICK = 60;
    uint256 constant T0 = 1_750_000_000;
    uint256 constant PM_IMD = 1e36;

    address constant PAYOUT = address(0x9A70);

    MockPoolManager pm;
    MoneyBackToken token;
    MoneyBackHook hook;
    PoolKey key;
    bool imdIs0;

    function assertEq(uint256 a, uint256 b, string memory m) internal pure {
        require(a == b, m);
    }

    function assertEq(int256 a, int256 b, string memory m) internal pure {
        require(a == b, m);
    }

    function assertEq(address a, address b, string memory m) internal pure {
        require(a == b, m);
    }

    function assertTrue(bool c, string memory m) internal pure {
        require(c, m);
    }

    function _abs(int256 x) internal pure returns (uint256) {
        return x < 0 ? uint256(-x) : uint256(x);
    }

    /// @dev Deploys MoneyBackHook via CREATE2 with a salt mined so the low 14 address bits equal `flags`.
    function _deployHook(address manager, address launchToken, address payout, uint160 flags)
        internal
        returns (MoneyBackHook h)
    {
        bytes32 salt = _mineSalt(manager, launchToken, payout, flags);
        h = new MoneyBackHook{salt: salt}(IPoolManager(manager), launchToken, payout);
    }

    function _mineSalt(address manager, address launchToken, address payout, uint160 flags)
        internal
        view
        returns (bytes32)
    {
        bytes32 initHash =
            keccak256(abi.encodePacked(type(MoneyBackHook).creationCode, abi.encode(manager, launchToken, payout)));
        for (uint256 salt = 0; salt < 1_000_000; ++salt) {
            address a = _create2(bytes32(salt), initHash);
            // Skip addresses already deployed (setUp used the first salt); a CREATE2 collision burns all gas.
            if ((uint160(a) & Hooks.ALL_HOOK_MASK) == flags && a.code.length == 0) return bytes32(salt);
        }
        revert("salt mining failed");
    }

    function _create2(bytes32 salt, bytes32 initHash) internal view returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initHash)))));
    }

    function _makeKey(bool imdFirst, address hooks) internal view returns (PoolKey memory k) {
        k.currency0 = Currency.wrap(imdFirst ? IMD_ADDR : address(token));
        k.currency1 = Currency.wrap(imdFirst ? address(token) : IMD_ADDR);
        k.fee = FEE;
        k.tickSpacing = TICK;
        k.hooks = IHooks(hooks);
    }

    /// @dev Full environment: IMD etched, PoolManager funded with IMD, token, hook, pool initialized at T0.
    function _setUpPool(bool imdFirst) internal {
        vm.etch(IMD_ADDR, address(new MockIMD()).code);
        pm = new MockPoolManager();
        MockIMD(IMD_ADDR).mint(address(pm), PM_IMD);
        token = new MoneyBackToken();
        hook = _deployHook(address(pm), address(token), PAYOUT, EXPECTED_FLAGS);
        imdIs0 = imdFirst;
        key = _makeKey(imdFirst, address(hook));
        vm.warp(T0);
        pm.initialize(key, 79228162514264337593543950336);
    }

    // Case numbering used throughout:
    //   1 exact-input buy  (IMD in, amountSpecified < 0)        -> beforeSwap, specified
    //   2 exact-output buy (MONEYBACK out, amountSpecified > 0) -> afterSwap, unspecified
    //   3 exact-input sell (MONEYBACK in, amountSpecified < 0)  -> afterSwap, unspecified
    //   4 exact-output sell(IMD out, amountSpecified > 0)       -> beforeSwap, specified
    function _params(uint8 c, uint256 amount) internal view returns (SwapParams memory p) {
        bool buy = c == 1 || c == 2;
        p.zeroForOne = buy ? imdIs0 : !imdIs0;
        p.amountSpecified = (c == 1 || c == 3) ? -int256(amount) : int256(amount);
        p.sqrtPriceLimitX96 = 0;
    }

    function _isSell(uint8 c) internal pure returns (bool) {
        return c == 3 || c == 4;
    }

    function _imdSide(int256 a0, int256 a1) internal view returns (int256) {
        return imdIs0 ? a0 : a1;
    }

    function _tokenSide(int256 a0, int256 a1) internal view returns (int256) {
        return imdIs0 ? a1 : a0;
    }

    /// @dev The IMD leg the hook defines for each case, given the amount and the mock pool's deltas.
    function _expectedLeg(uint8 c, uint256 amount, MockPoolManager.SwapResult memory r)
        internal
        view
        returns (uint256)
    {
        if (c == 1 || c == 4) return amount;
        return _abs(_imdSide(r.pool0, r.pool1));
    }

    function _surchargeAt(uint256 elapsed) internal pure returns (uint256) {
        if (elapsed >= 1800) return 0;
        return 2000 * (1800 - elapsed) / 1800;
    }

    function _imdOf(address a) internal view returns (uint256) {
        return MockIMD(IMD_ADDR).balanceOf(a);
    }

    function _imdId() internal pure returns (uint256) {
        return uint256(uint160(IMD_ADDR));
    }

    function _tokenId() internal view returns (uint256) {
        return uint256(uint160(address(token)));
    }
}

// =================================================================================================
// Invariant handler
// =================================================================================================

contract HookHandler is HookFixture {
    uint256 public accrued; // sum of hook fees taken (FeeAccrued base + surcharge)
    uint256 public swept; // sum of Swept amounts
    uint256 public swapCount;
    uint256 public sweepCount;
    uint256 public maxTokenSideHookDelta; // must stay 0
    uint256 public lpFeeOverrides; // must stay 0

    constructor(MockPoolManager _pm, MoneyBackToken _token, MoneyBackHook _hook, PoolKey memory _key, bool _imdIs0) {
        pm = _pm;
        token = _token;
        hook = _hook;
        key = _key;
        imdIs0 = _imdIs0;
    }

    function swap(uint8 c, uint256 amount, uint32 warpBy) external {
        c = uint8(c % 4) + 1;
        amount = amount % 1e30 + 1;
        vm.warp(block.timestamp + (warpBy % 4000));
        uint256 bps = hook.currentSurchargeBps();
        MockPoolManager.SwapResult memory r = pm.swap(key, _params(c, amount));
        uint256 leg = _expectedLeg(c, amount, r);
        uint256 fee = leg * BASE / BPS + (_isSell(c) ? leg * bps / BPS : 0);
        require(_imdSide(r.hook0, r.hook1) == int256(fee), "handler: hook IMD delta != fee");
        if (_abs(_tokenSide(r.hook0, r.hook1)) > maxTokenSideHookDelta) {
            maxTokenSideHookDelta = _abs(_tokenSide(r.hook0, r.hook1));
        }
        if (r.lpFeeOverride != 0) lpFeeOverrides++;
        accrued += fee;
        swapCount++;
    }

    function sweep(uint256 who) external {
        uint256 pending = hook.pending();
        vm.prank(address(uint160(0x1000 + who % 5)));
        hook.sweep();
        swept += pending;
        sweepCount++;
    }

    function warp(uint32 by) external {
        vm.warp(block.timestamp + (by % 10_000));
    }
}

// =================================================================================================
// Tests
// =================================================================================================

contract MoneyBackHookTest is HookFixture {
    event FeeAccrued(bool indexed isSell, uint256 baseFeeImd, uint256 surchargeImd, uint256 imdLeg);
    event Swept(uint256 imdAmount, address indexed to);
    event PoolBound(PoolId indexed id, uint256 initializedAt);

    HookHandler handler;
    address[] private _targets;

    function setUp() public {
        _setUpPool(true);
        handler = new HookHandler(pm, token, hook, key, imdIs0);
        _targets.push(address(handler));
    }

    function targetContracts() external view returns (address[] memory) {
        return _targets;
    }

    // ---------------------------------------------------------------------------------------------
    // deployment / constructor
    // ---------------------------------------------------------------------------------------------

    function test_deploymentAddressFlagBitsMatchPermissions() public view {
        uint160 bits = uint160(address(hook)) & Hooks.ALL_HOOK_MASK;
        assertEq(uint256(bits), uint256(EXPECTED_FLAGS), "low 14 bits are 0x20CC");
        assertEq(uint256(hook.requiredFlags()), uint256(EXPECTED_FLAGS), "requiredFlags");
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertEq(uint256(Hooks.flags(p)), uint256(bits), "flags(perms) == address bits");
        // Each declared permission on, every other off.
        assertTrue(p.beforeInitialize && bits & Hooks.BEFORE_INITIALIZE_FLAG != 0, "beforeInitialize");
        assertTrue(p.beforeSwap && bits & Hooks.BEFORE_SWAP_FLAG != 0, "beforeSwap");
        assertTrue(p.afterSwap && bits & Hooks.AFTER_SWAP_FLAG != 0, "afterSwap");
        assertTrue(p.beforeSwapReturnDelta && bits & Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG != 0, "beforeSwapReturnDelta");
        assertTrue(p.afterSwapReturnDelta && bits & Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG != 0, "afterSwapReturnDelta");
        assertTrue(!p.afterInitialize && bits & Hooks.AFTER_INITIALIZE_FLAG == 0, "afterInitialize off");
        assertTrue(!p.beforeAddLiquidity && bits & Hooks.BEFORE_ADD_LIQUIDITY_FLAG == 0, "beforeAddLiquidity off");
        assertTrue(!p.afterAddLiquidity && bits & Hooks.AFTER_ADD_LIQUIDITY_FLAG == 0, "afterAddLiquidity off");
        assertTrue(
            !p.beforeRemoveLiquidity && bits & Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG == 0, "beforeRemoveLiquidity off"
        );
        assertTrue(!p.afterRemoveLiquidity && bits & Hooks.AFTER_REMOVE_LIQUIDITY_FLAG == 0, "afterRemoveLiquidity off");
        assertTrue(!p.beforeDonate && bits & Hooks.BEFORE_DONATE_FLAG == 0, "beforeDonate off");
        assertTrue(!p.afterDonate && bits & Hooks.AFTER_DONATE_FLAG == 0, "afterDonate off");
        assertTrue(
            !p.afterAddLiquidityReturnDelta && bits & Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG == 0,
            "afterAddLiquidityReturnDelta off"
        );
        assertTrue(
            !p.afterRemoveLiquidityReturnDelta && bits & Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG == 0,
            "afterRemoveLiquidityReturnDelta off"
        );
    }

    function test_constructorStoresImmutablesAndConstants() public view {
        assertEq(address(hook.poolManager()), address(pm), "poolManager");
        assertEq(hook.launchToken(), address(token), "launchToken");
        assertEq(hook.payout(), PAYOUT, "payout");
        assertEq(hook.IMD(), IMD_ADDR, "IMD constant");
        assertEq(hook.baseFeeBps(), 425, "baseFeeBps");
        assertEq(hook.BASE_FEE_BPS(), 425, "BASE_FEE_BPS");
        assertEq(hook.SURCHARGE_START_BPS(), 2000, "surcharge start");
        assertEq(hook.SURCHARGE_DURATION(), 1800, "surcharge duration");
        assertEq(uint256(hook.POOL_FEE()), 12_500, "pool fee");
        assertEq(uint256(int256(hook.POOL_TICK_SPACING())), 60, "tick spacing");
    }

    function test_constructorRejectsWrongFlagBits() public {
        // One bit off (afterInitialize set instead of beforeInitialize): v4 would reject this address too.
        uint160 wrong = EXPECTED_FLAGS ^ Hooks.BEFORE_INITIALIZE_FLAG ^ Hooks.AFTER_INITIALIZE_FLAG;
        bytes32 salt = _mineSalt(address(pm), address(token), PAYOUT, wrong);
        bytes32 initHash = keccak256(
            abi.encodePacked(type(MoneyBackHook).creationCode, abi.encode(address(pm), address(token), PAYOUT))
        );
        address predicted = _create2(salt, initHash);
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, predicted));
        new MoneyBackHook{salt: salt}(IPoolManager(address(pm)), address(token), PAYOUT);
        // No flags at all.
        salt = _mineSalt(address(pm), address(token), PAYOUT, 0);
        predicted = _create2(salt, initHash);
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, predicted));
        new MoneyBackHook{salt: salt}(IPoolManager(address(pm)), address(token), PAYOUT);
    }

    function test_constructorRejectsZeroAddresses() public {
        bytes32 salt = bytes32(uint256(1));
        vm.expectRevert(abi.encodeWithSelector(MoneyBackHook.ZeroAddress.selector));
        new MoneyBackHook{salt: salt}(IPoolManager(address(0)), address(token), PAYOUT);
        vm.expectRevert(abi.encodeWithSelector(MoneyBackHook.ZeroAddress.selector));
        new MoneyBackHook{salt: salt}(IPoolManager(address(pm)), address(0), PAYOUT);
        vm.expectRevert(abi.encodeWithSelector(MoneyBackHook.ZeroAddress.selector));
        new MoneyBackHook{salt: salt}(IPoolManager(address(pm)), address(token), address(0));
    }

    function test_constructorRejectsImdAsLaunchToken() public {
        vm.expectRevert(abi.encodeWithSelector(MoneyBackHook.WrongLaunchToken.selector));
        new MoneyBackHook{salt: bytes32(uint256(2))}(IPoolManager(address(pm)), IMD_ADDR, PAYOUT);
    }

    function test_hookRejectsEthAndHasNoAdminSurface() public {
        (bool ok,) = address(hook).call{value: 1}("");
        assertTrue(!ok, "hook accepted ETH");
        bytes4[6] memory sels = [
            bytes4(keccak256("owner()")),
            bytes4(keccak256("setPayout(address)")),
            bytes4(keccak256("pause()")),
            bytes4(keccak256("upgradeTo(address)")),
            bytes4(keccak256("withdraw(address,uint256)")),
            bytes4(keccak256("transferOwnership(address)"))
        ];
        for (uint256 i = 0; i < sels.length; ++i) {
            (ok,) = address(hook).call(abi.encodeWithSelector(sels[i], address(this), uint256(1)));
            assertTrue(!ok, "unexpected admin selector answered");
        }
    }

    // ---------------------------------------------------------------------------------------------
    // beforeInitialize
    // ---------------------------------------------------------------------------------------------

    function test_initializeBindsPoolAndRecordsTimestamp() public view {
        assertEq(hook.initializedAt(), T0, "initializedAt");
        assertTrue(PoolId.unwrap(hook.poolId()) == keccak256(abi.encode(key)), "poolId");
        PoolKey memory k = hook.poolKey();
        assertEq(Currency.unwrap(k.currency0), Currency.unwrap(key.currency0), "currency0");
        assertEq(Currency.unwrap(k.currency1), Currency.unwrap(key.currency1), "currency1");
        assertEq(uint256(k.fee), uint256(FEE), "fee");
        assertEq(uint256(int256(k.tickSpacing)), uint256(int256(TICK)), "tickSpacing");
        assertEq(address(k.hooks), address(hook), "hooks");
        assertEq(hook.currentSurchargeBps(), 2000, "surcharge at t0");
        assertEq(hook.pending(), 0, "nothing pending");
    }

    function test_initializeEmitsPoolBound() public {
        MoneyBackHook fresh = _deployHook(address(pm), address(token), PAYOUT, EXPECTED_FLAGS);
        PoolKey memory k = _makeKey(false, address(fresh));
        vm.warp(T0 + 5);
        vm.expectEmit(true, false, false, true);
        emit PoolBound(PoolId.wrap(keccak256(abi.encode(k))), T0 + 5);
        pm.initialize(k, 1 << 96);
        assertEq(fresh.initializedAt(), T0 + 5, "initializedAt");
    }

    function test_viewsBeforeInitialization() public {
        MoneyBackHook fresh = _deployHook(address(pm), address(token), PAYOUT, EXPECTED_FLAGS);
        assertEq(fresh.initializedAt(), 0, "not initialized");
        assertEq(fresh.currentSurchargeBps(), 0, "no surcharge before init");
        assertTrue(PoolId.unwrap(fresh.poolId()) == bytes32(0), "zero poolId");
        PoolKey memory k = fresh.poolKey();
        assertEq(Currency.unwrap(k.currency0), address(0), "zero key");
        assertEq(address(k.hooks), address(0), "zero hooks");
        assertEq(fresh.pending(), 0, "pending 0");
    }

    function test_initializeAcceptsEitherCurrencyOrder() public {
        MoneyBackHook fresh = _deployHook(address(pm), address(token), PAYOUT, EXPECTED_FLAGS);
        PoolKey memory k = _makeKey(false, address(fresh)); // token first, IMD second
        pm.initialize(k, 1 << 96);
        assertTrue(PoolId.unwrap(fresh.poolId()) == keccak256(abi.encode(k)), "bound with IMD as currency1");
    }

    function test_initializeRejectsSecondPool() public {
        PoolKey memory k = _makeKey(false, address(hook)); // same assets, other order: a different id
        vm.prank(address(pm));
        vm.expectRevert(abi.encodeWithSelector(MoneyBackHook.AlreadyBound.selector));
        hook.beforeInitialize(address(this), k, 1 << 96);
        vm.prank(address(pm));
        vm.expectRevert(abi.encodeWithSelector(MoneyBackHook.AlreadyBound.selector));
        hook.beforeInitialize(address(this), key, 1 << 96);
    }

    function test_initializeRejectsWrongKeys() public {
        MoneyBackHook fresh = _deployHook(address(pm), address(token), PAYOUT, EXPECTED_FLAGS);
        PoolKey memory k;
        vm.startPrank(address(pm));

        k = _makeKey(true, address(fresh));
        k.fee = 10_000;
        vm.expectRevert(abi.encodeWithSelector(MoneyBackHook.WrongPoolFee.selector));
        fresh.beforeInitialize(address(this), k, 1 << 96);

        k = _makeKey(true, address(fresh));
        k.fee = 0x800000; // dynamic fee flag
        vm.expectRevert(abi.encodeWithSelector(MoneyBackHook.WrongPoolFee.selector));
        fresh.beforeInitialize(address(this), k, 1 << 96);

        k = _makeKey(true, address(fresh));
        k.tickSpacing = 100;
        vm.expectRevert(abi.encodeWithSelector(MoneyBackHook.WrongTickSpacing.selector));
        fresh.beforeInitialize(address(this), k, 1 << 96);

        k = _makeKey(true, address(hook)); // another hook's address in the key
        vm.expectRevert(abi.encodeWithSelector(MoneyBackHook.WrongHook.selector));
        fresh.beforeInitialize(address(this), k, 1 << 96);

        k = _makeKey(true, address(0));
        vm.expectRevert(abi.encodeWithSelector(MoneyBackHook.WrongHook.selector));
        fresh.beforeInitialize(address(this), k, 1 << 96);

        // Neither currency is IMD.
        k = _makeKey(true, address(fresh));
        k.currency0 = Currency.wrap(address(0));
        vm.expectRevert(abi.encodeWithSelector(MoneyBackHook.WrongPairedCurrency.selector));
        fresh.beforeInitialize(address(this), k, 1 << 96);

        // IMD paired with something other than MONEYBACK, in both slots.
        k = _makeKey(true, address(fresh));
        k.currency1 = Currency.wrap(address(0xBEEF));
        vm.expectRevert(abi.encodeWithSelector(MoneyBackHook.WrongLaunchToken.selector));
        fresh.beforeInitialize(address(this), k, 1 << 96);
        k = _makeKey(false, address(fresh));
        k.currency0 = Currency.wrap(address(0xBEEF));
        vm.expectRevert(abi.encodeWithSelector(MoneyBackHook.WrongLaunchToken.selector));
        fresh.beforeInitialize(address(this), k, 1 << 96);

        // IMD / IMD.
        k = _makeKey(true, address(fresh));
        k.currency1 = Currency.wrap(IMD_ADDR);
        vm.expectRevert(abi.encodeWithSelector(MoneyBackHook.WrongLaunchToken.selector));
        fresh.beforeInitialize(address(this), k, 1 << 96);

        vm.stopPrank();
        assertEq(fresh.initializedAt(), 0, "nothing bound after rejected keys");
        // The right key still works afterwards.
        pm.initialize(_makeKey(true, address(fresh)), 1 << 96);
        assertEq(fresh.initializedAt(), T0, "bound");
    }

    function test_callbacksRejectNonPoolManager() public {
        SwapParams memory p = _params(1, 1e18);
        vm.startPrank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSelector(MoneyBackHook.NotPoolManager.selector));
        hook.beforeInitialize(address(this), key, 1 << 96);
        vm.expectRevert(abi.encodeWithSelector(MoneyBackHook.NotPoolManager.selector));
        hook.beforeSwap(address(this), key, p, "");
        vm.expectRevert(abi.encodeWithSelector(MoneyBackHook.NotPoolManager.selector));
        hook.afterSwap(address(this), key, p, BalanceDelta.wrap(0), "");
        vm.expectRevert(abi.encodeWithSelector(MoneyBackHook.NotPoolManager.selector));
        hook.unlockCallback("");
        vm.stopPrank();
        // Also from the test contract itself (the "router").
        vm.expectRevert(abi.encodeWithSelector(MoneyBackHook.NotPoolManager.selector));
        hook.beforeSwap(address(this), key, p, "");
        assertEq(hook.pending(), 0, "nothing accrued");
    }

    // ---------------------------------------------------------------------------------------------
    // the four swap cases at t = 0, 900, 1800, 1 day
    // ---------------------------------------------------------------------------------------------

    function _checkCase(uint8 c, uint256 amount, uint256 elapsed) internal {
        vm.warp(T0 + elapsed);
        uint256 bps = _surchargeAt(elapsed);
        assertEq(hook.currentSurchargeBps(), bps, "currentSurchargeBps");
        uint256 pendingBefore = hook.pending();

        MockPoolManager.SwapResult memory r = pm.swap(key, _params(c, amount));

        uint256 leg = _expectedLeg(c, amount, r);
        uint256 base = leg * BASE / BPS;
        uint256 sur = _isSell(c) ? leg * bps / BPS : 0;
        uint256 fee = base + sur;

        // Fee taken in IMD only, exactly base + surcharge, by one callback only.
        assertEq(_imdSide(r.hook0, r.hook1), int256(fee), "hook IMD delta == fee");
        assertEq(_tokenSide(r.hook0, r.hook1), 0, "hook never touches MONEYBACK side");
        assertEq(uint256(r.lpFeeOverride), 0, "LP fee never overridden");
        assertEq(int256(r.beforeUnspecified), 0, "beforeSwap never returns an unspecified delta");
        if (c == 1 || c == 4) {
            assertEq(int256(r.beforeSpecified), int256(fee), "cases 1/4 charged in beforeSwap");
            assertEq(int256(r.afterUnspecified), 0, "cases 1/4 return 0 in afterSwap");
        } else {
            assertEq(int256(r.beforeSpecified), 0, "cases 2/3 return 0 in beforeSwap");
            assertEq(int256(r.afterUnspecified), int256(fee), "cases 2/3 charged in afterSwap");
        }
        assertEq(hook.pending(), pendingBefore + fee, "pending grows by fee");
        assertEq(pm.balanceOf(address(hook), _tokenId()), 0, "no MONEYBACK claims");

        // Combined fee is within 1 wei of floor(leg * (425 + bps) / 10_000).
        uint256 combined = leg * (BASE + (_isSell(c) ? bps : 0)) / BPS;
        assertTrue(combined >= fee && combined - fee <= 1, "fee within 1 wei of combined formula");

        _checkSwapperAmounts(c, amount, leg, fee, r);
    }

    function _checkSwapperAmounts(
        uint8 c,
        uint256 amount,
        uint256 leg,
        uint256 fee,
        MockPoolManager.SwapResult memory r
    ) internal view {
        int256 swapperImd = _imdSide(r.swapper0, r.swapper1);
        int256 swapperTok = _tokenSide(r.swapper0, r.swapper1);
        if (c == 1) {
            assertEq(swapperImd, -int256(amount), "exact-input buy: pays exactly amountSpecified IMD");
            assertEq(_imdSide(r.pool0, r.pool1), -int256(amount - fee), "pool received amount - fee");
            assertEq(swapperTok, int256((amount - fee) * (1_000_000 - FEE) / 1_000_000), "MONEYBACK out of the net");
        } else if (c == 2) {
            assertEq(swapperTok, int256(amount), "exact-output buy: receives amountSpecified MONEYBACK");
            assertEq(swapperImd, -int256(leg + fee), "pays pool IMD + fee");
        } else if (c == 3) {
            assertEq(swapperTok, -int256(amount), "exact-input sell: pays amountSpecified MONEYBACK");
            assertEq(swapperImd, int256(leg - fee), "receives pool IMD - fee");
        } else {
            assertEq(swapperImd, int256(amount), "exact-output sell: receives exactly amountSpecified IMD");
            assertEq(_imdSide(r.pool0, r.pool1), int256(amount + fee), "pool paid amount + fee");
        }
    }

    function test_case1_exactInputBuy_t0() public {
        _checkCase(1, 1_000e18, 0);
    }

    function test_case1_exactInputBuy_t900() public {
        _checkCase(1, 123_456_789e9, 900);
    }

    function test_case1_exactInputBuy_t1800() public {
        _checkCase(1, 7e18 + 3, 1800);
    }

    function test_case1_exactInputBuy_t1day() public {
        _checkCase(1, 999_999, 86_400);
    }

    function test_case2_exactOutputBuy_t0() public {
        _checkCase(2, 1_000e18, 0);
    }

    function test_case2_exactOutputBuy_t900() public {
        _checkCase(2, 55_555e15, 900);
    }

    function test_case2_exactOutputBuy_t1800() public {
        _checkCase(2, 1e18 + 1, 1800);
    }

    function test_case2_exactOutputBuy_t1day() public {
        _checkCase(2, 31337, 86_400);
    }

    function test_case3_exactInputSell_t0() public {
        _checkCase(3, 1_000e18, 0);
    }

    function test_case3_exactInputSell_t900() public {
        _checkCase(3, 777e18 + 77, 900);
    }

    function test_case3_exactInputSell_t1800() public {
        _checkCase(3, 10e18, 1800);
    }

    function test_case3_exactInputSell_t1day() public {
        _checkCase(3, 123_457, 86_400);
    }

    function test_case4_exactOutputSell_t0() public {
        _checkCase(4, 1_000e18, 0);
    }

    function test_case4_exactOutputSell_t900() public {
        _checkCase(4, 42e18 + 1, 900);
    }

    function test_case4_exactOutputSell_t1800() public {
        _checkCase(4, 5e18, 1800);
    }

    function test_case4_exactOutputSell_t1day() public {
        _checkCase(4, 1, 86_400);
    }

    function test_allCasesWithImdAsCurrency1() public {
        // Rebuild the fixture with MONEYBACK as currency0 so _isSell / delta parsing is exercised the other way.
        _setUpPool(false);
        uint256[4] memory ts = [uint256(0), 900, 1800, 86_400];
        for (uint8 c = 1; c <= 4; ++c) {
            for (uint256 i = 0; i < 4; ++i) {
                _checkCase(c, 500e18 + c * 7 + i, ts[i]);
            }
        }
    }

    function test_feeAccruedEventsPerCase() public {
        uint256 amount = 1_000e18;
        // Case 1 at t0: buy, no surcharge.
        vm.expectEmit(true, false, false, true);
        emit FeeAccrued(false, amount * 425 / BPS, 0, amount);
        pm.swap(key, _params(1, amount));
        // Case 4 at t0: sell, 20% surcharge.
        vm.expectEmit(true, false, false, true);
        emit FeeAccrued(true, amount * 425 / BPS, amount * 2000 / BPS, amount);
        pm.swap(key, _params(4, amount));
        // Case 3 at +900: leg is the pool's IMD out, 10% surcharge.
        vm.warp(T0 + 900);
        uint256 leg = amount * (1_000_000 - FEE) / 1_000_000;
        vm.expectEmit(true, false, false, true);
        emit FeeAccrued(true, leg * 425 / BPS, leg * 1000 / BPS, leg);
        pm.swap(key, _params(3, amount));
        // Case 2 at +1800: leg is the pool's IMD in, no surcharge on buys anyway.
        vm.warp(T0 + 1800);
        uint256 legIn = (amount * 1_000_000 + (1_000_000 - FEE) - 1) / (1_000_000 - FEE);
        vm.expectEmit(true, false, false, true);
        emit FeeAccrued(false, legIn * 425 / BPS, 0, legIn);
        pm.swap(key, _params(2, amount));
    }

    /// @notice Acceptance: a sell at t=0 costs 1.25% LP + 4.25% + 20%; at t >= 1800 s 1.25% + 4.25%.
    function test_acceptanceSellCostAtT0AndAfterDecay() public {
        uint256 amount = 10_000e18;
        MockPoolManager.SwapResult memory r0 = pm.swap(key, _params(3, amount));
        uint256 leg = amount * (1_000_000 - FEE) / 1_000_000; // after the 1.25% LP fee
        uint256 got0 = uint256(_imdSide(r0.swapper0, r0.swapper1));
        assertEq(got0, leg - leg * 425 / BPS - leg * 2000 / BPS, "t0: LP + 4.25% + 20%");
        // 10_000 * 0.9875 * (1 - 0.2425) = 7480.3125
        assertEq(got0, 7_480_3125e14, "t0 effective 74.803125%");

        vm.warp(T0 + 1800);
        MockPoolManager.SwapResult memory r1 = pm.swap(key, _params(3, amount));
        uint256 got1 = uint256(_imdSide(r1.swapper0, r1.swapper1));
        assertEq(got1, leg - leg * 425 / BPS, "t>=1800: LP + 4.25% only");
        // 10_000 * 0.9875 * 0.9575 = 9455.3125
        assertEq(got1, 9_455_3125e14, "post-decay effective 94.553125%");

        vm.warp(T0 + 365 days);
        MockPoolManager.SwapResult memory r2 = pm.swap(key, _params(3, amount));
        assertEq(_imdSide(r2.swapper0, r2.swapper1), int256(got1), "surcharge stays 0 forever");
    }

    function test_buysNeverSurchargedAtAnyTime() public {
        uint256[5] memory ts = [uint256(0), 1, 899, 1799, 1800];
        for (uint256 i = 0; i < ts.length; ++i) {
            vm.warp(T0 + ts[i]);
            uint256 amount = 100e18;
            vm.expectEmit(true, false, false, true);
            emit FeeAccrued(false, amount * 425 / BPS, 0, amount);
            pm.swap(key, _params(1, amount));
        }
    }

    // ---------------------------------------------------------------------------------------------
    // surcharge formula and boundaries
    // ---------------------------------------------------------------------------------------------

    function test_surchargeBoundaries() public {
        vm.warp(T0);
        assertEq(hook.currentSurchargeBps(), 2000, "t0");
        vm.warp(T0 + 1);
        assertEq(hook.currentSurchargeBps(), uint256(2000) * 1799 / 1800, "t1 = 1998");
        assertEq(hook.currentSurchargeBps(), 1998, "t1 literal");
        vm.warp(T0 + 900);
        assertEq(hook.currentSurchargeBps(), 1000, "t900");
        vm.warp(T0 + 1799);
        assertEq(hook.currentSurchargeBps(), 1, "t1799 = 1 bps, not 0");
        vm.warp(T0 + 1800);
        assertEq(hook.currentSurchargeBps(), 0, "t1800 exactly 0");
        vm.warp(T0 + 1801);
        assertEq(hook.currentSurchargeBps(), 0, "t1801");
        vm.warp(T0 + 10 * 365 days);
        assertEq(hook.currentSurchargeBps(), 0, "ten years");
    }

    function test_surchargeAt1799IsStillChargedOnSells() public {
        vm.warp(T0 + 1799);
        uint256 amount = 100_000e18;
        vm.expectEmit(true, false, false, true);
        emit FeeAccrued(true, amount * 425 / BPS, amount * 1 / BPS, amount);
        pm.swap(key, _params(4, amount));
    }

    function test_surchargeAt1800IsZeroOnSells() public {
        vm.warp(T0 + 1800);
        uint256 amount = 100_000e18;
        vm.expectEmit(true, false, false, true);
        emit FeeAccrued(true, amount * 425 / BPS, 0, amount);
        pm.swap(key, _params(4, amount));
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_surchargeFormula(uint32 elapsed) public {
        vm.warp(T0 + elapsed);
        assertEq(hook.currentSurchargeBps(), _surchargeAt(elapsed), "formula");
        uint256 bps = hook.currentSurchargeBps();
        assertTrue(bps <= 2000, "never above 2000");
        if (elapsed < 1800) assertTrue(bps >= 1, "strictly positive before 1800 s");
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_surchargeIsMonotoneNonIncreasing(uint32 a, uint32 b) public {
        if (a > b) (a, b) = (b, a);
        vm.warp(T0 + a);
        uint256 x = hook.currentSurchargeBps();
        vm.warp(T0 + b);
        uint256 y = hook.currentSurchargeBps();
        assertTrue(y <= x, "surcharge increased over time");
    }

    // ---------------------------------------------------------------------------------------------
    // fuzz over sizes, cases and timestamps
    // ---------------------------------------------------------------------------------------------

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_feeMathsAllCases(uint8 c, uint256 amount, uint32 elapsed) public {
        c = uint8(c % 4) + 1;
        amount = amount % 1e30 + 1;
        elapsed = elapsed % 100_000;
        _checkCase(c, amount, elapsed);
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_tinyAmountsRoundDownToZeroFee(uint8 c, uint256 amount, uint32 elapsed) public {
        c = uint8(c % 4) + 1;
        amount = amount % 23 + 1; // 23 * 425 / 10_000 == 0 and 23 * 2000 / 10_000 == 4 at most
        vm.warp(T0 + elapsed);
        MockPoolManager.SwapResult memory r = pm.swap(key, _params(c, amount));
        uint256 leg = _expectedLeg(c, amount, r);
        uint256 expected = leg * BASE / BPS + (_isSell(c) ? leg * hook.currentSurchargeBps() / BPS : 0);
        assertEq(hook.pending(), expected, "rounded-down fee");
        assertTrue(expected <= 4, "base part always 0 at these sizes");
        assertEq(_tokenSide(r.hook0, r.hook1), 0, "no MONEYBACK delta");
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_sequenceAccumulatesPending(uint256 a, uint256 b, uint256 c, uint32 elapsed) public {
        a = a % 1e27 + 1;
        b = b % 1e27 + 1;
        c = c % 1e27 + 1;
        vm.warp(T0 + elapsed);
        uint256 bps = hook.currentSurchargeBps();
        MockPoolManager.SwapResult memory r3 = pm.swap(key, _params(3, b));
        pm.swap(key, _params(1, a));
        pm.swap(key, _params(4, c));
        uint256 leg3 = _abs(_imdSide(r3.pool0, r3.pool1));
        uint256 expected = a * BASE / BPS + (leg3 * BASE / BPS + leg3 * bps / BPS) + (c * BASE / BPS + c * bps / BPS);
        assertEq(hook.pending(), expected, "pending == sum of fees");
    }

    // ---------------------------------------------------------------------------------------------
    // swap adversarial: wrong keys, unbound hook, zero amounts, overflow
    // ---------------------------------------------------------------------------------------------

    function test_swapRejectsWrongPoolKey() public {
        SwapParams memory p = _params(1, 1e18);
        PoolKey memory k;
        vm.startPrank(address(pm));
        bytes memory err = abi.encodeWithSelector(MoneyBackHook.NotBoundPool.selector);

        k = key;
        k.fee = 3000;
        vm.expectRevert(err);
        hook.beforeSwap(address(this), k, p, "");
        vm.expectRevert(err);
        hook.afterSwap(address(this), k, p, BalanceDelta.wrap(0), "");

        k = key;
        k.tickSpacing = 10;
        vm.expectRevert(err);
        hook.beforeSwap(address(this), k, p, "");

        k = key;
        k.hooks = IHooks(address(0));
        vm.expectRevert(err);
        hook.beforeSwap(address(this), k, p, "");

        k = _makeKey(!imdIs0, address(hook)); // same assets, swapped order: another pool id
        vm.expectRevert(err);
        hook.beforeSwap(address(this), k, p, "");
        vm.expectRevert(err);
        hook.afterSwap(address(this), k, p, BalanceDelta.wrap(0), "");

        k = key;
        k.currency1 = Currency.wrap(address(0xBEEF));
        vm.expectRevert(err);
        hook.beforeSwap(address(this), k, p, "");
        vm.stopPrank();
        assertEq(hook.pending(), 0, "nothing accrued on rejected keys");
    }

    function test_swapBeforeInitializationReverts() public {
        MoneyBackHook fresh = _deployHook(address(pm), address(token), PAYOUT, EXPECTED_FLAGS);
        PoolKey memory k = _makeKey(true, address(fresh));
        SwapParams memory p = _params(1, 1e18);
        vm.startPrank(address(pm));
        vm.expectRevert(abi.encodeWithSelector(MoneyBackHook.NotBoundPool.selector));
        fresh.beforeSwap(address(this), k, p, "");
        vm.expectRevert(abi.encodeWithSelector(MoneyBackHook.NotBoundPool.selector));
        fresh.afterSwap(address(this), k, p, BalanceDelta.wrap(0), "");
        vm.stopPrank();
    }

    function test_zeroAmountSwapAccruesNothing() public {
        // v4 rejects amountSpecified == 0 before any hook call; if it ever reached the hook it must be harmless.
        SwapParams memory p = SwapParams({zeroForOne: !imdIs0, amountSpecified: 0, sqrtPriceLimitX96: 0});
        vm.startPrank(address(pm));
        (bytes4 s1, BeforeSwapDelta d, uint24 f) = hook.beforeSwap(address(this), key, p, "");
        (bytes4 s2, int128 u) = hook.afterSwap(address(this), key, p, BalanceDelta.wrap(0), "");
        p.zeroForOne = imdIs0;
        (bytes4 s3, BeforeSwapDelta d2,) = hook.beforeSwap(address(this), key, p, "");
        (bytes4 s4, int128 u2) = hook.afterSwap(address(this), key, p, BalanceDelta.wrap(0), "");
        vm.stopPrank();
        assertTrue(s1 == IHooks.beforeSwap.selector && s3 == s1, "beforeSwap selector");
        assertTrue(s2 == IHooks.afterSwap.selector && s4 == s2, "afterSwap selector");
        assertEq(BeforeSwapDelta.unwrap(d), 0, "zero delta");
        assertEq(BeforeSwapDelta.unwrap(d2), 0, "zero delta");
        assertEq(int256(u), 0, "zero after delta");
        assertEq(int256(u2), 0, "zero after delta");
        assertEq(uint256(f), 0, "no fee override");
        assertEq(hook.pending(), 0, "nothing minted");
        // And the mock, like v4, refuses the swap outright.
        vm.expectRevert(abi.encodeWithSelector(MockPoolManager.SwapAmountCannotBeZero.selector));
        pm.swap(key, p);
    }

    function test_afterSwapWithZeroPoolDeltaAccruesNothing() public {
        // Cases 2/3 with a pool that moved no IMD: fee 0, no mint, event still emitted with zeros.
        SwapParams memory p = _params(3, 1e18);
        vm.prank(address(pm));
        vm.expectEmit(true, false, false, true);
        emit FeeAccrued(true, 0, 0, 0);
        (, int128 u) = hook.afterSwap(address(this), key, p, BalanceDelta.wrap(0), "");
        assertEq(int256(u), 0, "zero");
        assertEq(hook.pending(), 0, "nothing minted");
    }

    function test_fixedCallbacksOnlyChargeTheirOwnCases() public {
        // beforeSwap on cases 2/3 returns zero and mints nothing; afterSwap on cases 1/4 likewise.
        vm.startPrank(address(pm));
        (, BeforeSwapDelta d2,) = hook.beforeSwap(address(this), key, _params(2, 1e18), "");
        (, BeforeSwapDelta d3,) = hook.beforeSwap(address(this), key, _params(3, 1e18), "");
        BalanceDelta big = BalanceDelta.wrap(int256(-1e18) << 128 | int256(1e18));
        (, int128 u1) = hook.afterSwap(address(this), key, _params(1, 1e18), big, "");
        (, int128 u4) = hook.afterSwap(address(this), key, _params(4, 1e18), big, "");
        vm.stopPrank();
        assertEq(BeforeSwapDelta.unwrap(d2), 0, "case 2 not charged in beforeSwap");
        assertEq(BeforeSwapDelta.unwrap(d3), 0, "case 3 not charged in beforeSwap");
        assertEq(int256(u1), 0, "case 1 not charged in afterSwap");
        assertEq(int256(u4), 0, "case 4 not charged in afterSwap");
        assertEq(hook.pending(), 0, "nothing minted");
    }

    function test_hugeSpecifiedAmountRevertsAmountOverflow() public {
        SwapParams memory p = _params(1, uint256(1) << 200);
        pm.setUnlocked(true); // as inside a real swap, so the hook's mint goes through and its own check fires
        vm.prank(address(pm));
        vm.expectRevert(abi.encodeWithSelector(MoneyBackHook.AmountOverflow.selector));
        hook.beforeSwap(address(this), key, p, "");
    }

    function test_hookNeverMintsMoneybackClaimsEvenIfGiftedImdClaims() public {
        pm.swap(key, _params(3, 1e21));
        assertEq(pm.balanceOf(address(hook), _tokenId()), 0, "no MONEYBACK claims");
        // Outsider gifts IMD claims: pending() reflects the claim balance and sweep moves all of it to payout.
        pm.giftClaims(address(hook), _imdId(), 5);
        uint256 p = hook.pending();
        hook.sweep();
        assertEq(_imdOf(PAYOUT), p, "gifted claims also go to payout only");
        assertEq(hook.pending(), 0, "all taken");
    }

    // ---------------------------------------------------------------------------------------------
    // sweep
    // ---------------------------------------------------------------------------------------------

    function test_emptySweepSucceedsAndEmitsZero() public {
        vm.prank(address(0x1234));
        vm.expectEmit(true, false, false, true);
        emit Swept(0, PAYOUT);
        hook.sweep();
        assertEq(_imdOf(PAYOUT), 0, "nothing paid");
        assertEq(hook.pending(), 0, "still zero");
    }

    function test_sweepTakesAllImdClaimsToPayout() public {
        pm.swap(key, _params(1, 1_000e18));
        pm.swap(key, _params(3, 500e18));
        uint256 pending = hook.pending();
        assertTrue(pending > 0, "something accrued");
        uint256 pmImd = _imdOf(address(pm));
        address anyone = address(0xAAAA);
        vm.prank(anyone);
        vm.expectEmit(true, false, false, true);
        emit Swept(pending, PAYOUT);
        hook.sweep();
        assertEq(hook.pending(), 0, "pending cleared");
        assertEq(pm.balanceOf(address(hook), _imdId()), 0, "claims burned");
        assertEq(_imdOf(PAYOUT), pending, "payout received everything");
        assertEq(_imdOf(address(pm)), pmImd - pending, "PoolManager paid it out");
        assertEq(_imdOf(address(hook)), 0, "hook holds no IMD");
        assertEq(_imdOf(anyone), 0, "caller gets nothing");
        assertEq(_imdOf(address(this)), 0, "router gets nothing");
        assertTrue(!pm.unlocked(), "manager locked again");
        // Second sweep: empty, fine.
        hook.sweep();
        assertEq(_imdOf(PAYOUT), pending, "nothing more");
    }

    function test_sweepAccumulatesAcrossRounds() public {
        pm.swap(key, _params(4, 100e18));
        uint256 p1 = hook.pending();
        hook.sweep();
        vm.warp(T0 + 3000);
        pm.swap(key, _params(2, 100e18));
        uint256 p2 = hook.pending();
        hook.sweep();
        assertEq(_imdOf(PAYOUT), p1 + p2, "cumulative");
    }

    function test_sweepReentrancyFromPayoutTransferIsRejected() public {
        pm.swap(key, _params(1, 1_000e18));
        uint256 pending = hook.pending();
        SweepReenterer attacker = new SweepReenterer(hook);
        MockIMD(IMD_ADDR).armReentry(address(attacker), PAYOUT);
        hook.sweep();
        assertTrue(MockIMD(IMD_ADDR).nestedCallReverted(), "nested sweep reverted");
        assertTrue(
            keccak256(MockIMD(IMD_ADDR).nestedReason())
                == keccak256(abi.encodeWithSelector(MoneyBackHook.Reentrancy.selector)),
            "nested sweep hit the Reentrancy guard"
        );
        assertEq(_imdOf(PAYOUT), pending, "paid exactly once");
        assertEq(hook.pending(), 0, "cleared");
        // The guard resets: a later sweep works.
        pm.swap(key, _params(1, 10e18));
        uint256 more = hook.pending();
        MockIMD(IMD_ADDR).armReentry(address(0), address(0));
        hook.sweep();
        assertEq(_imdOf(PAYOUT), pending + more, "later sweep fine");
    }

    function test_sweepCannotBeNestedInsideAnotherUnlock() public {
        pm.swap(key, _params(1, 1_000e18));
        NestedUnlocker n = new NestedUnlocker(pm, hook);
        n.run();
        assertTrue(
            keccak256(n.innerRevert()) == keccak256(abi.encodeWithSelector(MockPoolManager.AlreadyUnlocked.selector)),
            "unlock inside unlock rejected"
        );
        assertEq(_imdOf(PAYOUT), 0, "nothing moved");
        assertTrue(hook.pending() > 0, "claims intact");
        hook.sweep(); // guard was reset by the revert
        assertEq(hook.pending(), 0, "sweep works afterwards");
    }

    function test_unlockCallbackOutsideSweepIsRejected() public {
        pm.swap(key, _params(1, 1_000e18));
        // Even the PoolManager cannot drive unlockCallback unless sweep() is in progress.
        vm.prank(address(pm));
        vm.expectRevert(abi.encodeWithSelector(MoneyBackHook.Reentrancy.selector));
        hook.unlockCallback("");
        assertTrue(hook.pending() > 0, "untouched");
    }

    function test_sweepRevertsCleanlyIfTakeFails() public {
        pm.swap(key, _params(1, 1_000e18));
        // Drain the manager's IMD so take() cannot pay: sweep reverts, claims and guard state survive.
        vm.prank(address(pm));
        MockIMD(IMD_ADDR).transfer(address(0xD15C), PM_IMD);
        uint256 pending = hook.pending();
        vm.expectRevert();
        hook.sweep();
        assertEq(hook.pending(), pending, "claims untouched after failed sweep");
        MockIMD(IMD_ADDR).mint(address(pm), pending);
        hook.sweep();
        assertEq(_imdOf(PAYOUT), pending, "sweep recovers once the manager can pay");
    }

    // ---------------------------------------------------------------------------------------------
    // invariants over random swap / sweep / warp sequences
    // ---------------------------------------------------------------------------------------------

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 40
    function invariant_hookNeverHoldsMoneybackClaims() public view {
        assertEq(pm.balanceOf(address(hook), _tokenId()), 0, "MONEYBACK claims");
        assertEq(handler.maxTokenSideHookDelta(), 0, "hook delta on MONEYBACK side");
        assertEq(token.balanceOf(address(hook)), 0, "MONEYBACK ERC-20 in hook");
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 40
    function invariant_pendingEqualsAccruedMinusSwept() public view {
        assertEq(hook.pending(), handler.accrued() - handler.swept(), "pending != accrued - swept");
        assertEq(pm.balanceOf(address(hook), _imdId()), hook.pending(), "pending == claim balance");
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 40
    function invariant_sweepPaysOnlyPayout() public view {
        assertEq(_imdOf(PAYOUT), handler.swept(), "payout got exactly what was swept");
        assertEq(_imdOf(address(pm)), PM_IMD - handler.swept(), "manager paid only the swept amount");
        assertEq(_imdOf(address(hook)), 0, "hook holds no IMD");
        assertEq(_imdOf(address(handler)), 0, "caller holds no IMD");
        assertEq(MockIMD(IMD_ADDR).totalSupply(), PM_IMD, "no IMD created");
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 40
    function invariant_lpFeeNeverOverriddenAndManagerLocked() public view {
        assertEq(handler.lpFeeOverrides(), 0, "LP fee override returned");
        assertTrue(!pm.unlocked(), "manager left unlocked");
        assertEq(hook.initializedAt(), T0, "binding never changes");
        assertEq(hook.payout(), PAYOUT, "payout never changes");
    }
}
