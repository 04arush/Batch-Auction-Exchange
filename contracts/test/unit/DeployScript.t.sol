// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {Deploy} from "../../script/Deploy.s.sol";
import {DeployMocks} from "../../script/DeployMocks.s.sol";
import {BatchAuction} from "../../src/BatchAuction.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @notice Runs the deployment scripts inside the Foundry EVM (no node needed) so CI proves they still work.
contract DeployScriptTest is Test {
    address internal owner = makeAddr("owner");
    address internal treasury = makeAddr("treasury");
    address internal solver = makeAddr("solver");

    function _setEnv(address base, address quote, address owner_) internal {
        vm.setEnv("BASE_TOKEN", vm.toString(base));
        vm.setEnv("QUOTE_TOKEN", vm.toString(quote));
        vm.setEnv("OWNER", vm.toString(owner_));
        vm.setEnv("TREASURY", vm.toString(treasury));
        vm.setEnv("SOLVER", vm.toString(solver));
        vm.setEnv("EPOCH_DURATION", "300");
    }

    function test_deployMocks_returnsTwoWorkingTokens() public {
        (MockERC20 base, MockERC20 quote) = new DeployMocks().run();
        assertTrue(address(base) != address(quote));
        assertEq(base.decimals(), 18);
        assertEq(quote.decimals(), 18);
        assertGt(address(base).code.length, 0);
        assertGt(address(quote).code.length, 0);
    }

    function test_deploy_configuresTheExchangeFromEnv() public {
        (MockERC20 base, MockERC20 quote) = new DeployMocks().run();
        _setEnv(address(base), address(quote), owner);

        BatchAuction auction = new Deploy().run();

        assertEq(address(auction.baseToken()), address(base));
        assertEq(address(auction.quoteToken()), address(quote));
        assertEq(auction.owner(), owner);
        assertEq(auction.treasury(), treasury);
        assertEq(auction.epochDuration(), 300);
    }

    function test_deploy_revertsIfATokenHasNoCode() public {
        (MockERC20 base,) = new DeployMocks().run();
        _setEnv(address(base), makeAddr("not-a-contract"), owner);

        Deploy script = new Deploy();
        vm.expectRevert(bytes("token has no code on this chain"));
        script.run();
    }

    function test_deploy_revertsIfBaseEqualsQuote() public {
        (MockERC20 base,) = new DeployMocks().run();
        _setEnv(address(base), address(base), owner);

        Deploy script = new Deploy();
        vm.expectRevert(bytes("base == quote"));
        script.run();
    }
}
