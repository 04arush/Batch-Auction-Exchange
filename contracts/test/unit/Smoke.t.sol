// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { FeeOnTransferERC20 } from "../mocks/FeeOnTransferERC20.sol";

contract SmokeTest is Test {
    function test_mockTokenMints() public {
        MockERC20 t = new MockERC20("T", "T", 18);
        t.mint(address(this), 5 ether);
        assertEq(t.balanceOf(address(this)), 5 ether);
    }

    function test_feeTokenTakesOnePercent() public {
        FeeOnTransferERC20 t = new FeeOnTransferERC20();
        t.mint(address(this), 100 ether);
        address john = makeAddr("john");
        t.transfer(john, 100 ether);
        assertEq(t.balanceOf(john), 99 ether);
    }
}
