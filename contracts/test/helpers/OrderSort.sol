// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {SignedOrder} from "../../src/OrderTypes.sol";

library OrderSort {
    /// @dev Insertion sort by canonical priority.
    /// `ids[i]` is the digest of `a[i]`; both arrays are permuted together.
    function sort(SignedOrder[] memory a, bytes32[] memory ids, bool isBuy) internal pure {
        for (uint256 i = 1; i < a.length; i++) {
            uint256 j = i;
            while (
                j > 0
                    && _before(a[j].order.limitPrice, ids[j], a[j - 1].order.limitPrice, ids[j - 1], isBuy)
            ) {
                SignedOrder memory tmp = a[j];
                a[j] = a[j - 1];
                a[j - 1] = tmp;
                bytes32 tmpId = ids[j];
                ids[j] = ids[j - 1];
                ids[j - 1] = tmpId;
                j--;
            }
        }
    }

    function _before(uint128 la, bytes32 ia, uint128 lb, bytes32 ib, bool isBuy) private pure returns (bool) {
        if (la != lb) return isBuy ? la > lb : la < lb;
        return ia < ib;
    }
}
