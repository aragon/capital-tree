// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {IDAO} from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";

/// @title IComponent
/// @notice How the setup initializes every recipe component: a fresh clone gets the installing DAO,
///         its initialization dependencies and its own settings
interface IComponent {
    /// @notice Thrown when a component gets a number of dependencies it doesn't expect
    error WrongDependencyCount(uint256 expected, uint256 actual);

    /// @param dao The DAO the component works for
    /// @param deps Setup supplies [flowBudget] to every action and [] to budgets and splitters.
    ///             Actions that do not use the budget ignore this argument.
    /// @param settings The component's own settings, ABI-encoded in the shape it documents
    function initialize(IDAO dao, address[] calldata deps, bytes calldata settings) external;
}
