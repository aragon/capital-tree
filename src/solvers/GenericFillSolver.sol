// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {CapitalTreePlugin} from "../CapitalTreePlugin.sol";

import {IFiller} from "../interfaces/IFiller.sol";

/// @title GenericFillSolver
/// @notice Minimal permissioned ERC20 executor for open-fill callbacks.
/// @dev    Deliberately minimal, solvers wanting additional guarantees can implement custom checks.
contract GenericFillSolver is IFiller {
    using SafeERC20 for IERC20;

    /// @notice Thrown when a call in the `fillOffer` batch reverts
    error CallFailed(uint256 idx);
    /// @notice Thrown when the caller is neither `authorized` (`trigger`, `sweep`) nor the plugin's DAO (`fillOffer`)
    error Unauthorized();
    /// @notice Thrown when `authorized` is address(0)
    error InvalidAuthorized();

    /// @notice Restricts the caller of trigger and sweep functions.
    address public immutable authorized;

    /// @notice The plugin this solver triggers. Only its DAO can call `fillOffer`.
    CapitalTreePlugin public immutable plugin;

    constructor(address _authorized, CapitalTreePlugin _plugin) {
        if (_authorized == address(0)) revert InvalidAuthorized();
        authorized = _authorized;
        plugin = _plugin;
    }

    function _checkAuth(address _caller) internal view {
        if (_caller != authorized) revert Unauthorized();
    }

    /// @notice Entrypoint for passing generic calldata for atomic swaps.
    /// @param data The node data, one entry per node. The OpenFill node's entry is `abi.encode(Action[])`,
    ///        the batch `fillOffer` runs.
    function trigger(bytes[] calldata data) external {
        _checkAuth(msg.sender);
        plugin.trigger("", data);
    }

    /// @notice Sends the entire ERC20 balance to recipient.
    /// @dev    Can be atomically added to fillOffer calldata to return excess tokens after a swap.
    function sweep(IERC20 token, address recipient) external {
        if (msg.sender != address(this)) _checkAuth(msg.sender);
        uint256 balance = token.balanceOf(address(this));
        if (balance == 0) return;
        token.safeTransfer(recipient, balance);
    }

    /// @inheritdoc IFiller
    /// @dev Runs the batch in `data` (`abi.encode(Action[])`). An ERC20 executor: its calls carry no ether.
    function fillOffer(IERC20, uint256, IERC20, uint256, bytes calldata data) external override {
        if (msg.sender != address(plugin.dao())) revert Unauthorized();
        Action[] memory calls = abi.decode(data, (Action[]));
        for (uint256 i; i < calls.length; ++i) {
            (bool ok,) = calls[i].to.call(calls[i].data);
            if (!ok) revert CallFailed(i);
        }
    }
}
