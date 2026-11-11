// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CapitalTreePluginSetup, NONE} from "../src/setup/CapitalTreePluginSetup.sol";
import {
    TRIGGER_PERMISSION_ID,
    PAUSE_PERMISSION_ID,
    SET_SETTINGS_PERMISSION_ID,
    CHECKPOINT_PERMISSION_ID,
    RECORD_CLAIM_PERMISSION_ID,
    RATIO_BASE
} from "../src/lib/constants.sol";

/// @title Recipes
/// @notice Registry ids and install recipes for the common flows. A recipe is
///         `abi.encode(CapitalTreePluginSetup.InstallParams)`, and names its own components by
///         their index in it. Every recipe gives `_guardian` PAUSE on the plugin and `_manager`
///         SET_SETTINGS on each component with setters.
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

    address internal constant ANY_ADDR = address(type(uint160).max);

    /// @notice Thrown when an OpenFill recipe's stream has no cap, so its auction has no worst price
    error UncappedStream();

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

    /// @notice Stream → OpenFill → burn all the proceeds. The stream's `maxBudget` sets the worst
    ///         price: `demandPerFill / maxBudget`. Components: 0 budget, 1 OpenFill, 2 Burn.
    function buyAndBurn(address _manager, address _guardian, Stream memory _stream, Swap memory _swap)
        internal
        pure
        returns (CapitalTreePluginSetup.InstallParams memory _params)
    {
        if (_stream.maxBudget == 0) revert UncappedStream();
        _params.components = new CapitalTreePluginSetup.Component[](3);
        _params.components[0] = CapitalTreePluginSetup.Component(
            STREAM_BUDGET,
            new uint256[](0),
            abi.encode(_stream.token, _stream.amountPerEpoch, _stream.maxBudget, _stream.epochInterval)
        );
        uint256[] memory _openFillDeps = new uint256[](1);
        _openFillDeps[0] = 0; // the budget
        _params.components[1] = CapitalTreePluginSetup.Component(
            OPEN_FILL, _openFillDeps, abi.encode(_swap.demandedToken, _swap.demandPerFill)
        );
        _params.components[2] = CapitalTreePluginSetup.Component(BURN, new uint256[](0), "");

        _params.nodes = new CapitalTreePluginSetup.RecipeNode[](2);
        // Node 0: OpenFill (component 1) → node 1
        uint32[] memory _openFillChildren = new uint32[](1);
        _openFillChildren[0] = 1;
        _params.nodes[0] = CapitalTreePluginSetup.RecipeNode(1, _openFillChildren, NONE, false, false);
        // Node 1: Burn (component 2), a leaf
        _params.nodes[1] = CapitalTreePluginSetup.RecipeNode(2, new uint32[](0), NONE, false, false);

        _params.grants = new CapitalTreePluginSetup.Grant[](6);
        _params.grants[0] = _grant(_plugin(), _account(ANY_ADDR), TRIGGER_PERMISSION_ID);
        _params.grants[1] = _grant(_plugin(), _account(_guardian), PAUSE_PERMISSION_ID);
        _params.grants[2] = _grant(_component(0), _account(_manager), SET_SETTINGS_PERMISSION_ID);
        _params.grants[3] = _grant(_component(1), _account(_manager), SET_SETTINGS_PERMISSION_ID);
        _params.grants[4] = _grant(_component(0), _dao(), CHECKPOINT_PERMISSION_ID);
        _params.grants[5] = _grant(_component(0), _component(1), CHECKPOINT_PERMISSION_ID);
    }

    /// @notice Stream → OpenFill → burn the proceeds, except `_feeWeight` (of RATIO_BASE) to `_fee`.
    ///         The stream's `maxBudget` sets the worst price: `demandPerFill / maxBudget`.
    ///         Components: 0 budget, 1 OpenFill, 2 Burn, 3 Transfer, 4 WeightSplitter.
    function buyback(
        address _manager,
        address _guardian,
        Stream memory _stream,
        Swap memory _swap,
        address _fee,
        uint32 _feeWeight
    ) internal pure returns (CapitalTreePluginSetup.InstallParams memory _params) {
        uint32[] memory _weights = new uint32[](2);
        (_weights[0], _weights[1]) = (uint32(RATIO_BASE) - _feeWeight, _feeWeight);

        if (_stream.maxBudget == 0) revert UncappedStream();
        _params.components = new CapitalTreePluginSetup.Component[](5);
        _params.components[0] = CapitalTreePluginSetup.Component(
            STREAM_BUDGET,
            new uint256[](0),
            abi.encode(_stream.token, _stream.amountPerEpoch, _stream.maxBudget, _stream.epochInterval)
        );
        uint256[] memory _openFillDeps = new uint256[](1);
        _openFillDeps[0] = 0; // the budget
        _params.components[1] = CapitalTreePluginSetup.Component(
            OPEN_FILL, _openFillDeps, abi.encode(_swap.demandedToken, _swap.demandPerFill)
        );
        _params.components[2] = CapitalTreePluginSetup.Component(BURN, new uint256[](0), "");
        _params.components[3] = CapitalTreePluginSetup.Component(TRANSFER, new uint256[](0), abi.encode(_fee));
        _params.components[4] =
            CapitalTreePluginSetup.Component(WEIGHT_SPLITTER, new uint256[](0), abi.encode(_weights));

        _params.nodes = new CapitalTreePluginSetup.RecipeNode[](3);
        // Node 0: OpenFill (component 1) → nodes 1 and 2, split by the WeightSplitter (component 4)
        uint32[] memory _openFillChildren = new uint32[](2);
        (_openFillChildren[0], _openFillChildren[1]) = (1, 2);
        _params.nodes[0] = CapitalTreePluginSetup.RecipeNode(1, _openFillChildren, 4, false, false);
        // Node 1: Burn (component 2), a leaf
        _params.nodes[1] = CapitalTreePluginSetup.RecipeNode(2, new uint32[](0), NONE, false, false);
        // Node 2: Transfer to the fee recipient (component 3), a leaf
        _params.nodes[2] = CapitalTreePluginSetup.RecipeNode(3, new uint32[](0), NONE, false, false);

        _params.grants = new CapitalTreePluginSetup.Grant[](7);
        _params.grants[0] = _grant(_plugin(), _account(ANY_ADDR), TRIGGER_PERMISSION_ID);
        _params.grants[1] = _grant(_plugin(), _account(_guardian), PAUSE_PERMISSION_ID);
        _params.grants[2] = _grant(_component(0), _account(_manager), SET_SETTINGS_PERMISSION_ID);
        _params.grants[3] = _grant(_component(1), _account(_manager), SET_SETTINGS_PERMISSION_ID);
        _params.grants[4] = _grant(_component(0), _dao(), CHECKPOINT_PERMISSION_ID);
        _params.grants[5] = _grant(_component(0), _component(1), CHECKPOINT_PERMISSION_ID);
        _params.grants[6] = _grant(_component(4), _account(_manager), SET_SETTINGS_PERMISSION_ID);
    }

    /// @notice Merkle claim of `_token` → pay the beneficiary.
    ///         Components: 0 MerkleClaimBudget, 1 TransferToBeneficiary.
    function merkleClaim(address _manager, address _guardian, IERC20 _token, bytes32 _root)
        internal
        pure
        returns (CapitalTreePluginSetup.InstallParams memory _params)
    {
        _params.components = new CapitalTreePluginSetup.Component[](2);
        _params.components[0] =
            CapitalTreePluginSetup.Component(MERKLE_CLAIM, new uint256[](0), abi.encode(_token, _root));
        _params.components[1] = CapitalTreePluginSetup.Component(TRANSFER_TO_BENEFICIARY, new uint256[](0), "");

        _params.nodes = new CapitalTreePluginSetup.RecipeNode[](1);
        // Node 0: TransferToBeneficiary (component 1), a leaf
        _params.nodes[0] = CapitalTreePluginSetup.RecipeNode(1, new uint32[](0), NONE, false, false);

        _params.grants = new CapitalTreePluginSetup.Grant[](4);
        _params.grants[0] = _grant(_plugin(), _account(ANY_ADDR), TRIGGER_PERMISSION_ID);
        _params.grants[1] = _grant(_plugin(), _account(_guardian), PAUSE_PERMISSION_ID);
        _params.grants[2] = _grant(_component(0), _account(_manager), SET_SETTINGS_PERMISSION_ID);
        _params.grants[3] = _grant(_component(0), _dao(), RECORD_CLAIM_PERMISSION_ID);
    }

    /// @notice Stream → a branch paying each recipient its weight (of RATIO_BASE). Two or more
    ///         recipients. Components: 0 budget, then one Transfer per recipient, then the WeightSplitter.
    function payroll(
        address _manager,
        address _guardian,
        Stream memory _stream,
        address[] memory _recipients,
        uint32[] memory _weights
    ) internal pure returns (CapitalTreePluginSetup.InstallParams memory _params) {
        uint256 _count = _recipients.length;
        _params.components = new CapitalTreePluginSetup.Component[](2 + _count);
        _params.components[0] = CapitalTreePluginSetup.Component(
            STREAM_BUDGET,
            new uint256[](0),
            abi.encode(_stream.token, _stream.amountPerEpoch, _stream.maxBudget, _stream.epochInterval)
        );
        _params.components[1 + _count] =
            CapitalTreePluginSetup.Component(WEIGHT_SPLITTER, new uint256[](0), abi.encode(_weights));

        _params.nodes = new CapitalTreePluginSetup.RecipeNode[](1 + _count);
        // Node 0: a branch without an action → nodes 1 to `_count`, split by the WeightSplitter
        // (component 1 + `_count`)
        uint32[] memory _branchChildren = new uint32[](_count);
        for (uint256 i; i < _count; ++i) {
            _branchChildren[i] = uint32(1 + i);
        }
        _params.nodes[0] = CapitalTreePluginSetup.RecipeNode(NONE, _branchChildren, 1 + _count, false, false);
        for (uint256 i; i < _count; ++i) {
            _params.components[1 + i] =
                CapitalTreePluginSetup.Component(TRANSFER, new uint256[](0), abi.encode(_recipients[i]));
            // Node 1 + i: Transfer to recipient i (component 1 + i), a leaf
            _params.nodes[1 + i] = CapitalTreePluginSetup.RecipeNode(1 + i, new uint32[](0), NONE, false, false);
        }

        _params.grants = new CapitalTreePluginSetup.Grant[](5);
        _params.grants[0] = _grant(_plugin(), _account(ANY_ADDR), TRIGGER_PERMISSION_ID);
        _params.grants[1] = _grant(_plugin(), _account(_guardian), PAUSE_PERMISSION_ID);
        _params.grants[2] = _grant(_component(0), _account(_manager), SET_SETTINGS_PERMISSION_ID);
        _params.grants[3] = _grant(_component(0), _dao(), CHECKPOINT_PERMISSION_ID);
        _params.grants[4] = _grant(_component(1 + _count), _account(_manager), SET_SETTINGS_PERMISSION_ID);
    }

    // Grants

    function _grant(CapitalTreePluginSetup.Ref memory _where, CapitalTreePluginSetup.Ref memory _who, bytes32 _id)
        private
        pure
        returns (CapitalTreePluginSetup.Grant memory)
    {
        return CapitalTreePluginSetup.Grant(_where, _who, _id);
    }

    function _component(uint256 _index) private pure returns (CapitalTreePluginSetup.Ref memory) {
        return CapitalTreePluginSetup.Ref(CapitalTreePluginSetup.RefKind.Component, address(0), _index);
    }

    function _plugin() private pure returns (CapitalTreePluginSetup.Ref memory) {
        return CapitalTreePluginSetup.Ref(CapitalTreePluginSetup.RefKind.Plugin, address(0), 0);
    }

    function _dao() private pure returns (CapitalTreePluginSetup.Ref memory) {
        return CapitalTreePluginSetup.Ref(CapitalTreePluginSetup.RefKind.Dao, address(0), 0);
    }

    function _account(address _address) private pure returns (CapitalTreePluginSetup.Ref memory) {
        return CapitalTreePluginSetup.Ref(CapitalTreePluginSetup.RefKind.Account, _address, 0);
    }
}
