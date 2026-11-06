// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {CapitalPipelinePlugin} from "../CapitalPipelinePlugin.sol";

// TODO: Make the shared IFiller nonpayable and remove this temporary local interface.
interface IFiller {
    function fillOffer(
        IERC20 offeredToken,
        uint256 offeredAmount,
        IERC20 demandedToken,
        uint256 demandedAmount,
        bytes calldata data
    ) external;
}

/// @title GenericFillSolver
/// @notice Minimal permissioned ERC20 executor for open-fill callbacks.
/// @dev    Deliberately minimal, solvers wanting additional guarantees can implement custom checks.
contract GenericFillSolver is IFiller {
    using SafeERC20 for IERC20;

    error CallFailed(uint256 idx);
    error Unauthorized();
    error InvalidAuthorized();

    /// @notice Restricts the caller of trigger and sweep functions.
    address public immutable authorized;

    CapitalPipelinePlugin public immutable plugin;

    constructor(address _authorized, CapitalPipelinePlugin _plugin) {
        if (_authorized == address(0)) revert InvalidAuthorized();
        authorized = _authorized;
        plugin = _plugin;
    }

    function _checkAuth(address _caller) internal view {
        if (_caller != authorized) revert Unauthorized();
    }

    /// @notice Entrypoint for passing generic calldata for atomic swaps.
    function trigger(bytes[] calldata data) external {
        _checkAuth(msg.sender);
        plugin.trigger(data);
    }

    /// @notice Sends the entire ERC20 balance to recipient.
    /// @dev    Can be atomically added to fillOffer calldata to return excess tokens after a swap.
    function sweep(IERC20 token, address recipient) external {
        if (msg.sender != address(this)) _checkAuth(msg.sender);
        uint256 balance = token.balanceOf(address(this));
        if (balance == 0) return;
        token.safeTransfer(recipient, balance);
    }

    /// @notice Executes the supplied batch in the DAO callback during OpenFill.
    function fillOffer(IERC20, uint256, IERC20, uint256, bytes calldata data) external override {
        if (msg.sender != address(plugin.dao())) revert Unauthorized();
        Action[] memory calls = abi.decode(data, (Action[]));
        for (uint256 i; i < calls.length; ++i) {
            (bool ok,) = calls[i].to.call(calls[i].data);
            if (!ok) revert CallFailed(i);
        }
    }
}
