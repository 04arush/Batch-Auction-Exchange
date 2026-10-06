// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {Order, SignedOrder, Side, OrderLib} from "./OrderTypes.sol";
import {ClearMath} from "./libraries/ClearMath.sol";
import {OrderValidation} from "./libraries/OrderValidation.sol";

contract BatchAuction is EIP712, Ownable2Step, Pausable, ReentrancyGuard {

    using SafeERC20 for IERC20;

    // ==================== STATE VARIABLES ====================

    uint256 public constant MAX_ORDERS_PER_SIDE = 32;

    IERC20 public immutable baseToken;
    IERC20 public immutable quoteToken;
    uint256 public immutable epochDuration;

    address public treasury;


    // ======================= MAPPINGS ========================

    mapping(address => bool) public isSolver;

    /// @notice Internal escrow: account => token => amount
    mapping(address => mapping(address => uint256)) public balances;
    /// @notice A nonce is "used" once cancelled or settled. Used nonces can never settle.
    mapping(address => mapping(uint256 => bool)) public nonceUsed;
    mapping(uint64 => bool) public epochSettled;


    // ======================== ERRORS =========================

    error BatchAuction__ZeroAddress();
    error BatchAuction__InvalidConfig();
    error BatchAuction__ZeroAmount();
    error BatchAuction__UnsupportedToken(address token);
    error BatchAuction__TransferAmountMismatch(uint256 expected, uint256 received);
    error BatchAuction__InsufficientBalance(address account, address token, uint256 have, uint256 need);
    error BatchAuction__NonceAlreadyUsed(address trader, uint256 nonce);
    error BatchAuction__NotSolver(address caller);
    error BatchAuction__EpochNotEnded(uint64 epoch, uint256 endsAt);
    error BatchAuction__EpochAlreadySettled(uint64 epoch);
    error BatchAuction__TooManyOrders();
    error BatchAuction__InvalidSignature(address trader, uint256 nonce);
    error BatchAuction__NoTrade();
    error BatchAuction__PriceLimitViolated(bytes32 orderId);
    error BatchAuction__ConservationViolated();


    // ======================== EVENTS =========================

    event Deposited(address indexed account, address indexed token, uint256 amount);
    event Withdrawn(address indexed account, address indexed token, uint256 amount);
    event OrderCancelled(address indexed trader, uint256 indexed nonce);
    event SolverUpdated(address indexed solver, bool allowed);
    event TreasuryUpdated(address indexed treasury);
    event OrderFilled(
            uint64 indexed epoch,
            bytes32 indexed orderId,
            address indexed trader,
            Side side,
            uint256 nonce,
            uint256 baseFilled,
            uint256 quoteAmount
        );
        event BatchSettled(
            uint64 indexed epoch,
            uint256 clearingPrice,
            uint256 baseVolume,
            uint256 quoteVolume,
            uint256 dust,
            uint256 buyOrders,
            uint256 sellOrders
        );


    // ====================== FUNCTIONS ========================

    // ---------------------- constructor ----------------------

    constructor(
        IERC20 _base,
        IERC20 _quote,
        uint256 _epochDuration,
        address _owner,
        address _treasury
    ) EIP712("BatchAuction", "1") Ownable(_owner) {
        if (address(_base) == address(0) || address(_quote) == address(0) || _treasury == address(0)) {
            revert BatchAuction__ZeroAddress();
        }
        if (_base == _quote || _epochDuration == 0) {
            revert BatchAuction__InvalidConfig();
        }
        baseToken = _base;
        quoteToken = _quote;
        epochDuration = _epochDuration;
        treasury = _treasury;
    }

    // ------------------------ escrow -------------------------

    function deposit(address token, uint256 amount) external nonReentrant whenNotPaused {
        _requireSupported(token);
        if (amount == 0) revert BatchAuction__ZeroAmount();

        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(token).balanceOf(address(this)) - balanceBefore;
        if (received != amount) revert BatchAuction__TransferAmountMismatch(amount, received);

        balances[msg.sender][token] += amount;
        emit Deposited(msg.sender, token, amount);
    }

    /// @dev Intentionally NOT pausable: users can always exit.
    function withdraw(address token, uint256 amount) external nonReentrant {
        if (amount == 0) revert BatchAuction__ZeroAmount();
        uint256 bal = balances[msg.sender][token];
        if (bal < amount) revert BatchAuction__InsufficientBalance(msg.sender, token, bal, amount);

        balances[msg.sender][token] = bal - amount;
        IERC20(token).safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, token, amount);
    }

    /// @notice Intentionally NOT pausable. Burn a nonce so the matching signed order can never settle.
    function cancelOrder(uint256 nonce) external {
        if (nonceUsed[msg.sender][nonce]) revert BatchAuction__NonceAlreadyUsed(msg.sender, nonce);
        nonceUsed[msg.sender][nonce] = true;
        emit OrderCancelled(msg.sender, nonce);
    }

    // ---------------------- settlement -----------------------

    /// @notice Settle epoch at one uniform clearing price derived on-chain from the supplied orders.
    function settleBatch(uint64 epoch, SignedOrder[] calldata buys, SignedOrder[] calldata sells)
        external
        nonReentrant
        whenNotPaused
    {
        if (!isSolver[msg.sender]) revert BatchAuction__NotSolver(msg.sender);
        uint256 endsAt = epochEnd(epoch);
        if (block.timestamp < endsAt) revert BatchAuction__EpochNotEnded(epoch, endsAt);
        if (epochSettled[epoch]) revert BatchAuction__EpochAlreadySettled(epoch);
        if (buys.length > MAX_ORDERS_PER_SIDE || sells.length > MAX_ORDERS_PER_SIDE) revert BatchAuction__TooManyOrders();

        ClearMath.Entry[] memory buyBook = _loadBook(buys, Side.Buy, epoch);
        ClearMath.Entry[] memory sellBook = _loadBook(sells, Side.Sell, epoch);
        ClearMath.assertSorted(buyBook, true);
        ClearMath.assertSorted(sellBook, false);

        ClearMath.Result memory r = ClearMath.clear(buyBook, sellBook);
        if (r.volume == 0) revert BatchAuction__NoTrade();

        epochSettled[epoch] = true;
        (uint256 baseBought, uint256 quotePaid) = _settleBuys(buys, buyBook, r.buyFills, r.price, epoch);
        (uint256 baseSold, uint256 quoteReceived) = _settleSells(sells, sellBook, r.sellFills, r.price, epoch);

        if (baseBought != r.volume || baseSold != r.volume || quotePaid < quoteReceived) {
            revert BatchAuction__ConservationViolated();
        }
        uint256 dust = quotePaid - quoteReceived;
        if (dust != 0) balances[treasury][address(quoteToken)] += dust;

        emit BatchSettled(epoch, r.price, r.volume, quoteReceived, dust, buys.length, sells.length);
    }

    function _loadBook(SignedOrder[] calldata orders, Side side, uint64 epoch)
        private
        returns (ClearMath.Entry[] memory book)
    {
        book = new ClearMath.Entry[](orders.length);
        for (uint256 i = 0; i < orders.length; i++) {
            Order calldata o = orders[i].order;
            OrderValidation.validateFields(o, side, epoch);

            bytes32 digest = _hashTypedDataV4(OrderLib.hash(o));
            if (!SignatureChecker.isValidSignatureNow(o.trader, digest, orders[i].signature)) {
                revert BatchAuction__InvalidSignature(o.trader, o.nonce);
            }

            if (nonceUsed[o.trader][o.nonce]) revert BatchAuction__NonceAlreadyUsed(o.trader, o.nonce);
            nonceUsed[o.trader][o.nonce] = true;

            book[i] = ClearMath.Entry({
                base: o.baseAmount,
                limit: o.limitPrice,
                id: digest
            });
        }
    }

    function _settleBuys(
        SignedOrder[] calldata orders,
        ClearMath.Entry[] memory book,
        uint256[] memory fills,
        uint256 price,
        uint64 epoch
    ) private returns (uint256 baseOut, uint256 quotePaid) {
        for (uint256 i = 0; i < orders.length; i++) {
            uint256 f = fills[i];
            if (f == 0) continue;
            Order calldata o = orders[i].order;
            if (o.limitPrice < price || f > o.baseAmount) revert BatchAuction__PriceLimitViolated(book[i].id);

            uint256 pay = ClearMath.quoteCeil(f, price);
            _debit(o.trader, address(quoteToken), pay);
            balances[o.recipient][address(baseToken)] += f;

            baseOut += f;
            quotePaid += pay;
            emit OrderFilled(epoch, book[i].id, o.trader, Side.Buy, o.nonce, f, pay);
        }
    }

    function _settleSells(
        SignedOrder[] calldata orders,
        ClearMath.Entry[] memory book,
        uint256[] memory fills,
        uint256 price,
        uint64 epoch
    ) private returns (uint256 baseIn, uint256 quoteReceived) {
        for (uint256 i = 0; i < orders.length; i++) {
            uint256 f = fills[i];
            if (f == 0) continue;
            Order calldata o = orders[i].order;
            if (o.limitPrice > price || f > o.baseAmount) revert BatchAuction__PriceLimitViolated(book[i].id);

            uint256 receive_ = ClearMath.quoteFloor(f, price);
            _debit(o.trader, address(baseToken), f);
            balances[o.recipient][address(quoteToken)] += receive_;

            baseIn += f;
            quoteReceived += receive_;
            emit OrderFilled(epoch, book[i].id, o.trader, Side.Sell, o.nonce, f, receive_);
        }
    }


    function _debit(address account, address token, uint256 amount) private {
        uint256 bal = balances[account][token];
        if (bal < amount) revert BatchAuction__InsufficientBalance(account, token, bal, amount);
        balances[account][token] = bal - amount;
    }

    // ------------------------- admin -------------------------

    function setSolver(address solver, bool allowed) external onlyOwner {
        if (solver == address(0)) revert BatchAuction__ZeroAddress();
        isSolver[solver] = allowed;
        emit SolverUpdated(solver, allowed);
    }

    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert BatchAuction__ZeroAddress();
        treasury = newTreasury;
        emit TreasuryUpdated(newTreasury);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // ------------------------- epochs ------------------------

    function currentEpoch() public view returns (uint64) {
        return uint64(block.timestamp / epochDuration);
    }

    function epochEnd(uint64 epoch) public view returns (uint256) {
        return (uint256(epoch) + 1) * epochDuration;
    }

    // ----------------------- signatures ----------------------

    function orderDigest(Order calldata o) external view returns (bytes32) {
        return _hashTypedDataV4(OrderLib.hash(o));
    }

    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    // ------------------------ internal -----------------------

    function _requireSupported(address token) private view {
        if (token != address(baseToken) && token != address(quoteToken)) revert BatchAuction__UnsupportedToken(token);
    }
}
