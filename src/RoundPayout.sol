// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @dev Minimal ERC-20 interface (OpenZeppelin IERC20 selectors).
interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}

/// @title RoundPayout
/// @notice Token-agnostic batch payer driven by the off-chain IMD Money Back engine, which pays
///         underwater holders back in IMD every 15 minutes. One `payRound` per round id.
///
///         Access control, pausing, reentrancy protection and safe ERC-20 handling follow the
///         OpenZeppelin v5 `Ownable2Step`, `Pausable`, `ReentrancyGuard` and `SafeERC20`
///         contracts (same function names, events and custom errors), inlined so the file
///         builds with no vendored dependency.
///
///         Trust assumptions: the owner (the engine key) decides who is paid, how much, with which
///         token, can sweep any balance out, and can pause. This is the only privileged contract in
///         the launch. Anyone can fund it.
///
///         Invariants:
///         - A round id is paid at most once: `isPaid(roundId)` flips to true at the end of a
///           successful `payRound` and never flips back.
///         - `rounds(roundId).totalPaid` counts only legs that actually transferred (initial batch
///           plus successful retries); failed legs are held in `failed(roundId, to)` until retried
///           or written off, and `rounds(roundId).failedCount` is the number of legs still failed.
///         - `payRound` reverts up front when sum(amounts) exceeds the contract's token balance,
///           so a batch that starts always has enough to pay every leg.
///         - sum of all `Paid` amounts of a token <= sum of everything ever received in that token.
contract RoundPayout {
    // ---------------------------------------------------------------------------------------------
    // Ownable2Step (OpenZeppelin v5 surface)
    // ---------------------------------------------------------------------------------------------

    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    error OwnableUnauthorizedAccount(address account);
    error OwnableInvalidOwner(address owner);

    address private _owner;
    address private _pendingOwner;

    modifier onlyOwner() {
        if (_owner != msg.sender) revert OwnableUnauthorizedAccount(msg.sender);
        _;
    }

    function owner() public view returns (address) {
        return _owner;
    }

    function pendingOwner() public view returns (address) {
        return _pendingOwner;
    }

    /// @notice Starts a two-step handoff; `newOwner` must call `acceptOwnership`.
    function transferOwnership(address newOwner) external onlyOwner {
        _pendingOwner = newOwner;
        emit OwnershipTransferStarted(_owner, newOwner);
    }

    function acceptOwnership() external {
        if (_pendingOwner != msg.sender) revert OwnableUnauthorizedAccount(msg.sender);
        _transferOwnership(msg.sender);
    }

    /// @notice Leaves the contract without an owner: no further payRound, sweep, pause or retry.
    function renounceOwnership() external onlyOwner {
        _transferOwnership(address(0));
    }

    function _transferOwnership(address newOwner) private {
        delete _pendingOwner;
        address previous = _owner;
        _owner = newOwner;
        emit OwnershipTransferred(previous, newOwner);
    }

    // ---------------------------------------------------------------------------------------------
    // Pausable (OpenZeppelin v5 surface)
    // ---------------------------------------------------------------------------------------------

    event Paused(address account);
    event Unpaused(address account);

    error EnforcedPause();
    error ExpectedPause();

    bool private _paused;

    modifier whenNotPaused() {
        if (_paused) revert EnforcedPause();
        _;
    }

    function paused() public view returns (bool) {
        return _paused;
    }

    function pause() external onlyOwner {
        if (_paused) revert EnforcedPause();
        _paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyOwner {
        if (!_paused) revert ExpectedPause();
        _paused = false;
        emit Unpaused(msg.sender);
    }

    // ---------------------------------------------------------------------------------------------
    // ReentrancyGuard (OpenZeppelin v5 surface)
    // ---------------------------------------------------------------------------------------------

    error ReentrancyGuardReentrantCall();

    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _status = _NOT_ENTERED;

    modifier nonReentrant() {
        if (_status == _ENTERED) revert ReentrancyGuardReentrantCall();
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }

    // ---------------------------------------------------------------------------------------------
    // RoundPayout
    // ---------------------------------------------------------------------------------------------

    /// @notice Maximum legs per batch.
    uint256 public constant MAX_BATCH = 500;

    struct Round {
        address token;
        uint256 paidAt;
        uint256 count;
        uint256 failedCount;
        bytes32 ledgerHash;
        uint256 totalPaid;
    }

    /// @notice Per-round record: (token, paidAt, count, failedCount, ledgerHash, totalPaid).
    mapping(uint256 roundId => Round) public rounds;
    /// @notice Amount still owed to `to` for `roundId` after a failed leg (0 when nothing is owed).
    mapping(uint256 roundId => mapping(address to => uint256 amount)) public failed;

    event Funded(address indexed token, address indexed from, uint256 amount);
    event Swept(address indexed token, address indexed to, uint256 amount);
    event Paid(uint256 indexed roundId, address indexed to, uint256 amount);
    event PayFailed(uint256 indexed roundId, address indexed to, uint256 amount, bytes reason);
    event WrittenOff(uint256 indexed roundId, address indexed to, uint256 amount);
    event RoundPaid(
        uint256 indexed roundId,
        address indexed token,
        bytes32 ledgerHash,
        uint256 twapCloseX96,
        uint256 totalEligibleLoss,
        uint256 totalPaid,
        uint256 count
    );

    error RoundAlreadyPaid(uint256 roundId);
    error RoundNotPaid(uint256 roundId);
    error LengthMismatch();
    error EmptyBatch();
    error BatchTooLarge(uint256 length);
    error InsufficientBalance(uint256 needed, uint256 available);
    error AllTransfersFailed(uint256 roundId);
    error NothingFailed(uint256 roundId, address to);
    error ZeroAddress();
    error SafeERC20FailedOperation(address token);

    /// @param initialOwner The engine key ($owner).
    constructor(address initialOwner) {
        if (initialOwner == address(0)) revert OwnableInvalidOwner(address(0));
        _transferOwnership(initialOwner);
    }

    // ---------------------------------------------------------------------------------------------
    // Funding
    // ---------------------------------------------------------------------------------------------

    /// @notice Pulls `amount` of `token` from the caller (needs prior approval). Anyone may fund.
    function fund(address token, uint256 amount) external nonReentrant {
        _safeTransferFrom(token, msg.sender, address(this), amount);
        emit Funded(token, msg.sender, amount);
    }

    /// @notice Owner escape hatch: sends `amount` of `token` to `to`. Works while paused.
    function sweep(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        _safeTransfer(token, to, amount);
        emit Swept(token, to, amount);
    }

    // ---------------------------------------------------------------------------------------------
    // Rounds
    // ---------------------------------------------------------------------------------------------

    /// @notice Pays one round: `amounts[i]` of `token` to `to[i]` for every i.
    /// @dev Reverts RoundAlreadyPaid if the round id was used; LengthMismatch / EmptyBatch /
    ///      BatchTooLarge on bad shapes; InsufficientBalance up front if sum(amounts) exceeds the
    ///      balance. Each leg is a low-level ERC-20 transfer: a leg that reverts or returns false
    ///      is recorded in `failed[roundId][to]` (accumulating if `to` repeats) and emitted as
    ///      PayFailed, and the batch continues. AllTransfersFailed reverts the whole call only when
    ///      every leg failed. The round is marked paid after the loop.
    /// @return totalPaid Sum of the legs that transferred (failed legs excluded).
    function payRound(
        uint256 roundId,
        address token,
        address[] calldata to,
        uint256[] calldata amounts,
        bytes32 ledgerHash,
        uint256 twapCloseX96,
        uint256 totalEligibleLoss
    ) external onlyOwner whenNotPaused nonReentrant returns (uint256 totalPaid) {
        Round storage round = rounds[roundId];
        if (round.paidAt != 0) revert RoundAlreadyPaid(roundId);
        uint256 n = to.length;
        if (n != amounts.length) revert LengthMismatch();
        if (n == 0) revert EmptyBatch();
        if (n > MAX_BATCH) revert BatchTooLarge(n);
        if (token == address(0)) revert ZeroAddress();

        _requireBalance(token, _sum(amounts));

        uint256 failedCount;
        (totalPaid, failedCount) = _payLegs(roundId, token, to, amounts);
        if (failedCount == n) revert AllTransfersFailed(roundId);

        round.token = token;
        round.paidAt = block.timestamp;
        round.count = n;
        round.failedCount = failedCount;
        round.ledgerHash = ledgerHash;
        round.totalPaid = totalPaid;
        emit RoundPaid(roundId, token, ledgerHash, twapCloseX96, totalEligibleLoss, totalPaid, n);
    }

    /// @dev Sends every leg with a low-level try; failed legs are recorded and emitted, never revert.
    function _payLegs(uint256 roundId, address token, address[] calldata to, uint256[] calldata amounts)
        private
        returns (uint256 totalPaid, uint256 failedCount)
    {
        for (uint256 i = 0; i < to.length; ++i) {
            address recipient = to[i];
            uint256 amount = amounts[i];
            (bool ok, bytes memory reason) = _tryTransfer(token, recipient, amount);
            if (ok) {
                totalPaid += amount;
                emit Paid(roundId, recipient, amount);
            } else {
                failed[roundId][recipient] += amount;
                ++failedCount;
                emit PayFailed(roundId, recipient, amount, reason);
            }
        }
    }

    function _sum(uint256[] calldata amounts) private pure returns (uint256 total) {
        for (uint256 i = 0; i < amounts.length; ++i) {
            total += amounts[i];
        }
    }

    /// @dev Reverts InsufficientBalance unless this contract holds at least `needed` of `token`.
    function _requireBalance(address token, uint256 needed) private view {
        uint256 available = IERC20(token).balanceOf(address(this));
        if (needed > available) revert InsufficientBalance(needed, available);
    }

    /// @notice Re-sends the failed legs of a paid round to each address in `to`, in the round's
    ///         token. A leg that succeeds is cleared and counted into the round's totalPaid; one
    ///         that fails again stays recorded and emits PayFailed. Reverts NothingFailed for an
    ///         address with nothing owed (including a duplicate in `to`).
    /// @return totalPaid Sum of the legs that transferred in this call.
    function retryFailed(uint256 roundId, address[] calldata to)
        external
        onlyOwner
        whenNotPaused
        nonReentrant
        returns (uint256 totalPaid)
    {
        Round storage round = rounds[roundId];
        if (round.paidAt == 0) revert RoundNotPaid(roundId);
        address token = round.token;
        uint256 n = to.length;
        if (n == 0) revert EmptyBatch();
        if (n > MAX_BATCH) revert BatchTooLarge(n);

        uint256 needed;
        for (uint256 i = 0; i < n; ++i) {
            uint256 owed = failed[roundId][to[i]];
            if (owed == 0) revert NothingFailed(roundId, to[i]);
            needed += owed;
        }
        _requireBalance(token, needed);

        for (uint256 i = 0; i < n; ++i) {
            address recipient = to[i];
            uint256 amount = failed[roundId][recipient];
            if (amount == 0) revert NothingFailed(roundId, recipient);
            (bool ok, bytes memory reason) = _tryTransfer(token, recipient, amount);
            if (ok) {
                delete failed[roundId][recipient];
                round.failedCount -= 1;
                round.totalPaid += amount;
                totalPaid += amount;
                emit Paid(roundId, recipient, amount);
            } else {
                emit PayFailed(roundId, recipient, amount, reason);
            }
        }
    }

    /// @notice Clears a failed leg without paying it.
    function writeOffFailed(uint256 roundId, address to) external onlyOwner nonReentrant {
        uint256 amount = failed[roundId][to];
        if (amount == 0) revert NothingFailed(roundId, to);
        delete failed[roundId][to];
        rounds[roundId].failedCount -= 1;
        emit WrittenOff(roundId, to, amount);
    }

    // ---------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------

    /// @notice True once `payRound(roundId, ...)` has completed.
    function isPaid(uint256 roundId) external view returns (bool) {
        return rounds[roundId].paidAt != 0;
    }

    // ---------------------------------------------------------------------------------------------
    // ERC-20 helpers
    // ---------------------------------------------------------------------------------------------

    /// @dev Low-level "try": never reverts. Success means the call did not revert and either
    ///      returned true, or returned nothing while `token` has code (USDT-style tokens).
    function _tryTransfer(address token, address to, uint256 amount) private returns (bool ok, bytes memory data) {
        (ok, data) = token.call(abi.encodeCall(IERC20.transfer, (to, amount)));
        if (ok) ok = _returnedTrue(token, data);
    }

    /// @dev SafeERC20.safeTransfer semantics.
    function _safeTransfer(address token, address to, uint256 amount) private {
        (bool ok, bytes memory data) = token.call(abi.encodeCall(IERC20.transfer, (to, amount)));
        if (!ok || !_returnedTrue(token, data)) revert SafeERC20FailedOperation(token);
    }

    /// @dev SafeERC20.safeTransferFrom semantics.
    function _safeTransferFrom(address token, address from, address to, uint256 amount) private {
        (bool ok, bytes memory data) = token.call(abi.encodeCall(IERC20.transferFrom, (from, to, amount)));
        if (!ok || !_returnedTrue(token, data)) revert SafeERC20FailedOperation(token);
    }

    function _returnedTrue(address token, bytes memory data) private view returns (bool) {
        if (data.length == 0) return token.code.length > 0;
        if (data.length < 32) return false;
        uint256 word;
        assembly ("memory-safe") {
            word := mload(add(data, 0x20))
        }
        return word == 1;
    }
}
