// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {BatchAuction} from "../../src/BatchAuction.sol";
import {Order, SignedOrder, Side} from "../../src/OrderTypes.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

abstract contract BaseTest is Test {
    uint256 internal constant EPOCH_DURATION = 300;
    uint64 internal constant EPOCH = 10;
    uint256 internal constant START = 1_000 ether;

    uint256 internal constant ALICE_PK = 0xA11CE;
    uint256 internal constant BOB_PK = 0xB0B;
    uint256 internal constant CAROL_PK = 0xCA401;
    uint256 internal constant DAVE_PK = 0xDA7E;

    address internal alice = vm.addr(ALICE_PK);
    address internal bob = vm.addr(BOB_PK);
    address internal carol = vm.addr(CAROL_PK);
    address internal dave = vm.addr(DAVE_PK);

    address internal owner = makeAddr("owner");
    address internal treasury = makeAddr("treasury");
    address internal solver = makeAddr("solver");

    BatchAuction internal auction;
    MockERC20 internal base;
    MockERC20 internal quote;

    function setUp() public virtual {
        base = new MockERC20("Base", "BASE", 18);
        quote = new MockERC20("Quote", "QUOTE", 18);
        auction = new BatchAuction(base, quote, EPOCH_DURATION, owner, treasury);
        vm.prank(owner);
        auction.setSolver(solver, true);
        vm.warp(uint256(EPOCH) * EPOCH_DURATION);
    }

    /// @dev Mint `amount` to `who` and deposit it into the exchange.
    function _fund(address who, MockERC20 token, uint256 amount) internal {
        token.mint(who, amount);
        vm.startPrank(who);
        token.approve(address(auction), amount);
        auction.deposit(address(token), amount);
        vm.stopPrank();
    }

    function _fundActors() internal {
        address[4] memory actors = [alice, bob, carol, dave];
        for (uint256 i = 0; i < actors.length; i++) {
            _fund(actors[i], base, START);
            _fund(actors[i], quote, START);
        }
    }

    function _order(
        address trader,
        Side side,
        uint256 baseAmount,
        uint256 limitPrice,
        uint256 nonce)
    internal pure returns (Order memory) {
        return Order({
            trader: trader,
            side: side,
            baseAmount: uint128(baseAmount),
            limitPrice: uint128(limitPrice),
            epoch: EPOCH,
            expiry: type(uint64).max,
            nonce: nonce,
            recipient: trader
        });
    }

    function _sign(uint256 pk, Order memory o) internal view returns (SignedOrder memory) {
        bytes32 digest = auction.orderDigest(o);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return SignedOrder({
            order: o,
            signature: abi.encodePacked(r, s, v)
        });
    }
}
