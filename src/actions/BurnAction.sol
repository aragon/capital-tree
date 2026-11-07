// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {IDAO} from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";
import {Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import {INodeAction} from "../interfaces/INodeAction.sol";
import {Input, Movement} from "../lib/types.sol";
import {LeafAction} from "./base/LeafAction.sol";

/// @title BurnAction
/// @notice Leaf that burns its whole input with `ERC20Burnable.burn`, lowering the total supply
/// @dev The token must implement `burn(uint256)`. Postcondition: the DAO's balance dropped by the
///      whole input. The plugin only checks it didn't drop by more, so without this a token whose
///      fallback accepts `burn` without burning (WETH9) would pass.
contract BurnAction is LeafAction {
    /// @notice Thrown when the DAO holds more than it should after the burn
    error NotBurned(IERC20 token, uint256 maxBalance, uint256 balance);

    function initialize(IDAO _dao) external initializer {
        __DaoAuthorizableUpgradeable_init(_dao);
    }

    /// @inheritdoc INodeAction
    function build(address, bytes calldata, Input calldata _input)
        external
        pure
        returns (Movement memory _movement, Action[] memory _actions)
    {
        _movement = _consume(_input);
        _actions = new Action[](1);
        _actions[0] =
            Action({to: address(_input.token), value: 0, data: abi.encodeCall(ERC20Burnable.burn, (_input.amount))});
    }

    /// @inheritdoc INodeAction
    /// @dev Snapshot: the DAO's balance before the burn
    function preconditions(address, bytes calldata, Movement calldata _movement)
        external
        view
        override
        returns (bytes memory)
    {
        return abi.encode(_movement.inToken.balanceOf(address(dao())));
    }

    /// @inheritdoc INodeAction
    function postconditions(address, Movement calldata _movement, bytes calldata _snapshot) external view override {
        uint256 _maxBalance = abi.decode(_snapshot, (uint256)) - _movement.inAmount;
        uint256 _balance = _movement.inToken.balanceOf(address(dao()));
        if (_balance > _maxBalance) revert NotBurned(_movement.inToken, _maxBalance, _balance);
    }
}
