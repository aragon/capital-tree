// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {IDAO} from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";

/// @title IComponent
/// @notice How the setup initializes every recipe component: a fresh clone gets the installing DAO,
///         its initialization dependencies and its own settings. The component then names the
///         permissions it needs to work, which the setup grants as declared.
interface IComponent {
    /// @notice A permission `who` needs on `where`
    struct Permission {
        address where;
        address who;
        bytes32 permissionId;
    }

    /// @notice Thrown when a component gets a number of dependencies it doesn't expect
    error WrongDependencyCount(uint256 expected, uint256 actual);

    /// @notice Initializes the clone, once, when the setup prepares the installation
    /// @param dao The DAO the component works for
    /// @param deps Setup supplies [flowBudget] to every action and [] to budgets and splitters.
    ///             Actions that do not use the budget ignore this argument.
    /// @param settings The component's own settings, ABI-encoded in the shape it documents
    function initialize(IDAO dao, address[] calldata deps, bytes calldata settings) external;

    /// @notice The permissions this component needs to work in a flow, such as the DAO's right to
    ///         commit a budget. Not the ones that decide who governs it (a manager's settings, a
    ///         guardian's pause): the recipe grants those.
    /// @param dao The installing DAO
    /// @param plugin The flow's plugin
    /// @param budget The flow's budget
    function requiredPermissions(address dao, address plugin, address budget)
        external
        view
        returns (Permission[] memory);
}
