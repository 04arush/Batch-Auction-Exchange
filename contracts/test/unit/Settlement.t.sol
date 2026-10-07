// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {SettlementBase} from "../helpers/SettlementBase.sol";
import {BatchAuction} from "../../src/BatchAuction.sol";
import {ClearMath} from "../../src/libraries/ClearMath.sol";
import {OrderValidation} from "../../src/libraries/OrderValidation.sol";
import {Order, SignedOrder, Side} from "../../src/OrderTypes.sol";

contract SettlementTest is SettlementBase {
    event BatchSettled (
        uint64 indexed epoch,
        uint256 clearingPrice,
        uint256 baseVolume,
        uint256 quoteVolume,
        uint256 dust,
        uint256 buyOrders,
        uint256 sellOrders
    );

    function setUp() public override {
        super.setUp();
        _fundActors();
    }

    // ---------------- happy paths ----------------

    function test_fullCross_clearsAtLowestOptimalPrice() public {
        SignedOrder[] memory buys = _one(_sign(ALICE_PK, _order(alice, Side.Buy, 10 ether, 102 ether, 1)));
        SignedOrder[] memory sells = _one(_sign(BOB_PK, _order(bob, Side.Sell, 10 ether, 98 ether, 1)));

        _settle(buys, sells);

        assertEq(_bal(alice, base), START + 10 ether);
        assertEq(_bal(alice, quote), START - 980 ether);
        assertEq(_bal(bob, base), START - 10 ether);
        assertEq(_bal(bob, quote), START + 980 ether);
        assertTrue(auction.epochSettled(EPOCH));
        assertTrue(auction.nonceUsed(alice, 1));
    }

    function test_emitsBatchSettled() public {
        SignedOrder[] memory buys = _sorted(_one(_sign(ALICE_PK, _order(alice, Side.Buy, 10 ether, 102 ether, 1))), true);
        SignedOrder[] memory sells = _sorted(_one(_sign(BOB_PK, _order(bob, Side.Sell, 10 ether, 98 ether, 1))), false);
        vm.warp(auction.epochEnd(EPOCH));

        vm.expectEmit(true, false, false, true, address(auction));
        emit BatchSettled(EPOCH, 98 ether, 10 ether, 980 ether, 0, 1, 1);
        vm.prank(solver);
        auction.settleBatch(EPOCH, buys, sells);
    }

    function test_partialFill_marginalBuyAndUnfilledEscrowIsWithdrawable() public {
        SignedOrder[] memory buys = _two(
            _sign(ALICE_PK, _order(alice, Side.Buy, 10 ether, 105 ether, 2)),
            _sign(CAROL_PK, _order(carol, Side.Buy, 10 ether, 100 ether, 1))
        );
        SignedOrder[] memory sells = _one(_sign(BOB_PK, _order(bob, Side.Sell, 15 ether, 95 ether, 1)));

        _settle(buys, sells);

        assertEq(_bal(alice, base), START + 10 ether);
        assertEq(_bal(alice, quote), START - 950 ether);
        assertEq(_bal(carol, base), START + 5 ether);
        assertEq(_bal(carol, quote), START - 475 ether);
        assertEq(_bal(bob, quote), START + 1425 ether);

        vm.prank(carol);
        auction.withdraw(address(quote), START - 475 ether);
        assertEq(quote.balanceOf(carol), START - 475 ether);
    }

    function test_sellSideRationing() public {
        SignedOrder[] memory buys = _one(_sign(ALICE_PK, _order(alice, Side.Buy, 6 ether, 100 ether, 1)));
        SignedOrder[] memory sells = _two(
            _sign(BOB_PK, _order(bob, Side.Sell, 5 ether, 90 ether, 1)),
            _sign(CAROL_PK, _order(carol, Side.Sell, 5 ether, 95 ether, 1))
        );

        _settle(buys, sells);

        assertEq(_bal(bob, base), START - 5 ether);
        assertEq(_bal(bob, quote), START + 475 ether);
        assertEq(_bal(carol, base), START - 1 ether);
        assertEq(_bal(carol, quote), START + 95 ether);
        assertEq(_bal(alice, quote), START - 570 ether);
    }

    function test_dustGoesToTreasury() public {
        SignedOrder[] memory buys = _one(_sign(ALICE_PK, _order(alice, Side.Buy, 3, 5e17, 1)));
        SignedOrder[] memory sells = _one(_sign(BOB_PK, _order(bob, Side.Sell, 3, 5e17, 1)));

        _settle(buys, sells);

        assertEq(_bal(alice, quote), START - 2);
        assertEq(_bal(bob, quote), START + 1);
        assertEq(_bal(treasury, quote), 1);

        uint256 total = _bal(alice, quote) + _bal(bob, quote) + _bal(carol, quote) + _bal(dave, quote)
            + _bal(treasury, quote);
        assertEq(total, 4 * START);
    }

    function test_tieOnLimit_isBrokenByLowerDigest() public {
        Order memory oa = _order(alice, Side.Buy, 10 ether, 100 ether, 3);
        Order memory oc = _order(carol, Side.Buy, 10 ether, 100 ether, 3);
        bool aliceWins = auction.orderDigest(oa) < auction.orderDigest(oc);

        SignedOrder[] memory buys = _two(_sign(ALICE_PK, oa), _sign(CAROL_PK, oc));
        SignedOrder[] memory sells = _one(_sign(BOB_PK, _order(bob, Side.Sell, 10 ether, 100 ether, 1)));

        _settle(buys, sells);

        assertEq(_bal(alice, base), aliceWins ? START + 10 ether : START);
        assertEq(_bal(carol, base), aliceWins ? START : START + 10 ether);
    }

    function test_maxValues_doNotOverflow() public {
        uint256 maxBase = type(uint128).max;
        uint256 maxPrice = type(uint128).max;
        uint256 pay = Math.mulDiv(maxBase, maxPrice, 1e18, Math.Rounding.Ceil);
        uint256 got = Math.mulDiv(maxBase, maxPrice, 1e18);
        _fund(alice, quote, pay);
        _fund(bob, base, maxBase);

        SignedOrder[] memory buys = _one(_sign(ALICE_PK, _order(alice, Side.Buy, maxBase, maxPrice, 50)));
        SignedOrder[] memory sells = _one(_sign(BOB_PK, _order(bob, Side.Sell, maxBase, maxPrice, 50)));

        _settle(buys, sells);

        assertEq(_bal(alice, base), START + maxBase);
        assertEq(_bal(alice, quote), START);
        assertEq(_bal(bob, quote), START + got);
        assertEq(_bal(treasury, quote), pay - got);
    }

    function test_noMatch_revertsAndDoesNotConsumeEpoch() public {
        SignedOrder[] memory buys = _one(_sign(ALICE_PK, _order(alice, Side.Buy, 5 ether, 90 ether, 1)));
        SignedOrder[] memory sells = _one(_sign(BOB_PK, _order(bob, Side.Sell, 5 ether, 100 ether, 1)));

        _expectSettleRevert(abi.encodeWithSelector(BatchAuction.BatchAuction__NoTrade.selector), buys, sells, true);

        assertFalse(auction.epochSettled(EPOCH));
        assertFalse(auction.nonceUsed(alice, 1));
    }

    // ---------------- access and timing ----------------

    function test_revertsIfCallerIsNotSolver() public {
        SignedOrder[] memory buys = _sorted(_one(_sign(ALICE_PK, _order(alice, Side.Buy, 1 ether, 102 ether, 1))), true);
        SignedOrder[] memory sells = _sorted(_one(_sign(BOB_PK, _order(bob, Side.Sell, 1 ether, 98 ether, 1))), false);
        vm.warp(auction.epochEnd(EPOCH));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BatchAuction.BatchAuction__NotSolver.selector, alice));
        auction.settleBatch(EPOCH, buys, sells);
    }

    function test_revertsBeforeEpochEnds() public {
        SignedOrder[] memory buys = _sorted(_one(_sign(ALICE_PK, _order(alice, Side.Buy, 1 ether, 102 ether, 1))), true);
        SignedOrder[] memory sells = _sorted(_one(_sign(BOB_PK, _order(bob, Side.Sell, 1 ether, 98 ether, 1))), false);
        uint256 endsAt = auction.epochEnd(EPOCH);

        vm.prank(solver);
        vm.expectRevert(abi.encodeWithSelector(BatchAuction.BatchAuction__EpochNotEnded.selector, EPOCH, endsAt));
        auction.settleBatch(EPOCH, buys, sells);
    }

    function test_revertsIfEpochAlreadySettled() public {
        _settle(
            _one(_sign(ALICE_PK, _order(alice, Side.Buy, 1 ether, 102 ether, 1))),
            _one(_sign(BOB_PK, _order(bob, Side.Sell, 1 ether, 98 ether, 1)))
        );

        SignedOrder[] memory buys = _one(_sign(ALICE_PK, _order(alice, Side.Buy, 1 ether, 102 ether, 2)));
        SignedOrder[] memory sells = _one(_sign(BOB_PK, _order(bob, Side.Sell, 1 ether, 98 ether, 2)));
        _expectSettleRevert(abi.encodeWithSelector(BatchAuction.BatchAuction__EpochAlreadySettled.selector, EPOCH), buys, sells, true);
    }

    function test_revertsWhenPaused() public {
        SignedOrder[] memory buys = _one(_sign(ALICE_PK, _order(alice, Side.Buy, 1 ether, 102 ether, 1)));
        SignedOrder[] memory sells = _one(_sign(BOB_PK, _order(bob, Side.Sell, 1 ether, 98 ether, 1)));
        vm.prank(owner);
        auction.pause();
        _expectSettleRevert(abi.encodeWithSelector(Pausable.EnforcedPause.selector), buys, sells, true);
    }

    function test_revertsIfTooManyOrders() public {
        SignedOrder[] memory buys = new SignedOrder[](33);
        SignedOrder[] memory sells = new SignedOrder[](0);
        _expectSettleRevert(abi.encodeWithSelector(BatchAuction.BatchAuction__TooManyOrders.selector), buys, sells, false);
    }

    // ---------------- expiry boundaries ----------------

        function test_expiry_exactlyAtSettlementTimeIsValid() public {
            Order memory o = _order(alice, Side.Buy, 1 ether, 102 ether, 1);
            o.expiry = uint64(auction.epochEnd(EPOCH));
            _settle(_one(_sign(ALICE_PK, o)), _one(_sign(BOB_PK, _order(bob, Side.Sell, 1 ether, 98 ether, 1))));
            assertEq(_bal(alice, base), START + 1 ether);
        }

        function test_expiry_oneSecondTooLateReverts() public {
            Order memory o = _order(alice, Side.Buy, 1 ether, 102 ether, 1);
            o.expiry = uint64(auction.epochEnd(EPOCH) - 1);
            SignedOrder[] memory buys = _one(_sign(ALICE_PK, o));
            SignedOrder[] memory sells = _one(_sign(BOB_PK, _order(bob, Side.Sell, 1 ether, 98 ether, 1)));

            _expectSettleRevert(
                abi.encodeWithSelector(OrderValidation.OrderValidation__Expired.selector, o.expiry, auction.epochEnd(EPOCH)),
                buys,
                sells,
                true
            );
        }

    // ---------------- order validity ----------------

    function test_revertsOnWrongEpoch() public {
        Order memory o = _order(alice, Side.Buy, 1 ether, 102 ether, 1);
        o.epoch = EPOCH + 1;
        SignedOrder[] memory buys = _one(_sign(ALICE_PK, o));
        SignedOrder[] memory sells = _one(_sign(BOB_PK, _order(bob, Side.Sell, 1 ether, 98 ether, 1)));
        _expectSettleRevert(
            abi.encodeWithSelector(OrderValidation.OrderValidation__WrongEpoch.selector, EPOCH, EPOCH + 1), buys, sells, true
        );
    }

    function test_revertsIfOrderIsOnTheWrongSide() public {
        SignedOrder[] memory buys = _one(_sign(ALICE_PK, _order(alice, Side.Sell, 1 ether, 102 ether, 1)));
        SignedOrder[] memory sells = new SignedOrder[](0);
        _expectSettleRevert(abi.encodeWithSelector(OrderValidation.OrderValidation__WrongSide.selector), buys, sells, true);
    }

    function test_revertsOnTamperedOrder() public {
        SignedOrder memory so = _sign(ALICE_PK, _order(alice, Side.Buy, 1 ether, 102 ether, 1));
        so.order.limitPrice = 150 ether;
        SignedOrder[] memory sells = _one(_sign(BOB_PK, _order(bob, Side.Sell, 1 ether, 98 ether, 1)));
        _expectSettleRevert(
            abi.encodeWithSelector(BatchAuction.BatchAuction__InvalidSignature.selector, alice, 1), _one(so), sells, true
        );
    }

    function test_revertsOnWrongSigner() public {
        SignedOrder memory so = _sign(BOB_PK, _order(alice, Side.Buy, 1 ether, 102 ether, 1));
        SignedOrder[] memory sells = _one(_sign(BOB_PK, _order(bob, Side.Sell, 1 ether, 98 ether, 1)));
        _expectSettleRevert(
            abi.encodeWithSelector(BatchAuction.BatchAuction__InvalidSignature.selector, alice, 1), _one(so), sells, true
        );
    }

    function test_cancelledOrderCannotSettle() public {
        SignedOrder[] memory buys = _one(_sign(ALICE_PK, _order(alice, Side.Buy, 1 ether, 102 ether, 1)));
        SignedOrder[] memory sells = _one(_sign(BOB_PK, _order(bob, Side.Sell, 1 ether, 98 ether, 1)));

        vm.prank(alice);
        auction.cancelOrder(1);

        _expectSettleRevert(abi.encodeWithSelector(BatchAuction.BatchAuction__NonceAlreadyUsed.selector, alice, 1), buys, sells, true);
    }

    function test_cancelAfterSettlementReverts() public {
        _settle(
            _one(_sign(ALICE_PK, _order(alice, Side.Buy, 1 ether, 102 ether, 1))),
            _one(_sign(BOB_PK, _order(bob, Side.Sell, 1 ether, 98 ether, 1)))
        );
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BatchAuction.BatchAuction__NonceAlreadyUsed.selector, alice, 1));
        auction.cancelOrder(1);
    }

    function test_duplicateOrderInBatchReverts() public {
        SignedOrder memory a = _sign(ALICE_PK, _order(alice, Side.Buy, 1 ether, 102 ether, 1));
        SignedOrder[] memory buys = _two(a, a);
        SignedOrder[] memory sells = _one(_sign(BOB_PK, _order(bob, Side.Sell, 2 ether, 98 ether, 1)));
        _expectSettleRevert(abi.encodeWithSelector(BatchAuction.BatchAuction__NonceAlreadyUsed.selector, alice, 1), buys, sells, false);
    }

    function test_unsortedBookReverts() public {
        SignedOrder[] memory buys = _two(
            _sign(ALICE_PK, _order(alice, Side.Buy, 1 ether, 100 ether, 1)),
            _sign(CAROL_PK, _order(carol, Side.Buy, 1 ether, 105 ether, 1))
        );
        SignedOrder[] memory sells = _one(_sign(BOB_PK, _order(bob, Side.Sell, 2 ether, 95 ether, 1)));
        _expectSettleRevert(abi.encodeWithSelector(ClearMath.ClearMath__NotSorted.selector, 1), buys, sells, false);
    }

    function test_revertsIfTraderLacksEscrow() public {
        uint256 evePk = 0xE7E;
        address eve = vm.addr(evePk);
        SignedOrder[] memory buys = _one(_sign(evePk, _order(eve, Side.Buy, 10 ether, 102 ether, 1)));
        SignedOrder[] memory sells = _one(_sign(BOB_PK, _order(bob, Side.Sell, 10 ether, 98 ether, 1)));
        _expectSettleRevert(
            abi.encodeWithSelector(BatchAuction.BatchAuction__InsufficientBalance.selector, eve, address(quote), 0, 980 ether),
            buys,
            sells,
            true
        );
    }
}
