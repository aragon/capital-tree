// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {
    DaoAuthorizableUpgradeable
} from "@aragon/osx-commons-contracts/src/permission/auth/DaoAuthorizableUpgradeable.sol";
import {INodeAction} from "../../interfaces/INodeAction.sol";
import {IBudget} from "../../interfaces/IBudget.sol";
import {IComponent} from "../../interfaces/IComponent.sol";
import {Asset} from "../../lib/types.sol";

/// @title LeafAction
/// @notice Base for leaves: actions that consume their whole input and output nothing. Not bound to
///         a budget, and without preconditions or postconditions unless a leaf adds them.
abstract contract LeafAction is INodeAction, IComponent, DaoAuthorizableUpgradeable {
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @inheritdoc INodeAction
    function budget() external pure returns (IBudget) {}

    /// @inheritdoc INodeAction
    function preconditions(address, bytes calldata, Asset calldata, Asset calldata)
        external
        view
        virtual
        returns (bytes memory)
    {}

    /// @inheritdoc INodeAction
    function postconditions(address, Asset calldata, Asset calldata, bytes calldata) external view virtual {}

    /// @dev What every leaf produces: nothing. It spends its whole input.
    function _consume(Asset calldata _input) internal pure returns (Asset memory) {
        return Asset(_input.token, 0);
    }
}
