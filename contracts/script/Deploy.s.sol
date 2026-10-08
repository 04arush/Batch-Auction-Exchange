// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BatchAuction} from "../src/BatchAuction.sol";

/// @notice Deploys BatchAuction for one token pair.
/// All parameters come from environment variables.
contract Deploy is Script {
    function run() external returns (BatchAuction auction) {
        IERC20 base = IERC20(vm.envAddress("BASE_TOKEN"));
        IERC20 quote = IERC20(vm.envAddress("QUOTE_TOKEN"));
        address owner = vm.envAddress("OWNER");
        address treasury = vm.envAddress("TREASURY");
        address solver = vm.envAddress("SOLVER");
        uint256 epochDuration = vm.envOr("EPOCH_DURATION", uint256(300));

        require(address(base) != address(0) && address(quote) != address(0), "token is zero");
        require(address(base) != address(quote), "base == quote");
        require(
            address(base).code.length > 0 && address(quote).code.length > 0,
            "token has no code on this chain"
        );

        vm.startBroadcast();
        auction = new BatchAuction(base, quote, epochDuration, owner, treasury);
        if (msg.sender == owner) {
            auction.setSolver(solver, true);
        }
        vm.stopBroadcast();

        console2.log("chainId       :", block.chainid);
        console2.log("BatchAuction  :", address(auction));
        console2.log("base / quote  :", address(base), address(quote));
        console2.log("epochDuration :", epochDuration);
        console2.log("owner         :", owner);
        console2.log("treasury      :", treasury);
        if (msg.sender != owner) {
            console2.log("NEXT: owner must call setSolver(solver,true) for", solver);
        }
    }
}
