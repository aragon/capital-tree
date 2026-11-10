// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import {INodeAction} from "../../interfaces/INodeAction.sol";
import {LeafAction} from "./LeafAction.sol";
import {Asset} from "../../lib/types.sol";
import {transferAction} from "../../lib/tokens.sol";

/// @title TransferBase
/// @notice Leaf that sends its whole input to one recipient. Postcondition: the recipient's balance
///         rose by the amount, which catches tokens that return false instead of reverting.
/// @dev Fee-on-transfer and rebasing tokens fail the postcondition by design.
abstract contract TransferBase is LeafAction {
    /// @notice Thrown when a recipient holds less than it should after the transfer
    error ReceiptShortfall(IERC20 token, address recipient, uint256 expected, uint256 actual);

    /// @inheritdoc INodeAction
    function build(address, bytes calldata _data, Asset calldata _input)
        external
        view
        virtual
        returns (Asset memory _output, Action[] memory _actions)
    {
        _output = _consume(_input);
        _actions = new Action[](1);
        _actions[0] = transferAction(_input.token, _recipient(_data), _input.amount);
    }

    /// @inheritdoc INodeAction
    /// @dev Snapshot: the recipient and its balance before the transfer. The recipient goes in the
    ///      snapshot because `postconditions` doesn't get the node's data.
    function preconditions(address, bytes calldata _data, Asset calldata _input, Asset calldata)
        external
        view
        virtual
        override
        returns (bytes memory)
    {
        address _to = _recipient(_data);
        return abi.encode(_to, _input.token.balanceOf(_to));
    }

    /// @inheritdoc INodeAction
    /// @dev The recipient got at least the amount. That the DAO gave at most the amount is the
    ///      plugin's own balance check, right after this.
    function postconditions(address, Asset calldata _input, Asset calldata, bytes calldata _snapshot)
        external
        view
        virtual
        override
    {
        (address _to, uint256 _toBefore) = abi.decode(_snapshot, (address, uint256));

        uint256 _expected = _toBefore + _input.amount;
        uint256 _balance = _input.token.balanceOf(_to);
        if (_balance < _expected) revert ReceiptShortfall(_input.token, _to, _expected, _balance);
    }

    /// @param _data The node's trigger data
    function _recipient(bytes calldata _data) internal view virtual returns (address);
}
