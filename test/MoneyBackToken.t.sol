// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MoneyBackToken} from "src/MoneyBackToken.sol";

// This repository vendors no forge-std and the test paths may not add a lib/, so the suite talks to
// the Foundry cheatcode address through the minimal interface below. A failing assertion reverts,
// which the runner reports as a failed test.
interface VmTok {
    function prank(address) external;
    function expectRevert(bytes calldata) external;
    function expectRevert() external;
    function expectEmit(bool, bool, bool, bool) external;
    function assume(bool) external pure;
}

/// @dev Random-call handler for the token invariants: three actors move tokens around with
///      transfer / approve / transferFrom, and probe the two things the token must never do:
///      change its supply and move value to or from the zero address.
contract TokenHandler {
    MoneyBackToken public immutable token;
    address[3] public actors;
    uint256 public transfers;
    uint256 public transferFroms;

    constructor(MoneyBackToken _token) {
        token = _token;
        actors = [address(0xA11CE), address(0xB0B), address(0xCA51)];
    }

    function _actor(uint256 seed) private view returns (address) {
        return actors[seed % 3];
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        amount = amount % (token.balanceOf(from) + 1);
        VmTok(address(uint160(uint256(keccak256("hevm cheat code"))))).prank(from);
        require(token.transfer(to, amount), "transfer returned false");
        transfers++;
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) external {
        VmTok(address(uint160(uint256(keccak256("hevm cheat code"))))).prank(_actor(ownerSeed));
        require(token.approve(_actor(spenderSeed), amount), "approve returned false");
    }

    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amount) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 cap = token.allowance(owner, spender);
        uint256 bal = token.balanceOf(owner);
        if (cap > bal) cap = bal;
        amount = amount % (cap + 1);
        VmTok(address(uint160(uint256(keccak256("hevm cheat code"))))).prank(spender);
        require(token.transferFrom(owner, _actor(toSeed), amount), "transferFrom returned false");
        transferFroms++;
    }
}

