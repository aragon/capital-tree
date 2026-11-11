// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";

/// @title IBudget
/// @notice How much of a token a flow may spend in one trigger
/// @dev Budgets are clones initialized for one DAO and expose it as `dao()`
///      (`DaoAuthorizableUpgradeable`). The plugin rejects budgets bound to another DAO or to none.
interface IBudget {
    /// @notice The token this budget releases
    function token() external view returns (IERC20);

    /// @notice What the flow spends in this trigger: the root's input, all of which it must take
    /// @param caller Who triggered the flow
    /// @param data The trigger's budget data, empty for a budget that needs none
    /// @return amount The amount the root receives
    function available(address caller, bytes calldata data) external view returns (uint256 amount);

    /// @notice DAO actions that record the spend. The plugin executes them once, in their own
    ///         `dao.execute`, after the whole tree ran.
    /// @param caller Who triggered the flow
    /// @param data The trigger's budget data, as passed to `available`
    function commitActions(address caller, bytes calldata data) external view returns (Action[] memory);
}

/// @title ICheckpointedBudget
/// @notice A budget that can be restarted from zero
interface ICheckpointedBudget is IBudget {
    /// @notice Restarts the available amount from zero
    function writeCheckpoint() external;
}
