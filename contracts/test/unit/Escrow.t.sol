// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {FeeOnTransferERC20} from "../mocks/FeeOnTransferERC20.sol";
import {BatchAuction} from "../../src/BatchAuction.sol";
import {BaseTest} from "../helpers/BaseTest.sol";

contract EscrowTest is BaseTest {
    function test_deposit_creditsInternalBalance() public {
        base.mint(alice, 100 ether);
        vm.startPrank(alice);
        base.approve(address(auction), 100 ether);
        auction.deposit(address(base), 60 ether);
        vm.stopPrank();

        assertEq(auction.balances(alice, address(base)), 60 ether);
        assertEq(base.balanceOf(address(auction)), 60 ether);
        assertEq(base.balanceOf(alice), 40 ether);
    }

    function test_deposit_revertsOnZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(BatchAuction.BatchAuction__ZeroAmount.selector);
        auction.deposit(address(base), 0);
    }

    function test_deposit_revertsOnUnsupportedToken() public {
        MockERC20 other = new MockERC20("Other", "OTH", 18);
        other.mint(alice, 1 ether);
        vm.startPrank(alice);
        other.approve(address(auction), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(BatchAuction.BatchAuction__UnsupportedToken.selector, address(other)));
        auction.deposit(address(other), 1 ether);
        vm.stopPrank();
    }

    function test_deposit_revertsOnFeeOnTransferToken() public {
        FeeOnTransferERC20 fee = new FeeOnTransferERC20();
        BatchAuction a2 = new BatchAuction(fee, quote, EPOCH_DURATION, owner, treasury);
        fee.mint(alice, 100 ether);

        vm.startPrank(alice);
        fee.approve(address(a2), 100 ether);
        vm.expectRevert(abi.encodeWithSelector(BatchAuction.BatchAuction__TransferAmountMismatch.selector, 100 ether, 99 ether));
        a2.deposit(address(fee), 100 ether);
        vm.stopPrank();
    }

    function test_withdraw_returnsTokens() public {
        _fund(alice, base, 50 ether);
        vm.prank(alice);
        auction.withdraw(address(base), 20 ether);

        assertEq(auction.balances(alice, address(base)), 30 ether);
        assertEq(base.balanceOf(alice), 20 ether);
    }

    function test_withdraw_revertsWhenOverdrawing() public {
        _fund(alice, base, 10 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BatchAuction.BatchAuction__InsufficientBalance.selector, alice, address(base), 10 ether, 11 ether));
        auction.withdraw(address(base), 11 ether);
    }

    function test_cancel_marksNonceUsed() public {
        vm.prank(alice);
        auction.cancelOrder(7);
        assertTrue(auction.nonceUsed(alice, 7));
        assertFalse(auction.nonceUsed(alice, 8));
        assertFalse(auction.nonceUsed(bob, 7));
    }

    function test_cancel_revertsOnSecondCancel() public {
        vm.startPrank(alice);
        auction.cancelOrder(7);
        vm.expectRevert(abi.encodeWithSelector(BatchAuction.BatchAuction__NonceAlreadyUsed.selector, alice, 7));
        auction.cancelOrder(7);
        vm.stopPrank();
    }

    function test_pause_blocksDepositButNotWithdrawOrCancel() public {
        _fund(alice, base, 10 ether);

        vm.prank(owner);
        auction.pause();

        base.mint(alice, 1 ether);
        vm.startPrank(alice);
        base.approve(address(auction), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(Pausable.EnforcedPause.selector));
        auction.deposit(address(base), 1 ether);

        auction.withdraw(address(base), 10 ether);
        auction.cancelOrder(1);
        vm.stopPrank();

        assertEq(auction.balances(alice, address(base)), 0);
    }

    function test_onlyOwnerCanAdministrate() public {
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        auction.setSolver(alice, true);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        auction.pause();
        vm.stopPrank();
    }

    function testFuzz_depositWithdrawRoundTrip(uint256 amount, uint128 part) public {
        amount = uint128(bound(amount, 1, type(uint112).max));
        part = uint128(bound(part, 1, amount));

        _fund(alice, base, amount);
        vm.prank(alice);
        auction.withdraw(address(base), part);

        assertEq(auction.balances(alice, address(base)), amount - part);
        assertEq(base.balanceOf(address(auction)), amount - part);
    }
}
