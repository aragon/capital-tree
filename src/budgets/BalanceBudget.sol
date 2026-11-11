// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IDAO} from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";
import {Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import {
    DaoAuthorizableUpgradeable
} from "@aragon/osx-commons-contracts/src/permission/auth/DaoAuthorizableUpgradeable.sol";
import {IBudget} from "../interfaces/IBudget.sol";
import {IComponent} from "../interfaces/IComponent.sol";

/// @title BalanceBudget
/// @notice The DAO's whole balance of a token, with nothing to commit. The root receives all of it.
contract BalanceBudget is IBudget, IComponent, DaoAuthorizableUpgradeable {
    /// @inheritdoc IBudget
    IERC20 public token;

    /// @notice Thrown when the token is not a contract
    error InvalidToken();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @param _dao The DAO holding the funds
    /// @param _settings `abi.encode(IERC20 token)`: the ERC20 token the budget gives
    function initialize(IDAO _dao, address[] calldata, bytes calldata _settings) external initializer {
        IERC20 _token = abi.decode(_settings, (IERC20));
        if (address(_token).code.length == 0) revert InvalidToken();

        __DaoAuthorizableUpgradeable_init(_dao);
        token = _token;
    }

    /// @inheritdoc IBudget
    /// @dev The DAO's balance of the token
    function available(address, bytes calldata) external view returns (uint256) {
        return token.balanceOf(address(dao()));
    }

    /// @inheritdoc IBudget
    function fundActions(address, bytes calldata) external pure returns (Action[] memory) {}

    /// @inheritdoc IBudget
    function commitActions(address, bytes calldata) external pure returns (Action[] memory) {}
}
