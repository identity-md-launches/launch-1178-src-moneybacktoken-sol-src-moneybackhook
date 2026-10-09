// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {
    MoneyBackHook,
    IPoolManager,
    IUnlockCallback,
    IHooks,
    PoolKey,
    SwapParams,
    Currency,
    BalanceDelta
} from "src/MoneyBackHook.sol";

/// @dev Minimal ERC-20 surface the router needs (OpenZeppelin IERC20 selectors).
interface IERC20 {
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}

/// @dev The v4-core `IPoolManager` functions the router calls beyond the ones the hook already
///      declares (selectors and struct layouts match v4-core).
interface IRouterPoolManager is IPoolManager {
    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData)
        external
        returns (BalanceDelta swapDelta);
    function sync(Currency currency) external;
    function settle() external payable returns (uint256 paid);
}

/// @title IMD Money Back router
/// @notice Lets buyers pay ETH for MONEYBACK and sellers get ETH back, in one transaction, through
///         two Uniswap v4 pools on Robinhood Chain:
///
///           public pool  ETH / IMD        currency0 = native ETH, currency1 = IMD, fee 10000,
///                                         tickSpacing 100, no hook   (hardcoded below)
///           our pool     MONEYBACK / IMD  the key MoneyBackHook binds in beforeInitialize
///                                         (read from hook.poolKey() on every call)
///
///         buyWithEth : ETH -> IMD on the public pool, then IMD -> MONEYBACK on our pool.
///         sellForEth : MONEYBACK -> IMD on our pool, then IMD -> ETH on the public pool.
///
///         Both legs are exact-input swaps inside a single PoolManager unlock. The hook sees an
///         ordinary swap with this router as the sender, so its 4.25% base fee (and the sell
///         surcharge) apply exactly as they would to a direct IMD trade; the router adds no fee.
///
///         Invariants:
///         - The router holds nothing between calls: every call ends by taking all MONEYBACK and
///           any IMD or ETH left over to msg.sender. Its ETH, IMD and MONEYBACK balances (and its
///           PoolManager deltas) are zero after every call.
///         - It never approves anyone for anything and keeps no allowance from anyone: sellers'
///           MONEYBACK is pulled with transferFrom straight into the PoolManager.
///         - No owner, no setter, no pause, no upgrade, no selfdestruct.
///         - unlockCallback only runs for the PoolManager, and only with the exact data a buy,
///           sell or quote of this contract just passed to unlock(), once per call; buy, sell and
///           quote cannot reenter.
///         - receive() only accepts ETH from the PoolManager (sell proceeds taken to the router).
///         - quoteBuy / quoteSell never change state: they run the real swaps inside an unlock
///           that always reverts, and read the result out of the revert data.
contract MoneyBackRouter is IUnlockCallback {
    // ---------------------------------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------------------------------

    /// @notice IMD on Robinhood Chain (chainId 4663), the paired currency of both pools. 18 decimals.
    address public constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;

    /// @notice Public ETH / IMD pool: fee 10000 (1%), tickSpacing 100, no hook.
    uint24 public constant PUBLIC_POOL_FEE = 10_000;
    /// @notice Public ETH / IMD pool tick spacing.
    int24 public constant PUBLIC_POOL_TICK_SPACING = 100;

    /// @dev v4-core TickMath.MIN_SQRT_PRICE + 1 and MAX_SQRT_PRICE - 1: the widest allowed price
    ///      limits, so an exact-input swap consumes as much input as the pool's liquidity allows.
    uint160 private constant _MIN_SQRT_PRICE_LIMIT = 4_295_128_740;
    uint160 private constant _MAX_SQRT_PRICE_LIMIT = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_341;

    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    // ---------------------------------------------------------------------------------------------
    // Immutables
    // ---------------------------------------------------------------------------------------------

    /// @notice The Uniswap v4 PoolManager.
    IRouterPoolManager public immutable poolManager;
    /// @notice The MoneyBackHook whose bound pool is our MONEYBACK / IMD pool.
    MoneyBackHook public immutable hook;
    /// @notice The MONEYBACK token (hook.launchToken()).
    address public immutable token;

    // ---------------------------------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------------------------------

    /// @dev Reentrancy lock for buy, sell and quote.
    uint256 private _status = _NOT_ENTERED;
    /// @dev keccak256 of the callback data this contract handed to unlock(), set right before the
    ///      call and cleared by unlockCallback. The callback only runs for exactly that data, once,
    ///      so nobody can drive it with data of their own (e.g. a forged sell for another user)
    ///      while a call is in flight.
    bytes32 private _expectedCallback;

    // ---------------------------------------------------------------------------------------------
    // Types, events and errors
    // ---------------------------------------------------------------------------------------------

    enum Action {
        Buy,
        Sell,
        QuoteBuy,
        QuoteSell
    }

    /// @dev What the unlock callback is asked to do. `amount` is the ETH (buy) or MONEYBACK
    ///      (sell) input; `minOut` the MONEYBACK (buy) or ETH (sell) floor; `user` the trader.
    struct CallbackData {
        Action action;
        address user;
        uint256 amount;
        uint256 minOut;
    }

    /// @dev What the unlock callback reports back. `amountIn` is the input actually consumed by
    ///      the first leg, `imdMid` the IMD consumed by the second leg, `amountOut` the final output.
    struct Result {
        uint256 amountIn;
        uint256 imdMid;
        uint256 amountOut;
    }

    /// @notice MONEYBACK bought with ETH. ethIn is the ETH the public pool consumed, imdIn the IMD
    ///         our pool consumed (hook fee included), tokensOut the MONEYBACK sent to the buyer.
    event BoughtWithEth(address indexed buyer, uint256 ethIn, uint256 imdIn, uint256 tokensOut);
    /// @notice MONEYBACK sold for ETH. tokensIn is the MONEYBACK our pool consumed, imdOut the IMD
    ///         it paid after the hook fee, ethOut the ETH sent to the seller.
    event SoldForEth(address indexed seller, uint256 tokensIn, uint256 imdOut, uint256 ethOut);

    error ZeroAddress();
    error ZeroAmount();
    error Expired();
    error InsufficientOutput(uint256 amountOut, uint256 minOut);
    error NotPoolManager();
    error Reentrancy();
    error UnexpectedCallback();
    error PoolNotBound();
    error AmountOverflow();
    error TransferFromFailed();
    error EthTransferFailed();
    /// @dev Carries a quote out of the always-reverting simulation unlock. Never reaches a caller.
    error QuoteResult(uint256 amountOut);

    // ---------------------------------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------------------------------

    /// @param manager The Uniswap v4 PoolManager ($poolManager).
    /// @param hook_   The deployed MoneyBackHook ($contract:MoneyBackHook). The MONEYBACK token
    ///                is read from it; the pool key is read from it on every call, so the router
    ///                may be deployed before the pool is initialized.
    constructor(IPoolManager manager, address hook_) {
        if (address(manager) == address(0) || hook_ == address(0)) revert ZeroAddress();
        poolManager = IRouterPoolManager(address(manager));
        hook = MoneyBackHook(hook_);
        address token_ = MoneyBackHook(hook_).launchToken();
        if (token_ == address(0)) revert ZeroAddress();
        token = token_;
    }

    // ---------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------

    /// @notice The public ETH / IMD pool key (hardcoded).
    function publicPoolKey() public pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(IMD),
            fee: PUBLIC_POOL_FEE,
            tickSpacing: PUBLIC_POOL_TICK_SPACING,
            hooks: IHooks(address(0))
        });
    }

    /// @notice Our MONEYBACK / IMD pool key, as bound by the hook. Reverts until the pool is initialized.
    function launchPoolKey() public view returns (PoolKey memory key) {
        key = hook.poolKey();
        if (address(key.hooks) != address(hook)) revert PoolNotBound();
    }

    // ---------------------------------------------------------------------------------------------
    // Trading
    // ---------------------------------------------------------------------------------------------

    /// @notice Swaps all of msg.value ETH -> IMD -> MONEYBACK and sends the MONEYBACK to msg.sender.
    ///         Any ETH the public pool did not consume and any IMD our pool did not consume are
    ///         refunded to msg.sender in the same call.
    /// @param minTokensOut Reverts with InsufficientOutput if fewer MONEYBACK would be received (or none).
    /// @param deadline     Reverts with Expired once block.timestamp is past it.
    /// @return tokensOut   MONEYBACK sent to msg.sender.
    function buyWithEth(uint256 minTokensOut, uint256 deadline) external payable returns (uint256 tokensOut) {
        _enter();
        if (block.timestamp > deadline) revert Expired();
        if (msg.value == 0) revert ZeroAmount();

        Result memory r = _run(CallbackData(Action.Buy, msg.sender, msg.value, minTokensOut));
        tokensOut = r.amountOut;

        // ETH dust: msg.value minus what settle{value} paid in. Everything the router holds goes back.
        _sendAllEth(msg.sender);
        emit BoughtWithEth(msg.sender, r.amountIn, r.imdMid, tokensOut);
        _exit();
    }

    /// @notice Pulls `tokens` MONEYBACK from msg.sender (allowance required), swaps
    ///         MONEYBACK -> IMD -> ETH and sends the ETH to msg.sender. Any MONEYBACK our pool did
    ///         not consume and any IMD the public pool did not consume are refunded to msg.sender.
    /// @param tokens    MONEYBACK to sell.
    /// @param minEthOut Reverts with InsufficientOutput if less ETH would be received (or none).
    /// @param deadline  Reverts with Expired once block.timestamp is past it.
    /// @return ethOut   ETH sent to msg.sender.
    function sellForEth(uint256 tokens, uint256 minEthOut, uint256 deadline) external returns (uint256 ethOut) {
        _enter();
        if (block.timestamp > deadline) revert Expired();
        if (tokens == 0) revert ZeroAmount();

        Result memory r = _run(CallbackData(Action.Sell, msg.sender, tokens, minEthOut));
        ethOut = r.amountOut;

        _sendAllEth(msg.sender);
        emit SoldForEth(msg.sender, r.amountIn, r.imdMid, ethOut);
        _exit();
    }

    // ---------------------------------------------------------------------------------------------
    // Quotes (revert-and-catch simulation)
    // ---------------------------------------------------------------------------------------------

    /// @notice MONEYBACK that buyWithEth would send for `ethIn` right now, hook fee included.
    ///         Returns 0 when the route yields nothing (buyWithEth would revert).
    /// @dev Runs both swaps for real inside an unlock that always reverts, so nothing is changed.
    ///      Not typed `view` because the PoolManager writes transient storage during a swap and
    ///      rejects it under STATICCALL; call it with eth_call off-chain.
    function quoteBuy(uint256 ethIn) external returns (uint256 tokensOut) {
        _enter();
        tokensOut = _quote(CallbackData(Action.QuoteBuy, msg.sender, ethIn, 0));
        _exit();
    }

    /// @notice ETH that sellForEth would send for `tokens` right now, hook fee and surcharge included.
    ///         Returns 0 when the route yields nothing (sellForEth would revert).
    /// @dev See quoteBuy: not `view`, state-neutral, meant for eth_call.
    function quoteSell(uint256 tokens) external returns (uint256 ethOut) {
        _enter();
        ethOut = _quote(CallbackData(Action.QuoteSell, msg.sender, tokens, 0));
        _exit();
    }

    // ---------------------------------------------------------------------------------------------
    // PoolManager callback
    // ---------------------------------------------------------------------------------------------

    /// @notice Runs the two swap legs for the call in progress. PoolManager only, and only with the
    ///         exact data buyWithEth, sellForEth, quoteBuy or quoteSell just passed to unlock().
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        bytes32 expected = _expectedCallback;
        if (expected == bytes32(0) || keccak256(data) != expected) revert UnexpectedCallback();
        delete _expectedCallback;

        CallbackData memory d = abi.decode(data, (CallbackData));
        Result memory r;
        if (d.action == Action.Buy || d.action == Action.QuoteBuy) {
            r = _buy(d);
        } else {
            r = _sell(d);
        }
        if (d.action == Action.QuoteBuy || d.action == Action.QuoteSell) revert QuoteResult(r.amountOut);
        if (r.amountOut == 0 || r.amountOut < d.minOut) revert InsufficientOutput(r.amountOut, d.minOut);
        return abi.encode(r);
    }

    /// @notice Sell proceeds are taken from the PoolManager to this contract and forwarded in the
    ///         same call. Nothing else may send ETH here.
    receive() external payable {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
    }

    // ---------------------------------------------------------------------------------------------
    // Internals: legs
    // ---------------------------------------------------------------------------------------------

    /// @dev ETH -> IMD on the public pool, IMD -> MONEYBACK on our pool. For a real buy, settles the
    ///      ETH consumed, takes the MONEYBACK and any IMD left over to the user. A quote only swaps.
    function _buy(CallbackData memory d) private returns (Result memory r) {
        bool quote = d.action == Action.QuoteBuy;

        // Leg 1: exact-input ETH -> IMD (ETH is currency0 of the public pool).
        (int256 a0, int256 a1) = _swap(publicPoolKey(), true, d.amount);
        r.amountIn = uint256(-a0);
        uint256 imdOut = uint256(a1);
        if (!quote) {
            // sync(native) clears any ERC-20 sync left in transient storage earlier in this
            // transaction, so settle{value} is credited as ETH (v4's documented native settle).
            poolManager.sync(Currency.wrap(address(0)));
            poolManager.settle{value: r.amountIn}();
        }
        if (imdOut == 0) return r; // amountOut 0: the caller reverts (buy) or reports 0 (quote)

        // Leg 2: exact-input IMD -> MONEYBACK on our pool. The hook charges its fee inside this swap.
        (PoolKey memory key, bool imdIs0) = _launchPool();
        (a0, a1) = _swap(key, imdIs0, imdOut);
        (int256 imdDelta, int256 tokenDelta) = imdIs0 ? (a0, a1) : (a1, a0);
        r.imdMid = uint256(-imdDelta);
        r.amountOut = uint256(tokenDelta);
        if (quote) return r;

        poolManager.take(Currency.wrap(token), d.user, r.amountOut);
        uint256 imdDust = imdOut - r.imdMid; // leg 2 can consume less than it was offered
        if (imdDust != 0) poolManager.take(Currency.wrap(IMD), d.user, imdDust);
    }

    /// @dev MONEYBACK -> IMD on our pool, IMD -> ETH on the public pool. For a real sell, pulls the
    ///      MONEYBACK from the user straight into the PoolManager, takes the ETH to this contract
    ///      (forwarded by the caller) and any IMD or MONEYBACK left over to the user. A quote only swaps.
    function _sell(CallbackData memory d) private returns (Result memory r) {
        bool quote = d.action == Action.QuoteSell;

        uint256 tokensIn = d.amount;
        if (!quote) {
            poolManager.sync(Currency.wrap(token));
            if (!IERC20(token).transferFrom(d.user, address(poolManager), tokensIn)) revert TransferFromFailed();
            tokensIn = poolManager.settle();
            if (tokensIn == 0) revert ZeroAmount();
        }

        // Leg 1: exact-input MONEYBACK -> IMD on our pool. The hook charges base fee + surcharge inside.
        (PoolKey memory key, bool imdIs0) = _launchPool();
        (int256 a0, int256 a1) = _swap(key, !imdIs0, tokensIn);
        (int256 imdDelta, int256 tokenDelta) = imdIs0 ? (a0, a1) : (a1, a0);
        r.amountIn = uint256(-tokenDelta);
        uint256 imdOut = uint256(imdDelta);
        if (imdOut == 0) return r;

        // Leg 2: exact-input IMD -> ETH on the public pool (IMD is currency1, so oneForZero).
        (a0, a1) = _swap(publicPoolKey(), false, imdOut);
        r.imdMid = uint256(-a1);
        r.amountOut = uint256(a0);
        if (quote) return r;

        if (r.amountOut != 0) poolManager.take(Currency.wrap(address(0)), address(this), r.amountOut);
        uint256 imdDust = imdOut - r.imdMid;
        if (imdDust != 0) poolManager.take(Currency.wrap(IMD), d.user, imdDust);
        uint256 tokenDust = tokensIn - r.amountIn;
        if (tokenDust != 0) poolManager.take(Currency.wrap(token), d.user, tokenDust);
    }

    /// @dev Exact-input swap of `amountIn` with the widest price limit and no hook data.
    ///      Returns the caller's (this router's) net delta per currency as v4 reports it.
    function _swap(PoolKey memory key, bool zeroForOne, uint256 amountIn) private returns (int256 a0, int256 a1) {
        if (amountIn > uint256(uint128(type(int128).max))) revert AmountOverflow();
        BalanceDelta delta = poolManager.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? _MIN_SQRT_PRICE_LIMIT : _MAX_SQRT_PRICE_LIMIT
            }),
            ""
        );
        a0 = _amount0(delta);
        a1 = _amount1(delta);
    }

    /// @dev Our pool's key and whether IMD is its currency0 (MONEYBACK -> IMD is then oneForZero).
    function _launchPool() private view returns (PoolKey memory key, bool imdIs0) {
        key = launchPoolKey();
        imdIs0 = Currency.unwrap(key.currency0) == IMD;
    }

    // ---------------------------------------------------------------------------------------------
    // Internals: unlock plumbing
    // ---------------------------------------------------------------------------------------------

    function _run(CallbackData memory d) private returns (Result memory r) {
        bytes memory data = abi.encode(d);
        _expectedCallback = keccak256(data);
        r = abi.decode(poolManager.unlock(data), (Result));
        // The callback cleared it; a PoolManager that never called back leaves it set.
        if (_expectedCallback != bytes32(0)) revert UnexpectedCallback();
    }

    /// @dev Runs the legs inside an unlock that ends in QuoteResult(amountOut); decodes it.
    ///      Any other revert reason (pool not initialized, no liquidity, ...) is bubbled up as is.
    function _quote(CallbackData memory d) private returns (uint256 amountOut) {
        if (d.amount == 0) return 0;
        bytes memory data = abi.encode(d);
        _expectedCallback = keccak256(data);
        try poolManager.unlock(data) {
            // The callback always reverts for quotes; reaching here means the PoolManager did not run it.
            revert UnexpectedCallback();
        } catch (bytes memory reason) {
            delete _expectedCallback; // the revert undid the callback's own clear
            if (reason.length == 36 && bytes4(reason) == QuoteResult.selector) {
                assembly ("memory-safe") {
                    amountOut := mload(add(reason, 36))
                }
            } else {
                assembly ("memory-safe") {
                    revert(add(reason, 32), mload(reason))
                }
            }
        }
    }

    /// @dev Sends this contract's whole ETH balance to `to`. After every call the router's ETH
    ///      balance is therefore zero.
    function _sendAllEth(address to) private {
        uint256 amount = address(this).balance;
        if (amount == 0) return;
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert EthTransferFailed();
    }

    function _enter() private {
        if (_status == _ENTERED) revert Reentrancy();
        _status = _ENTERED;
    }

    function _exit() private {
        _status = _NOT_ENTERED;
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
