// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPPT} from "../../src/interfaces/IPointsModule.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockPPT is IPPT, IERC20 {
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    uint256 private _totalSupply;
    uint256 private _effectiveSupply;
    bool private _useEffectiveSupply = true;

    string public constant name = "Mock PPT";
    string public constant symbol = "MPPT";
    uint8 public constant decimals = 18;

    function mint(address to, uint256 amount) external {
        _balances[to] += amount;
        _totalSupply += amount;
        _effectiveSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function burn(address from, uint256 amount) external {
        require(_balances[from] >= amount, "Insufficient balance");
        _balances[from] -= amount;
        _totalSupply -= amount;
        _effectiveSupply -= amount;
        emit Transfer(from, address(0), amount);
    }

    function setEffectiveSupply(uint256 supply) external {
        _effectiveSupply = supply;
    }

    function setUseEffectiveSupply(bool use) external {
        _useEffectiveSupply = use;
    }

    function balanceOf(address account) external view override(IPPT, IERC20) returns (uint256) {
        return _balances[account];
    }

    function effectiveSupply() external view override returns (uint256) {
        if (!_useEffectiveSupply) revert("effectiveSupply not supported");
        return _effectiveSupply;
    }

    function totalSupply() external view override(IPPT, IERC20) returns (uint256) {
        return _totalSupply;
    }

    // ERC20 functions
    function transfer(address to, uint256 amount) external override returns (bool) {
        require(_balances[msg.sender] >= amount, "Insufficient balance");
        _balances[msg.sender] -= amount;
        _balances[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function allowance(address owner, address spender) external view override returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        _allowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        require(_balances[from] >= amount, "Insufficient balance");
        require(_allowances[from][msg.sender] >= amount, "Insufficient allowance");
        _balances[from] -= amount;
        _balances[to] += amount;
        _allowances[from][msg.sender] -= amount;
        emit Transfer(from, to, amount);
        return true;
    }
}
