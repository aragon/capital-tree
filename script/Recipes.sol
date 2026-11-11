// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CapitalTreePluginSetup as Setup} from "../src/setup/CapitalTreePluginSetup.sol";
import {IDonationVault} from "../src/interfaces/IDonationVault.sol";
import {
    TRIGGER_PERMISSION_ID,
    PAUSE_PERMISSION_ID,
    SET_SETTINGS_PERMISSION_ID,
    CHECKPOINT_PERMISSION_ID,
    RECORD_CLAIM_PERMISSION_ID,
    RATIO_BASE
} from "../src/lib/constants.sol";

/// @title Recipes
/// @notice A budget and a tree of independently deployed actions and splitters. Permissions sit
///         next to the contract they apply to; recipients, including the DAO, are actual addresses.
library Recipes {
    bytes32 internal constant STREAM_BUDGET = "StreamBudget@1";
    bytes32 internal constant BALANCE_BUDGET = "BalanceBudget@1";
    bytes32 internal constant OPEN_FILL = "OpenFillAction@1";
    bytes32 internal constant MERKLE_CLAIM = "MerkleClaimBudget@1";
    bytes32 internal constant TRANSFER = "TransferAction@1";
    bytes32 internal constant TRANSFER_TO_BENEFICIARY = "TransferToBeneficiaryAction@1";
    bytes32 internal constant BURN = "BurnAction@1";
    bytes32 internal constant KEEP = "KeepAction@1";
    bytes32 internal constant WEIGHT_SPLITTER = "WeightSplitter@1";
    bytes32 internal constant VAULT_DONATE = "VaultDonateAction@1";

    address internal constant ANY_ADDR = address(type(uint160).max);

    /// @notice Thrown when an OpenFill recipe's stream has no cap, so its auction has no worst price
    error UncappedStream();

    /// @notice Thrown when a fee isn't between 1 and 9,999 basis points
    error InvalidFeeBps();

    /// @notice Thrown when a fee has no recipient
    error InvalidFeeRecipient();

    struct Stream {
        IERC20 token;
        uint256 amountPerEpoch;
        uint256 maxBudget;
        uint256 epochInterval;
    }

    struct Swap {
        IERC20 demandedToken;
        uint256 demandPerFill;
    }

    /// @notice Stream → OpenFill → burn the proceeds.
    function buyAndBurn(address _dao, address _manager, address _guardian, Stream memory _stream, Swap memory _swap)
        internal
        pure
        returns (Setup.InstallParams memory _params)
    {
        if (_stream.maxBudget == 0) revert UncappedStream();
        _params.budget = _streamBudget(_dao, _manager, _stream);
        _params.pluginPermissions = _pluginPermissions(_guardian);
        _params.nodes = new Setup.RecipeNode[](2);
        uint32[] memory _children = new uint32[](1);
        _children[0] = 1;
        _params.nodes[0] = Setup.RecipeNode({
            action: _openFill(_manager, _swap),
            children: _children,
            splitter: _noComponent(),
            skipWhenEmpty: false,
            forwardSurplus: false
        });
        _params.nodes[1] = _leaf(BURN, "");
    }

    /// @notice Stream → OpenFill → burn and pay a fee, split by weight.
    function buyback(
        address _dao,
        address _manager,
        address _guardian,
        Stream memory _stream,
        Swap memory _swap,
        address _fee,
        uint32 _feeWeight
    ) internal pure returns (Setup.InstallParams memory _params) {
        if (_stream.maxBudget == 0) revert UncappedStream();
        _params.budget = _streamBudget(_dao, _manager, _stream);
        _params.pluginPermissions = _pluginPermissions(_guardian);
        uint32[] memory _weights = new uint32[](2);
        (_weights[0], _weights[1]) = (uint32(RATIO_BASE) - _feeWeight, _feeWeight);
        uint32[] memory _children = new uint32[](2);
        (_children[0], _children[1]) = (1, 2);
        _params.nodes = new Setup.RecipeNode[](3);
        _params.nodes[0] = Setup.RecipeNode({
            action: _openFill(_manager, _swap),
            children: _children,
            splitter: _splitter(_manager, _weights),
            skipWhenEmpty: false,
            forwardSurplus: false
        });
        _params.nodes[1] = _leaf(BURN, "");
        _params.nodes[2] = _leaf(TRANSFER, abi.encode(_fee));
    }

    /// @notice Stream → OpenFill → pay the fee, then donate the rest, including surplus.
    function buybackAndDonate(
        address _dao,
        address _manager,
        address _guardian,
        Stream memory _stream,
        Swap memory _swap,
        IDonationVault _vault,
        address _feeRecipient,
        uint256 _feeBps
    ) internal pure returns (Setup.InstallParams memory _params) {
        if (_feeBps == 0 || _feeBps >= 10_000) revert InvalidFeeBps();
        if (_feeRecipient == address(0)) revert InvalidFeeRecipient();
        if (_stream.maxBudget == 0) revert UncappedStream();
        _params.budget = _streamBudget(_dao, _manager, _stream);
        _params.pluginPermissions = _pluginPermissions(_guardian);
        uint32 _feeWeight = uint32(_feeBps * RATIO_BASE / 10_000);
        uint32[] memory _weights = new uint32[](2);
        (_weights[0], _weights[1]) = (_feeWeight, uint32(RATIO_BASE) - _feeWeight);
        uint32[] memory _children = new uint32[](2);
        (_children[0], _children[1]) = (1, 2);
        _params.nodes = new Setup.RecipeNode[](3);
        _params.nodes[0] = Setup.RecipeNode({
            action: _openFill(_manager, _swap),
            children: _children,
            splitter: _splitter(_manager, _weights),
            skipWhenEmpty: false,
            forwardSurplus: true
        });
        // A failed donation rolls back the preceding fee payment too.
        _params.nodes[1] = _leaf(TRANSFER, abi.encode(_feeRecipient));
        _params.nodes[2] = _leaf(VAULT_DONATE, abi.encode(_vault));
    }

    /// @notice Merkle claim → pay the beneficiary.
    function merkleClaim(address _dao, address _manager, address _guardian, IERC20 _token, bytes32 _root)
        internal
        pure
        returns (Setup.InstallParams memory _params)
    {
        Setup.Grant[] memory _permissions = new Setup.Grant[](2);
        _permissions[0] = Setup.Grant(_manager, SET_SETTINGS_PERMISSION_ID);
        _permissions[1] = Setup.Grant(_dao, RECORD_CLAIM_PERMISSION_ID);
        _params.budget = Setup.Component(MERKLE_CLAIM, abi.encode(_token, _root), _permissions);
        _params.pluginPermissions = _pluginPermissions(_guardian);
        _params.nodes = new Setup.RecipeNode[](1);
        _params.nodes[0] = _leaf(TRANSFER_TO_BENEFICIARY, "");
    }

    /// @notice Stream → a branch paying each recipient its weight. Each leaf owns its Transfer clone.
    function payroll(
        address _dao,
        address _manager,
        address _guardian,
        Stream memory _stream,
        address[] memory _recipients,
        uint32[] memory _weights
    ) internal pure returns (Setup.InstallParams memory _params) {
        _params.budget = _streamBudget(_dao, _manager, _stream);
        _params.pluginPermissions = _pluginPermissions(_guardian);
        uint32[] memory _children = new uint32[](_recipients.length);
        _params.nodes = new Setup.RecipeNode[](1 + _recipients.length);
        for (uint256 i; i < _recipients.length; ++i) {
            _children[i] = uint32(1 + i);
            _params.nodes[1 + i] = _leaf(TRANSFER, abi.encode(_recipients[i]));
        }
        _params.nodes[0] = Setup.RecipeNode({
            action: Setup.Action(bytes32(0), "", new Setup.Grant[](0), new bytes32[](0)),
            children: _children,
            splitter: _splitter(_manager, _weights),
            skipWhenEmpty: false,
            forwardSurplus: false
        });
    }

    // Declarations include their settings and permissions. No addresses need patching after deployment.

    function _streamBudget(address _dao, address _manager, Stream memory _stream)
        private
        pure
        returns (Setup.Component memory)
    {
        Setup.Grant[] memory _permissions = new Setup.Grant[](2);
        _permissions[0] = Setup.Grant(_manager, SET_SETTINGS_PERMISSION_ID);
        _permissions[1] = Setup.Grant(_dao, CHECKPOINT_PERMISSION_ID);
        return Setup.Component(
            STREAM_BUDGET,
            abi.encode(_stream.token, _stream.amountPerEpoch, _stream.maxBudget, _stream.epochInterval),
            _permissions
        );
    }

    function _openFill(address _manager, Swap memory _swap) private pure returns (Setup.Action memory) {
        bytes32[] memory _budgetPermissions = new bytes32[](1);
        _budgetPermissions[0] = CHECKPOINT_PERMISSION_ID;
        return Setup.Action(
            OPEN_FILL,
            abi.encode(_swap.demandedToken, _swap.demandPerFill),
            _managerPermission(_manager),
            _budgetPermissions
        );
    }

    function _splitter(address _manager, uint32[] memory _weights) private pure returns (Setup.Component memory) {
        return Setup.Component(WEIGHT_SPLITTER, abi.encode(_weights), _managerPermission(_manager));
    }

    function _leaf(bytes32 _id, bytes memory _settings) private pure returns (Setup.RecipeNode memory) {
        return Setup.RecipeNode({
            action: Setup.Action(_id, _settings, new Setup.Grant[](0), new bytes32[](0)),
            children: new uint32[](0),
            splitter: _noComponent(),
            skipWhenEmpty: false,
            forwardSurplus: false
        });
    }

    function _noComponent() private pure returns (Setup.Component memory) {
        return Setup.Component(bytes32(0), "", new Setup.Grant[](0));
    }

    function _managerPermission(address _manager) private pure returns (Setup.Grant[] memory _permissions) {
        _permissions = new Setup.Grant[](1);
        _permissions[0] = Setup.Grant(_manager, SET_SETTINGS_PERMISSION_ID);
    }

    function _pluginPermissions(address _guardian) private pure returns (Setup.Grant[] memory _permissions) {
        _permissions = new Setup.Grant[](2);
        _permissions[0] = Setup.Grant(ANY_ADDR, TRIGGER_PERMISSION_ID);
        _permissions[1] = Setup.Grant(_guardian, PAUSE_PERMISSION_ID);
    }
}
