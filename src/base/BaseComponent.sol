// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {
    DaoAuthorizableUpgradeable
} from "@aragon/osx-commons-contracts/src/permission/auth/DaoAuthorizableUpgradeable.sol";
import {IComponent} from "../interfaces/IComponent.sol";

/// @title BaseComponent
/// @notice Base for every recipe component: a clone bound to one DAO, which needs no permissions
///         to work unless it declares them
/// @dev The implementation can't be initialized: only its clones can
abstract contract BaseComponent is IComponent, DaoAuthorizableUpgradeable {
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @inheritdoc IComponent
    function requiredPermissions(address, address, address) external view virtual returns (Permission[] memory) {}
}
