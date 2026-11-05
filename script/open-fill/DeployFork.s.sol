// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DeployFlow} from "./DeployFlow.sol";

/// @dev Deploys into the caller's Ethereum fork only; the test funds and accrues the stream.
contract DeployFork is DeployFlow {
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    function run() public returns (Deployment memory) {
        require(block.chainid == 1 && WETH.code.length > 0, "Ethereum mainnet fork required");
        // Deliberately easy receipt floor: this tests routing, not price selection.
        return _deploy(IERC20(WETH), IERC20(USDC), 1 ether, 100e6);
    }
}
