// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {INodeAction} from "../../interfaces/INodeAction.sol";
import {IBudget} from "../../interfaces/IBudget.sol";
import {BaseComponent} from "../../base/BaseComponent.sol";
import {Asset} from "../../lib/types.sol";

/// @title BaseAction
/// @notice Base for every node action. Not bound to a budget, and without preconditions or
///         postconditions unless the action adds them.
abstract contract BaseAction is INodeAction, BaseComponent {
    /// @inheritdoc INodeAction
    function budget() external view virtual returns (IBudget) {}

    /// @inheritdoc INodeAction
    function preconditions(address, bytes calldata, Asset calldata, Asset calldata)
        external
        view
        virtual
        returns (bytes memory)
    {}

    /// @inheritdoc INodeAction
    function postconditions(address, Asset calldata, Asset calldata, bytes calldata) external view virtual {}
}
