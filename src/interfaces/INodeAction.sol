// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import {IBudget} from "./IBudget.sol";
import {Input, Movement} from "../lib/types.sol";

/// @title INodeAction
/// @notice What a node of a flow tree does with its input. The plugin calls all three hooks, in
///         order, on every node that has an action, so an action's safety checks can't be left out.
/// @dev Actions are clones initialized for one DAO and expose it as `dao()`
///      (`DaoAuthorizableUpgradeable`). The plugin rejects actions bound to another DAO or to none.
interface INodeAction {
    /// @notice The budget this action is bound to, or address(0) if it works with any input.
    ///         A bound action must be bound to the flow's budget.
    function budget() external view returns (IBudget);

    /// @notice Reverts if the action must not run on `input`
    function preconditions(address caller, Input calldata input) external view;

    /// @notice What the node spends from `input` (`inAmount`, which must be all of it), what it
    ///         produces (`outToken`/`outAmount`, zero for a leaf) and optionally a `beneficiary`,
    ///         plus the actions that do the work.
    /// @dev `outAmount` is the least the node produces, checked after it runs. The children get
    ///      `outAmount`, or everything that arrived when the node is marked `forwardSurplus`.
    function build(address caller, bytes calldata data, Input calldata input)
        external
        view
        returns (Movement memory movement, Action[] memory actions);

    /// @notice The checks that make the work safe. The plugin calls each one read-only (staticcall)
    ///         right after the node's `dao.execute`; a check reverts when the work went wrong.
    /// @dev Called before the work runs, so a check can carry the state it compares against (a
    ///      balance before the work). Checks can't send value or change state.
    function postconditions(address caller, Movement calldata movement) external view returns (Action[] memory);
}
