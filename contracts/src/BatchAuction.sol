// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Order, OrderLib} from "./OrderTypes.sol";

contract BatchAuction is EIP712, Ownable2Step, Pausable, ReentrancyGuard {

    using SafeERC20 for IERC20;

    // ==================== STATE VARIABLES ====================

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


    // ======================== ERRORS =========================

    error BatchAuction__ZeroAddress();
    error BatchAuction__InvalidConfig();
    error BatchAuction__ZeroAmount();
    error BatchAuction__UnsupportedToken(address token);
    error BatchAuction__TransferAmountMismatch(uint256 expected, uint256 received);
    error BatchAuction__InsufficientBalance(address account, address token, uint256 have, uint256 need);
    error BatchAuction__NonceAlreadyUsed(address trader, uint256 nonce);


    // ======================== EVENTS =========================

    event Deposited(address indexed account, address indexed token, uint256 amount);
    event Withdrawn(address indexed account, address indexed token, uint256 amount);
    event OrderCancelled(address indexed trader, uint256 indexed nonce);
    event SolverUpdated(address indexed solver, bool allowed);
    event TreasuryUpdated(address indexed treasury);


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
