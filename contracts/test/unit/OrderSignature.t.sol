// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {BatchAuction} from "../../src/BatchAuction.sol";
import {Order, Side} from "../../src/OrderTypes.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract OrderSignatureTest is Test {

    BatchAuction internal auction;
    MockERC20 internal base;
    MockERC20 internal quote;

    uint256 internal constant ALICE_PK = 0xA11CE;
    address internal alice = vm.addr(ALICE_PK);

    function setUp() public {
        base = new MockERC20("Base", "BASE", 18);
        quote = new MockERC20("Quote", "QUOTE", 18);
        auction = new BatchAuction(base, quote, 300, address(this), address(0xBEEF));
    }

    function _order() internal view returns (Order memory) {
        return Order({
            trader: alice,
            side: Side.Buy,
            baseAmount: 10 ether,
            limitPrice: 100 ether,
            epoch: 10,
            expiry: 1_000_000,
            nonce: 1,
            recipient: alice
        });
    }

    function test_digest_matchesIndependentEip712Computation() public view {
        Order memory o = _order();
        bytes32 typeHash = keccak256(
            "Order(address trader,uint8 side,uint128 baseAmount,uint128 limitPrice,uint64 epoch,uint64 expiry,uint256 nonce,address recipient)"
        );
        bytes32 structHash = keccak256(
            abi.encode(typeHash, o.trader, uint8(o.side), o.baseAmount, o.limitPrice, o.epoch, o.expiry, o.nonce, o.recipient)
        );
        bytes32 domainTypeHash = keccak256(
            "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
        );
        bytes32 domainSep = keccak256(
            abi.encode(domainTypeHash, keccak256("BatchAuction"), keccak256("1"), block.chainid, address(auction))
        );
        bytes32 expected = keccak256(abi.encodePacked("\x19\x01", domainSep, structHash));

        assertEq(auction.domainSeparator(), domainSep);
        assertEq(auction.orderDigest(o), expected);
    }

    function test_signature_recoversTrader() public {
        Order memory o = _order();
        bytes32 digest = auction.orderDigest(o);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ALICE_PK, digest);
        assertEq(ECDSA.recover(digest, abi.encodePacked(r, s, v)), alice);
    }

    function _differs(Order memory m, bytes32 original) internal view returns (bool) {
        return auction.orderDigest(m) != original;
    }

    function test_digest_changesWhenAnyFieldChanges() public view {
        bytes32 d = auction.orderDigest(_order());
        Order memory m;

        m = _order(); m.trader = address(0xdead);
        assertTrue(_differs(m, d), "trader");

        m = _order(); m.side = Side.Sell;
        assertTrue(_differs(m, d), "side");

        m = _order(); m.baseAmount += 1;
        assertTrue(_differs(m, d), "baseAmount");

        m = _order(); m.limitPrice += 1;
        assertTrue(_differs(m, d), "limitPrice");

        m = _order(); m.epoch += 1;
        assertTrue(_differs(m, d), "epoch");

        m = _order(); m.expiry += 1;
        assertTrue(_differs(m, d), "expiry");

        m = _order(); m.nonce += 1;
        assertTrue(_differs(m, d), "nonce");

        m = _order(); m.recipient = address(0xdead);
        assertTrue(_differs(m, d), "recipient");
    }

    function test_digest_changesAcrossChains() public {
        bytes32 d1 = auction.orderDigest(_order());
        vm.chainId(999);
        bytes32 d2 = auction.orderDigest(_order());
        assertTrue(d1 != d2);
    }

    function test_digest_changesAcrossDeployments() public {
        BatchAuction other = new BatchAuction(base, quote, 300, address(this), address(0xBEEF));
        assertTrue(auction.orderDigest(_order()) != other.orderDigest(_order()));
    }
}
