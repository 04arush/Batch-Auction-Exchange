// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Order, OrderLib} from "./OrderTypes.sol";

contract BatchAuction is EIP712, Ownable2Step {

    // ==================== STATE VARIABLES ====================

    IERC20 public immutable baseToken;
    IERC20 public immutable quoteToken;
    uint256 public immutable epochDuration;
    address public treasury;


    // ======================= MAPPINGS ========================

    mapping(address => bool) public isSolver;


    // ======================== ERRORS =========================

    error BatchAuction__ZeroAddress();
    error BatchAuction__InvalidConfig();


    // ======================== EVENTS =========================

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
        return _domainSeparator();
    }
}
