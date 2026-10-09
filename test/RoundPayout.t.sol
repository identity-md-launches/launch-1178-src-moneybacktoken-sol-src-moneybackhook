// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {RoundPayout} from "src/RoundPayout.sol";

// No forge-std is vendored and the test paths may not add a lib/, so this suite talks to the
// Foundry cheatcode address through the minimal interface below. A failing assertion reverts.
interface VmRP {
    function prank(address) external;
    function startPrank(address) external;
    function stopPrank() external;
    function warp(uint256) external;
    function expectRevert(bytes calldata) external;
    function expectRevert() external;
    function expectEmit(bool, bool, bool, bool) external;
    function assume(bool) external pure;
}

// =================================================================================================
// Token stand-ins
// =================================================================================================

/// @dev Plain ERC-20 returning true, with per-recipient failure modes the tests can switch on:
///      revert with a reason, revert silently, or return false. Also an optional reentrancy hook.
contract MockToken {
    string public name = "Mock";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    mapping(address => bool) public revertsFor; // transfer to this address reverts("blocked")
    mapping(address => bool) public silentFor; // transfer to this address reverts with no data
    mapping(address => bool) public falseFor; // transfer to this address returns false
    address public reenterTarget; // if set, transfer() calls back into this address with reenterData
    bytes public reenterData;

    error Blocked(address to);

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function setRevertsFor(address a, bool v) external {
        revertsFor[a] = v;
    }

    function setSilentFor(address a, bool v) external {
        silentFor[a] = v;
    }

    function setFalseFor(address a, bool v) external {
        falseFor[a] = v;
    }

    address public reenterOn;

    function setReenter(address target, bytes calldata data) external {
        reenterTarget = target;
        reenterData = data;
        reenterOn = address(0xA1); // recipient A in the tests
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        if (revertsFor[to]) revert Blocked(to);
        if (silentFor[to]) {
            assembly { revert(0, 0) }
        }
        if (falseFor[to]) return false;
        if (reenterTarget != address(0) && to == reenterOn) {
            // Only the leg to `reenterOn` reenters (a storage flag could not survive the revert).
            (bool ok, bytes memory ret) = reenterTarget.call(reenterData);
            // Surface the reentrancy guard's revert so the leg is recorded as failed with that reason.
            if (!ok) {
                assembly { revert(add(ret, 0x20), mload(ret)) }
            }
        }
        return _move(msg.sender, to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        require(a >= amount, "allowance");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        return _move(from, to, amount);
    }

    function _move(address from, address to, uint256 amount) internal returns (bool) {
        require(balanceOf[from] >= amount, "balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev USDT-style: transfer / transferFrom return nothing.
contract NoReturnToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
    }

    function transfer(address to, uint256 amount) external {
        require(balanceOf[msg.sender] >= amount, "balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }

    function transferFrom(address from, address to, uint256 amount) external {
        require(allowance[from][msg.sender] >= amount, "allowance");
        allowance[from][msg.sender] -= amount;
        require(balanceOf[from] >= amount, "balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

/// @dev Token whose transferFrom returns false without reverting.
contract FalseToken {
    function balanceOf(address) external pure returns (uint256) {
        return 0;
    }

    function transferFrom(address, address, uint256) external pure returns (bool) {
        return false;
    }

    function transfer(address, uint256) external pure returns (bool) {
        return false;
    }
}

/// @dev Returns a 1-byte truthy value: shorter than a word, so SafeERC20 must treat it as failure.
contract ShortReturnToken {
    function transfer(address, uint256) external pure {
        assembly {
            mstore(0, 1)
            return(31, 1)
        }
    }

    function balanceOf(address) external pure returns (uint256) {
        return type(uint256).max;
    }
}

// =================================================================================================
// Invariant handler
// =================================================================================================

/// @dev Drives RoundPayout with random funding, rounds (some legs to blocked recipients), retries,
///      write-offs, sweeps and pause toggles, and keeps the ground-truth ledger the invariants are
///      checked against.
contract PayoutHandler {
    VmRP constant vm = VmRP(address(uint160(uint256(keccak256("hevm cheat code")))));

    RoundPayout public immutable payout;
    MockToken public immutable token;
    address public immutable owner;

    address[4] public recipients;
    uint256 public funded; // everything ever pulled in via fund()
    uint256 public paidTotal; // sum of all Paid amounts (initial + retries)
    uint256 public sweptTotal; // sum of all Swept amounts
    uint256 public writtenOffTotal;
    uint256 public nextRound = 1;
    uint256[] public paidRounds;
    mapping(uint256 => uint256) public ledgerPaid; // per round: sum of Paid
    mapping(uint256 => mapping(address => uint256)) public ledgerFailed; // per round & recipient: still owed
    mapping(uint256 => uint256) public ledgerFailedCount;
    // calls
    uint256 public roundsPaid;
    uint256 public roundsWithFailures;
    uint256 public retriesOk;
    uint256 public writeOffs;

    constructor(RoundPayout _payout, MockToken _token, address _owner) {
        payout = _payout;
        token = _token;
        owner = _owner;
        recipients = [address(0x1001), address(0x1002), address(0x1003), address(0x1004)];
        token.mint(address(this), type(uint128).max);
        token.approve(address(payout), type(uint256).max);
    }

    function paidRoundCount() external view returns (uint256) {
        return paidRounds.length;
    }

    function fund(uint256 amount) external {
        amount = amount % 1e24;
        payout.fund(address(token), amount);
        funded += amount;
    }

    function setBlocked(uint256 seed, bool blocked) external {
        token.setRevertsFor(recipients[seed % 4], blocked);
    }

    function pay(uint256 n, uint256 seed) external {
        n = n % 6 + 1;
        address[] memory to = new address[](n);
        uint256[] memory amounts = new uint256[](n);
        uint256 sum;
        for (uint256 i = 0; i < n; ++i) {
            to[i] = recipients[uint256(keccak256(abi.encode(seed, i))) % 4];
            amounts[i] = uint256(keccak256(abi.encode(seed, i, "amt"))) % 1e21;
            sum += amounts[i];
        }
        uint256 roundId = nextRound++;
        uint256 bal = token.balanceOf(address(payout));
        bool paused = payout.paused();
        if (paused) {
            vm.prank(owner);
            vm.expectRevert(
                RoundPayout.EnforcedPause.selector == bytes4(0)
                    ? bytes("")
                    : abi.encodeWithSelector(RoundPayout.EnforcedPause.selector)
            );
            payout.payRound(roundId, address(token), to, amounts, bytes32(roundId), 0, 0);
            return;
        }
        if (sum > bal) {
            vm.prank(owner);
            vm.expectRevert(abi.encodeWithSelector(RoundPayout.InsufficientBalance.selector, sum, bal));
            payout.payRound(roundId, address(token), to, amounts, bytes32(roundId), 0, 0);
            return;
        }
        // Predict the outcome: legs to a blocked recipient fail.
        uint256 expectPaid;
        uint256 expectFailed;
        for (uint256 i = 0; i < n; ++i) {
            if (token.revertsFor(to[i])) expectFailed++;
            else expectPaid += amounts[i];
        }
        vm.prank(owner);
        if (expectFailed == n) {
            vm.expectRevert(abi.encodeWithSelector(RoundPayout.AllTransfersFailed.selector, roundId));
            payout.payRound(roundId, address(token), to, amounts, bytes32(roundId), 0, 0);
            return;
        }
        uint256 got = payout.payRound(roundId, address(token), to, amounts, bytes32(roundId), 0, 0);
        require(got == expectPaid, "handler: totalPaid mismatch");
        paidTotal += got;
        ledgerPaid[roundId] = got;
        for (uint256 i = 0; i < n; ++i) {
            if (token.revertsFor(to[i])) {
                if (ledgerFailed[roundId][to[i]] == 0) ledgerFailedCount[roundId]++;
                ledgerFailed[roundId][to[i]] += amounts[i];
            }
        }
        // failedCount in the contract counts legs, not distinct recipients: record both.
        legsFailed[roundId] = expectFailed;
        paidRounds.push(roundId);
        roundsPaid++;
        if (expectFailed > 0) roundsWithFailures++;
    }

    mapping(uint256 => uint256) public legsFailed;

    function retry(uint256 roundSeed, uint256 recipientSeed) external {
        if (paidRounds.length == 0) return;
        uint256 roundId = paidRounds[roundSeed % paidRounds.length];
        address to = recipients[recipientSeed % 4];
        uint256 owed = ledgerFailed[roundId][to];
        address[] memory arr = new address[](1);
        arr[0] = to;
        if (payout.paused()) {
            vm.prank(owner);
            vm.expectRevert(abi.encodeWithSelector(RoundPayout.EnforcedPause.selector));
            payout.retryFailed(roundId, arr);
            return;
        }
        if (owed == 0) {
            vm.prank(owner);
            vm.expectRevert(abi.encodeWithSelector(RoundPayout.NothingFailed.selector, roundId, to));
            payout.retryFailed(roundId, arr);
            return;
        }
        uint256 bal = token.balanceOf(address(payout));
        if (owed > bal) {
            vm.prank(owner);
            vm.expectRevert(abi.encodeWithSelector(RoundPayout.InsufficientBalance.selector, owed, bal));
            payout.retryFailed(roundId, arr);
            return;
        }
        vm.prank(owner);
        uint256 got = payout.retryFailed(roundId, arr);
        if (token.revertsFor(to)) {
            require(got == 0, "handler: retry paid a blocked recipient");
        } else {
            require(got == owed, "handler: retry amount");
            paidTotal += got;
            ledgerPaid[roundId] += got;
            delete ledgerFailed[roundId][to];
            ledgerFailedCount[roundId]--;
            retriesOk++;
        }
    }

    function writeOff(uint256 roundSeed, uint256 recipientSeed) external {
        if (paidRounds.length == 0) return;
        uint256 roundId = paidRounds[roundSeed % paidRounds.length];
        address to = recipients[recipientSeed % 4];
        uint256 owed = ledgerFailed[roundId][to];
        vm.prank(owner);
        if (owed == 0) {
            vm.expectRevert(abi.encodeWithSelector(RoundPayout.NothingFailed.selector, roundId, to));
            payout.writeOffFailed(roundId, to);
            return;
        }
        payout.writeOffFailed(roundId, to);
        writtenOffTotal += owed;
        delete ledgerFailed[roundId][to];
        ledgerFailedCount[roundId]--;
        writeOffs++;
    }

    function sweep(uint256 amount) external {
        uint256 bal = token.balanceOf(address(payout));
        amount = amount % (bal + 1);
        vm.prank(owner);
        payout.sweep(address(token), address(0x5EEE), amount);
        sweptTotal += amount;
    }

    function togglePause() external {
        bool paused = payout.paused();
        vm.prank(owner);
        if (paused) payout.unpause();
        else payout.pause();
    }

    /// @dev Replays an already-paid round id: must always revert, whatever else happened.
    function replay(uint256 roundSeed) external {
        if (paidRounds.length == 0) return;
        uint256 roundId = paidRounds[roundSeed % paidRounds.length];
        address[] memory to = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        to[0] = recipients[0];
        amounts[0] = 0;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(RoundPayout.RoundAlreadyPaid.selector, roundId));
        payout.payRound(roundId, address(token), to, amounts, 0, 0, 0);
    }

    /// @dev A stranger calling the privileged functions: must always revert.
    function strangerCalls(uint256 seed) external {
        address stranger = address(uint160(0xBAD0000 + seed % 7));
        address[] memory to = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        to[0] = recipients[0];
        vm.startPrank(stranger);
        vm.expectRevert(abi.encodeWithSelector(RoundPayout.OwnableUnauthorizedAccount.selector, stranger));
        payout.payRound(nextRound, address(token), to, amounts, 0, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(RoundPayout.OwnableUnauthorizedAccount.selector, stranger));
        payout.sweep(address(token), stranger, 1);
        vm.expectRevert(abi.encodeWithSelector(RoundPayout.OwnableUnauthorizedAccount.selector, stranger));
        payout.pause();
        vm.stopPrank();
    }
}

// =================================================================================================
// Tests
// =================================================================================================

contract RoundPayoutTest {
    VmRP constant vm = VmRP(address(uint160(uint256(keccak256("hevm cheat code")))));

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
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event Paused(address account);
    event Unpaused(address account);

    address constant OWNER = address(0x0E0E);
    address constant STRANGER = address(0x5713);
    address constant A = address(0xA1);
    address constant B = address(0xB2);
    address constant C = address(0xC3);

    RoundPayout payout;
    MockToken token;
    PayoutHandler handler;
    address[] private _targets;

    function setUp() public {
        payout = new RoundPayout(OWNER);
        token = new MockToken();
        token.mint(address(this), 1e30);
        token.approve(address(payout), type(uint256).max);
        handler = new PayoutHandler(payout, token, OWNER);
        _targets.push(address(handler));
    }

    function targetContracts() external view returns (address[] memory) {
        return _targets;
    }

    // ---------------------------------------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------------------------------------

    function assertEq(uint256 a, uint256 b, string memory m) internal pure {
        require(a == b, m);
    }

    function assertEq(address a, address b, string memory m) internal pure {
        require(a == b, m);
    }

    function assertTrue(bool c, string memory m) internal pure {
        require(c, m);
    }

    function _arr1(address a, uint256 x) internal pure returns (address[] memory to, uint256[] memory amts) {
        to = new address[](1);
        amts = new uint256[](1);
        to[0] = a;
        amts[0] = x;
    }

    function _arr3(uint256 x, uint256 y, uint256 z) internal pure returns (address[] memory to, uint256[] memory amts) {
        to = new address[](3);
        amts = new uint256[](3);
        to[0] = A;
        to[1] = B;
        to[2] = C;
        amts[0] = x;
        amts[1] = y;
        amts[2] = z;
    }

    function _fund(uint256 amount) internal {
        payout.fund(address(token), amount);
    }

    function _pay(uint256 roundId, address[] memory to, uint256[] memory amts) internal returns (uint256) {
        vm.prank(OWNER);
        return payout.payRound(roundId, address(token), to, amts, bytes32(roundId), 0, 0);
    }

    function _round(uint256 id)
        internal
        view
        returns (address tok, uint256 paidAt, uint256 count, uint256 failedCount, bytes32 hash, uint256 totalPaid)
    {
        return payout.rounds(id);
    }

    // ---------------------------------------------------------------------------------------------
    // constructor / ownership
    // ---------------------------------------------------------------------------------------------

    function test_constructorSetsOwner() public {
        vm.expectEmit(true, true, false, true);
        emit OwnershipTransferred(address(0), OWNER);
        RoundPayout p = new RoundPayout(OWNER);
        assertEq(p.owner(), OWNER, "owner");
        assertEq(p.pendingOwner(), address(0), "pending");
        assertTrue(!p.paused(), "not paused");
        assertEq(p.MAX_BATCH(), 500, "max batch");
    }

    function test_constructorRejectsZeroOwner() public {
        vm.expectRevert(abi.encodeWithSelector(RoundPayout.OwnableInvalidOwner.selector, address(0)));
        new RoundPayout(address(0));
    }

    function test_ownable2StepHandoff() public {
        address newOwner = address(0x0ABC);
        vm.prank(OWNER);
        vm.expectEmit(true, true, false, true);
        emit OwnershipTransferStarted(OWNER, newOwner);
        payout.transferOwnership(newOwner);
        // Nothing changes until acceptance: old owner still privileged, new one not yet.
        assertEq(payout.owner(), OWNER, "owner unchanged before accept");
        assertEq(payout.pendingOwner(), newOwner, "pending");
        vm.prank(newOwner);
        vm.expectRevert(abi.encodeWithSelector(RoundPayout.OwnableUnauthorizedAccount.selector, newOwner));
        payout.pause();
        vm.prank(OWNER);
        payout.pause();
        // Only the pending owner may accept.
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(RoundPayout.OwnableUnauthorizedAccount.selector, STRANGER));
        payout.acceptOwnership();
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(RoundPayout.OwnableUnauthorizedAccount.selector, OWNER));
        payout.acceptOwnership();
        vm.prank(newOwner);
        vm.expectEmit(true, true, false, true);
        emit OwnershipTransferred(OWNER, newOwner);
        payout.acceptOwnership();
        assertEq(payout.owner(), newOwner, "new owner");
        assertEq(payout.pendingOwner(), address(0), "pending cleared");
        // Old owner is locked out, new owner is in.
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(RoundPayout.OwnableUnauthorizedAccount.selector, OWNER));
        payout.unpause();
        vm.prank(newOwner);
        payout.unpause();
    }

    function test_transferOwnershipOnlyOwnerAndCancelable() public {
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(RoundPayout.OwnableUnauthorizedAccount.selector, STRANGER));
        payout.transferOwnership(STRANGER);
        vm.prank(OWNER);
        payout.transferOwnership(STRANGER);
        // Re-pointing to zero cancels the pending handoff.
        vm.prank(OWNER);
        payout.transferOwnership(address(0));
        assertEq(payout.pendingOwner(), address(0), "cancelled");
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(RoundPayout.OwnableUnauthorizedAccount.selector, STRANGER));
        payout.acceptOwnership();
    }

    function test_renounceOwnershipLocksEverything() public {
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(RoundPayout.OwnableUnauthorizedAccount.selector, STRANGER));
        payout.renounceOwnership();
        vm.prank(OWNER);
        payout.transferOwnership(STRANGER);
        vm.prank(OWNER);
        payout.renounceOwnership();
        assertEq(payout.owner(), address(0), "no owner");
        assertEq(payout.pendingOwner(), address(0), "pending cleared on renounce");
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(RoundPayout.OwnableUnauthorizedAccount.selector, OWNER));
        payout.pause();
    }

    function test_privilegedFunctionsRejectNonOwner() public {
        (address[] memory to, uint256[] memory amts) = _arr1(A, 1);
        vm.startPrank(STRANGER);
        bytes memory err = abi.encodeWithSelector(RoundPayout.OwnableUnauthorizedAccount.selector, STRANGER);
        vm.expectRevert(err);
        payout.payRound(1, address(token), to, amts, 0, 0, 0);
        vm.expectRevert(err);
        payout.sweep(address(token), STRANGER, 1);
        vm.expectRevert(err);
        payout.retryFailed(1, to);
        vm.expectRevert(err);
        payout.writeOffFailed(1, A);
        vm.expectRevert(err);
        payout.pause();
        vm.expectRevert(err);
        payout.unpause();
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------------------------------
    // fund / sweep
    // ---------------------------------------------------------------------------------------------

    function test_fundPullsTokensFromAnyone() public {
        token.mint(STRANGER, 5e18);
        vm.startPrank(STRANGER);
        token.approve(address(payout), 5e18);
        vm.expectEmit(true, true, false, true);
        emit Funded(address(token), STRANGER, 5e18);
        payout.fund(address(token), 5e18);
        vm.stopPrank();
        assertEq(token.balanceOf(address(payout)), 5e18, "funded");
        assertEq(token.balanceOf(STRANGER), 0, "pulled");
    }

    function test_fundZeroAmountSucceeds() public {
        payout.fund(address(token), 0);
        assertEq(token.balanceOf(address(payout)), 0, "nothing");
    }

    function test_fundWithoutApprovalReverts() public {
        token.mint(STRANGER, 1);
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(RoundPayout.SafeERC20FailedOperation.selector, address(token)));
        payout.fund(address(token), 1);
    }

    function test_fundRejectsFalseReturningToken() public {
        FalseToken f = new FalseToken();
        vm.expectRevert(abi.encodeWithSelector(RoundPayout.SafeERC20FailedOperation.selector, address(f)));
        payout.fund(address(f), 1);
    }

    function test_fundRejectsEoaToken() public {
        vm.expectRevert(abi.encodeWithSelector(RoundPayout.SafeERC20FailedOperation.selector, address(0xDEAD1)));
        payout.fund(address(0xDEAD1), 1);
    }

    function test_fundAcceptsNoReturnToken() public {
        NoReturnToken u = new NoReturnToken();
        u.mint(address(this), 10);
        u.approve(address(payout), 10);
        payout.fund(address(u), 10);
        assertEq(u.balanceOf(address(payout)), 10, "usdt-style funded");
    }

    function test_sweepByOwnerMovesTokens() public {
        _fund(10e18);
        vm.prank(OWNER);
        vm.expectEmit(true, true, false, true);
        emit Swept(address(token), B, 4e18);
        payout.sweep(address(token), B, 4e18);
        assertEq(token.balanceOf(B), 4e18, "swept");
        assertEq(token.balanceOf(address(payout)), 6e18, "remaining");
    }

    function test_sweepWorksWhilePaused() public {
        _fund(1);
        vm.startPrank(OWNER);
        payout.pause();
        payout.sweep(address(token), B, 1);
        vm.stopPrank();
        assertEq(token.balanceOf(B), 1, "swept while paused");
    }

    function test_sweepRejectsZeroRecipient() public {
        _fund(1);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(RoundPayout.ZeroAddress.selector));
        payout.sweep(address(token), address(0), 1);
    }

    function test_sweepAboveBalanceReverts() public {
        _fund(1);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(RoundPayout.SafeERC20FailedOperation.selector, address(token)));
        payout.sweep(address(token), B, 2);
    }

    function test_sweepRejectsShortReturnData() public {
        ShortReturnToken s = new ShortReturnToken();
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(RoundPayout.SafeERC20FailedOperation.selector, address(s)));
        payout.sweep(address(s), B, 1);
    }

    // ---------------------------------------------------------------------------------------------
    // payRound: happy path
    // ---------------------------------------------------------------------------------------------

    function test_payRoundPaysEveryLegAndRecords() public {
        _fund(100e18);
        (address[] memory to, uint256[] memory amts) = _arr3(10e18, 20e18, 30e18);
        vm.warp(1_700_000_000);
        vm.prank(OWNER);
        vm.expectEmit(true, true, false, true);
        emit Paid(7, A, 10e18);
        vm.expectEmit(true, true, false, true);
        emit Paid(7, B, 20e18);
        vm.expectEmit(true, true, false, true);
        emit Paid(7, C, 30e18);
        vm.expectEmit(true, true, false, true);
        emit RoundPaid(7, address(token), bytes32(uint256(0xABCD)), 99, 123, 60e18, 3);
        uint256 total = payout.payRound(7, address(token), to, amts, bytes32(uint256(0xABCD)), 99, 123);
        assertEq(total, 60e18, "totalPaid returned");
        assertTrue(payout.isPaid(7), "isPaid");
        assertTrue(!payout.isPaid(8), "other round not paid");
        (address tok, uint256 paidAt, uint256 count, uint256 failedCount, bytes32 hash, uint256 totalPaid) = _round(7);
        assertEq(tok, address(token), "token");
        assertEq(paidAt, 1_700_000_000, "paidAt");
        assertEq(count, 3, "count");
        assertEq(failedCount, 0, "failedCount");
        assertTrue(hash == bytes32(uint256(0xABCD)), "ledgerHash");
        assertEq(totalPaid, 60e18, "totalPaid");
        assertEq(token.balanceOf(A), 10e18, "A");
        assertEq(token.balanceOf(B), 20e18, "B");
        assertEq(token.balanceOf(C), 30e18, "C");
        assertEq(token.balanceOf(address(payout)), 40e18, "remaining");
    }

    function test_payRoundExactBalanceSucceeds() public {
        _fund(30e18);
        (address[] memory to, uint256[] memory amts) = _arr3(10e18, 10e18, 10e18);
        _pay(1, to, amts);
        assertEq(token.balanceOf(address(payout)), 0, "drained exactly");
    }

    function test_payRoundZeroAmountLegIsPaid() public {
        (address[] memory to, uint256[] memory amts) = _arr1(A, 0);
        uint256 total = _pay(1, to, amts);
        assertEq(total, 0, "zero total");
        assertTrue(payout.isPaid(1), "paid with zero amounts");
    }

    function test_payRoundRoundIdZeroIsOrdinary() public {
        _fund(1);
        (address[] memory to, uint256[] memory amts) = _arr1(A, 1);
        _pay(0, to, amts);
        assertTrue(payout.isPaid(0), "round 0 paid");
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(RoundPayout.RoundAlreadyPaid.selector, 0));
        payout.payRound(0, address(token), to, amts, 0, 0, 0);
    }

    function test_payRoundMaxBatchOf500() public {
        _fund(500);
        address[] memory to = new address[](500);
        uint256[] memory amts = new uint256[](500);
        for (uint256 i = 0; i < 500; ++i) {
            to[i] = address(uint160(0x10000 + i));
            amts[i] = 1;
        }
        uint256 total = _pay(1, to, amts);
        assertEq(total, 500, "500 legs");
        (,, uint256 count,,,) = _round(1);
        assertEq(count, 500, "count 500");
    }

    function test_payRoundWithNoReturnToken() public {
        NoReturnToken u = new NoReturnToken();
        u.mint(address(payout), 10);
        (address[] memory to, uint256[] memory amts) = _arr1(A, 10);
        vm.prank(OWNER);
        uint256 total = payout.payRound(1, address(u), to, amts, 0, 0, 0);
        assertEq(total, 10, "usdt-style leg paid");
        assertEq(u.balanceOf(A), 10, "A got it");
    }

    function test_payRoundIsTokenAgnosticPerRound() public {
        NoReturnToken u = new NoReturnToken();
        u.mint(address(payout), 1);
        _fund(1);
        (address[] memory to, uint256[] memory amts) = _arr1(A, 1);
        _pay(1, to, amts);
        vm.prank(OWNER);
        payout.payRound(2, address(u), to, amts, 0, 0, 0);
        (address t1,,,,,) = _round(1);
        (address t2,,,,,) = _round(2);
        assertEq(t1, address(token), "round 1 token");
        assertEq(t2, address(u), "round 2 token");
    }

    // ---------------------------------------------------------------------------------------------
    // payRound: reverts
    // ---------------------------------------------------------------------------------------------

    function test_payRoundIdempotent() public {
        _fund(10);
        (address[] memory to, uint256[] memory amts) = _arr1(A, 1);
        _pay(5, to, amts);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(RoundPayout.RoundAlreadyPaid.selector, 5));
        payout.payRound(5, address(token), to, amts, 0, 0, 0);
        // Different token, same id: still rejected.
        NoReturnToken u = new NoReturnToken();
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(RoundPayout.RoundAlreadyPaid.selector, 5));
        payout.payRound(5, address(u), to, amts, 0, 0, 0);
        assertEq(token.balanceOf(A), 1, "paid once");
    }

    function test_payRoundLengthMismatch() public {
        address[] memory to = new address[](2);
        uint256[] memory amts = new uint256[](1);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(RoundPayout.LengthMismatch.selector));
        payout.payRound(1, address(token), to, amts, 0, 0, 0);
    }

    function test_payRoundEmptyBatch() public {
        address[] memory to = new address[](0);
        uint256[] memory amts = new uint256[](0);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(RoundPayout.EmptyBatch.selector));
        payout.payRound(1, address(token), to, amts, 0, 0, 0);
        assertTrue(!payout.isPaid(1), "empty batch does not mark paid");
    }

    function test_payRoundBatchTooLarge() public {
        address[] memory to = new address[](501);
        uint256[] memory amts = new uint256[](501);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(RoundPayout.BatchTooLarge.selector, 501));
        payout.payRound(1, address(token), to, amts, 0, 0, 0);
    }

    function test_payRoundZeroToken() public {
        (address[] memory to, uint256[] memory amts) = _arr1(A, 1);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(RoundPayout.ZeroAddress.selector));
        payout.payRound(1, address(0), to, amts, 0, 0, 0);
    }

    function test_payRoundInsufficientBalanceUpFront() public {
        _fund(29e18);
        (address[] memory to, uint256[] memory amts) = _arr3(10e18, 10e18, 10e18);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(RoundPayout.InsufficientBalance.selector, 30e18, 29e18));
        payout.payRound(1, address(token), to, amts, 0, 0, 0);
        // Nothing moved, nothing recorded.
        assertEq(token.balanceOf(A), 0, "A unpaid");
        assertTrue(!payout.isPaid(1), "not paid");
    }

    function test_payRoundSumOverflowReverts() public {
        address[] memory to = new address[](2);
        uint256[] memory amts = new uint256[](2);
        to[0] = A;
        to[1] = B;
        amts[0] = type(uint256).max;
        amts[1] = 1;
        vm.prank(OWNER);
        vm.expectRevert();
        payout.payRound(1, address(token), to, amts, 0, 0, 0);
    }

    function test_payRoundBlockedWhilePaused() public {
        _fund(1);
        (address[] memory to, uint256[] memory amts) = _arr1(A, 1);
        vm.startPrank(OWNER);
        vm.expectEmit(false, false, false, true);
        emit Paused(OWNER);
        payout.pause();
        assertTrue(payout.paused(), "paused");
        vm.expectRevert(abi.encodeWithSelector(RoundPayout.EnforcedPause.selector));
        payout.payRound(1, address(token), to, amts, 0, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(RoundPayout.EnforcedPause.selector));
        payout.retryFailed(1, to);
        vm.expectEmit(false, false, false, true);
        emit Unpaused(OWNER);
        payout.unpause();
        payout.payRound(1, address(token), to, amts, 0, 0, 0);
        vm.stopPrank();
        assertTrue(payout.isPaid(1), "paid after unpause");
    }

    function test_pauseTwiceAndUnpauseWhenRunningRevert() public {
        vm.startPrank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(RoundPayout.ExpectedPause.selector));
        payout.unpause();
        payout.pause();
        vm.expectRevert(abi.encodeWithSelector(RoundPayout.EnforcedPause.selector));
        payout.pause();
        vm.stopPrank();
    }

    function test_payRoundWithEoaTokenReverts() public {
        (address[] memory to, uint256[] memory amts) = _arr1(A, 1);
        vm.prank(OWNER);
        vm.expectRevert();
        payout.payRound(1, address(0xDEAD2), to, amts, 0, 0, 0);
    }

    // ---------------------------------------------------------------------------------------------
    // payRound: partial failure accounting
    // ---------------------------------------------------------------------------------------------

    function test_partialFailureIsRecordedAndBatchContinues() public {
        _fund(60e18);
        token.setRevertsFor(B, true);
        (address[] memory to, uint256[] memory amts) = _arr3(10e18, 20e18, 30e18);
        vm.prank(OWNER);
        vm.expectEmit(true, true, false, true);
        emit Paid(1, A, 10e18);
        vm.expectEmit(true, true, false, true);
        emit PayFailed(1, B, 20e18, abi.encodeWithSelector(MockToken.Blocked.selector, B));
        vm.expectEmit(true, true, false, true);
        emit Paid(1, C, 30e18);
        vm.expectEmit(true, true, false, true);
        emit RoundPaid(1, address(token), bytes32(0), 0, 0, 40e18, 3);
        uint256 total = payout.payRound(1, address(token), to, amts, 0, 0, 0);
        assertEq(total, 40e18, "totalPaid excludes failed leg");
        assertTrue(payout.isPaid(1), "round marked paid despite failure");
        assertEq(payout.failed(1, B), 20e18, "failed amount stored");
        assertEq(payout.failed(1, A), 0, "A not failed");
        (,, uint256 count, uint256 failedCount,, uint256 totalPaid) = _round(1);
        assertEq(count, 3, "count");
        assertEq(failedCount, 1, "failedCount");
        assertEq(totalPaid, 40e18, "record totalPaid");
        assertEq(token.balanceOf(address(payout)), 20e18, "failed amount stays in contract");
    }

    function test_partialFailureSilentRevertAndFalseReturn() public {
        _fund(3);
        token.setSilentFor(A, true);
        token.setFalseFor(B, true);
        (address[] memory to, uint256[] memory amts) = _arr3(1, 1, 1);
        vm.prank(OWNER);
        vm.expectEmit(true, true, false, true);
        emit PayFailed(1, A, 1, "");
        vm.expectEmit(true, true, false, true);
        emit PayFailed(1, B, 1, abi.encode(false));
        uint256 total = payout.payRound(1, address(token), to, amts, 0, 0, 0);
        assertEq(total, 1, "only C paid");
        assertEq(payout.failed(1, A), 1, "A failed");
        assertEq(payout.failed(1, B), 1, "B failed (returned false)");
        (,,, uint256 failedCount,,) = _round(1);
        assertEq(failedCount, 2, "two failed legs");
    }

    function test_duplicateFailedRecipientAccumulates() public {
        _fund(10);
        token.setRevertsFor(A, true);
        address[] memory to = new address[](3);
        uint256[] memory amts = new uint256[](3);
        to[0] = A;
        to[1] = A;
        to[2] = B;
        amts[0] = 3;
        amts[1] = 4;
        amts[2] = 1;
        _pay(1, to, amts);
        assertEq(payout.failed(1, A), 7, "accumulated");
        (,,, uint256 failedCount,,) = _round(1);
        assertEq(failedCount, 2, "two legs failed");
    }

    function test_allTransfersFailedReverts() public {
        _fund(10);
        token.setRevertsFor(A, true);
        token.setRevertsFor(B, true);
        token.setRevertsFor(C, true);
        (address[] memory to, uint256[] memory amts) = _arr3(1, 1, 1);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(RoundPayout.AllTransfersFailed.selector, 1));
        payout.payRound(1, address(token), to, amts, 0, 0, 0);
        assertTrue(!payout.isPaid(1), "not marked paid");
        assertEq(payout.failed(1, A), 0, "failed map rolled back");
    }

    function test_singleLegFailureIsAllTransfersFailed() public {
        _fund(1);
        token.setRevertsFor(A, true);
        (address[] memory to, uint256[] memory amts) = _arr1(A, 1);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(RoundPayout.AllTransfersFailed.selector, 1));
        payout.payRound(1, address(token), to, amts, 0, 0, 0);
    }

    function test_reentrantTokenCannotReenterPayRound() public {
        _fund(10);
        (address[] memory to, uint256[] memory amts) = _arr3(1, 2, 3);
        (address[] memory nestedTo, uint256[] memory nestedAmts) = _arr1(C, 1);
        // The token calls payRound(2, ...) from inside the first leg's transfer. onlyOwner runs
        // before nonReentrant and rejects the token; it bubbles that revert, so leg A fails with
        // that reason and the batch continues with B and C. (The guard itself is exercised by the
        // fund/sweep reentry test below, where no access check precedes it.)
        token.setReenter(
            address(payout),
            abi.encodeCall(payout.payRound, (2, address(token), nestedTo, nestedAmts, bytes32(0), 0, 0))
        );
        vm.prank(OWNER);
        vm.expectEmit(true, true, false, true);
        emit PayFailed(1, A, 1, abi.encodeWithSelector(RoundPayout.OwnableUnauthorizedAccount.selector, address(token)));
        vm.expectEmit(true, true, false, true);
        emit Paid(1, B, 2);
        uint256 total = payout.payRound(1, address(token), to, amts, 0, 0, 0);
        assertEq(total, 5, "B and C paid, A failed");
        assertEq(payout.failed(1, A), 1, "A recorded as failed");
        assertTrue(payout.isPaid(1), "outer round paid");
        assertTrue(!payout.isPaid(2), "nested round never paid");
        assertEq(token.balanceOf(C), 3, "C paid once, not by the nested call");
    }

    function test_reentrantTokenCannotReenterFundOrSweepDuringPayRound() public {
        _fund(10);
        (address[] memory to, uint256[] memory amts) = _arr3(1, 1, 1);
        token.setReenter(address(payout), abi.encodeCall(payout.fund, (address(token), 1)));
        vm.prank(OWNER);
        vm.expectEmit(true, true, false, true);
        emit PayFailed(1, A, 1, abi.encodeWithSelector(RoundPayout.ReentrancyGuardReentrantCall.selector));
        payout.payRound(1, address(token), to, amts, 0, 0, 0);
        assertEq(token.balanceOf(address(payout)), 8, "no nested fund happened");
        // sweep via a malicious token during a round
        token.setReenter(address(payout), abi.encodeCall(payout.sweep, (address(token), STRANGER, 1)));
        vm.prank(OWNER);
        uint256 total = payout.payRound(2, address(token), to, amts, 0, 0, 0);
        assertEq(total, 2, "first leg failed on reentrant sweep");
        assertEq(token.balanceOf(STRANGER), 0, "nothing swept");
    }

    // ---------------------------------------------------------------------------------------------
    // retryFailed / writeOffFailed
    // ---------------------------------------------------------------------------------------------

    function _payWithBFailed() internal {
        _fund(60e18);
        token.setRevertsFor(B, true);
        (address[] memory to, uint256[] memory amts) = _arr3(10e18, 20e18, 30e18);
        _pay(1, to, amts);
    }

    function test_retryFailedPaysAndClears() public {
        _payWithBFailed();
        token.setRevertsFor(B, false);
        address[] memory r = new address[](1);
        r[0] = B;
        vm.prank(OWNER);
        vm.expectEmit(true, true, false, true);
        emit Paid(1, B, 20e18);
        uint256 got = payout.retryFailed(1, r);
        assertEq(got, 20e18, "retry total");
        assertEq(payout.failed(1, B), 0, "cleared");
        assertEq(token.balanceOf(B), 20e18, "B paid");
        (,,, uint256 failedCount,, uint256 totalPaid) = _round(1);
        assertEq(failedCount, 0, "failedCount back to 0");
        assertEq(totalPaid, 60e18, "totalPaid includes retry");
        // Second retry: nothing owed.
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(RoundPayout.NothingFailed.selector, 1, B));
        payout.retryFailed(1, r);
    }

    function test_retryFailedStillFailingKeepsRecord() public {
        _payWithBFailed();
        address[] memory r = new address[](1);
        r[0] = B;
        vm.prank(OWNER);
        vm.expectEmit(true, true, false, true);
        emit PayFailed(1, B, 20e18, abi.encodeWithSelector(MockToken.Blocked.selector, B));
        uint256 got = payout.retryFailed(1, r);
        assertEq(got, 0, "nothing paid");
        assertEq(payout.failed(1, B), 20e18, "still owed");
        (,,, uint256 failedCount,, uint256 totalPaid) = _round(1);
        assertEq(failedCount, 1, "still failed");
        assertEq(totalPaid, 40e18, "unchanged");
    }

    function test_retryFailedRevertsForUnpaidRound() public {
        address[] memory r = new address[](1);
        r[0] = B;
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(RoundPayout.RoundNotPaid.selector, 9));
        payout.retryFailed(9, r);
    }

    function test_retryFailedShapeChecks() public {
        _payWithBFailed();
        vm.startPrank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(RoundPayout.EmptyBatch.selector));
        payout.retryFailed(1, new address[](0));
        vm.expectRevert(abi.encodeWithSelector(RoundPayout.BatchTooLarge.selector, 501));
        payout.retryFailed(1, new address[](501));
        address[] memory dup = new address[](2);
        dup[0] = B;
        dup[1] = B;
        token.setRevertsFor(B, false);
        // The pre-check sums the owed amount once per entry, so a duplicate first trips the
        // balance check; with enough balance it is the NothingFailed on the second entry.
        vm.expectRevert(abi.encodeWithSelector(RoundPayout.InsufficientBalance.selector, 40e18, 20e18));
        payout.retryFailed(1, dup);
        vm.stopPrank();
        _fund(100e18);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(RoundPayout.NothingFailed.selector, 1, B));
        payout.retryFailed(1, dup);
        assertEq(payout.failed(1, B), 20e18, "duplicate retry rolled back");
    }

    function test_retryFailedInsufficientBalanceAfterSweep() public {
        _payWithBFailed();
        vm.prank(OWNER);
        payout.sweep(address(token), OWNER, 20e18); // drains the held failed amount
        token.setRevertsFor(B, false);
        address[] memory r = new address[](1);
        r[0] = B;
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(RoundPayout.InsufficientBalance.selector, 20e18, 0));
        payout.retryFailed(1, r);
    }

    function test_writeOffFailedClearsWithoutPaying() public {
        _payWithBFailed();
        uint256 bal = token.balanceOf(address(payout));
        vm.prank(OWNER);
        vm.expectEmit(true, true, false, true);
        emit WrittenOff(1, B, 20e18);
        payout.writeOffFailed(1, B);
        assertEq(payout.failed(1, B), 0, "cleared");
        assertEq(token.balanceOf(B), 0, "not paid");
        assertEq(token.balanceOf(address(payout)), bal, "balance untouched");
        (,,, uint256 failedCount,, uint256 totalPaid) = _round(1);
        assertEq(failedCount, 0, "failedCount");
        assertEq(totalPaid, 40e18, "totalPaid unchanged");
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(RoundPayout.NothingFailed.selector, 1, B));
        payout.writeOffFailed(1, B);
    }

    function test_writeOffFailedNothingOwedReverts() public {
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(RoundPayout.NothingFailed.selector, 3, A));
        payout.writeOffFailed(3, A);
    }

    // ---------------------------------------------------------------------------------------------
    // fuzz
    // ---------------------------------------------------------------------------------------------

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_payRoundAccounting(uint256 fundAmt, uint256 a, uint256 b, uint256 c, uint8 blockedMask) public {
        a %= 1e24;
        b %= 1e24;
        c %= 1e24;
        fundAmt %= 3e24;
        _fund(fundAmt);
        (address[] memory to, uint256[] memory amts) = _arr3(a, b, c);
        bool[3] memory blocked = [blockedMask & 1 != 0, blockedMask & 2 != 0, blockedMask & 4 != 0];
        uint256 expectPaid;
        uint256 expectFailed;
        for (uint256 i = 0; i < 3; ++i) {
            token.setRevertsFor(to[i], blocked[i]);
            if (blocked[i]) expectFailed++;
            else expectPaid += amts[i];
        }
        uint256 sum = a + b + c;
        vm.prank(OWNER);
        if (sum > fundAmt) {
            vm.expectRevert(abi.encodeWithSelector(RoundPayout.InsufficientBalance.selector, sum, fundAmt));
            payout.payRound(1, address(token), to, amts, 0, 0, 0);
            return;
        }
        if (expectFailed == 3) {
            vm.expectRevert(abi.encodeWithSelector(RoundPayout.AllTransfersFailed.selector, 1));
            payout.payRound(1, address(token), to, amts, 0, 0, 0);
            return;
        }
        uint256 total = payout.payRound(1, address(token), to, amts, 0, 0, 0);
        assertEq(total, expectPaid, "totalPaid");
        assertTrue(total <= fundAmt, "sum(Paid) <= funded");
        assertEq(token.balanceOf(address(payout)), fundAmt - expectPaid, "contract keeps failed + surplus");
        (,,, uint256 failedCount,, uint256 totalPaid) = _round(1);
        assertEq(failedCount, expectFailed, "failedCount");
        assertEq(totalPaid, expectPaid, "record");
        for (uint256 i = 0; i < 3; ++i) {
            assertEq(payout.failed(1, to[i]), blocked[i] ? amts[i] : 0, "failed map");
        }
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_batchSizeBoundary(uint16 n) public {
        n = uint16(n % 600);
        address[] memory to = new address[](n);
        uint256[] memory amts = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            to[i] = address(uint160(0x20000 + i));
        }
        vm.prank(OWNER);
        if (n == 0) {
            vm.expectRevert(abi.encodeWithSelector(RoundPayout.EmptyBatch.selector));
        } else if (n > 500) {
            vm.expectRevert(abi.encodeWithSelector(RoundPayout.BatchTooLarge.selector, uint256(n)));
        }
        payout.payRound(1, address(token), to, amts, 0, 0, 0);
    }

    // ---------------------------------------------------------------------------------------------
    // invariants (random sequences of fund / payRound / retry / writeOff / sweep / pause)
    // ---------------------------------------------------------------------------------------------

    /// forge-config: default.invariant.runs = 96
    /// forge-config: default.invariant.depth = 40
    function invariant_balanceEqualsFundedMinusPaidMinusSwept() public view {
        assertEq(
            token.balanceOf(address(payout)),
            handler.funded() - handler.paidTotal() - handler.sweptTotal(),
            "held != funded - paid - swept"
        );
    }

    /// forge-config: default.invariant.runs = 96
    /// forge-config: default.invariant.depth = 40
    function invariant_sumPaidNeverExceedsFunded() public view {
        assertTrue(handler.paidTotal() + handler.sweptTotal() <= handler.funded(), "paid out more than funded");
        // Recipients hold exactly what was paid to them.
        uint256 held;
        for (uint256 i = 0; i < 4; ++i) {
            held += token.balanceOf(handler.recipients(i));
        }
        assertEq(held, handler.paidTotal(), "recipient balances != sum(Paid)");
    }

    /// forge-config: default.invariant.runs = 96
    /// forge-config: default.invariant.depth = 40
    function invariant_roundRecordsMatchLedger() public view {
        uint256 n = handler.paidRoundCount();
        for (uint256 i = 0; i < n; ++i) {
            uint256 id = handler.paidRounds(i);
            assertTrue(payout.isPaid(id), "paid round reopened");
            (address tok,, uint256 count, uint256 failedCount,, uint256 totalPaid) = payout.rounds(id);
            assertEq(tok, address(token), "token");
            assertTrue(count >= 1 && count <= 6, "count");
            assertEq(totalPaid, handler.ledgerPaid(id), "totalPaid vs ledger");
            uint256 owed;
            for (uint256 r = 0; r < 4; ++r) {
                address who = handler.recipients(r);
                assertEq(payout.failed(id, who), handler.ledgerFailed(id, who), "failed vs ledger");
                owed += payout.failed(id, who);
            }
            // failedCount counts legs, so it is at least the number of distinct recipients still
            // owed, and zero exactly when nothing is owed.
            if (owed == 0) {
                assertTrue(
                    failedCount == 0 || handler.legsFailed(id) > handler.ledgerFailedCount(id),
                    "failedCount with nothing owed"
                );
            } else {
                assertTrue(failedCount >= handler.ledgerFailedCount(id), "failedCount below owed recipients");
            }
        }
        // Unpaid ids stay unpaid.
        assertTrue(!payout.isPaid(handler.nextRound()), "future round paid");
    }

    /// forge-config: default.invariant.runs = 96
    /// forge-config: default.invariant.depth = 40
    function invariant_ownerNeverChangesWithoutHandoff() public view {
        assertEq(payout.owner(), OWNER, "owner drifted");
        assertEq(payout.pendingOwner(), address(0), "pending owner set");
    }
}
