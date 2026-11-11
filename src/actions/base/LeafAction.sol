// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseAction} from "./BaseAction.sol";
import {Asset} from "../../lib/types.sol";

/// @title LeafAction
/// @notice Base for leaves: actions that consume their whole input and output nothing
abstract contract LeafAction is BaseAction {
    /// @dev What every leaf produces: nothing. It spends its whole input.
    function _consume(Asset calldata _input) internal pure returns (Asset memory) {
        return Asset(_input.token, 0);
    }
}
