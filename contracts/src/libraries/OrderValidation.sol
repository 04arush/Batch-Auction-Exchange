// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Order, Side} from "../OrderTypes.sol";

library OrderValidation {
    error OrderValidation__WrongSide();
    error OrderValidation__WrongEpoch(uint64 expected, uint64 actual);
    error OrderValidation__Expired(uint64 expiry, uint256 nowTimestamp);
    error OrderValidation__InvalidOrder();

    /// @dev Field-level checks that need no storage
    function validateFields(Order calldata o, Side expectedSide, uint64 epoch) internal view {
        if (o.side != expectedSide) revert OrderValidation__WrongSide();
        if (o.trader == address(0) || o.recipient == address(0) || o.baseAmount == 0 || o.limitPrice == 0) {
            revert OrderValidation__InvalidOrder();
        }
        if (o.epoch != epoch) revert OrderValidation__WrongEpoch(epoch, o.epoch);
        if (block.timestamp > o.expiry) revert OrderValidation__Expired(o.expiry, block.timestamp);
    }
}
