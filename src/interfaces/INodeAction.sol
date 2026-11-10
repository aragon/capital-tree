// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import {IBudget} from "./IBudget.sol";
import {Asset} from "../lib/types.sol";

/// @title INodeAction
/// @notice What a node of a flow tree does with its input. The plugin calls `build`,
///         `preconditions` and `postconditions`, in that order, on every node that has an action,
///         so an action's safety checks can't be left out. All three are views, so the plugin
///         calls them read-only (staticcall).
/// @dev Actions are clones initialized for one DAO and expose it as `dao()`
///      (`DaoAuthorizableUpgradeable`). The plugin rejects actions bound to another DAO or to none.
interface INodeAction {
    /// @notice The budget this action is bound to, or address(0) if it works with any input.
    ///         A bound action must be bound to the flow's budget.
    function budget() external view returns (IBudget);

    /// @notice What the node produces for its children (`output`, zero for a leaf), plus the
    ///         actions that do the work. The node spends its whole input.
    /// @dev `output` is the least the action accepts: the plugin checks that it arrived after the
    ///      node runs. The children get it, or everything that arrived when the node is marked
    ///      `forwardSurplus`.
    function build(address caller, bytes calldata data, Asset calldata input)
        external
        view
        returns (Asset memory output, Action[] memory actions);

    /// @notice Reverts if the action must not run. Called after `build`, on the output the plugin
    ///         checked, right before the node's `dao.execute`.
    /// @param data The node's trigger data, as passed to `build`
    /// @return snapshot What `postconditions` compares against, read before the work runs (a
    ///         balance, and anything the check needs to find it again, such as a lock id)
    function preconditions(address caller, bytes calldata data, Asset calldata input, Asset calldata output)
        external
        view
        returns (bytes memory snapshot);

    /// @notice Reverts unless the work went right by the action's own standard (a tolerance, a
    ///         surplus cap, a recipient check). Called right after the node's `dao.execute`, before
    ///         the plugin checks that the node spent at most its input and its output arrived.
    /// @param snapshot What `preconditions` returned
    function postconditions(address caller, Asset calldata input, Asset calldata output, bytes calldata snapshot)
        external
        view;
}
