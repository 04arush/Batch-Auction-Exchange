// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

enum Side {
    Buy,
    Sell
}

/// @notice A trade intent. Signed off-chain (EIP-712) and settled in the batch for `epoch`.
struct Order {
    address trader;
    Side side;
    uint128 baseAmount;
    uint128 limitPrice;
    uint64 epoch;
    uint64 expiry;
    uint256 nonce;
    address recipient;
}

struct SignedOrder {
    Order order;
    bytes signature;
}

library OrderLib {
    bytes32 internal constant ORDER_TYPEHASH = keccak256(
        "Order(address trader, uin8 side, uint128 baseAmount, uint128 limitPrice, uint64 epoch, uint64 expiry, uint256 nonce, address recipient)"
    );

    function hash(Order memory o) internal pure returns (bytes32) {
        return keccak256(abi.encode(
            ORDER_TYPEHASH,
            o.trader,
            uint8(o.side),
            o.baseAmount,
            o.limitPrice,
            o.epoch,
            o.expiry,
            o.nonce,
            o.recipient
        ));
    }
}
