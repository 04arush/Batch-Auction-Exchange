// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {BatchAuction} from "../../src/BatchAuction.sol";
import {Order, SignedOrder, Side} from "../../src/OrderTypes.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {OrderSort} from "../helpers/OrderSort.sol";

contract AuctionHandler is Test {

    BatchAuction public auction;
    MockERC20 public base;
    MockERC20 public quote;
    address public solver;
    address public treasury;

    uint256 internal constant N_ACTORS = 5;
    uint256[] internal pks;
    address[] public actors;
    mapping(address => uint256) internal nextNonce;

    uint64 public lastEpoch = 10;

    uint256 public ghostSettlements;
    bool public ghostFillBoundViolated;
    bool public ghostPriceLimitViolated;
    bool public ghostConservationViolated;
    bool public ghostDoubleSettle;

    uint64[] public settledEpochs;
    struct UsedNonce {
        address trader;
        uint256 nonce;
    }
    UsedNonce[] internal usedNonces;

    constructor(BatchAuction auction_, MockERC20 base_, MockERC20 quote_, address solver_, address treasury_) {
        auction = auction_;
        base = base_;
        quote = quote_;
        solver = solver_;
        treasury = treasury_;
        for (uint256 i = 0; i < N_ACTORS; i++) {
            uint256 pk = 0x1000 + i;
            address a = vm.addr(pk);
            pks.push(pk);
            actors.push(a);
            nextNonce[a] = 1000;
            _depositFor(a, base_, 10_000 ether);
            _depositFor(a, quote_, 10_000 ether);
        }
    }

    function deposit(uint256 actorSeed, bool isBase, uint256 amount) external {
        address a = actors[actorSeed % N_ACTORS];
        _depositFor(a, isBase ? base : quote, bound(amount, 1, 1_000 ether));
    }

    function withdraw(uint256 actorSeed, bool isBase, uint256 amount) external {
        address a = actors[actorSeed % N_ACTORS];
        MockERC20 t = isBase ? base : quote;
        uint256 bal = auction.balances(a, address(t));
        if (bal == 0) return;
        vm.prank(a);
        auction.withdraw(address(t), bound(amount, 1, bal / 2 + 1));
    }

    function cancel(uint256 actorSeed, uint256 nonce) external {
        address a = actors[actorSeed % N_ACTORS];
        nonce = bound(nonce, 0, 999);
        if (auction.nonceUsed(a, nonce)) return;
        vm.prank(a);
        auction.cancelOrder(nonce);
        usedNonces.push(UsedNonce(a, nonce));
    }

    function settle(uint256 seed, uint8 nBuys, uint8 nSells) external {
        uint256 nb = bound(nBuys, 0, 6);
        uint256 ns = bound(nSells, 0, 6);
        uint64 epoch = ++lastEpoch;
        vm.warp(auction.epochEnd(epoch));

        SignedOrder[] memory buys = new SignedOrder[](nb);
        bytes32[] memory bIds = new bytes32[](nb);
        SignedOrder[] memory sells = new SignedOrder[](ns);
        bytes32[] memory sIds = new bytes32[](ns);
        for (uint256 i = 0; i < nb; i++) {
            (buys[i], bIds[i]) = _makeOrder(seed, i, Side.Buy, epoch);
        }
        for (uint256 j = 0; j < ns; j++) {
            (sells[j], sIds[j]) = _makeOrder(seed, j, Side.Sell, epoch);
        }
        OrderSort.sort(buys, bIds, true);
        OrderSort.sort(sells, sIds, false);

        vm.recordLogs();
        vm.prank(solver);
        try auction.settleBatch(epoch, buys, sells) {
            ghostSettlements++;
            settledEpochs.push(epoch);
            _checkFills(buys, bIds, sells, sIds);
            for (uint256 i = 0; i < nb; i++) {
                usedNonces.push(UsedNonce(buys[i].order.trader, buys[i].order.nonce));
            }
            for (uint256 j = 0; j < ns; j++) {
                usedNonces.push(UsedNonce(sells[j].order.trader, sells[j].order.nonce));
            }
            vm.prank(solver);
            try auction.settleBatch(epoch, buys, sells) {
                ghostDoubleSettle = true;
            } catch {}
        } catch {}
    }

    function allAccounts() external view returns (address[] memory out) {
        out = new address[](actors.length + 1);
        for (uint256 i = 0; i < actors.length; i++) {
            out[i] = actors[i];
        }
        out[actors.length] = treasury;
    }

    function settledEpochsLength() external view returns (uint256) {
        return settledEpochs.length;
    }

    function usedNoncesLength() external view returns (uint256) {
        return usedNonces.length;
    }

    function usedNonceAt(uint256 i) external view returns (address, uint256) {
        return (usedNonces[i].trader, usedNonces[i].nonce);
    }

    function _depositFor(address a, MockERC20 t, uint256 amount) internal {
        t.mint(a, amount);
        vm.startPrank(a);
        t.approve(address(auction), amount);
        auction.deposit(address(t), amount);
        vm.stopPrank();
    }

    function _makeOrder(uint256 seed, uint256 i, Side side, uint64 epoch)
        internal
        returns (SignedOrder memory so, bytes32 id)
    {
        uint256 h = uint256(keccak256(abi.encode(seed, i, side)));
        uint256 ai = h % N_ACTORS;
        address a = actors[ai];
        Order memory o = Order({
            trader: a,
            side: side,
            baseAmount: uint128((((h >> 8) % 20) + 1) * 1 ether),
            limitPrice: uint128((90 + ((h >> 16) % 21)) * 1 ether),
            epoch: epoch,
            expiry: type(uint64).max,
            nonce: nextNonce[a]++,
            recipient: a
        });
        id = auction.orderDigest(o);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pks[ai], id);
        so = SignedOrder({order: o, signature: abi.encodePacked(r, s, v)});
    }

    function _checkFills(
        SignedOrder[] memory buys,
        bytes32[] memory bIds,
        SignedOrder[] memory sells,
        bytes32[] memory sIds
    ) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("OrderFilled(uint64,bytes32,address,uint8,uint256,uint256,uint256)");
        uint256 buyBase;
        uint256 sellBase;
        uint256 buyQuote;
        uint256 sellQuote;

        for (uint256 k = 0; k < logs.length; k++) {
            if (logs[k].emitter != address(auction) || logs[k].topics[0] != sig) continue;
            bytes32 id = logs[k].topics[2];
            (uint8 side,, uint256 baseFilled, uint256 quoteAmt) =
                abi.decode(logs[k].data, (uint8, uint256, uint256, uint256));

            (Order memory o, bool found) = _lookup(id, buys, bIds, sells, sIds);
            if (!found || baseFilled > o.baseAmount) {
                ghostFillBoundViolated = true;
                continue;
            }
            if (side == 0) {
                buyBase += baseFilled;
                buyQuote += quoteAmt;
                if (quoteAmt > Math.mulDiv(baseFilled, o.limitPrice, 1e18, Math.Rounding.Ceil)) {
                    ghostPriceLimitViolated = true;
                }
            } else {
                sellBase += baseFilled;
                sellQuote += quoteAmt;
                if (quoteAmt < Math.mulDiv(baseFilled, o.limitPrice, 1e18)) ghostPriceLimitViolated = true;
            }
        }
        if (buyBase != sellBase || buyQuote < sellQuote) ghostConservationViolated = true;
    }

    function _lookup(
        bytes32 id,
        SignedOrder[] memory buys,
        bytes32[] memory bIds,
        SignedOrder[] memory sells,
        bytes32[] memory sIds
    ) internal pure returns (Order memory o, bool found) {
        for (uint256 i = 0; i < bIds.length; i++) {
            if (bIds[i] == id) return (buys[i].order, true);
        }
        for (uint256 j = 0; j < sIds.length; j++) {
            if (sIds[j] == id) return (sells[j].order, true);
        }
    }
}
