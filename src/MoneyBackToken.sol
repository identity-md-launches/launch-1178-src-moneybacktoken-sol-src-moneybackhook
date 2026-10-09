// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IMD Money Back token ($MONEYBACK)
/// @notice Plain ERC-20 with the OpenZeppelin v5 `ERC20` surface (same functions, events, custom
///         errors and semantics), inlined so the file builds with no vendored dependency.
///         18 decimals. The entire supply, exactly 1_000_000_000e18, is minted once in the
///         constructor to `msg.sender` (the launch factory). No constructor arguments.
///
///         Invariants:
///         - `totalSupply()` is 1_000_000_000e18 forever: there is no mint after construction and no burn.
///         - No owner, no privileged function, no transfer fee, no transfer hook, no pause.
///         - Transfers to or from the zero address revert (OpenZeppelin v5 behaviour).
contract MoneyBackToken {
    // ---------------------------------------------------------------------------------------------
    // ERC-20 events and errors (OpenZeppelin v5 IERC20 / IERC20Errors)
    // ---------------------------------------------------------------------------------------------

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    error ERC20InsufficientBalance(address sender, uint256 balance, uint256 needed);
    error ERC20InvalidSender(address sender);
    error ERC20InvalidReceiver(address receiver);
    error ERC20InsufficientAllowance(address spender, uint256 allowance, uint256 needed);
    error ERC20InvalidApprover(address approver);
    error ERC20InvalidSpender(address spender);

    // ---------------------------------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------------------------------

    /// @notice Fixed supply minted once to the deployer: one billion tokens with 18 decimals.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e18;

    string private constant _NAME = "IMD Money Back";
    string private constant _SYMBOL = "MONEYBACK";

    // ---------------------------------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------------------------------

    mapping(address account => uint256) private _balances;
    mapping(address account => mapping(address spender => uint256)) private _allowances;
    uint256 private _totalSupply;

    /// @notice Mints the whole fixed supply to the deployer (the launch factory).
    constructor() {
        _mint(msg.sender, TOTAL_SUPPLY);
    }

    // ---------------------------------------------------------------------------------------------
    // Metadata
    // ---------------------------------------------------------------------------------------------

    function name() public pure returns (string memory) {
        return _NAME;
    }

    function symbol() public pure returns (string memory) {
        return _SYMBOL;
    }

    function decimals() public pure returns (uint8) {
        return 18;
    }

    // ---------------------------------------------------------------------------------------------
    // ERC-20
    // ---------------------------------------------------------------------------------------------

    function totalSupply() public view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) public view returns (uint256) {
        return _balances[account];
    }

    function transfer(address to, uint256 value) public returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    function allowance(address owner, address spender) public view returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 value) public returns (bool) {
        _approve(msg.sender, spender, value, true);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) public returns (bool) {
        _spendAllowance(from, msg.sender, value);
        _transfer(from, to, value);
        return true;
    }

    // ---------------------------------------------------------------------------------------------
    // Internals (OpenZeppelin v5 semantics)
    // ---------------------------------------------------------------------------------------------

    function _transfer(address from, address to, uint256 value) internal {
        if (from == address(0)) revert ERC20InvalidSender(address(0));
        if (to == address(0)) revert ERC20InvalidReceiver(address(0));
        _update(from, to, value);
    }

    function _update(address from, address to, uint256 value) internal {
        if (from == address(0)) {
            _totalSupply += value;
        } else {
            uint256 fromBalance = _balances[from];
            if (fromBalance < value) revert ERC20InsufficientBalance(from, fromBalance, value);
            unchecked {
                _balances[from] = fromBalance - value;
            }
        }
        if (to == address(0)) {
            unchecked {
                _totalSupply -= value;
            }
        } else {
            unchecked {
                _balances[to] += value;
            }
        }
        emit Transfer(from, to, value);
    }

    function _mint(address account, uint256 value) internal {
        if (account == address(0)) revert ERC20InvalidReceiver(address(0));
        _update(address(0), account, value);
    }

    function _approve(address owner, address spender, uint256 value, bool emitEvent) internal {
        if (owner == address(0)) revert ERC20InvalidApprover(address(0));
        if (spender == address(0)) revert ERC20InvalidSpender(address(0));
        _allowances[owner][spender] = value;
        if (emitEvent) emit Approval(owner, spender, value);
    }

    function _spendAllowance(address owner, address spender, uint256 value) internal {
        uint256 currentAllowance = _allowances[owner][spender];
        if (currentAllowance < type(uint256).max) {
            if (currentAllowance < value) revert ERC20InsufficientAllowance(spender, currentAllowance, value);
            unchecked {
                _approve(owner, spender, currentAllowance - value, false);
            }
        }
    }
}
