// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ClearMath} from "../../src/libraries/ClearMath.sol";

/// @dev Exposes the library's internal revert externally so vm.expectRevert can see it
contract ClearingHarness {
    function assertSorted(ClearMath.Entry[] memory book, bool isBuy) external pure {
        ClearMath.assertSorted(book, isBuy);
    }
}

contract ClearMathTest is Test {

    ClearingHarness public harness = new ClearingHarness();

    function _e(uint256 base, uint256 limit, uint256 id) internal pure returns (ClearMath.Entry memory) {
        return ClearMath.Entry({
            base: uint128(base),
            limit: uint128(limit),
            id: bytes32(id)
        });
    }

    function _book1(ClearMath.Entry memory a) internal pure returns (ClearMath.Entry[] memory b) {
        b = new ClearMath.Entry[](1);
        b[0] = a;
    }

    function _book2(ClearMath.Entry memory a, ClearMath.Entry memory c)
        internal
        pure
        returns (ClearMath.Entry[] memory b)
    {
        b = new ClearMath.Entry[](2);
        b[0] = a;
        b[1] = c;
    }

    // ==================== Test Cases ====================

    function test_noCrossNoTrade() public pure {
        ClearMath.Result memory r = ClearMath.clear(_book1(_e(5e18, 90e18, 1)), _book1(_e(5e18, 100e18, 2)));
        assertEq(r.volume, 0);
        assertEq(r.price, 0);
        assertEq(r.buyFills[0], 0);
        assertEq(r.sellFills[0], 0);
    }

    function test_fullCross_lowestPriceOnTie() public pure {
        ClearMath.Result memory r = ClearMath.clear(_book1(_e(10e18, 102e18, 1)), _book1(_e(10e18, 98e18, 2)));
        assertEq(r.price, 98e18);
        assertEq(r.volume, 10e18);
        assertEq(r.buyFills[0], 10e18);
        assertEq(r.sellFills[0], 10e18);
    }

    function test_partialMarginalBuy() public pure {
        ClearMath.Result memory r =
            ClearMath.clear(_book2(_e(10e18, 105e18, 1), _e(10e18, 100e18, 2)), _book1(_e(15e18, 95e18, 3)));
        assertEq(r.price, 95e18);
        assertEq(r.volume, 15e18);
        assertEq(r.buyFills[0], 10e18);
        assertEq(r.buyFills[1], 5e18);
        assertEq(r.sellFills[0], 15e18);
    }

    function test_sellSideRationing() public pure {
        ClearMath.Result memory r =
            ClearMath.clear(_book1(_e(6e18, 100e18, 1)), _book2(_e(5e18, 90e18, 2), _e(5e18, 95e18, 3)));
        assertEq(r.price, 95e18);
        assertEq(r.volume, 6e18);
        assertEq(r.buyFills[0], 6e18);
        assertEq(r.sellFills[0], 5e18);
        assertEq(r.sellFills[1], 1e18);
    }

    function test_dust() public pure {
        ClearMath.Result memory r = ClearMath.clear(_book1(_e(3, 5e17, 1)), _book1(_e(3, 5e17, 2)));
        assertEq(r.price, 5e17);
        assertEq(r.volume, 3);
        uint256 paid = ClearMath.quoteCeil(r.buyFills[0], r.price);
        uint256 received = ClearMath.quoteFloor(r.sellFills[0], r.price);
        assertEq(paid, 2);
        assertEq(received, 1);
    }

    function test_equalLimits_filledByLowerIdFirst() public pure {
        ClearMath.Result memory r =
            ClearMath.clear(_book2(_e(10e18, 100e18, 1), _e(10e18, 100e18, 2)), _book1(_e(10e18, 100e18, 3)));
        assertEq(r.price, 100e18);
        assertEq(r.buyFills[0], 10e18);
        assertEq(r.buyFills[1], 0);
    }

    function test_assertSorted_acceptsCanonicalBooks() public view {
        harness.assertSorted(_book2(_e(1, 105e18, 9), _e(1, 100e18, 1)), true); // buys: limit DESC
        harness.assertSorted(_book2(_e(1, 90e18, 9), _e(1, 95e18, 1)), false); // sells: limit ASC
        harness.assertSorted(_book2(_e(1, 100e18, 1), _e(1, 100e18, 2)), true); // tie: id ASC
    }

    function test_assertSorted_rejectsWrongOrderAndDuplicates() public {
        vm.expectRevert(abi.encodeWithSelector(ClearMath.ClearMath__NotSorted.selector, 1));
        harness.assertSorted(_book2(_e(1, 100e18, 1), _e(1, 105e18, 2)), true); // buys ascending

        vm.expectRevert(abi.encodeWithSelector(ClearMath.ClearMath__NotSorted.selector, 1));
        harness.assertSorted(_book2(_e(1, 95e18, 1), _e(1, 90e18, 2)), false); // sells descending

        vm.expectRevert(abi.encodeWithSelector(ClearMath.ClearMath__NotSorted.selector, 1));
        harness.assertSorted(_book2(_e(1, 100e18, 2), _e(1, 100e18, 1)), true); // tie, wrong id order

        vm.expectRevert(abi.encodeWithSelector(ClearMath.ClearMath__NotSorted.selector, 1));
        harness.assertSorted(_book2(_e(1, 100e18, 5), _e(1, 100e18, 5)), true); // duplicate
    }
}
