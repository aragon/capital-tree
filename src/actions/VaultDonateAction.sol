// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IDAO} from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";
import {Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import {IDonationVault} from "../interfaces/IDonationVault.sol";
import {LeafAction} from "./base/LeafAction.sol";
import {Asset} from "../lib/types.sol";

/// @notice Compounds the entire input for existing vault holders without minting shares.
/// @dev The configured vault is trusted; only vaults accounting donations immediately are supported.
contract VaultDonateAction is LeafAction {
    IDonationVault public vault;

    error WrongAsset();
    error AssetsNotIncreased(uint256 expected, uint256 actual);

    function initialize(IDAO _dao, IDonationVault _vault) external initializer {
        __DaoAuthorizableUpgradeable_init(_dao);
        vault = _vault;
    }

    function preconditions(address, bytes calldata, Asset calldata _input, Asset calldata)
        external
        view
        override
        returns (bytes memory snapshot)
    {
        if (address(_input.token) != vault.asset()) revert WrongAsset();
        return abi.encode(vault.totalAssets());
    }

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
