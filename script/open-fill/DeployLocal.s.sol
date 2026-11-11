// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20Mock} from "../../test/mocks/ERC20Mock.sol";
import {DeployFlow} from "./DeployFlow.sol";

// Separate spender and target so the examples exercise both quote addresses.
contract LocalSpender {
    using SafeERC20 for IERC20;

    function pull(IERC20 token, address from, uint256 amount) external {
        token.safeTransferFrom(from, msg.sender, amount);
    }
}

// Local stand-in; not an aggregator ABI or liquidity model.
contract LocalRouter {
    using SafeERC20 for IERC20;
    LocalSpender public immutable spender = new LocalSpender();

    function swap(IERC20 sell, IERC20 buy, uint256 amountIn, uint256 amountOut, address receiver) external payable {
        spender.pull(sell, msg.sender, amountIn);
        buy.safeTransfer(receiver, amountOut);
    }
}

contract DeployLocal is DeployFlow {
    // In-memory deployment only; no RPC or private key required.
    function run() public returns (Deployment memory d, LocalRouter router) {
        ERC20Mock sell = new ERC20Mock("Offered", "OFR");
        ERC20Mock buy = new ERC20Mock("Demanded", "DMD");
        d = _deploy(sell, buy, 100 ether, 5 ether, msg.sender);
        router = new LocalRouter();
        sell.mint(address(d.dao), 100 ether);
        buy.mint(address(router), 5 ether);
        d.budget.sync();
        vm.warp(block.timestamp + EPOCH);
        console2.log("DAO", address(d.dao));
        console2.log("Plugin", address(d.plugin));
        console2.log("Solver", address(d.solver));
    }
}
