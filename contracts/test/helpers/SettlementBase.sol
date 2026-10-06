// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {BaseTest} from "./BaseTest.sol";
import {OrderSort} from "./OrderSort.sol";
import {SignedOrder} from "../../src/OrderTypes.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

abstract contract SettlementBase is BaseTest {
    function _sorted(SignedOrder[] memory arr, bool isBuy) internal view returns (SignedOrder[] memory) {
        bytes32[] memory ids = new bytes32[](arr.length);
        for (uint256 i = 0; i < arr.length; i++) {
            ids[i] = auction.orderDigest(arr[i].order);
        }
        OrderSort.sort(arr, ids, isBuy);
        return arr;
    }

    function _settle(SignedOrder[] memory buys, SignedOrder[] memory sells) internal {
        buys = _sorted(buys, true);
        sells = _sorted(sells, false);
        vm.warp(auction.epochEnd(EPOCH));
        vm.prank(solver);
        auction.settleBatch(EPOCH, buys, sells);
    }

    function _expectSettleRevert(
        bytes memory err,
        SignedOrder[] memory buys,
        SignedOrder[] memory sells,
        bool sortFirst
    ) internal {
        if (sortFirst) {
            buys = _sorted(buys, true);
            sells = _sorted(sells, false);
        }
        vm.warp(auction.epochEnd(EPOCH));
        vm.expectRevert(err);
        vm.prank(solver);
        auction.settleBatch(EPOCH, buys, sells);
    }

    function _bal(address who, MockERC20 token) internal view returns (uint256) {
        return auction.balances(who, address(token));
    }

    function _one(SignedOrder memory a) internal pure returns (SignedOrder[] memory arr) {
        arr = new SignedOrder[](1);
        arr[0] = a;
    }

    function _two(SignedOrder memory a, SignedOrder memory b) internal pure returns (SignedOrder[] memory arr) {
        arr = new SignedOrder[](2);
        arr[0] = a;
        arr[1] = b;
    }
}
