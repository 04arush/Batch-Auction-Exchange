// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ClearMath} from "../../src/libraries/ClearMath.sol";

contract ClearMathFuzzTest is Test {

    /// @dev Deterministic pseudo-random sorted book.
    /// Limits are coarse (80...129) so ties are likely to occur.
    function _randomBook(uint256 seed, uint256 count, bool isBuy)
        internal
        pure
        returns (ClearMath.Entry[] memory book)
    {
        book = new ClearMath.Entry[](count);
        for (uint256 i = 0; i < count; i++) {
            uint256 h = uint256(keccak256(abi.encode(seed, isBuy, i)));
            book[i] = ClearMath.Entry({
                base: uint128(((h % 1_000) + 1) * 1e15),
                limit: uint128((((h >> 32) % 50) + 80) * 1e18),
                id: bytes32(h)
            });
        }
        for (uint256 i = 1; i < count; i++) {
            uint256 j = i;
            while (j > 0 && ClearMath.precedes(book[j], book[j - 1], isBuy)) {
                ClearMath.Entry memory tmp = book[j];
                book[j] = book[j - 1];
                book[j - 1] = tmp;
                j--;
            }
        }
    }

    function _sum(uint256[] memory a) internal pure returns (uint256 s) {
        for (uint256 i = 0; i < a.length; i++) {
            s += a[i];
        }
    }

    function testFuzz_clear_properties(uint256 seed, uint8 nBuys, uint8 nSells) public {
        uint256 n = bound(nBuys, 0, 12);
        uint256 m = bound(nSells, 0, 12);
        ClearMath.Entry[] memory buys = _randomBook(seed, n, true);
        ClearMath.Entry[] memory sells = _randomBook(~seed, m, false);

        ClearMath.assertSorted(buys, true);
        ClearMath.assertSorted(sells, false);

        ClearMath.Result memory r = ClearMath.clear(buys, sells);

        assertEq(_sum(r.buyFills), r.volume, "buy fills sum");
        assertEq(_sum(r.sellFills), r.volume, "sell fills sum");

        for (uint256 i = 0; i < n; i++) {
            assertLe(r.buyFills[i], buys[i].base, "buy fill > base");
            if (r.buyFills[i] > 0) assertGe(buys[i].limit, r.price, "buy limit violated");
        }
        for (uint256 j = 0; j < m; j++) {
            assertLe(r.sellFills[j], sells[j].base, "sell fill > base");
            if (r.sellFills[j] > 0) assertLe(sells[j].limit, r.price, "sell limit violated");
        }

        for (uint256 k = 0; k < n + m; k++) {
            uint256 p = k < n ? buys[k].limit : sells[k - n].limit;
            (uint256 d, uint256 s) = ClearMath.depthAt(buys, sells, p);
            assertLe(d < s ? d : s, r.volume, "a better price exists");
        }

        for (uint256 i = 0; i < n; i++) {
            if (r.buyFills[i] < buys[i].base) {
                for (uint256 j = i + 1; j < n; j++) {
                    assertEq(r.buyFills[j], 0, "buy priority");
                }
            }
        }
        for (uint256 i = 0; i < m; i++) {
            if (r.sellFills[i] < sells[i].base) {
                for (uint256 j = i + 1; j < m; j++) {
                    assertEq(r.sellFills[j], 0, "sell priority");
                }
            }
        }

        uint256 paid;
        uint256 received;
        for (uint256 i = 0; i < n; i++) {
            paid += ClearMath.quoteCeil(r.buyFills[i], r.price);
        }
        for (uint256 j = 0; j < m; j++) {
            received += ClearMath.quoteFloor(r.sellFills[j], r.price);
        }
        assertGe(paid, received, "insolvent rounding");
    }
}
