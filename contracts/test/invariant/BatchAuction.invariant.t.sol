// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console2} from "forge-std/console2.sol";

import {SettlementBase} from "../helpers/SettlementBase.sol";
import {AuctionHandler} from "./AuctionHandler.sol";

contract BatchAuctionInvariantTest is SettlementBase {
    AuctionHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new AuctionHandler(auction, base, quote, solver, treasury);

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = handler.deposit.selector;
        selectors[1] = handler.withdraw.selector;
        selectors[2] = handler.cancel.selector;
        selectors[3] = handler.settle.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_solvency() public {
        address[] memory accts = handler.allAccounts();
        uint256 sumBase;
        uint256 sumQuote;
        for (uint256 i = 0; i < accts.length; i++) {
            sumBase += auction.balances(accts[i], address(base));
            sumQuote += auction.balances(accts[i], address(quote));
        }
        assertEq(base.balanceOf(address(auction)), sumBase, "base insolvent");
        assertEq(quote.balanceOf(address(auction)), sumQuote, "quote insolvent");
    }

    function invariant_fillsRespectBoundsAndLimits() public {
        assertFalse(handler.ghostFillBoundViolated(), "fill exceeded signed amount");
        assertFalse(handler.ghostPriceLimitViolated(), "price limit violated");
    }

    function invariant_everyBatchConserves() public {
        assertFalse(handler.ghostConservationViolated(), "batch did not conserve");
    }

    function invariant_noEpochSettlesTwice() public {
        assertFalse(handler.ghostDoubleSettle(), "double settlement succeeded");
    }

    function invariant_settledEpochsStaySettled() public {
        for (uint256 i = 0; i < handler.settledEpochsLength(); i++) {
            assertTrue(auction.epochSettled(handler.settledEpochs(i)));
        }
    }

    function invariant_usedNonceStaysUsed() public {
        for (uint256 i = 0; i < handler.usedNoncesLength(); i++) {
            (address trader, uint256 nonce) = handler.usedNonceAt(i);
            assertTrue(auction.nonceUsed(trader, nonce));
        }
    }

    function afterInvariant() public view {
        console2.log("successful settlements:", handler.ghostSettlements());
    }
}