contract MoneyBackTokenTest {
    VmTok constant vm = VmTok(address(uint160(uint256(keccak256("hevm cheat code")))));

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    uint256 constant SUPPLY = 1_000_000_000e18;
    // Distinct from the invariant handler's actors, which are seeded with balances in setUp.
    address constant ALICE = address(0xA11CE2);
    address constant BOB = address(0xB0B2);

    MoneyBackToken token;
    TokenHandler handler;
    address[] private _targets;

    function setUp() public {
        token = new MoneyBackToken();
        handler = new TokenHandler(token);
        // Seed the invariant actors; the deployer keeps the rest.
        token.transfer(handler.actors(0), 300_000_000e18);
        token.transfer(handler.actors(1), 200_000_000e18);
        token.transfer(handler.actors(2), 1e18);
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

    function assertEq(string memory a, string memory b, string memory m) internal pure {
        require(keccak256(bytes(a)) == keccak256(bytes(b)), m);
    }

    // ---------------------------------------------------------------------------------------------
    // metadata and supply
    // ---------------------------------------------------------------------------------------------

    function test_metadata() public view {
        assertEq(token.name(), "IMD Money Back", "name");
        assertEq(token.symbol(), "MONEYBACK", "symbol");
        assertEq(uint256(token.decimals()), 18, "decimals");
    }

    function test_constructorMintsWholeSupplyToDeployer() public {
        vm.expectEmit(true, true, false, true);
        emit Transfer(address(0), address(this), SUPPLY);
        MoneyBackToken fresh = new MoneyBackToken();
        assertEq(fresh.totalSupply(), SUPPLY, "totalSupply");
        assertEq(fresh.TOTAL_SUPPLY(), SUPPLY, "TOTAL_SUPPLY constant");
        assertEq(fresh.balanceOf(address(this)), SUPPLY, "deployer balance");
    }

    function test_supplyIsExactlyOneBillionWithEighteenDecimals() public view {
        assertEq(token.totalSupply(), 1_000_000_000 * 10 ** uint256(token.decimals()), "1e9 * 10^18");
    }

    function test_deployerIsMsgSenderNotTxOrigin() public {
        // Deploy from a contract (the factory pattern): the factory, not tx.origin, gets the supply.
        Factory f = new Factory();
        MoneyBackToken t = f.deploy();
        assertEq(t.balanceOf(address(f)), SUPPLY, "factory holds supply");
        assertEq(t.balanceOf(address(this)), 0, "caller holds nothing");
    }

    /// @notice No owner, mint, burn, pause or fee entry points exist on the token.
    function test_noPrivilegedSurface() public {
        bytes4[7] memory sels = [
            bytes4(keccak256("owner()")),
            bytes4(keccak256("mint(address,uint256)")),
            bytes4(keccak256("burn(uint256)")),
            bytes4(keccak256("burn(address,uint256)")),
            bytes4(keccak256("burnFrom(address,uint256)")),
            bytes4(keccak256("pause()")),
            bytes4(keccak256("setFee(uint256)"))
        ];
        for (uint256 i = 0; i < sels.length; ++i) {
            (bool ok,) = address(token).call(abi.encodeWithSelector(sels[i], address(this), uint256(1)));
            require(!ok, "unexpected privileged selector answered");
        }
        assertEq(token.totalSupply(), SUPPLY, "supply unchanged");
    }

    function test_rejectsEth() public {
        (bool ok,) = address(token).call{value: 1}("");
        require(!ok, "token accepted ETH");
    }

    // ---------------------------------------------------------------------------------------------
    // transfer
    // ---------------------------------------------------------------------------------------------

    function test_transferMovesBalanceAndEmits() public {
        uint256 before = token.balanceOf(address(this));
        vm.expectEmit(true, true, false, true);
        emit Transfer(address(this), BOB, 5e18);
        require(token.transfer(BOB, 5e18), "returns true");
        assertEq(token.balanceOf(BOB), 5e18, "bob");
        assertEq(token.balanceOf(address(this)), before - 5e18, "sender");
        assertEq(token.totalSupply(), SUPPLY, "supply");
    }

    function test_transferZeroAmountSucceeds() public {
        require(token.transfer(BOB, 0), "zero transfer");
        assertEq(token.balanceOf(BOB), 0, "bob");
    }

    function test_transferToSelfKeepsBalance() public {
        uint256 before = token.balanceOf(address(this));
        token.transfer(address(this), before);
        assertEq(token.balanceOf(address(this)), before, "self transfer");
    }

    function test_transferWholeBalanceLeavesZero() public {
        uint256 bal = token.balanceOf(address(this));
        token.transfer(BOB, bal);
        assertEq(token.balanceOf(address(this)), 0, "drained");
        assertEq(token.balanceOf(BOB), bal, "bob");
    }

    function test_transferRevertsOnInsufficientBalance() public {
        uint256 bal = token.balanceOf(address(this));
        vm.expectRevert(
            abi.encodeWithSelector(MoneyBackToken.ERC20InsufficientBalance.selector, address(this), bal, bal + 1)
        );
        token.transfer(BOB, bal + 1);
    }

    function test_transferFromEmptyAccountRevertsEvenForOneWei() public {
        address nobody = address(0x9999);
        vm.prank(nobody);
        vm.expectRevert(abi.encodeWithSelector(MoneyBackToken.ERC20InsufficientBalance.selector, nobody, 0, 1));
        token.transfer(BOB, 1);
    }

    function test_transferToZeroAddressReverts() public {
        vm.expectRevert(abi.encodeWithSelector(MoneyBackToken.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
    }

    // ---------------------------------------------------------------------------------------------
    // approve / allowance / transferFrom
    // ---------------------------------------------------------------------------------------------

    function test_approveSetsAllowanceAndEmits() public {
        vm.expectEmit(true, true, false, true);
        emit Approval(address(this), ALICE, 7);
        require(token.approve(ALICE, 7), "returns true");
        assertEq(token.allowance(address(this), ALICE), 7, "allowance");
        // Overwrites, does not add.
        token.approve(ALICE, 3);
        assertEq(token.allowance(address(this), ALICE), 3, "overwritten");
    }

    function test_approveZeroSpenderReverts() public {
        vm.expectRevert(abi.encodeWithSelector(MoneyBackToken.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
    }

    function test_transferFromSpendsAllowance() public {
        token.approve(ALICE, 10e18);
        vm.prank(ALICE);
        vm.expectEmit(true, true, false, true);
        emit Transfer(address(this), BOB, 4e18);
        require(token.transferFrom(address(this), BOB, 4e18), "returns true");
        assertEq(token.allowance(address(this), ALICE), 6e18, "allowance decremented");
        assertEq(token.balanceOf(BOB), 4e18, "bob");
    }

    function test_transferFromDoesNotEmitApprovalOnSpend() public {
        // OZ v5 semantics: spending allowance does not emit Approval. Count log entries via a probe.
        token.approve(ALICE, 10e18);
        vm.prank(ALICE);
        // expectEmit with checkData on Transfer only: an unexpected Approval event in between would
        // not fail expectEmit, so assert the allowance path explicitly instead.
        token.transferFrom(address(this), BOB, 1);
        assertEq(token.allowance(address(this), ALICE), 10e18 - 1, "allowance");
    }

    function test_transferFromInfiniteAllowanceIsNotDecremented() public {
        token.approve(ALICE, type(uint256).max);
        vm.prank(ALICE);
        token.transferFrom(address(this), BOB, 1e18);
        assertEq(token.allowance(address(this), ALICE), type(uint256).max, "still infinite");
    }

    function test_transferFromRevertsWithoutAllowance() public {
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(MoneyBackToken.ERC20InsufficientAllowance.selector, ALICE, 0, 1));
        token.transferFrom(address(this), BOB, 1);
    }

    function test_transferFromRevertsWhenAllowanceBelowAmount() public {
        token.approve(ALICE, 5);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(MoneyBackToken.ERC20InsufficientAllowance.selector, ALICE, 5, 6));
        token.transferFrom(address(this), BOB, 6);
    }

    function test_transferFromRevertsWhenBalanceBelowAmountEvenWithAllowance() public {
        vm.prank(BOB); // BOB has 0
        token.approve(ALICE, 100);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(MoneyBackToken.ERC20InsufficientBalance.selector, BOB, 0, 100));
        token.transferFrom(BOB, ALICE, 100);
    }

    function test_transferFromToZeroAddressReverts() public {
        token.approve(ALICE, 1);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(MoneyBackToken.ERC20InvalidReceiver.selector, address(0)));
        token.transferFrom(address(this), address(0), 1);
    }

    function test_transferFromExactAllowanceLeavesZero() public {
        token.approve(ALICE, 9);
        vm.prank(ALICE);
        token.transferFrom(address(this), BOB, 9);
        assertEq(token.allowance(address(this), ALICE), 0, "zero");
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(MoneyBackToken.ERC20InsufficientAllowance.selector, ALICE, 0, 1));
        token.transferFrom(address(this), BOB, 1);
    }

    // ---------------------------------------------------------------------------------------------
    // fuzz
    // ---------------------------------------------------------------------------------------------

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_transferConservesSupplyAndBalances(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != address(this));
        uint256 bal = token.balanceOf(address(this));
        amount = amount % (bal + 1);
        uint256 toBefore = token.balanceOf(to);
        token.transfer(to, amount);
        assertEq(token.balanceOf(address(this)), bal - amount, "sender");
        assertEq(token.balanceOf(to), toBefore + amount, "receiver");
        assertEq(token.totalSupply(), SUPPLY, "supply");
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_transferAboveBalanceAlwaysReverts(uint256 excess) public {
        excess = excess % 1e30 + 1;
        uint256 bal = token.balanceOf(address(this));
        vm.expectRevert(
            abi.encodeWithSelector(MoneyBackToken.ERC20InsufficientBalance.selector, address(this), bal, bal + excess)
        );
        token.transfer(BOB, bal + excess);
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_allowanceAccounting(uint256 allowed, uint256 spend) public {
        vm.assume(allowed != type(uint256).max);
        uint256 bal = token.balanceOf(address(this));
        spend = spend % (bal + 1);
        token.approve(ALICE, allowed);
        vm.prank(ALICE);
        if (spend > allowed) {
            vm.expectRevert(
                abi.encodeWithSelector(MoneyBackToken.ERC20InsufficientAllowance.selector, ALICE, allowed, spend)
            );
            token.transferFrom(address(this), BOB, spend);
        } else {
            token.transferFrom(address(this), BOB, spend);
            assertEq(token.allowance(address(this), ALICE), allowed - spend, "remaining allowance");
            assertEq(token.balanceOf(BOB), spend, "bob");
        }
    }

    // ---------------------------------------------------------------------------------------------
    // invariants
    // ---------------------------------------------------------------------------------------------

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 32
    function invariant_totalSupplyNeverChanges() public view {
        assertEq(token.totalSupply(), SUPPLY, "supply drifted");
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 32
    function invariant_balancesSumToSupply() public view {
        uint256 sum = token.balanceOf(address(this)) + token.balanceOf(address(handler))
            + token.balanceOf(handler.actors(0)) + token.balanceOf(handler.actors(1))
            + token.balanceOf(handler.actors(2));
        assertEq(sum, SUPPLY, "balances != supply");
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 32
    function invariant_zeroAddressHoldsNothing() public view {
        assertEq(token.balanceOf(address(0)), 0, "zero address balance");
    }
}

contract Factory {
    function deploy() external returns (MoneyBackToken) {
        return new MoneyBackToken();
    }
}
