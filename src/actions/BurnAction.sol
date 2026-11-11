// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {IDAO} from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";
import {Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import {INodeAction} from "../interfaces/INodeAction.sol";
import {Asset} from "../lib/types.sol";
import {LeafAction} from "./base/LeafAction.sol";

/// @title BurnAction
/// @notice Leaf that burns its whole input with `ERC20Burnable.burn`, lowering the total supply
/// @dev The token must implement `burn(uint256)`. Postcondition: the DAO's balance dropped by
///      exactly the input, which catches a token whose fallback accepts `burn` without burning (WETH9).
contract BurnAction is LeafAction {
    /// @notice Thrown when the DAO holds more than it should after the burn
    error NotBurned(IERC20 token, uint256 maxBalance, uint256 balance);

    /// @notice Thrown when the DAO lost more than the input
    error Overspent(IERC20 token, uint256 minBalance, uint256 balance);

    /// @notice Initializes the action
    /// @param _dao The DAO the action works for. It takes no dependencies or settings.
    function initialize(IDAO _dao, address[] calldata, bytes calldata) external initializer {
        __DaoAuthorizableUpgradeable_init(_dao);
    }

    /// @inheritdoc INodeAction
    function build(address, bytes calldata, Asset calldata _input)
        external
        pure
        returns (Asset memory _output, Action[] memory _actions)
    {
        _output = _consume(_input);
        _actions = new Action[](1);
        _actions[0] =
            Action({to: address(_input.token), value: 0, data: abi.encodeCall(ERC20Burnable.burn, (_input.amount))});
    }

    /// @inheritdoc INodeAction
    /// @dev Snapshot: the DAO's balance before the burn
    function preconditions(address, bytes calldata, Asset calldata _input, Asset calldata)
        external
        view
        override
        returns (bytes memory)
    {
        return abi.encode(_input.token.balanceOf(address(dao())));
    }

    /// @inheritdoc INodeAction
    /// @dev The DAO's balance dropped by exactly the input: no less (it really burned), no more
    ///      (it didn't overspend)
    function postconditions(address, Asset calldata _input, Asset calldata, bytes calldata _snapshot)
        external
        view
        override
    {
        // Can't underflow: the burn would have reverted if the DAO held less than the input
        uint256 _expected = abi.decode(_snapshot, (uint256)) - _input.amount;
        uint256 _balance = _input.token.balanceOf(address(dao()));
        if (_balance > _expected) revert NotBurned(_input.token, _expected, _balance);
        if (_balance < _expected) revert Overspent(_input.token, _expected, _balance);
    }
}
