// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {CapitalPipelinePlugin} from "../CapitalPipelinePlugin.sol";
import {IFiller} from "../interfaces/IFiller.sol";
import {NATIVE, tokenBalance} from "../lib/tokens.sol";

/// @title GenericSwapSolver
/// @notice Executes caller-supplied Action[] batches inside a v2 open-fill callback.
/// @dev Permissionless executor: all balances and allowances to it are publicly spendable.
///      Pulling tokens, router approvals, payment and profit distribution belong in the batch.
///      Low-level calls only check EVM success; token return values are not decoded.
contract GenericSwapSolver is IFiller {
    using SafeERC20 for IERC20;

    /// @notice Triggers a pipeline with an empty array or one payload per node.
    /// @dev msg.value stays here to fund callback actions; the plugin's trigger is not payable.
    function trigger(CapitalPipelinePlugin plugin, bytes[] calldata data) external payable {
        plugin.trigger(data);
    }

    /// @notice Runs abi.encode(Action[]) in order, reverting the batch if a call fails.
    /// @dev Deliberately callable directly; the DAO enforces its receipt separately.
    function fillOffer(IERC20, uint256, IERC20, uint256, bytes calldata data) external payable override {
        Action[] memory calls = abi.decode(data, (Action[]));
        for (uint256 i; i < calls.length; ++i) {
            (bool ok,) = calls[i].to.call{value: calls[i].value}(calls[i].data);
            require(ok, "fillOffer: Call Failed");
        }
    }

    /// @notice Sends the entire balance of token (or v2 NATIVE ETH) to recipient.
    /// @dev May be called by anyone, including this solver as the last action in a batch.
    function sweep(IERC20 token, address recipient) external {
        uint256 balance = tokenBalance(token, address(this));
        if (balance == 0) return;
        if (token == NATIVE) Address.sendValue(payable(recipient), balance);
        else token.safeTransfer(recipient, balance);
    }

    receive() external payable {}
}
