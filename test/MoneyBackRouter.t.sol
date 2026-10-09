// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MoneyBackRouter, IRouterPoolManager} from "src/MoneyBackRouter.sol";
import {
    MoneyBackHook,
    Hooks,
    IHooks,
    IPoolManager,
    IUnlockCallback,
    PoolKey,
    SwapParams,
    Currency,
    BalanceDelta,
    BeforeSwapDelta
} from "src/MoneyBackHook.sol";
import {MoneyBackToken} from "src/MoneyBackToken.sol";

// No forge-std is vendored and the test paths may not add a lib/, so this suite talks to the
// Foundry cheatcode address through the minimal interface below. A failing assertion reverts.
interface VmRouter {
    function prank(address) external;
    function startPrank(address) external;
    function stopPrank() external;
    function warp(uint256) external;
    function etch(address, bytes calldata) external;
    function deal(address, uint256) external;
    function expectRevert(bytes calldata) external;
    function expectRevert() external;
    function expectEmit(bool, bool, bool, bool) external;
}

interface IERC20Min {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

address constant IMD_ADDR = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
uint160 constant HOOK_FLAGS = 0x20CC;
uint160 constant MIN_LIMIT = 4_295_128_740;
uint160 constant MAX_LIMIT = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_341;

function amount0Of(BalanceDelta d) pure returns (int256 a) {
    assembly ("memory-safe") {
        a := sar(128, d)
    }
}

function amount1Of(BalanceDelta d) pure returns (int256 a) {
    assembly ("memory-safe") {
        a := signextend(15, d)
    }
}

// =================================================================================================
// IMD stand-in (etched at the hardcoded IMD address; no immutables so the runtime code is etchable)
// =================================================================================================

contract MockImdToken {
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "IMD: balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

// =================================================================================================
// PoolManager stand-in with two pools
// =================================================================================================

/// @dev Reproduces the parts of Uniswap v4 PoolManager the router and the hook depend on:
///      - unlock / unlockCallback with AlreadyUnlocked and v4's non-zero delta count check at the
///        end (CurrencyNotSettled): every account must have settled every currency it touched;
///      - sync / settle exactly as v4 documents them: sync(native) resets the synced currency and
///        settle{value} is then credited as ETH; sync(erc20) snapshots reserves and settle credits
///        the balance difference;
///      - take (native or ERC-20, pays real value out), ERC-6909 mint / burn / balanceOf, all only
///        while unlocked, each moving the caller's delta;
///      - initialize: calls beforeInitialize on the key's hook (or nothing for a hookless key);
///      - swap: exact input only (all the router ever does), constant-price pool with a configurable
///        rate charging the key's LP fee on the input, an optional per-pool input cap that models a
///        partial fill (price limit / liquidity exhausted), and the hook delta flow of v4's
///        Hooks.beforeSwap / afterSwap for a hooked key.
///      Misbehaviour switches let tests drive the router's defensive paths (tampered or skipped callback).
contract TwoPoolManager is IRouterPoolManager {
    error AlreadyUnlocked();
    error ManagerLocked();
    error CurrencyNotSettled(uint256 nonzeroDeltaCount);
    error SwapAmountCannotBeZero();
    error ExactInputOnly();
    error PoolNotInitialized();
    error PoolAlreadyInitialized();
    error HookDeltaExceedsSwapAmount();
    error InvalidHookResponse();
    error NonzeroNativeValue();
    error NativeTransferFailed();

    struct Pool {
        bool initialized;
        uint24 fee;
        uint256 num; // 1 unit of currency0 buys num/den units of currency1 (before fees)
        uint256 den;
        uint256 cap; // max input the pool consumes per swap; 0 = unlimited
        address hooks;
    }

    struct SwapLog {
        bytes32 poolId;
        address sender;
        bool zeroForOne;
        int256 amountSpecified;
        uint160 limit;
        uint256 hookDataLength;
        int256 swapper0;
        int256 swapper1;
        int256 hook0;
        int256 hook1;
    }

    mapping(bytes32 => Pool) public pools;
    mapping(address owner => mapping(uint256 id => uint256)) public balanceOf;
    mapping(address account => mapping(address currency => int256)) public currencyDelta;
    uint256 public nonzeroDeltaCount;
    bool public unlocked;
    SwapLog[] public swapLogs;

    address private _syncedCurrency; // address(0) = native (v4's reset state)
    uint256 private _syncedReserves;

    bool public tamperCallback;
    bool public skipCallback;

    // ------------------------------------------------------------------ test configuration

    function poolIdOf(PoolKey memory key) public pure returns (bytes32) {
        return keccak256(abi.encode(key));
    }

    function setRate(bytes32 id, uint256 num, uint256 den) external {
        pools[id].num = num;
        pools[id].den = den;
    }

    function setCap(bytes32 id, uint256 cap) external {
        pools[id].cap = cap;
    }

    function capOf(bytes32 id) external view returns (uint256) {
        return pools[id].cap;
    }

    function setTamper(bool v) external {
        tamperCallback = v;
    }

    function setSkip(bool v) external {
        skipCallback = v;
    }

    function swapLogCount() external view returns (uint256) {
        return swapLogs.length;
    }

    function lastSwap() external view returns (SwapLog memory) {
        return swapLogs[swapLogs.length - 1];
    }

    // ------------------------------------------------------------------ v4 surface

    function initialize(PoolKey memory key, uint160 sqrtPriceX96) external {
        bytes32 id = poolIdOf(key);
        if (pools[id].initialized) revert PoolAlreadyInitialized();
        if (address(key.hooks) != address(0)) {
            bytes4 sel = key.hooks.beforeInitialize(msg.sender, key, sqrtPriceX96);
            if (sel != IHooks.beforeInitialize.selector) revert InvalidHookResponse();
        }
        pools[id] = Pool({initialized: true, fee: key.fee, num: 1, den: 1, cap: 0, hooks: address(key.hooks)});
    }

    function unlock(bytes calldata data) external returns (bytes memory result) {
        if (unlocked) revert AlreadyUnlocked();
        unlocked = true;
        if (skipCallback) {
            result = abi.encode(uint256(0), uint256(0), uint256(0));
        } else if (tamperCallback) {
            result = IUnlockCallback(msg.sender).unlockCallback(abi.encodePacked(data, bytes1(0x01)));
        } else {
            result = IUnlockCallback(msg.sender).unlockCallback(data);
        }
        if (nonzeroDeltaCount != 0) revert CurrencyNotSettled(nonzeroDeltaCount);
        unlocked = false;
    }

    function sync(Currency currency) external {
        address c = Currency.unwrap(currency);
        if (c == address(0)) {
            _syncedCurrency = address(0);
            _syncedReserves = 0;
        } else {
            _syncedCurrency = c;
            _syncedReserves = IERC20Min(c).balanceOf(address(this));
        }
    }

    function settle() external payable returns (uint256 paid) {
        if (!unlocked) revert ManagerLocked();
        address c = _syncedCurrency;
        if (c == address(0)) {
            paid = msg.value;
        } else {
            if (msg.value > 0) revert NonzeroNativeValue();
            paid = IERC20Min(c).balanceOf(address(this)) - _syncedReserves;
            _syncedCurrency = address(0);
            _syncedReserves = 0;
        }
        _accountDelta(c, int256(paid), msg.sender);
    }

    function take(Currency currency, address to, uint256 amount) external {
        if (!unlocked) revert ManagerLocked();
        address c = Currency.unwrap(currency);
        _accountDelta(c, -int256(amount), msg.sender);
        if (c == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert NativeTransferFailed();
        } else {
            require(IERC20Min(c).transfer(to, amount), "mock: take transfer");
        }
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

    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData)
        external
        returns (BalanceDelta)
    {
        if (!unlocked) revert ManagerLocked();
        if (params.amountSpecified == 0) revert SwapAmountCannotBeZero();
        if (params.amountSpecified > 0) revert ExactInputOnly();
        bytes32 id = poolIdOf(key);
        Pool memory pool = pools[id];
        if (!pool.initialized) revert PoolNotInitialized();

        swapLogs.push();
        SwapLog storage log = swapLogs[swapLogs.length - 1];
        log.poolId = id;
        log.sender = msg.sender;
        log.zeroForOne = params.zeroForOne;
        log.amountSpecified = params.amountSpecified;
        log.limit = params.sqrtPriceLimitX96;
        log.hookDataLength = hookData.length;

        (int256 hookSpecified, int256 hookUnspecified, int256 amountToSwap) = _before(key, params, hookData, pool.hooks);
        (int256 pool0, int256 pool1) = _pool(pool, params.zeroForOne, uint256(-amountToSwap));
        hookUnspecified += _after(key, params, hookData, pool.hooks, pool0, pool1);
        // Exact input: the specified currency is the input currency.
        (log.hook0, log.hook1) = params.zeroForOne ? (hookSpecified, hookUnspecified) : (hookUnspecified, hookSpecified);
        log.swapper0 = pool0 - log.hook0;
        log.swapper1 = pool1 - log.hook1;
        _settleSwap(key, log, pool.hooks);
        return _toBalanceDelta(log.swapper0, log.swapper1);
    }

    function _before(PoolKey memory key, SwapParams memory params, bytes calldata hookData, address hooks)
        internal
        returns (int256 hookSpecified, int256 hookUnspecified, int256 amountToSwap)
    {
        amountToSwap = params.amountSpecified;
        if (hooks == address(0)) return (0, 0, amountToSwap);
        (bytes4 sel, BeforeSwapDelta bsd,) = key.hooks.beforeSwap(msg.sender, key, params, hookData);
        if (sel != IHooks.beforeSwap.selector) revert InvalidHookResponse();
        hookSpecified = amount0Of(BalanceDelta.wrap(BeforeSwapDelta.unwrap(bsd)));
        hookUnspecified = amount1Of(BalanceDelta.wrap(BeforeSwapDelta.unwrap(bsd)));
        if (hookSpecified != 0) {
            amountToSwap += hookSpecified;
            if (amountToSwap > 0) revert HookDeltaExceedsSwapAmount();
        }
    }

    function _after(
        PoolKey memory key,
        SwapParams memory params,
        bytes calldata hookData,
        address hooks,
        int256 pool0,
        int256 pool1
    ) internal returns (int256) {
        if (hooks == address(0)) return 0;
        (bytes4 sel, int128 afterUnspecified) =
            key.hooks.afterSwap(msg.sender, key, params, _toBalanceDelta(pool0, pool1), hookData);
        if (sel != IHooks.afterSwap.selector) revert InvalidHookResponse();
        return afterUnspecified;
    }

    function _settleSwap(PoolKey memory key, SwapLog storage log, address hooks) internal {
        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        if (hooks != address(0)) {
            _accountDelta(c0, log.hook0, hooks);
            _accountDelta(c1, log.hook1, hooks);
        }
        _accountDelta(c0, log.swapper0, msg.sender);
        _accountDelta(c1, log.swapper1, msg.sender);
    }

    // ------------------------------------------------------------------ internals

    /// @dev Constant-price pool charging `fee` pips on the input, consuming at most `cap` input.
    function _pool(Pool memory pool, bool zeroForOne, uint256 inAmt) internal pure returns (int256 a0, int256 a1) {
        if (pool.cap != 0 && inAmt > pool.cap) inAmt = pool.cap;
        uint256 net = inAmt * (1_000_000 - uint256(pool.fee)) / 1_000_000;
        uint256 outAmt = zeroForOne ? net * pool.num / pool.den : net * pool.den / pool.num;
        if (zeroForOne) {
            a0 = -int256(inAmt);
            a1 = int256(outAmt);
        } else {
            a0 = int256(outAmt);
            a1 = -int256(inAmt);
        }
    }

    function _accountDelta(address currency, int256 delta, address account) internal {
        if (delta == 0) return;
        int256 cur = currencyDelta[account][currency];
        int256 next = cur + delta;
        if (cur == 0 && next != 0) nonzeroDeltaCount++;
        if (cur != 0 && next == 0) nonzeroDeltaCount--;
        currencyDelta[account][currency] = next;
    }

    function _toBalanceDelta(int256 a0, int256 a1) internal pure returns (BalanceDelta d) {
        assembly ("memory-safe") {
            d := or(shl(128, a0), and(sub(shl(128, 1), 1), a1))
        }
    }
}

// =================================================================================================
// Helper contracts
// =================================================================================================

/// @dev A "hook" whose launchToken() is zero: the router constructor must refuse it.
contract ZeroTokenHook {
    function launchToken() external pure returns (address) {
        return address(0);
    }
}

/// @dev Buys MONEYBACK with IMD directly on our pool (no router), the way any v4 integrator would:
///      exact-input swap, settle the IMD, take the MONEYBACK. Used to prove the router pays the
///      hook exactly what a direct IMD buy pays.
contract DirectBuyer is IUnlockCallback {
    TwoPoolManager public pm;
    PoolKey public key;
    bool public imdIs0;
    address public token;

    constructor(TwoPoolManager _pm, PoolKey memory _key, bool _imdIs0, address _token) {
        pm = _pm;
        key = _key;
        imdIs0 = _imdIs0;
        token = _token;
    }

    function buy(uint256 imdIn) external returns (uint256 tokensOut) {
        tokensOut = abi.decode(pm.unlock(abi.encode(imdIn)), (uint256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(pm), "direct: not pm");
        uint256 imdIn = abi.decode(data, (uint256));
        BalanceDelta d = pm.swap(
            key,
            SwapParams({
                zeroForOne: imdIs0, amountSpecified: -int256(imdIn), sqrtPriceLimitX96: imdIs0 ? MIN_LIMIT : MAX_LIMIT
            }),
            ""
        );
        int256 tokDelta = imdIs0 ? amount1Of(d) : amount0Of(d);
        int256 imdDelta = imdIs0 ? amount0Of(d) : amount1Of(d);
        pm.sync(Currency.wrap(IMD_ADDR));
        MockImdToken(IMD_ADDR).transfer(address(pm), uint256(-imdDelta));
        pm.settle();
        pm.take(Currency.wrap(token), address(this), uint256(tokDelta));
        return abi.encode(uint256(tokDelta));
    }
}

/// @dev Trades through the router and, from inside the ETH it receives back (dust refund on a buy,
///      proceeds on a sell), tries to reenter the router. Records what the nested call did and never
///      reverts itself, so the outer call's own outcome is observable.
contract Reenterer {
    MoneyBackRouter public router;
    MoneyBackToken public token;
    uint8 public mode; // 0 none, 1 buyWithEth, 2 sellForEth, 3 quoteBuy, 4 quoteSell, 5 unlockCallback, 6 plain ETH
    uint256 public received;
    bool public nestedReverted;
    bytes public nestedReason;

    constructor(MoneyBackRouter _router, MoneyBackToken _token) {
        router = _router;
        token = _token;
    }

    function setMode(uint8 m) external {
        mode = m;
    }

    function buy(uint256 minOut, uint256 deadline) external payable returns (uint256) {
        return router.buyWithEth{value: msg.value}(minOut, deadline);
    }

    function sell(uint256 tokens, uint256 minOut, uint256 deadline) external returns (uint256) {
        token.approve(address(router), tokens);
        return router.sellForEth(tokens, minOut, deadline);
    }

    receive() external payable {
        received += msg.value;
        if (mode == 0) return;
        bytes memory data;
        uint256 value;
        if (mode == 1) {
            data = abi.encodeCall(MoneyBackRouter.buyWithEth, (0, block.timestamp));
            value = 1;
        } else if (mode == 2) {
            data = abi.encodeCall(MoneyBackRouter.sellForEth, (1, 0, block.timestamp));
        } else if (mode == 3) {
            data = abi.encodeCall(MoneyBackRouter.quoteBuy, (1));
        } else if (mode == 4) {
            data = abi.encodeCall(MoneyBackRouter.quoteSell, (1));
        } else if (mode == 5) {
            data = abi.encodeCall(MoneyBackRouter.unlockCallback, (bytes("")));
        } else {
            value = 1;
        }
        (bool ok, bytes memory ret) = address(router).call{value: value}(data);
        nestedReverted = !ok;
        nestedReason = ret;
    }
}

/// @dev A trader contract with no receive(): cannot be paid ETH.
contract NoReceive {
    MoneyBackRouter public router;
    MoneyBackToken public token;

    constructor(MoneyBackRouter _router, MoneyBackToken _token) {
        router = _router;
        token = _token;
    }

    function buy(uint256 minOut, uint256 deadline) external payable returns (uint256) {
        return router.buyWithEth{value: msg.value}(minOut, deadline);
    }

    function sell(uint256 tokens, uint256 minOut, uint256 deadline) external returns (uint256) {
        token.approve(address(router), tokens);
        return router.sellForEth(tokens, minOut, deadline);
    }
}

// =================================================================================================
// Shared fixture
// =================================================================================================

abstract contract RouterFixture {
    VmRouter constant vm = VmRouter(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint256 constant BPS = 10_000;
    uint256 constant BASE = 425;
    uint256 constant PIPS = 1_000_000;
    uint24 constant LAUNCH_FEE = 12_500;
    int24 constant LAUNCH_TICK = 60;
    uint24 constant PUBLIC_FEE = 10_000;
    int24 constant PUBLIC_TICK = 100;
    uint256 constant T0 = 1_750_000_000;
    uint256 constant RATE = 1000; // IMD per ETH on the public pool
    uint256 constant PM_ETH = 1e30;
    uint256 constant PM_IMD = 1e36;
    uint256 constant PM_TOKENS = 500_000_000e18;
    address constant PAYOUT = address(0x9A70);
    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);

    TwoPoolManager pm;
    MoneyBackToken token;
    MoneyBackHook hook;
    MoneyBackRouter router;
    PoolKey launchKey;
    PoolKey publicKey;
    bytes32 launchId;
    bytes32 publicId;
    bool imdIs0;

    struct BuyMath {
        uint256 ethUsed;
        uint256 imdOut;
        uint256 fee;
        uint256 imdMid;
        uint256 tokensOut;
        uint256 imdDust;
    }

    struct SellMath {
        uint256 tokensUsed;
        uint256 poolImd;
        uint256 fee;
        uint256 imdOut;
        uint256 imdUsed;
        uint256 ethOut;
        uint256 imdDust;
        uint256 tokenDust;
    }

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

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    // ------------------------------------------------------------------ deployment

    function _deployHook(address manager, address launchToken, address payout, uint160 flags)
        internal
        returns (MoneyBackHook h)
    {
        bytes32 initHash = keccak256(
            abi.encodePacked(type(MoneyBackHook).creationCode, abi.encode(manager, launchToken, payout))
        );
        for (uint256 salt = 0; salt < 1_000_000; ++salt) {
            address a = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(salt), initHash))))
            );
            if ((uint160(a) & Hooks.ALL_HOOK_MASK) == flags && a.code.length == 0) {
                return new MoneyBackHook{salt: bytes32(salt)}(IPoolManager(manager), launchToken, payout);
            }
        }
        revert("salt mining failed");
    }

    function _makeLaunchKey(bool imdFirst, address hooks) internal view returns (PoolKey memory k) {
        k.currency0 = Currency.wrap(imdFirst ? IMD_ADDR : address(token));
        k.currency1 = Currency.wrap(imdFirst ? address(token) : IMD_ADDR);
        k.fee = LAUNCH_FEE;
        k.tickSpacing = LAUNCH_TICK;
        k.hooks = IHooks(hooks);
    }

    /// @dev Everything except initializing our pool: IMD etched, PoolManager funded with ETH, IMD and
    ///      MONEYBACK, hook deployed with mined flag bits, router deployed, public pool initialized at
    ///      1 ETH = RATE IMD, traders funded.
    function _setUpUnbound() internal {
        vm.etch(IMD_ADDR, address(new MockImdToken()).code);
        pm = new TwoPoolManager();
        vm.deal(address(pm), PM_ETH);
        MockImdToken(IMD_ADDR).mint(address(pm), PM_IMD);
        token = new MoneyBackToken();
        token.transfer(address(pm), PM_TOKENS);
        hook = _deployHook(address(pm), address(token), PAYOUT, HOOK_FLAGS);
        router = new MoneyBackRouter(IPoolManager(address(pm)), address(hook));
        publicKey = router.publicPoolKey();
        publicId = pm.poolIdOf(publicKey);
        vm.warp(T0);
        pm.initialize(publicKey, 1 << 96);
        pm.setRate(publicId, RATE, 1);
        vm.deal(ALICE, 1_000_000 ether);
        vm.deal(BOB, 1_000_000 ether);
        token.transfer(ALICE, 10_000_000e18);
        token.transfer(BOB, 10_000_000e18);
    }

    function _setUp(bool imdFirst) internal {
        _setUpUnbound();
        imdIs0 = imdFirst;
        launchKey = _makeLaunchKey(imdFirst, address(hook));
        launchId = pm.poolIdOf(launchKey);
        pm.initialize(launchKey, 1 << 96);
    }

    // ------------------------------------------------------------------ expected amounts

    /// @dev What a buy of `ethIn` must do, given the mock pools' rates, LP fees, caps and the hook's
    ///      exact-input buy rule (fee = floor(IMD offered * 425 / 10_000), taken before the pool swaps).
    function _buyMath(uint256 ethIn) internal view returns (BuyMath memory q) {
        uint256 capPub = pm.capOf(publicId);
        uint256 capL = pm.capOf(launchId);
        q.ethUsed = capPub != 0 ? _min(ethIn, capPub) : ethIn;
        q.imdOut = q.ethUsed * (PIPS - PUBLIC_FEE) / PIPS * RATE;
        if (q.imdOut == 0) return q;
        q.fee = q.imdOut * BASE / BPS;
        uint256 poolIn = q.imdOut - q.fee;
        if (capL != 0) poolIn = _min(poolIn, capL);
        q.tokensOut = poolIn * (PIPS - LAUNCH_FEE) / PIPS;
        q.imdMid = poolIn + q.fee;
        q.imdDust = q.imdOut - q.imdMid;
    }

    /// @dev What a sell of `tokens` must do right now (surcharge read from the hook).
    function _sellMath(uint256 tokens) internal view returns (SellMath memory q) {
        uint256 capPub = pm.capOf(publicId);
        uint256 capL = pm.capOf(launchId);
        q.tokensUsed = capL != 0 ? _min(tokens, capL) : tokens;
        q.poolImd = q.tokensUsed * (PIPS - LAUNCH_FEE) / PIPS;
        q.fee = q.poolImd * BASE / BPS + q.poolImd * hook.currentSurchargeBps() / BPS;
        q.imdOut = q.poolImd - q.fee;
        q.tokenDust = tokens - q.tokensUsed;
        if (q.imdOut == 0) return q;
        q.imdUsed = capPub != 0 ? _min(q.imdOut, capPub) : q.imdOut;
        q.ethOut = q.imdUsed * (PIPS - PUBLIC_FEE) / PIPS / RATE;
        q.imdDust = q.imdOut - q.imdUsed;
    }

    // ------------------------------------------------------------------ balances

    function _imdOf(address a) internal view returns (uint256) {
        return MockImdToken(IMD_ADDR).balanceOf(a);
    }

    function _claims(address a, address currency) internal view returns (uint256) {
        return pm.balanceOf(a, uint256(uint160(currency)));
    }

    /// @dev The router holds nothing: no ETH, IMD or MONEYBACK, no claims, no open deltas.
    function _assertRouterEmpty() internal view {
        assertEq(address(router).balance, 0, "router holds ETH");
        assertEq(_imdOf(address(router)), 0, "router holds IMD");
        assertEq(token.balanceOf(address(router)), 0, "router holds MONEYBACK");
        assertEq(_claims(address(router), address(0)), 0, "router holds ETH claims");
        assertEq(_claims(address(router), IMD_ADDR), 0, "router holds IMD claims");
        assertEq(_claims(address(router), address(token)), 0, "router holds MONEYBACK claims");
        assertEq(pm.currencyDelta(address(router), address(0)), 0, "open ETH delta");
        assertEq(pm.currencyDelta(address(router), IMD_ADDR), 0, "open IMD delta");
        assertEq(pm.currencyDelta(address(router), address(token)), 0, "open MONEYBACK delta");
        assertEq(pm.nonzeroDeltaCount(), 0, "manager has unsettled deltas");
        assertTrue(!pm.unlocked(), "manager left unlocked");
        assertEq(token.allowance(address(router), address(pm)), 0, "router approved the manager");
    }

    function _buyAs(address who, uint256 ethIn, uint256 minOut, uint256 deadline) internal returns (uint256) {
        vm.prank(who);
        return router.buyWithEth{value: ethIn}(minOut, deadline);
    }

    function _sellAs(address who, uint256 tokens, uint256 minOut, uint256 deadline) internal returns (uint256 out) {
        vm.startPrank(who);
        token.approve(address(router), tokens);
        out = router.sellForEth(tokens, minOut, deadline);
        vm.stopPrank();
    }

    /// @dev Like _sellAs but expects the SoldForEth event (the approval is done before the expectation is armed).
    function _sellExpectingEvent(address who, uint256 tokens, uint256 tokensIn, uint256 imdOut, uint256 ethOut)
        internal
        returns (uint256 out)
    {
        vm.startPrank(who);
        token.approve(address(router), tokens);
        vm.expectEmit(true, false, false, true);
        emit SoldForEth(who, tokensIn, imdOut, ethOut);
        out = router.sellForEth(tokens, ethOut, block.timestamp);
        vm.stopPrank();
    }

    event SoldForEth(address indexed seller, uint256 tokensIn, uint256 imdOut, uint256 ethOut);
}

