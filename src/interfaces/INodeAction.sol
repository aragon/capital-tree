// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import {IBudget} from "./IBudget.sol";
import {Input, Movement} from "../lib/types.sol";

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

    /// @notice What the node spends from `input` (`inAmount`, which must be all of it), what it
    ///         produces (`outToken`/`outAmount`, zero for a leaf) and optionally a `beneficiary`,
    ///         plus the actions that do the work.
    /// @dev `outAmount` is the least the node produces, checked after it runs. The children get
    ///      `outAmount`, or everything that arrived when the node is marked `forwardSurplus`.
    function build(address caller, bytes calldata data, Input calldata input)
        external
        view
        returns (Movement memory movement, Action[] memory actions);

    /// @notice Reverts if the action must not run. Called after `build`, on the movement the plugin
    ///         checked, right before the node's `dao.execute`.
    /// @param data The node's trigger data, as passed to `build`
    /// @return snapshot What `postconditions` compares against, read before the work runs (a
    ///         balance, and anything the check needs to find it again, such as a lock id)
    function preconditions(address caller, bytes calldata data, Movement calldata movement)
        external
        view
        returns (bytes memory snapshot);

    /// @notice Reverts unless the work went right. Called right after the node's `dao.execute`.
    /// @param snapshot What `preconditions` returned
    function postconditions(address caller, Movement calldata movement, bytes calldata snapshot) external view;
}
