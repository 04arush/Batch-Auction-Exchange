// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BaseTest} from "../helpers/BaseTest.sol";
import {BatchAuction} from "../../src/BatchAuction.sol";

/// @notice Covers owner-only configuration and constructor validation.
contract AdminTest is BaseTest {
    function test_setTreasury_updatesAndRejectsZero() public {
        vm.prank(owner);
        auction.setTreasury(alice);
        assertEq(auction.treasury(), alice);

        vm.prank(owner);
        vm.expectRevert(BatchAuction.BatchAuction__ZeroAddress.selector);
        auction.setTreasury(address(0));
    }

    function test_unpause_restoresDeposits() public {
        vm.prank(owner);
        auction.pause();
        vm.prank(owner);
        auction.unpause();

        _fund(alice, base, 1 ether); // deposit works again
        assertEq(auction.balances(alice, address(base)), 1 ether);
    }

    function test_currentEpoch_followsTimestamp() public {
        assertEq(auction.currentEpoch(), EPOCH);
        vm.warp(auction.epochEnd(EPOCH));
        assertEq(auction.currentEpoch(), EPOCH + 1);
    }

    function test_constructor_rejectsBadConfig() public {
        IERC20 b = IERC20(address(base));
        IERC20 q = IERC20(address(quote));

        vm.expectRevert(BatchAuction.BatchAuction__ZeroAddress.selector);
        new BatchAuction(IERC20(address(0)), q, 300, owner, treasury);

        vm.expectRevert(BatchAuction.BatchAuction__ZeroAddress.selector);
        new BatchAuction(b, q, 300, owner, address(0));

        vm.expectRevert(BatchAuction.BatchAuction__InvalidConfig.selector); // base == quote
        new BatchAuction(b, b, 300, owner, treasury);

        vm.expectRevert(BatchAuction.BatchAuction__InvalidConfig.selector); // zero epoch length
        new BatchAuction(b, q, 0, owner, treasury);
    }
}
