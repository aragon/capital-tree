// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {IDAO} from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";
import {TransferBase} from "./base/TransferBase.sol";

/// @title TransferAction
/// @notice Leaf that sends its whole input to a fixed recipient
contract TransferAction is TransferBase {
    /// @notice Who receives the node's input
    address public recipient;

    /// @notice Thrown when the recipient is address(0)
    error NoRecipient();

    /// @notice Initializes the action with its fixed recipient
    /// @param _dao The DAO paying
    /// @param _settings `abi.encode(address to)`: the recipient
    function initialize(IDAO _dao, address[] calldata, bytes calldata _settings) external initializer {
        address _to = abi.decode(_settings, (address));
        if (_to == address(0)) revert NoRecipient();
        __DaoAuthorizableUpgradeable_init(_dao);
        recipient = _to;
    }

    /// @dev Ignores the node's data: the recipient is fixed
    function _recipient(bytes calldata) internal view override returns (address) {
        return recipient;
    }
}
