// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IDAO} from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";
import {Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import {IDonationVault} from "../interfaces/IDonationVault.sol";
import {LeafAction} from "./base/LeafAction.sol";
import {Asset} from "../lib/types.sol";

/// @title VaultDonateAction
/// @notice Leaf that donates its whole input to a vault, raising the backing of existing shares
///         without minting new ones
/// @dev The configured vault is trusted; only vaults accounting donations immediately are supported.
contract VaultDonateAction is LeafAction {
    /// @notice The vault the input is donated to. Its asset must be the input token.
    IDonationVault public vault;

    /// @notice Thrown when the input token isn't the vault's asset
    error WrongAsset();

    /// @notice Thrown when the vault's total assets rose by less than the input
    error AssetsNotIncreased(uint256 expected, uint256 actual);

    /// @notice Initializes the action with its vault
    /// @param _dao The DAO donating
    /// @param _settings `abi.encode(IDonationVault vault)`: the trusted vault, whose asset must match the input token
    function initialize(IDAO _dao, address[] calldata, bytes calldata _settings) external initializer {
        __DaoAuthorizableUpgradeable_init(_dao);
        vault = abi.decode(_settings, (IDonationVault));
    }

    /// @notice Reverts unless the input token is the vault's asset
    /// @return snapshot The vault's total assets before the donation
    function preconditions(address, bytes calldata, Asset calldata _input, Asset calldata)
        external
        view
        override
        returns (bytes memory snapshot)
    {
        if (address(_input.token) != vault.asset()) revert WrongAsset();
        return abi.encode(vault.totalAssets());
    }

    /// @notice Donates the whole input to the vault: approve it, donate it, clear the approval.
    ///         Outputs nothing.
    function build(address, bytes calldata, Asset calldata _input)
        external
        view
        returns (Asset memory, Action[] memory _actions)
    {
        _actions = new Action[](3);
        _actions[0] = Action(address(_input.token), 0, abi.encodeCall(IERC20.approve, (address(vault), _input.amount)));
        _actions[1] = Action(address(vault), 0, abi.encodeCall(IDonationVault.donate, (_input.amount)));
        _actions[2] = Action(address(_input.token), 0, abi.encodeCall(IERC20.approve, (address(vault), 0)));
        return (_consume(_input), _actions);
    }

    /// @notice Reverts unless the vault's total assets rose by at least the input
    function postconditions(address, Asset calldata _input, Asset calldata, bytes calldata _snapshot)
        external
        view
        override
    {
        uint256 _expected = abi.decode(_snapshot, (uint256)) + _input.amount;
        uint256 _actual = vault.totalAssets();
        if (_actual < _expected) revert AssetsNotIncreased(_expected, _actual);
    }
}
