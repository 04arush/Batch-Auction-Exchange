// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {BatchAuction} from "../../src/BatchAuction.sol";

/// @dev TEST ONLY. When armed, calls back into the exchange in the middle of a transfer into it.
contract ReentrantToken is ERC20 {
    BatchAuction public target;
    bool public armed;

    constructor() ERC20("Reentrant", "RE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function arm(BatchAuction t) external {
        target = t;
        armed = true;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (armed && to == address(target)) {
            armed = false;
            target.withdraw(address(this), 1);
        }
    }
}
