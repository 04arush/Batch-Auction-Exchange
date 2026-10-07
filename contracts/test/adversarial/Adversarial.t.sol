// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {SettlementBase} from "../helpers/SettlementBase.sol";
import {BatchAuction} from "../../src/BatchAuction.sol";
import {OrderValidation} from "../../src/libraries/OrderValidation.sol";
import {Order, SignedOrder, Side} from "../../src/OrderTypes.sol";
import {ReentrantToken} from "../mocks/ReentrantToken.sol";

contract AdversarialTest is SettlementBase {
    function setUp() public override {
        super.setUp();
        _fundActors();
    }

    function _pair(uint256 nonce) internal view returns (SignedOrder[] memory buys, SignedOrder[] memory sells) {
        buys = _one(_sign(ALICE_PK, _order(alice, Side.Buy, 1 ether, 102 ether, nonce)));
        sells = _one(_sign(BOB_PK, _order(bob, Side.Sell, 1 ether, 98 ether, nonce)));
    }

    // -------------------- reentrancy / token behaviour --------------------

    function test_reentrantToken_cannotReenterDuringDeposit() public {
        ReentrantToken evil = new ReentrantToken();
        BatchAuction a2 = new BatchAuction(evil, quote, EPOCH_DURATION, owner, treasury);
        evil.mint(alice, 10 ether);
        evil.arm(a2);

        vm.startPrank(alice);
        evil.approve(address(a2), 10 ether);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        a2.deposit(address(evil), 10 ether);
        vm.stopPrank();
    }

    // ------------------------------- replay -------------------------------

    function test_orderSignedForAnotherDeployment_isRejected() public {
        BatchAuction other = new BatchAuction(base, quote, EPOCH_DURATION, owner, treasury);
        vm.prank(owner);
        other.setSolver(solver, true);

        (SignedOrder[] memory buys, SignedOrder[] memory sells) = _pair(1); // signed for `auction`
        vm.warp(other.epochEnd(EPOCH));
        vm.expectRevert(abi.encodeWithSelector(BatchAuction.BatchAuction__InvalidSignature.selector, alice, 1));
        vm.prank(solver);
        other.settleBatch(EPOCH, buys, sells);
    }

    function test_orderSignedForAnotherChain_isRejected() public {
        (SignedOrder[] memory buys, SignedOrder[] memory sells) = _pair(1);
        vm.warp(auction.epochEnd(EPOCH));
        vm.chainId(999);
        vm.expectRevert(abi.encodeWithSelector(BatchAuction.BatchAuction__InvalidSignature.selector, alice, 1));
        vm.prank(solver);
        auction.settleBatch(EPOCH, buys, sells);
    }

    function test_orderForOldEpoch_cannotBeReplayedInANewEpoch() public {
        (SignedOrder[] memory buys, SignedOrder[] memory sells) = _pair(1);
        vm.warp(auction.epochEnd(EPOCH + 1));
        vm.expectRevert(abi.encodeWithSelector(OrderValidation.OrderValidation__WrongEpoch.selector, EPOCH + 1, EPOCH));
        vm.prank(solver);
        auction.settleBatch(EPOCH + 1, buys, sells);
    }

    function test_settledOrderCannotBeReused() public {
        (SignedOrder[] memory buys, SignedOrder[] memory sells) = _pair(1);
        _settle(buys, sells);
        (SignedOrder[] memory b2, SignedOrder[] memory s2) = _pair(1);
        _expectSettleRevert(abi.encodeWithSelector(BatchAuction.BatchAuction__EpochAlreadySettled.selector, EPOCH), b2, s2, true);
    }

    // --------- solver power: documented limitation, demonstrated ----------

    function test_solverCensorship_changesPriceButNeverBreaksLimits() public {
        SignedOrder[] memory buys = _one(_sign(CAROL_PK, _order(carol, Side.Buy, 10 ether, 100 ether, 1)));
        SignedOrder[] memory sells = _one(_sign(BOB_PK, _order(bob, Side.Sell, 10 ether, 95 ether, 1)));

        _settle(buys, sells);

        assertEq(_bal(carol, quote), START - 950 ether);
        assertEq(_bal(bob, quote), START + 950 ether);
        assertEq(_bal(alice, base), START);
    }

    // ------------------------------- pause --------------------------------

    function test_pause_neverTrapsFunds() public {
        (SignedOrder[] memory buys, SignedOrder[] memory sells) = _pair(1);
        _settle(buys, sells);

        vm.prank(owner);
        auction.pause();

        vm.prank(alice);
        auction.withdraw(address(base), START + 1 ether);
        assertEq(base.balanceOf(alice), START + 1 ether);
    }
}
