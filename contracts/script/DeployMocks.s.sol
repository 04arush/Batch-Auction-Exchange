// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";

/// @notice Deploys two mock ERC-20s so the exchange can be demoed.
contract DeployMocks is Script {
    function run() external returns (MockERC20 base, MockERC20 quote) {
        vm.startBroadcast();
        base = new MockERC20("Mock Base", "mBASE", 18);
        quote = new MockERC20("Mock Quote", "mQUOTE", 18);
        vm.stopBroadcast();

        console2.log("MOCK base :", address(base));
        console2.log("MOCK quote:", address(quote));
    }
}
