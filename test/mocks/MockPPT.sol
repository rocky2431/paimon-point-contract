// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPPT} from "../../src/interfaces/IPointsModule.sol";

contract MockPPT is IPPT {
    mapping(address => uint256) private _balances;
    uint256 private _totalSupply;
    uint256 private _effectiveSupply;
    bool private _useEffectiveSupply = true;

    function mint(address to, uint256 amount) external {
        _balances[to] += amount;
        _totalSupply += amount;
        _effectiveSupply += amount;
    }

    function burn(address from, uint256 amount) external {
        require(_balances[from] >= amount, "Insufficient balance");
        _balances[from] -= amount;
        _totalSupply -= amount;
        _effectiveSupply -= amount;
    }

    function transfer(address from, address to, uint256 amount) external {
        require(_balances[from] >= amount, "Insufficient balance");
        _balances[from] -= amount;
        _balances[to] += amount;
    }

    function setEffectiveSupply(uint256 supply) external {
        _effectiveSupply = supply;
    }

    function setUseEffectiveSupply(bool use) external {
        _useEffectiveSupply = use;
    }

    function balanceOf(address account) external view override returns (uint256) {
        return _balances[account];
    }

    function effectiveSupply() external view override returns (uint256) {
        if (!_useEffectiveSupply) revert("effectiveSupply not supported");
        return _effectiveSupply;
    }

    function totalSupply() external view override returns (uint256) {
        return _totalSupply;
    }
}
