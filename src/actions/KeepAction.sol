// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {IDAO} from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";
import {Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import {INodeAction} from "../interfaces/INodeAction.sol";
import {Asset} from "../lib/types.sol";
import {LeafAction} from "./base/LeafAction.sol";

/// @title KeepAction
/// @notice Leaf that leaves its whole input in the DAO, so keeping funds is an explicit choice
contract KeepAction is LeafAction {
    /// @notice Initializes the action
    /// @param _dao The DAO the action works for. It takes no dependencies or settings.
    function initialize(IDAO _dao, address[] calldata, bytes calldata) external initializer {
        __DaoAuthorizableUpgradeable_init(_dao);
    }

    /// @inheritdoc INodeAction
    function build(address, bytes calldata, Asset calldata _input)
        external
        pure
        returns (Asset memory, Action[] memory)
    {
        return (_consume(_input), new Action[](0)); // no actions: the input stays where it is
    }
}
