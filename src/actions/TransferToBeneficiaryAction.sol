// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {IDAO} from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";
import {TransferBase} from "./base/TransferBase.sol";

/// @title TransferToBeneficiaryAction
/// @notice Leaf that sends its whole input to the address in its node data, chosen by whoever
///         triggers the flow
/// @dev Node data: abi.encode(address beneficiary). The trigger caller picks it, so only use this
///      where the caller is entitled to direct the funds: under a MerkleClaimBudget (the caller
///      must be the claimer) or on a flow whose trigger is restricted. Never on a flow anyone can
///      trigger with a stream or balance budget: anyone could pay themselves.
contract TransferToBeneficiaryAction is TransferBase {
    /// @notice Thrown when the node data names no beneficiary
    error NoBeneficiary();

    /// @param _dao The DAO the action works for. It takes no dependencies or settings.
    function initialize(IDAO _dao, address[] calldata, bytes calldata) external initializer {
        __DaoAuthorizableUpgradeable_init(_dao);
    }

    function _recipient(bytes calldata _data) internal pure override returns (address _beneficiary) {
        if (_data.length != 32) revert NoBeneficiary();
        _beneficiary = abi.decode(_data, (address));
        if (_beneficiary == address(0)) revert NoBeneficiary();
    }
}
