// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import {INodeAction} from "../../interfaces/INodeAction.sol";
import {LeafAction} from "./LeafAction.sol";
import {Input, Movement} from "../../lib/types.sol";
import {transferAction} from "../../lib/tokens.sol";

/// @title TransferBase
/// @notice Leaf that sends its whole input to one recipient. Postcondition: the recipient's balance
///         rose by the amount, which catches tokens that return false instead of reverting.
/// @dev Fee-on-transfer and rebasing tokens fail the postcondition by design.
abstract contract TransferBase is LeafAction {
    /// @notice Thrown when a recipient holds less than it should after the transfer
    error ReceiptShortfall(IERC20 token, address recipient, uint256 expected, uint256 actual);

    /// @inheritdoc INodeAction
    function build(address, bytes calldata, Input calldata _input)
        external
        view
        virtual
        returns (Movement memory _movement, Action[] memory _actions)
    {
        _movement = _consume(_input);
        _actions = new Action[](1);
        _actions[0] = transferAction(_input.token, _recipient(_input.beneficiary), _input.amount);
    }

    /// @inheritdoc INodeAction
    /// @dev Snapshot: the recipient's balance before the transfer
    function preconditions(address, bytes calldata, Movement calldata _movement)
        external
        view
        virtual
        override
        returns (bytes memory)
    {
        return abi.encode(_movement.inToken.balanceOf(_recipient(_movement.beneficiary)));
    }

    /// @inheritdoc INodeAction
    function postconditions(address, Movement calldata _movement, bytes calldata _snapshot)
        external
        view
        virtual
        override
    {
        address _to = _recipient(_movement.beneficiary);
        uint256 _expected = abi.decode(_snapshot, (uint256)) + _movement.inAmount;
        uint256 _balance = _movement.inToken.balanceOf(_to);
        if (_balance < _expected) revert ReceiptShortfall(_movement.inToken, _to, _expected, _balance);
    }

    /// @param _beneficiary The flow's beneficiary, address(0) if none was set
    function _recipient(address _beneficiary) internal view virtual returns (address);
}