// =================================================================================================
// Invariant handler
// =================================================================================================

contract RouterHandler is RouterFixture {
    address[] public actors;
    uint256 public feesAccrued; // hook fees the router's trades caused
    uint256 public swept;
    uint256 public buysOk;
    uint256 public sellsOk;
    uint256 public buysReverted;
    uint256 public sellsReverted;
    uint256 public quotes;

    constructor(
        TwoPoolManager _pm,
        MoneyBackToken _token,
        MoneyBackHook _hook,
        MoneyBackRouter _router,
        PoolKey memory _launchKey,
        PoolKey memory _publicKey,
        bool _imdIs0,
        address[] memory _actors
    ) {
        pm = _pm;
        token = _token;
        hook = _hook;
        router = _router;
        launchKey = _launchKey;
        publicKey = _publicKey;
        launchId = pm.poolIdOf(_launchKey);
        publicId = pm.poolIdOf(_publicKey);
        imdIs0 = _imdIs0;
        actors = _actors;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    /// @dev Random partial-fill caps: none a quarter of the time, otherwise up to 20 ETH / 20_000 IMD
    ///      on the public pool (ETH is its input on a buy, IMD on a sell) and 20_000 on our pool.
    function _caps(uint256 capPub, uint256 capL, bool isBuy) internal {
        pm.setCap(publicId, capPub % 4 == 0 ? 0 : capPub % (isBuy ? 20e18 : 20_000e18));
        pm.setCap(launchId, capL % 4 == 0 ? 0 : capL % 20_000e18);
    }

    function buy(uint256 who, uint256 ethIn, uint8 minMode, uint8 deadlineMode, uint256 capPub, uint256 capL) external {
        address a = _actor(who);
        ethIn = ethIn % (1_000 ether + 1); // 0 included
        _caps(capPub, capL, true);
        BuyMath memory q = _buyMath(ethIn);
        uint256 minOut = minMode % 3 == 0 ? 0 : (minMode % 3 == 1 ? q.tokensOut : q.tokensOut + 1);
        uint256 deadline = deadlineMode % 4 == 0 ? block.timestamp - 1 : block.timestamp + deadlineMode;
        uint256 ethBefore = a.balance;
        uint256 tokBefore = token.balanceOf(a);
        uint256 imdBefore = _imdOf(a);
        vm.prank(a);
        try router.buyWithEth{value: ethIn}(minOut, deadline) returns (uint256 out) {
            require(
                ethIn != 0 && q.tokensOut != 0 && minOut <= q.tokensOut && deadline >= block.timestamp,
                "buy should have reverted"
            );
            require(out == q.tokensOut, "buy: out != expected");
            require(token.balanceOf(a) == tokBefore + q.tokensOut, "buy: tokens");
            require(a.balance == ethBefore - q.ethUsed, "buy: eth spent");
            require(_imdOf(a) == imdBefore + q.imdDust, "buy: imd dust");
            feesAccrued += q.fee;
            buysOk++;
        } catch {
            require(
                ethIn == 0 || q.tokensOut == 0 || minOut > q.tokensOut || deadline < block.timestamp,
                "buy reverted unexpectedly"
            );
            require(
                a.balance == ethBefore && token.balanceOf(a) == tokBefore && _imdOf(a) == imdBefore,
                "buy: revert changed balances"
            );
            buysReverted++;
        }
    }

    function sell(uint256 who, uint256 tokens, uint8 minMode, uint8 deadlineMode, uint256 capPub, uint256 capL)
        external
    {
        address a = _actor(who);
        tokens = tokens % (token.balanceOf(a) + 1); // 0 included
        _caps(capPub, capL, false);
        SellMath memory q = _sellMath(tokens);
        uint256 minOut = minMode % 3 == 0 ? 0 : (minMode % 3 == 1 ? q.ethOut : q.ethOut + 1);
        uint256 deadline = deadlineMode % 4 == 0 ? block.timestamp - 1 : block.timestamp + deadlineMode;
        uint256 ethBefore = a.balance;
        uint256 tokBefore = token.balanceOf(a);
        uint256 imdBefore = _imdOf(a);
        vm.startPrank(a);
        token.approve(address(router), tokens);
        try router.sellForEth(tokens, minOut, deadline) returns (uint256 out) {
            require(
                tokens != 0 && q.ethOut != 0 && minOut <= q.ethOut && deadline >= block.timestamp,
                "sell should have reverted"
            );
            require(out == q.ethOut, "sell: out != expected");
            require(a.balance == ethBefore + q.ethOut, "sell: eth");
            require(token.balanceOf(a) == tokBefore - q.tokensUsed, "sell: tokens");
            require(_imdOf(a) == imdBefore + q.imdDust, "sell: imd dust");
            feesAccrued += q.fee;
            sellsOk++;
        } catch {
            require(
                tokens == 0 || q.ethOut == 0 || minOut > q.ethOut || deadline < block.timestamp,
                "sell reverted unexpectedly"
            );
            require(
                a.balance == ethBefore && token.balanceOf(a) == tokBefore && _imdOf(a) == imdBefore,
                "sell: revert changed balances"
            );
            sellsReverted++;
        }
        token.approve(address(router), 0);
        vm.stopPrank();
    }

    function quote(uint256 who, uint256 amount, bool isBuy, uint256 capPub, uint256 capL) external {
        address a = _actor(who);
        _caps(capPub, capL, isBuy);
        uint256 pendingBefore = hook.pending();
        vm.prank(a);
        if (isBuy) {
            amount = amount % (1_000 ether + 1);
            uint256 out = router.quoteBuy(amount);
            require(out == _buyMath(amount).tokensOut, "quoteBuy != formula");
        } else {
            amount = amount % (1_000_000e18 + 1);
            uint256 out = router.quoteSell(amount);
            require(out == _sellMath(amount).ethOut, "quoteSell != formula");
        }
        require(hook.pending() == pendingBefore, "quote changed hook state");
        quotes++;
    }

    function sweep(uint256 who) external {
        uint256 pending = hook.pending();
        vm.prank(_actor(who));
        hook.sweep();
        swept += pending;
    }

    function warp(uint32 by) external {
        vm.warp(block.timestamp + (by % 4000));
    }
}

// =================================================================================================
// Tests
// =================================================================================================

contract MoneyBackRouterTest is RouterFixture {
    event BoughtWithEth(address indexed buyer, uint256 ethIn, uint256 imdIn, uint256 tokensOut);

    RouterHandler handler;
    address[] private _targets;
    uint256 private _initialEth;
    uint256 private _initialTokens;

    function setUp() public {
        _setUp(true);
        address[] memory actors = new address[](3);
        actors[0] = ALICE;
        actors[1] = BOB;
        actors[2] = address(0xCA51);
        vm.deal(actors[2], 1_000_000 ether);
        token.transfer(actors[2], 10_000_000e18);
        handler = new RouterHandler(pm, token, hook, router, launchKey, publicKey, imdIs0, actors);
        _targets.push(address(handler));
        _initialEth = address(pm).balance + ALICE.balance + BOB.balance + actors[2].balance;
        _initialTokens =
            token.balanceOf(address(pm)) + token.balanceOf(ALICE) + token.balanceOf(BOB) + token.balanceOf(actors[2]);
    }

    function targetContracts() external view returns (address[] memory) {
        return _targets;
    }

    // ---------------------------------------------------------------------------------------------
    // constructor and views
    // ---------------------------------------------------------------------------------------------

    function test_constructorStoresImmutablesFromHook() public view {
        assertEq(address(router.poolManager()), address(pm), "poolManager");
        assertEq(address(router.hook()), address(hook), "hook");
        assertEq(router.token(), address(token), "token read from hook.launchToken()");
        assertEq(router.IMD(), IMD_ADDR, "IMD constant");
        assertEq(uint256(router.PUBLIC_POOL_FEE()), 10_000, "public fee");
        assertEq(uint256(int256(router.PUBLIC_POOL_TICK_SPACING())), 100, "public tick spacing");
    }

    function test_publicPoolKeyIsHardcoded() public view {
        PoolKey memory k = router.publicPoolKey();
        assertEq(Currency.unwrap(k.currency0), address(0), "currency0 = native ETH");
        assertEq(Currency.unwrap(k.currency1), IMD_ADDR, "currency1 = IMD");
        assertEq(uint256(k.fee), 10_000, "fee 10000");
        assertEq(uint256(int256(k.tickSpacing)), 100, "tickSpacing 100");
        assertEq(address(k.hooks), address(0), "no hook");
    }

    function test_launchPoolKeyComesFromHook() public view {
        PoolKey memory k = router.launchPoolKey();
        assertEq(Currency.unwrap(k.currency0), Currency.unwrap(launchKey.currency0), "currency0");
        assertEq(Currency.unwrap(k.currency1), Currency.unwrap(launchKey.currency1), "currency1");
        assertEq(uint256(k.fee), 12_500, "fee");
        assertEq(uint256(int256(k.tickSpacing)), 60, "tickSpacing");
        assertEq(address(k.hooks), address(hook), "hooks");
    }

    function test_constructorRejectsZeroAddresses() public {
        vm.expectRevert(abi.encodeWithSelector(MoneyBackRouter.ZeroAddress.selector));
        new MoneyBackRouter(IPoolManager(address(0)), address(hook));
        vm.expectRevert(abi.encodeWithSelector(MoneyBackRouter.ZeroAddress.selector));
        new MoneyBackRouter(IPoolManager(address(pm)), address(0));
        ZeroTokenHook bad = new ZeroTokenHook();
        vm.expectRevert(abi.encodeWithSelector(MoneyBackRouter.ZeroAddress.selector));
        new MoneyBackRouter(IPoolManager(address(pm)), address(bad));
        // A hook address with no code at all: launchToken() has nothing to return.
        vm.expectRevert();
        new MoneyBackRouter(IPoolManager(address(pm)), address(0xDEAD1));
    }

    function test_routerHasNoAdminSurface() public {
        bytes4[7] memory sels = [
            bytes4(keccak256("owner()")),
            bytes4(keccak256("setHook(address)")),
            bytes4(keccak256("pause()")),
            bytes4(keccak256("upgradeTo(address)")),
            bytes4(keccak256("withdraw(address,uint256)")),
            bytes4(keccak256("approve(address,uint256)")),
            bytes4(keccak256("transferOwnership(address)"))
        ];
        for (uint256 i = 0; i < sels.length; ++i) {
            (bool ok,) = address(router).call(abi.encodeWithSelector(sels[i], address(this), uint256(1)));
            assertTrue(!ok, "unexpected admin selector answered");
        }
    }

    // ---------------------------------------------------------------------------------------------
    // before our pool is bound
    // ---------------------------------------------------------------------------------------------

    function test_beforePoolBoundEverythingReverts() public {
        _setUpUnbound();
        vm.expectRevert(abi.encodeWithSelector(MoneyBackRouter.PoolNotBound.selector));
        router.launchPoolKey();
        uint256 ethBefore = ALICE.balance;
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(MoneyBackRouter.PoolNotBound.selector));
        router.buyWithEth{value: 1 ether}(0, block.timestamp);
        assertEq(ALICE.balance, ethBefore, "ETH kept");
        vm.startPrank(ALICE);
        token.approve(address(router), 1e18);
        vm.expectRevert(abi.encodeWithSelector(MoneyBackRouter.PoolNotBound.selector));
        router.sellForEth(1e18, 0, block.timestamp);
        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSelector(MoneyBackRouter.PoolNotBound.selector));
        router.quoteBuy(1 ether);
        vm.expectRevert(abi.encodeWithSelector(MoneyBackRouter.PoolNotBound.selector));
        router.quoteSell(1e18);
        _assertRouterEmpty();
        // Once the pool is bound, the same router (deployed earlier) works: no redeploy needed.
        imdIs0 = true;
        launchKey = _makeLaunchKey(true, address(hook));
        launchId = pm.poolIdOf(launchKey);
        pm.initialize(launchKey, 1 << 96);
        uint256 out = _buyAs(ALICE, 1 ether, 0, block.timestamp);
        assertEq(out, _buyMath(1 ether).tokensOut, "buy works after binding");
        _assertRouterEmpty();
    }

    // ---------------------------------------------------------------------------------------------
    // buy happy path
    // ---------------------------------------------------------------------------------------------

    function test_buyHappyPath() public {
        uint256 ethIn = 1 ether;
        BuyMath memory q = _buyMath(ethIn);
        assertTrue(q.tokensOut > 0 && q.imdDust == 0 && q.ethUsed == ethIn, "fixture: full fill");
        uint256 pendingBefore = hook.pending();
        uint256 pmEth = address(pm).balance;
        uint256 pmTok = token.balanceOf(address(pm));
        uint256 pmImd = _imdOf(address(pm));

        vm.expectEmit(true, false, false, true);
        emit BoughtWithEth(ALICE, ethIn, q.imdMid, q.tokensOut);
        uint256 out = _buyAs(ALICE, ethIn, q.tokensOut, block.timestamp + 60);

        assertEq(out, q.tokensOut, "return value");
        assertEq(token.balanceOf(ALICE), 10_000_000e18 + q.tokensOut, "buyer got MONEYBACK");
        assertEq(ALICE.balance, 1_000_000 ether - ethIn, "buyer paid all ETH");
        assertEq(_imdOf(ALICE), 0, "no IMD dust on a full fill");
        assertEq(address(pm).balance, pmEth + ethIn, "manager received the ETH");
        assertEq(token.balanceOf(address(pm)), pmTok - q.tokensOut, "manager paid the MONEYBACK");
        assertEq(_imdOf(address(pm)), pmImd, "IMD never left the manager");
        assertEq(hook.pending(), pendingBefore + q.fee, "hook accrued 4.25% of the IMD leg");
        assertEq(q.fee, q.imdOut * 425 / 10_000, "fee is 4.25% of IMD bought");
        // Concrete numbers: 1 ETH -> 990 IMD -> fee 42.075 IMD -> pool 947.925 IMD -> 1.25% LP -> 936.075937... MONEYBACK
        assertEq(q.imdOut, 990e18, "IMD after 1% public LP fee");
        assertEq(q.fee, 42_075e15, "4.25% of 990");
        assertEq(q.tokensOut, 947_925e15 * (PIPS - LAUNCH_FEE) / PIPS, "MONEYBACK out");
        _assertRouterEmpty();
    }

    function test_buySwapLegsAreExactInputWithWidestLimitsAndRouterAsSender() public {
        _buyAs(ALICE, 2 ether, 0, block.timestamp);
        assertEq(pm.swapLogCount(), 2, "two legs");
        (bytes32 id0, address s0, bool z0, int256 a0, uint160 l0, uint256 h0,,,,) = pm.swapLogs(0);
        (bytes32 id1, address s1, bool z1, int256 a1, uint160 l1, uint256 h1,,,,) = pm.swapLogs(1);
        assertTrue(id0 == publicId, "leg 1 on the public pool");
        assertEq(s0, address(router), "leg 1 sender is the router");
        assertTrue(z0, "ETH is currency0: zeroForOne");
        assertEq(a0, -int256(2 ether), "leg 1 exact input of msg.value");
        assertEq(uint256(l0), uint256(MIN_LIMIT), "leg 1 widest limit");
        assertEq(h0, 0, "leg 1 no hook data");
        assertTrue(id1 == launchId, "leg 2 on our pool");
        assertEq(s1, address(router), "the hook sees the router as the swapper");
        assertTrue(z1 == imdIs0, "IMD -> MONEYBACK direction");
        assertEq(a1, -int256(_buyMath(2 ether).imdOut), "leg 2 exact input of all IMD received");
        assertEq(uint256(l1), uint256(imdIs0 ? MIN_LIMIT : MAX_LIMIT), "leg 2 widest limit");
        assertEq(h1, 0, "leg 2 no hook data");
    }

    function test_buyTwiceAndByTwoUsers() public {
        uint256 o1 = _buyAs(ALICE, 1 ether, 0, block.timestamp);
        uint256 o2 = _buyAs(ALICE, 1 ether, 0, block.timestamp);
        uint256 o3 = _buyAs(BOB, 3 ether, 0, block.timestamp);
        assertEq(o1, o2, "constant-price mock: same output twice");
        assertEq(o3, _buyMath(3 ether).tokensOut, "bob's buy");
        assertEq(token.balanceOf(ALICE), 10_000_000e18 + o1 + o2, "alice");
        assertEq(token.balanceOf(BOB), 10_000_000e18 + o3, "bob");
        assertEq(hook.pending(), 2 * _buyMath(1 ether).fee + _buyMath(3 ether).fee, "fees add up");
        _assertRouterEmpty();
    }

    function test_buyWorksWithImdAsCurrency1() public {
        _setUp(false);
        uint256 out = _buyAs(ALICE, 1 ether, 0, block.timestamp);
        assertEq(out, _buyMath(1 ether).tokensOut, "same maths with MONEYBACK as currency0");
        (,, bool z1,,,,,,,) = pm.swapLogs(1);
        assertTrue(!z1, "IMD is currency1: oneForZero");
        uint256 ethOut = _sellAs(ALICE, out, 0, block.timestamp);
        assertEq(ethOut, _sellMath(out).ethOut, "sell maths with MONEYBACK as currency0");
        _assertRouterEmpty();
    }

    /// @notice Acceptance: buying through the router pays the hook's 4.25% exactly as a direct IMD buy.
    function test_acceptanceRouterBuyPaysHookExactlyLikeDirectImdBuy() public {
        uint256 ethIn = 7 ether + 123_456_789;
        BuyMath memory q = _buyMath(ethIn);
        uint256 p0 = hook.pending();
        uint256 viaRouter = _buyAs(ALICE, ethIn, 0, block.timestamp);
        uint256 routerFee = hook.pending() - p0;

        DirectBuyer direct = new DirectBuyer(pm, launchKey, imdIs0, address(token));
        MockImdToken(IMD_ADDR).mint(address(direct), q.imdOut);
        uint256 p1 = hook.pending();
        uint256 viaDirect = direct.buy(q.imdOut);
        uint256 directFee = hook.pending() - p1;

        assertEq(routerFee, directFee, "router buy and direct buy pay the same hook fee");
        assertEq(routerFee, q.imdOut * 425 / 10_000, "4.25% of the IMD leg");
        assertEq(viaRouter, viaDirect, "same MONEYBACK for the same IMD");
        assertEq(token.balanceOf(address(direct)), viaDirect, "direct buyer got its tokens");
        assertEq(_imdOf(address(direct)), 0, "direct buyer spent all its IMD");
    }

    // ---------------------------------------------------------------------------------------------
    // sell happy path
    // ---------------------------------------------------------------------------------------------

    function test_sellHappyPathAtT0WithSurcharge() public {
        uint256 tokens = 1_000e18;
        assertEq(hook.currentSurchargeBps(), 2000, "surcharge at t0");
        SellMath memory q = _sellMath(tokens);
        assertTrue(q.ethOut > 0 && q.imdDust == 0 && q.tokenDust == 0, "fixture: full fill");
        uint256 pendingBefore = hook.pending();
        uint256 pmEth = address(pm).balance;

        uint256 out = _sellExpectingEvent(ALICE, tokens, tokens, q.imdOut, q.ethOut);

        assertEq(out, q.ethOut, "return value");
        assertEq(ALICE.balance, 1_000_000 ether + q.ethOut, "seller got ETH");
        assertEq(token.balanceOf(ALICE), 10_000_000e18 - tokens, "seller paid MONEYBACK");
        assertEq(token.balanceOf(address(pm)), PM_TOKENS + tokens, "manager received MONEYBACK");
        assertEq(address(pm).balance, pmEth - q.ethOut, "manager paid ETH");
        assertEq(hook.pending(), pendingBefore + q.fee, "hook accrued base + surcharge");
        assertEq(token.allowance(ALICE, address(router)), 0, "allowance fully consumed");
        // 1000 MONEYBACK -> 987.5 IMD (1.25% LP) -> fee 4.25% + 20% = 239.46875 -> 748.03125 IMD -> 1% -> 740.5509375 IMD -> /1000 ETH
        assertEq(q.poolImd, 987_5e17, "IMD out of our pool");
        assertEq(q.fee, 987_5e17 * 425 / BPS + 987_5e17 * 2000 / BPS, "fee parts");
        assertEq(q.imdOut, 748_03125e13, "IMD after hook");
        assertEq(q.ethOut, 748_03125e13 * 99 / 100 / 1000, "ETH after public LP fee at 1000 IMD/ETH");
        _assertRouterEmpty();
    }

    function test_sellAfterSurchargeDecayPaysOnlyBaseFee() public {
        vm.warp(T0 + 1800);
        assertEq(hook.currentSurchargeBps(), 0, "no surcharge");
        uint256 tokens = 1_000e18;
        SellMath memory q = _sellMath(tokens);
        uint256 p0 = hook.pending();
        uint256 out = _sellAs(BOB, tokens, 0, block.timestamp);
        assertEq(out, q.ethOut, "return");
        assertEq(hook.pending() - p0, q.poolImd * 425 / BPS, "4.25% only");
        assertTrue(out > _sellMathAt(T0, tokens), "more ETH than at t0");
        _assertRouterEmpty();
    }

    function _sellMathAt(uint256 ts, uint256 tokens) internal returns (uint256 ethOut) {
        uint256 now_ = block.timestamp;
        vm.warp(ts);
        ethOut = _sellMath(tokens).ethOut;
        vm.warp(now_);
    }

    function test_sellSwapLegsAreExactInputWithWidestLimits() public {
        uint256 tokens = 500e18;
        SellMath memory q = _sellMath(tokens);
        _sellAs(ALICE, tokens, 0, block.timestamp);
        (bytes32 id0, address s0, bool z0, int256 a0, uint160 l0, uint256 h0,,,,) = pm.swapLogs(0);
        (bytes32 id1, address s1, bool z1, int256 a1, uint160 l1, uint256 h1,,,,) = pm.swapLogs(1);
        assertTrue(id0 == launchId, "leg 1 on our pool");
        assertEq(s0, address(router), "hook sees the router");
        assertTrue(z0 == !imdIs0, "MONEYBACK -> IMD direction");
        assertEq(a0, -int256(tokens), "leg 1 exact input of the tokens pulled");
        assertEq(uint256(l0), uint256(imdIs0 ? MAX_LIMIT : MIN_LIMIT), "leg 1 widest limit");
        assertEq(h0, 0, "no hook data");
        assertTrue(id1 == publicId, "leg 2 on the public pool");
        assertEq(s1, address(router), "leg 2 sender");
        assertTrue(!z1, "IMD is currency1 of the public pool: oneForZero");
        assertEq(a1, -int256(q.imdOut), "leg 2 exact input of all IMD after the hook fee");
        assertEq(uint256(l1), uint256(MAX_LIMIT), "leg 2 widest limit");
        assertEq(h1, 0, "no hook data");
    }

    function test_buyThenSellRoundTrip() public {
        uint256 bought = _buyAs(ALICE, 10 ether, 0, block.timestamp);
        vm.warp(T0 + 3600);
        uint256 ethBack = _sellAs(ALICE, bought, 0, block.timestamp);
        assertEq(ethBack, _sellMath(bought).ethOut, "sell maths");
        assertTrue(ethBack < 10 ether, "fees were paid");
        // buy 0.99 * 0.9575 * 0.9875, sell 0.9875 * 0.9575 * 0.99: 0.93608^2 ~= 0.8762
        assertTrue(ethBack > 8.76 ether && ethBack < 8.77 ether, "round trip loses about 12.4%");
        assertEq(token.balanceOf(ALICE), 10_000_000e18, "all bought tokens sold");
        _assertRouterEmpty();
    }

    // ---------------------------------------------------------------------------------------------
    // minOut and deadline
    // ---------------------------------------------------------------------------------------------

    function test_buyRevertsOnMinOut() public {
        uint256 expected = _buyMath(1 ether).tokensOut;
        uint256 ethBefore = ALICE.balance;
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(MoneyBackRouter.InsufficientOutput.selector, expected, expected + 1));
        router.buyWithEth{value: 1 ether}(expected + 1, block.timestamp);
        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(MoneyBackRouter.InsufficientOutput.selector, expected, type(uint256).max)
        );
        router.buyWithEth{value: 1 ether}(type(uint256).max, block.timestamp);
        assertEq(ALICE.balance, ethBefore, "ETH returned by the revert");
        assertEq(hook.pending(), 0, "nothing accrued on a reverted buy");
        // Exactly minOut passes.
        assertEq(_buyAs(ALICE, 1 ether, expected, block.timestamp), expected, "minOut == out passes");
        _assertRouterEmpty();
    }

    function test_sellRevertsOnMinOut() public {
        uint256 expected = _sellMath(100e18).ethOut;
        vm.startPrank(ALICE);
        token.approve(address(router), 100e18);
        vm.expectRevert(abi.encodeWithSelector(MoneyBackRouter.InsufficientOutput.selector, expected, expected + 1));
        router.sellForEth(100e18, expected + 1, block.timestamp);
        vm.stopPrank();
        assertEq(token.balanceOf(ALICE), 10_000_000e18, "tokens returned by the revert");
        assertEq(token.allowance(ALICE, address(router)), 100e18, "allowance untouched by the revert");
        assertEq(_sellAs(ALICE, 100e18, expected, block.timestamp), expected, "minOut == out passes");
        _assertRouterEmpty();
    }

    function test_buyAndSellRevertOnDeadline() public {
        vm.warp(T0 + 100);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(MoneyBackRouter.Expired.selector));
        router.buyWithEth{value: 1 ether}(0, block.timestamp - 1);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(MoneyBackRouter.Expired.selector));
        router.buyWithEth{value: 1 ether}(0, 0);
        vm.startPrank(ALICE);
        token.approve(address(router), 1e18);
        vm.expectRevert(abi.encodeWithSelector(MoneyBackRouter.Expired.selector));
        router.sellForEth(1e18, 0, block.timestamp - 1);
        vm.stopPrank();
        // deadline == block.timestamp is still valid for both.
        _buyAs(ALICE, 1 ether, 0, block.timestamp);
        _sellAs(ALICE, 1e18, 0, block.timestamp);
        _assertRouterEmpty();
    }

    function test_deadlineIsCheckedBeforeAmount() public {
        // Expired takes precedence over ZeroAmount (both guards run before any swap).
        vm.warp(T0 + 10);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(MoneyBackRouter.Expired.selector));
        router.buyWithEth{value: 0}(0, block.timestamp - 1);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(MoneyBackRouter.Expired.selector));
        router.sellForEth(0, 0, block.timestamp - 1);
    }

    // ---------------------------------------------------------------------------------------------
    // zero value, tiny amounts, overflow, allowance
    // ---------------------------------------------------------------------------------------------

    function test_zeroValueBuyAndZeroTokenSellRevert() public {
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(MoneyBackRouter.ZeroAmount.selector));
        router.buyWithEth{value: 0}(0, block.timestamp);
        vm.startPrank(ALICE);
        token.approve(address(router), 1e18);
        vm.expectRevert(abi.encodeWithSelector(MoneyBackRouter.ZeroAmount.selector));
        router.sellForEth(0, 0, block.timestamp);
        vm.stopPrank();
        assertEq(pm.swapLogCount(), 0, "no swap attempted");
        _assertRouterEmpty();
    }

    function test_quoteZeroReturnsZeroWithoutTouchingTheManager() public {
        assertEq(router.quoteBuy(0), 0, "quoteBuy(0)");
        assertEq(router.quoteSell(0), 0, "quoteSell(0)");
        assertEq(pm.swapLogCount(), 0, "no swap");
    }

    function test_tinyBuyThatYieldsNothingReverts() public {
        // 1 wei of ETH: 1 * 0.99 = 0 IMD. Leg 2 never runs; the buy reverts with InsufficientOutput(0, 0).
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(MoneyBackRouter.InsufficientOutput.selector, 0, 0));
        router.buyWithEth{value: 1}(0, block.timestamp);
        assertEq(router.quoteBuy(1), 0, "quote reports 0 for the same input");
        // 1 wei of MONEYBACK: 0 IMD out of our pool; the sell reverts likewise.
        vm.startPrank(ALICE);
        token.approve(address(router), 1);
        vm.expectRevert(abi.encodeWithSelector(MoneyBackRouter.InsufficientOutput.selector, 0, 0));
        router.sellForEth(1, 0, block.timestamp);
        vm.stopPrank();
        assertEq(router.quoteSell(1), 0, "quote reports 0 for the same input");
        // Enough IMD out of our pool but too little for 1 wei of ETH at 1000 IMD/ETH: still InsufficientOutput(0, 0).
        vm.startPrank(ALICE);
        token.approve(address(router), 100);
        vm.expectRevert(abi.encodeWithSelector(MoneyBackRouter.InsufficientOutput.selector, 0, 0));
        router.sellForEth(100, 0, block.timestamp);
        vm.stopPrank();
        assertEq(hook.pending(), 0, "nothing accrued");
        _assertRouterEmpty();
    }

    function test_buyAboveInt128RevertsAmountOverflow() public {
        uint256 huge = uint256(uint128(type(int128).max)) + 1;
        vm.deal(ALICE, huge);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(MoneyBackRouter.AmountOverflow.selector));
        router.buyWithEth{value: huge}(0, block.timestamp);
        assertEq(ALICE.balance, huge, "ETH back");
        vm.expectRevert(abi.encodeWithSelector(MoneyBackRouter.AmountOverflow.selector));
        router.quoteBuy(huge);
        vm.expectRevert(abi.encodeWithSelector(MoneyBackRouter.AmountOverflow.selector));
        router.quoteSell(huge);
        // Exactly int128.max is accepted by the overflow guard (the pool then decides).
        vm.deal(address(pm), type(uint256).max / 4);
        MockImdToken(IMD_ADDR).mint(address(pm), type(uint256).max / 4);
        uint256 maxIn = uint256(uint128(type(int128).max));
        vm.deal(ALICE, maxIn);
        pm.setCap(publicId, 1 ether);
        uint256 out = _buyAs(ALICE, maxIn, 0, block.timestamp);
        assertEq(out, _buyMath(maxIn).tokensOut, "int128.max input, partially filled");
        assertEq(ALICE.balance, maxIn - 1 ether, "unconsumed ETH refunded");
        _assertRouterEmpty();
    }

    function test_sellWithoutAllowanceOrBalanceReverts() public {
        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(MoneyBackToken.ERC20InsufficientAllowance.selector, address(router), 0, 1e18)
        );
        router.sellForEth(1e18, 0, block.timestamp);
        address poor = address(0x900);
        vm.startPrank(poor);
        token.approve(address(router), 1e18);
        vm.expectRevert(abi.encodeWithSelector(MoneyBackToken.ERC20InsufficientBalance.selector, poor, 0, 1e18));
        router.sellForEth(1e18, 0, block.timestamp);
        vm.stopPrank();
        // Allowance for someone else cannot be used: msg.sender is always the seller.
        vm.prank(ALICE);
        token.approve(address(router), 1e18);
        vm.prank(BOB);
        vm.expectRevert(
            abi.encodeWithSelector(MoneyBackToken.ERC20InsufficientAllowance.selector, address(router), 0, 1e18)
        );
        router.sellForEth(1e18, 0, block.timestamp);
        assertEq(token.balanceOf(ALICE), 10_000_000e18, "alice's tokens untouched");
        _assertRouterEmpty();
    }

    function test_sellPullsExactlyTokensAndKeepsNoAllowance() public {
        vm.startPrank(ALICE);
        token.approve(address(router), type(uint256).max);
        router.sellForEth(5e18, 0, block.timestamp);
        vm.stopPrank();
        assertEq(token.balanceOf(ALICE), 10_000_000e18 - 5e18, "exactly 5 pulled");
        assertEq(token.allowance(ALICE, address(router)), type(uint256).max, "infinite allowance left as is");
        assertEq(token.balanceOf(address(router)), 0, "router never held the tokens");
        assertEq(token.allowance(address(router), address(pm)), 0, "router never approves");
        assertEq(token.allowance(address(router), ALICE), 0, "router never approves");
    }

    // ---------------------------------------------------------------------------------------------
    // dust refunds (partial fills)
    // ---------------------------------------------------------------------------------------------

    function test_buyRefundsEthDustWhenPublicPoolFillsPartially() public {
        pm.setCap(publicId, 0.4 ether);
        BuyMath memory q = _buyMath(1 ether);
        assertEq(q.ethUsed, 0.4 ether, "fixture");
        uint256 pmEth = address(pm).balance;
        vm.expectEmit(true, false, false, true);
        emit BoughtWithEth(ALICE, 0.4 ether, q.imdMid, q.tokensOut);
        uint256 out = _buyAs(ALICE, 1 ether, 0, block.timestamp);
        assertEq(out, q.tokensOut, "tokens for 0.4 ETH");
        assertEq(ALICE.balance, 1_000_000 ether - 0.4 ether, "0.6 ETH refunded");
        assertEq(address(pm).balance, pmEth + 0.4 ether, "manager got only what the pool consumed");
        assertEq(_imdOf(ALICE), 0, "no IMD dust");
        _assertRouterEmpty();
    }

    function test_buyRefundsImdDustWhenOurPoolFillsPartially() public {
        pm.setCap(launchId, 100e18);
        BuyMath memory q = _buyMath(1 ether);
        assertTrue(q.imdDust > 0, "fixture: dust");
        assertEq(q.imdMid, 100e18 + q.fee, "pool consumed the cap, hook kept its fee on the full leg");
        uint256 pmImd = _imdOf(address(pm));
        vm.expectEmit(true, false, false, true);
        emit BoughtWithEth(ALICE, 1 ether, q.imdMid, q.tokensOut);
        uint256 out = _buyAs(ALICE, 1 ether, 0, block.timestamp);
        assertEq(out, q.tokensOut, "tokens for 100 IMD");
        assertEq(_imdOf(ALICE), q.imdDust, "unconsumed IMD refunded to the buyer");
        assertEq(_imdOf(address(pm)), pmImd - q.imdDust, "manager paid the dust out");
        assertEq(ALICE.balance, 1_000_000 ether - 1 ether, "all ETH consumed by leg 1");
        assertEq(hook.pending(), q.fee, "fee accrued on the full IMD leg");
        _assertRouterEmpty();
    }

    function test_buyRefundsBothDustsWhenBothPoolsFillPartially() public {
        pm.setCap(publicId, 0.5 ether);
        pm.setCap(launchId, 10e18);
        BuyMath memory q = _buyMath(1 ether);
        uint256 out = _buyAs(BOB, 1 ether, 0, block.timestamp);
        assertEq(out, q.tokensOut, "tokens");
        assertEq(BOB.balance, 1_000_000 ether - 0.5 ether, "ETH dust");
        assertEq(_imdOf(BOB), q.imdDust, "IMD dust");
        _assertRouterEmpty();
    }

    function test_sellRefundsTokenDustWhenOurPoolFillsPartially() public {
        pm.setCap(launchId, 300e18);
        SellMath memory q = _sellMath(1_000e18);
        assertEq(q.tokenDust, 700e18, "fixture");
        uint256 out = _sellExpectingEvent(ALICE, 1_000e18, 300e18, q.imdOut, q.ethOut);
        assertEq(out, q.ethOut, "ETH for 300 tokens");
        assertEq(token.balanceOf(ALICE), 10_000_000e18 - 300e18, "700 MONEYBACK came back");
        assertEq(token.balanceOf(address(pm)), PM_TOKENS + 300e18, "manager kept only what the pool consumed");
        assertEq(_imdOf(ALICE), 0, "no IMD dust");
        _assertRouterEmpty();
    }

    function test_sellRefundsImdDustWhenPublicPoolFillsPartially() public {
        pm.setCap(publicId, 100e18);
        SellMath memory q = _sellMath(1_000e18);
        assertTrue(q.imdDust > 0 && q.imdUsed == 100e18, "fixture");
        uint256 out = _sellExpectingEvent(ALICE, 1_000e18, 1_000e18, 100e18, q.ethOut);
        assertEq(out, q.ethOut, "ETH for 100 IMD");
        assertEq(_imdOf(ALICE), q.imdDust, "unconsumed IMD refunded to the seller");
        assertEq(token.balanceOf(ALICE), 10_000_000e18 - 1_000e18, "all tokens consumed");
        _assertRouterEmpty();
    }

    function test_sellRefundsBothDusts() public {
        pm.setCap(launchId, 500e18);
        pm.setCap(publicId, 50e18);
        SellMath memory q = _sellMath(1_000e18);
        uint256 out = _sellAs(BOB, 1_000e18, 0, block.timestamp);
        assertEq(out, q.ethOut, "ETH");
        assertEq(token.balanceOf(BOB), 10_000_000e18 - 500e18, "token dust back");
        assertEq(_imdOf(BOB), q.imdDust, "IMD dust back");
        assertEq(BOB.balance, 1_000_000 ether + q.ethOut, "ETH received");
        _assertRouterEmpty();
    }

    function test_sellWhereSecondLegYieldsNothingRefundsNothingAndReverts() public {
        // Our pool pays IMD but the public pool is capped to 1 wei of IMD: 0 ETH out -> revert, all undone.
        pm.setCap(publicId, 1);
        vm.startPrank(ALICE);
        token.approve(address(router), 1_000e18);
        vm.expectRevert(abi.encodeWithSelector(MoneyBackRouter.InsufficientOutput.selector, 0, 0));
        router.sellForEth(1_000e18, 0, block.timestamp);
        vm.stopPrank();
        assertEq(token.balanceOf(ALICE), 10_000_000e18, "tokens back");
        assertEq(_imdOf(ALICE), 0, "no IMD kept");
        _assertRouterEmpty();
    }

    // ---------------------------------------------------------------------------------------------
    // quotes
    // ---------------------------------------------------------------------------------------------

    function test_quoteBuyMatchesBuyAndChangesNothing() public {
        uint256 ethIn = 3 ether;
        uint256 pending = hook.pending();
        uint256 logs = pm.swapLogCount();
        vm.prank(ALICE);
        uint256 quoted = router.quoteBuy(ethIn);
        assertEq(quoted, _buyMath(ethIn).tokensOut, "quote == formula");
        assertEq(hook.pending(), pending, "quote accrued nothing");
        assertEq(pm.swapLogCount(), logs, "swaps rolled back");
        assertEq(ALICE.balance, 1_000_000 ether, "quote cost nothing");
        assertTrue(!pm.unlocked(), "manager locked again");
        _assertRouterEmpty();
        uint256 real = _buyAs(ALICE, ethIn, quoted, block.timestamp);
        assertEq(real, quoted, "buy delivers exactly the quote");
        // With partial fills too.
        pm.setCap(publicId, 1 ether);
        pm.setCap(launchId, 50e18);
        quoted = router.quoteBuy(ethIn);
        assertEq(quoted, _buyMath(ethIn).tokensOut, "quote with caps");
        assertEq(_buyAs(BOB, ethIn, quoted, block.timestamp), quoted, "buy with caps delivers the quote");
    }

    function test_quoteSellMatchesSellAndChangesNothing() public {
        uint256 tokens = 1_234e18;
        vm.warp(T0 + 600);
        uint256 pending = hook.pending();
        vm.prank(BOB); // the quote caller needs no tokens and no allowance
        uint256 quoted = router.quoteSell(tokens);
        assertEq(quoted, _sellMath(tokens).ethOut, "quote == formula (surcharge included)");
        assertEq(hook.pending(), pending, "quote accrued nothing");
        assertEq(pm.swapLogCount(), 0, "swaps rolled back");
        assertEq(token.balanceOf(BOB), 10_000_000e18, "nothing pulled");
        _assertRouterEmpty();
        assertEq(_sellAs(ALICE, tokens, quoted, block.timestamp), quoted, "sell delivers exactly the quote");
        vm.warp(T0 + 1800);
        uint256 later = router.quoteSell(tokens);
        assertTrue(later > quoted, "quote follows the surcharge decay");
        assertEq(later, _sellMath(tokens).ethOut, "quote after decay");
        pm.setCap(launchId, 100e18);
        quoted = router.quoteSell(tokens);
        assertEq(quoted, _sellMath(tokens).ethOut, "quote with partial fill");
        assertEq(_sellAs(ALICE, tokens, quoted, block.timestamp), quoted, "sell with partial fill delivers the quote");
    }

    function test_quoteBubblesUpForeignReverts() public {
        TwoPoolManager other = new TwoPoolManager();
        // A router on a manager where the public pool was never initialized.
        MoneyBackHook h2 = _deployHook(address(other), address(token), PAYOUT, HOOK_FLAGS);
        MoneyBackRouter r2 = new MoneyBackRouter(IPoolManager(address(other)), address(h2));
        other.initialize(_makeLaunchKey(true, address(h2)), 1 << 96);
        vm.expectRevert(abi.encodeWithSelector(TwoPoolManager.PoolNotInitialized.selector));
        r2.quoteBuy(1 ether);
        vm.expectRevert(abi.encodeWithSelector(TwoPoolManager.PoolNotInitialized.selector));
        r2.quoteSell(1e18);
    }

    function test_quoteCannotBeCalledWhileLocked() public {
        pm.setSkip(true); // manager returns without calling back: a quote must not report a number
        vm.expectRevert(abi.encodeWithSelector(MoneyBackRouter.UnexpectedCallback.selector));
        router.quoteBuy(1 ether);
        vm.expectRevert(abi.encodeWithSelector(MoneyBackRouter.UnexpectedCallback.selector));
        router.quoteSell(1e18);
        pm.setSkip(false);
        assertEq(router.quoteBuy(1 ether), _buyMath(1 ether).tokensOut, "guard state reset after the revert");
    }

    // ---------------------------------------------------------------------------------------------
    // callback and receive() guards
    // ---------------------------------------------------------------------------------------------

    function test_unlockCallbackRejectsNonManager() public {
        bytes memory data = abi.encode(uint8(0), ALICE, uint256(1 ether), uint256(0));
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(MoneyBackRouter.NotPoolManager.selector));
        router.unlockCallback(data);
        vm.expectRevert(abi.encodeWithSelector(MoneyBackRouter.NotPoolManager.selector));
        router.unlockCallback(data);
    }

    function test_unlockCallbackRejectsManagerWithNoCallInFlight() public {
        // Even the real manager cannot drive the callback unless buy/sell/quote just handed it that data.
        bytes memory data = abi.encode(uint8(1), ALICE, uint256(1e18), uint256(0)); // a forged sell for alice
        vm.prank(ALICE);
        token.approve(address(router), 1e18);
        vm.prank(address(pm));
        vm.expectRevert(abi.encodeWithSelector(MoneyBackRouter.UnexpectedCallback.selector));
        router.unlockCallback(data);
        vm.prank(address(pm));
        vm.expectRevert(abi.encodeWithSelector(MoneyBackRouter.UnexpectedCallback.selector));
        router.unlockCallback("");
        assertEq(token.balanceOf(ALICE), 10_000_000e18, "alice's approved tokens untouched");
    }

    function test_tamperedCallbackDataIsRejected() public {
        pm.setTamper(true);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(MoneyBackRouter.UnexpectedCallback.selector));
        router.buyWithEth{value: 1 ether}(0, block.timestamp);
        vm.startPrank(ALICE);
        token.approve(address(router), 1e18);
        vm.expectRevert(abi.encodeWithSelector(MoneyBackRouter.UnexpectedCallback.selector));
        router.sellForEth(1e18, 0, block.timestamp);
        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSelector(MoneyBackRouter.UnexpectedCallback.selector));
        router.quoteBuy(1 ether);
        pm.setTamper(false);
        _buyAs(ALICE, 1 ether, 0, block.timestamp);
        _assertRouterEmpty();
    }

    function test_managerThatNeverCallsBackIsRejected() public {
        pm.setSkip(true);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(MoneyBackRouter.UnexpectedCallback.selector));
        router.buyWithEth{value: 1 ether}(0, block.timestamp);
        vm.startPrank(ALICE);
        token.approve(address(router), 1e18);
        vm.expectRevert(abi.encodeWithSelector(MoneyBackRouter.UnexpectedCallback.selector));
        router.sellForEth(1e18, 0, block.timestamp);
        vm.stopPrank();
        assertEq(ALICE.balance, 1_000_000 ether, "ETH back");
    }

    function test_receiveRejectsEthFromAnyoneButTheManager() public {
        (bool ok, bytes memory ret) = address(router).call{value: 1}("");
        assertTrue(!ok, "accepted ETH from the test contract");
        assertTrue(
            keccak256(ret) == keccak256(abi.encodeWithSelector(MoneyBackRouter.NotPoolManager.selector)), "wrong reason"
        );
        vm.prank(ALICE);
        (ok,) = address(router).call{value: 1 ether}("");
        assertTrue(!ok, "accepted ETH from a user");
        (ok,) = address(router).call{value: 1}(abi.encodeWithSignature("nothing()"));
        assertTrue(!ok, "no fallback");
        assertEq(address(router).balance, 0, "nothing stuck");
        vm.prank(address(pm));
        (ok,) = address(router).call{value: 1}("");
        assertTrue(ok, "the manager may pay ETH in (sell proceeds)");
        // Anything that lands outside a call goes to whoever trades next: the router never keeps it.
        uint256 before = BOB.balance;
        _buyAs(BOB, 1 ether, 0, block.timestamp);
        assertEq(BOB.balance, before - 1 ether + 1, "stray wei swept to the next caller");
        _assertRouterEmpty();
    }

    // ---------------------------------------------------------------------------------------------
    // reentrancy
    // ---------------------------------------------------------------------------------------------

    function _reentryCheck(Reenterer r, uint8 mode, bool viaSell) internal {
        r.setMode(mode);
        uint256 before = token.balanceOf(address(r));
        if (viaSell) {
            uint256 out = r.sell(100e18, 0, block.timestamp);
            assertEq(out, _sellMath(100e18).ethOut, "outer sell succeeded with the right amount");
            assertEq(token.balanceOf(address(r)), before - 100e18, "sold");
        } else {
            pm.setCap(publicId, 0.5 ether); // force an ETH dust refund so receive() runs during the buy
            uint256 out = r.buy{value: 1 ether}(0, block.timestamp);
            assertEq(out, _buyMath(1 ether).tokensOut, "outer buy succeeded with the right amount");
            pm.setCap(publicId, 0);
        }
        assertTrue(r.nestedReverted(), "nested call did not revert");
        bytes4 want =
            mode == 5 || mode == 6 ? MoneyBackRouter.NotPoolManager.selector : MoneyBackRouter.Reentrancy.selector;
        bytes memory reason = r.nestedReason();
        assertTrue(reason.length == 4 && bytes4(reason) == want, "nested call reverted for the wrong reason");
        _assertRouterEmpty();
    }

    function test_reentrancyFromSellProceedsIsBlocked() public {
        Reenterer r = new Reenterer(router, token);
        token.transfer(address(r), 1_000e18);
        vm.deal(address(r), 10 ether);
        for (uint8 mode = 1; mode <= 6; ++mode) {
            _reentryCheck(r, mode, true);
        }
    }

    function test_reentrancyFromBuyDustRefundIsBlocked() public {
        Reenterer r = new Reenterer(router, token);
        token.transfer(address(r), 1_000e18);
        vm.deal(address(r), 10 ether);
        for (uint8 mode = 1; mode <= 6; ++mode) {
            _reentryCheck(r, mode, false);
        }
        assertEq(r.received(), 6 * 0.5 ether, "every dust refund arrived");
    }

    function test_guardResetsAfterReverts() public {
        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(
                MoneyBackRouter.InsufficientOutput.selector, _buyMath(1 ether).tokensOut, type(uint256).max
            )
        );
        router.buyWithEth{value: 1 ether}(type(uint256).max, block.timestamp);
        _buyAs(ALICE, 1 ether, 0, block.timestamp);
        pm.setTamper(true);
        vm.expectRevert(abi.encodeWithSelector(MoneyBackRouter.UnexpectedCallback.selector));
        router.quoteSell(1e18);
        pm.setTamper(false);
        _sellAs(ALICE, 1e18, 0, block.timestamp);
        _assertRouterEmpty();
    }

    function test_contractWithoutReceiveCanBuyFullFillOnly() public {
        NoReceive n = new NoReceive(router, token);
        token.transfer(address(n), 1_000e18);
        vm.deal(address(n), 10 ether);
        uint256 out = n.buy{value: 1 ether}(0, block.timestamp);
        assertEq(out, _buyMath(1 ether).tokensOut, "no refund needed: fine");
        pm.setCap(publicId, 0.5 ether);
        vm.expectRevert(abi.encodeWithSelector(MoneyBackRouter.EthTransferFailed.selector));
        n.buy{value: 1 ether}(0, block.timestamp);
        pm.setCap(publicId, 0);
        vm.expectRevert(abi.encodeWithSelector(MoneyBackRouter.EthTransferFailed.selector));
        n.sell(100e18, 0, block.timestamp);
        assertEq(token.balanceOf(address(n)), 1_000e18 + out, "sell fully undone");
        _assertRouterEmpty();
    }

    // ---------------------------------------------------------------------------------------------
    // sweep interplay
    // ---------------------------------------------------------------------------------------------

    function test_feesFromRouterTradesAreSweepableToPayout() public {
        _buyAs(ALICE, 5 ether, 0, block.timestamp);
        _sellAs(BOB, 2_000e18, 0, block.timestamp);
        uint256 pending = hook.pending();
        assertEq(pending, _buyMath(5 ether).fee + _sellMath(2_000e18).fee, "both trades accrued");
        hook.sweep();
        assertEq(_imdOf(PAYOUT), pending, "payout received the IMD");
        assertEq(hook.pending(), 0, "cleared");
        assertEq(_imdOf(address(router)), 0, "router got none of it");
        _assertRouterEmpty();
    }

    // ---------------------------------------------------------------------------------------------
    // fuzz
    // ---------------------------------------------------------------------------------------------

    /// forge-config: default.fuzz.runs = 600
    function testFuzz_buyMatchesFormulaAndLeavesNothing(uint256 ethIn, uint32 elapsed, uint256 capPub, uint256 capL)
        public
    {
        ethIn = ethIn % 1_000 ether + 1;
        vm.warp(T0 + elapsed);
        pm.setCap(publicId, capPub % 3 == 0 ? 0 : capPub % 10 ether + 1);
        pm.setCap(launchId, capL % 3 == 0 ? 0 : capL % 10_000e18 + 1);
        BuyMath memory q = _buyMath(ethIn);
        uint256 quoted = router.quoteBuy(ethIn);
        assertEq(quoted, q.tokensOut, "quote");
        uint256 p0 = hook.pending();
        if (q.tokensOut == 0) {
            vm.prank(ALICE);
            vm.expectRevert(abi.encodeWithSelector(MoneyBackRouter.InsufficientOutput.selector, 0, 0));
            router.buyWithEth{value: ethIn}(0, block.timestamp);
            assertEq(ALICE.balance, 1_000_000 ether, "nothing spent");
        } else {
            uint256 out = _buyAs(ALICE, ethIn, q.tokensOut, block.timestamp);
            assertEq(out, q.tokensOut, "tokens");
            assertEq(ALICE.balance, 1_000_000 ether - q.ethUsed, "ETH spent == consumed");
            assertEq(_imdOf(ALICE), q.imdDust, "IMD dust");
            assertEq(hook.pending() - p0, q.fee, "fee == floor(imdOut * 425 / 10000)");
            assertEq(q.fee, q.imdOut * 425 / BPS, "buys never surcharged");
        }
        _assertRouterEmpty();
    }

    /// forge-config: default.fuzz.runs = 600
    function testFuzz_sellMatchesFormulaAndLeavesNothing(uint256 tokens, uint32 elapsed, uint256 capPub, uint256 capL)
        public
    {
        tokens = tokens % 10_000_000e18 + 1;
        vm.warp(T0 + elapsed);
        pm.setCap(publicId, capPub % 3 == 0 ? 0 : capPub % 100e18 + 1);
        pm.setCap(launchId, capL % 3 == 0 ? 0 : capL % 10_000e18 + 1);
        SellMath memory q = _sellMath(tokens);
        assertEq(router.quoteSell(tokens), q.ethOut, "quote");
        uint256 p0 = hook.pending();
        if (q.ethOut == 0) {
            vm.startPrank(ALICE);
            token.approve(address(router), tokens);
            vm.expectRevert(abi.encodeWithSelector(MoneyBackRouter.InsufficientOutput.selector, 0, 0));
            router.sellForEth(tokens, 0, block.timestamp);
            vm.stopPrank();
            assertEq(token.balanceOf(ALICE), 10_000_000e18, "nothing sold");
        } else {
            uint256 out = _sellAs(ALICE, tokens, q.ethOut, block.timestamp);
            assertEq(out, q.ethOut, "ETH");
            assertEq(ALICE.balance, 1_000_000 ether + q.ethOut, "ETH received");
            assertEq(token.balanceOf(ALICE), 10_000_000e18 - q.tokensUsed, "tokens consumed, dust back");
            assertEq(_imdOf(ALICE), q.imdDust, "IMD dust");
            assertEq(hook.pending() - p0, q.fee, "fee == base + surcharge on the pool's IMD out");
        }
        _assertRouterEmpty();
    }

    // ---------------------------------------------------------------------------------------------
    // invariants over random buy / sell / quote / sweep / warp sequences (reverting calls included)
    // ---------------------------------------------------------------------------------------------

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 40
    function invariant_routerHoldsNothing() public view {
        _assertRouterEmpty();
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 40
    function invariant_hookPendingEqualsRouterFeesMinusSwept() public view {
        assertEq(hook.pending(), handler.feesAccrued() - handler.swept(), "pending != fees - swept");
        assertEq(_imdOf(PAYOUT), handler.swept(), "payout got exactly what was swept");
        assertEq(_claims(address(hook), address(token)), 0, "hook holds MONEYBACK claims");
        assertEq(_claims(address(hook), address(0)), 0, "hook holds ETH claims");
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 40
    function invariant_valueIsConserved() public view {
        address third = handler.actors(2);
        uint256 eth = address(pm).balance + ALICE.balance + BOB.balance + third.balance + address(router).balance;
        assertEq(eth, _initialEth, "ETH created or lost");
        uint256 toks = token.balanceOf(address(pm)) + token.balanceOf(ALICE) + token.balanceOf(BOB)
            + token.balanceOf(third) + token.balanceOf(address(router)) + token.balanceOf(address(hook));
        assertEq(toks, _initialTokens, "MONEYBACK created or lost");
        assertEq(token.totalSupply(), 1_000_000_000e18, "supply fixed");
        uint256 imd = _imdOf(address(pm)) + _imdOf(PAYOUT) + _imdOf(ALICE) + _imdOf(BOB) + _imdOf(third)
            + _imdOf(address(router)) + _imdOf(address(hook));
        assertEq(imd, PM_IMD, "IMD created or lost");
        assertEq(MockImdToken(IMD_ADDR).totalSupply(), PM_IMD, "IMD supply");
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 40
    function invariant_bindingsNeverChange() public view {
        assertEq(address(router.hook()), address(hook), "hook");
        assertEq(router.token(), address(token), "token");
        PoolKey memory k = router.launchPoolKey();
        assertTrue(pm.poolIdOf(k) == launchId, "launch pool key");
        assertEq(hook.initializedAt(), T0, "initializedAt");
    }
}
