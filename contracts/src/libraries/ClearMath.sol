// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Pure Uniform-price call-auction clearing
library ClearMath {
    uint256 internal constant PRICE_SCALE = 1e18;

    error ClearMath__NotSorted(uint256 index);

    struct Entry {
        uint128 base;
        uint128 limit;
        bytes32 id;
    }

    struct Result {
        uint256 price;
        uint256 volume;
        uint256[] buyFills;
        uint256[] sellFills;
    }

    // -------------------- rounding --------------------

    /// @dev Quote a seller receives: rounded down
    function quoteFloor(uint256 baseAmount, uint256 price) internal pure returns (uint256) {
        return Math.mulDiv(baseAmount, price, PRICE_SCALE);
    }

    /// @dev Quote a buyer pays: rounded up
    function quoteCeil(uint256 baseAmount, uint256 price) internal pure returns (uint256) {
        return Math.mulDiv(baseAmount, price, PRICE_SCALE, Math.Rounding.Ceil);
    }

    // -------------------- ordering --------------------

    /// @dev True if `a` has higher priority than `b`
    /// Buys: higher limit first
    /// Sells: lower limit first
    /// Equal limits: lower id first
    function precedes(Entry memory a, Entry memory b, bool isBuy) internal pure returns (bool) {
        if (a.limit != b.limit) return isBuy ? a.limit > b.limit : a.limit < b.limit;
        return a.id < b.id;
    }

    /// @dev Reverts unless the book is strictly sorted by priority (forbids duplicates)
    function assertSorted(Entry[] memory book, bool isBuy) internal pure {
        for (uint256 i = 1; i < book.length; i++) {
            if (!precedes(book[i - 1], book[i], isBuy)) revert ClearMath__NotSorted(i);
        }
    }

    // -------------------- clearing --------------------

    /// @dev Demand and supply at price `p`
    function depthAt(Entry[] memory buys, Entry[] memory sells, uint256 p) internal pure returns (uint256 demand, uint256 supply) {
        for (uint256 i = 0; i < buys.length; i++) {
            if (buys[i].limit >= p) {
                demand += buys[i].base;
            }
        }
        for (uint256 j = 0; j < sells.length; j++) {
            if (sells[j].limit <= p) {
                supply += sells[j].base;
            }
        }
    }

    /// @dev Preconditions: both books are sorted
    function clear(Entry[] memory buys, Entry[] memory sells) internal pure returns (Result memory r) {
        uint256 n = buys.length;
        uint256 m = sells.length;
        r.buyFills = new uint256[](n);
        r.sellFills = new uint256[](m);

        uint256 bestVolume;
        uint256 bestImbalance = type(uint256).max;
        uint256 bestPrice;

        for (uint256 i = 0; i < n + m; i++) {
            uint256 p = i < n ? buys[i].limit : sells[i - n].limit;
            (uint256 d, uint256 s) = depthAt(buys, sells, p);
            uint256 v = d < s ? d : s;
            if (v == 0) continue;
            uint256 imbalance = d > s ? d - s : s - d;

            bool better = v > bestVolume
                || (v == bestVolume && (imbalance < bestImbalance || (imbalance == bestImbalance && p < bestPrice)));
            if (better) {
                bestVolume = v;
                bestImbalance = imbalance;
                bestPrice = p;
            }
        }
        if (bestVolume == 0) return r;
        r.price = bestPrice;
        r.volume = bestVolume;

        _allocate(buys, bestPrice, bestVolume, true, r.buyFills);
        _allocate(sells, bestPrice, bestVolume, false, r.sellFills);
    }

    function _allocate(
        Entry[] memory book,
        uint256 price,
        uint256 volume,
        bool isBuy,
        uint256[] memory fills
    ) private pure {
        uint256 remaining = volume;
        for (uint256 i = 0; i < book.length && remaining > 0; i++) {
            bool eligible = isBuy ? book[i].limit >= price : book[i].limit <= price;
            if (!eligible) break;
            uint256 f = book[i].base < remaining ? book[i].base : remaining;
            fills[i] = f;
            remaining -= f;
        }
    }
}
