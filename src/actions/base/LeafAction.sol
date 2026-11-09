// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {
    DaoAuthorizableUpgradeable
} from "@aragon/osx-commons-contracts/src/permission/auth/DaoAuthorizableUpgradeable.sol";
import {INodeAction} from "../../interfaces/INodeAction.sol";
import {IBudget} from "../../interfaces/IBudget.sol";
import {Input, Movement} from "../../lib/types.sol";

/// @title LeafAction
/// @notice Base for leaves: actions that consume their whole input and output nothing. Not bound to
///         a budget, and without preconditions or postconditions unless a leaf adds them.
abstract contract LeafAction is INodeAction, DaoAuthorizableUpgradeable {
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @inheritdoc INodeAction
    function budget() external pure returns (IBudget) {}

    /// @inheritdoc INodeAction
    function preconditions(address, bytes calldata, Movement calldata) external view virtual returns (bytes memory) {}

    /// @inheritdoc INodeAction
    function postconditions(address, Movement calldata, bytes calldata) external view virtual {}

    /// @dev What every leaf does with its input: spends all of it and outputs nothing
    function _consume(Input calldata _input) internal pure returns (Movement memory) {
        return Movement(_input.token, _input.amount, _input.token, 0, _input.beneficiary);
    }
}
