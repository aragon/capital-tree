// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IDAO} from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";
import {Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import {IDonationVault} from "../interfaces/IDonationVault.sol";
import {LeafAction} from "./base/LeafAction.sol";
import {Input, Movement} from "../lib/types.sol";

/// @notice Compounds the entire input for existing vault holders without minting shares.
/// @dev Pair with a weighted KeepAction sibling to retain part of a buyback in the DAO.
///      The configured vault is trusted; only vaults accounting donations immediately are supported.
contract VaultDonateAction is LeafAction {
    IDonationVault public vault;

    error InvalidVault();
    error WrongAsset();
    error EmptyVault();
    error AssetsNotIncreased(uint256 expected, uint256 actual);
    error ShareSupplyChanged(uint256 expected, uint256 actual);

    function initialize(IDAO _dao, IDonationVault _vault) external initializer {
        if (address(_vault).code.length == 0 || _vault.asset().code.length == 0) revert InvalidVault();
        __DaoAuthorizableUpgradeable_init(_dao);
        vault = _vault;
    }

    function preconditions(address, Input calldata _input) external view override {
        if (address(_input.token) != vault.asset()) revert WrongAsset();
        if (vault.totalSupply() == 0) revert EmptyVault();
    }

    function build(address, bytes calldata, Input calldata _input)
        external
        view
        returns (Movement memory, Action[] memory _actions)
    {
        _actions = new Action[](3);
        _actions[0] = Action(address(_input.token), 0, abi.encodeCall(IERC20.approve, (address(vault), _input.amount)));
        _actions[1] = Action(address(vault), 0, abi.encodeCall(IDonationVault.donate, (_input.amount)));
        _actions[2] = Action(address(_input.token), 0, abi.encodeCall(IERC20.approve, (address(vault), 0)));
        return (_consume(_input), _actions);
    }

    function postconditions(address, Movement calldata _movement)
        external
        view
        override
        returns (Action[] memory _checks)
    {
        _checks = new Action[](1);
        _checks[0] = Action(
            address(this),
            0,
            abi.encodeCall(this.assertDonated, (vault.totalAssets() + _movement.inAmount, vault.totalSupply()))
        );
    }

    /// @notice Checks the donation's economic effect immediately after the vault call.
    function assertDonated(uint256 _minAssets, uint256 _supplyBefore) external view {
        uint256 _assets = vault.totalAssets();
        if (_assets < _minAssets) revert AssetsNotIncreased(_minAssets, _assets);
        uint256 _supply = vault.totalSupply();
        if (_supply != _supplyBefore) revert ShareSupplyChanged(_supplyBefore, _supply);
    }
}
