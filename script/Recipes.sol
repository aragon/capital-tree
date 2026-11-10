// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IDAO} from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";
import {CapitalTreePluginSetup} from "../src/setup/CapitalTreePluginSetup.sol";
import {StreamBudget} from "../src/budgets/StreamBudget.sol";
import {BalanceBudget} from "../src/budgets/BalanceBudget.sol";
import {MerkleClaimBudget} from "../src/budgets/MerkleClaimBudget.sol";
import {OpenFillAction} from "../src/actions/OpenFillAction.sol";
import {TransferAction} from "../src/actions/TransferAction.sol";
import {TransferToBeneficiaryAction} from "../src/actions/TransferToBeneficiaryAction.sol";
import {BurnAction} from "../src/actions/BurnAction.sol";
import {WeightSplitter} from "../src/splitters/WeightSplitter.sol";
import {IBudget, ICheckpointedBudget} from "../src/interfaces/IBudget.sol";
import {INodeAction} from "../src/interfaces/INodeAction.sol";
import {ISplitter} from "../src/interfaces/ISplitter.sol";
import {Node} from "../src/lib/types.sol";
import {
    TRIGGER_PERMISSION_ID,
    PAUSE_PERMISSION_ID,
    SET_SETTINGS_PERMISSION_ID,
    CHECKPOINT_PERMISSION_ID,
    RECORD_CLAIM_PERMISSION_ID,
    RATIO_BASE
} from "../src/lib/constants.sol";
import {DAO_REF, PLUGIN_REF, ref} from "../src/lib/placeholders.sol";

/// @title Recipes
/// @notice Registry ids and install recipes for the common flows. A recipe is
///         `abi.encode(CapitalTreePluginSetup.InstallParams)`. Every recipe gives `_guardian` PAUSE on
///         the plugin and `_manager` SET_SETTINGS on each component with setters.
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
        _params.components = new CapitalTreePluginSetup.Component[](3);
        _params.components[0] = _cappedStreamBudget(_stream);
        _params.components[1] = _openFill(_swap);
        _params.components[2] = _burn();

        _params.budget = IBudget(ref(0));
        _params.nodes = new Node[](2);
        _params.nodes[0] = _then(1, 1);
        _params.nodes[1] = _leaf(2);

        _params.grants = _swapGrants(_manager, _guardian, 0);
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

        _params.components = new CapitalTreePluginSetup.Component[](5);
        _params.components[0] = _cappedStreamBudget(_stream);
        _params.components[1] = _openFill(_swap);
        _params.components[2] = _burn();
        _params.components[3] = _transfer(_fee);
        _params.components[4] = _weightSplitter(_weights);

        _params.budget = IBudget(ref(0));
        _params.nodes = new Node[](3);
        _params.nodes[0].action = INodeAction(ref(1));
        _params.nodes[0].children = new uint32[](2);
        (_params.nodes[0].children[0], _params.nodes[0].children[1]) = (1, 2);
        _params.nodes[0].splitter = ISplitter(ref(4));
        _params.nodes[1] = _leaf(2);
        _params.nodes[2] = _leaf(3);

        _params.grants = _swapGrants(_manager, _guardian, 1);
        _params.grants[6] = _grant(ref(4), _manager, SET_SETTINGS_PERMISSION_ID);
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
            _component(MERKLE_CLAIM, abi.encodeCall(MerkleClaimBudget.initialize, (IDAO(DAO_REF), _token, _root)));
        _params.components[1] = _component(
            TRANSFER_TO_BENEFICIARY, abi.encodeCall(TransferToBeneficiaryAction.initialize, (IDAO(DAO_REF)))
        );

        _params.budget = IBudget(ref(0));
        _params.nodes = new Node[](1);
        _params.nodes[0] = _leaf(1);

        _params.grants = new CapitalTreePluginSetup.Grant[](4);
        _params.grants[0] = _grant(PLUGIN_REF, ANY_ADDR, TRIGGER_PERMISSION_ID);
        _params.grants[1] = _grant(PLUGIN_REF, _guardian, PAUSE_PERMISSION_ID);
        _params.grants[2] = _grant(ref(0), _manager, SET_SETTINGS_PERMISSION_ID);
        _params.grants[3] = _grant(ref(0), DAO_REF, RECORD_CLAIM_PERMISSION_ID);
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
        _params.components[0] = _streamBudget(_stream);
        _params.components[1 + _count] = _weightSplitter(_weights);

        _params.budget = IBudget(ref(0));
        _params.nodes = new Node[](1 + _count);
        _params.nodes[0].children = new uint32[](_count); // no action: the root only splits
        _params.nodes[0].splitter = ISplitter(ref(1 + _count));
        for (uint256 i; i < _count; ++i) {
            _params.components[1 + i] = _transfer(_recipients[i]);
            _params.nodes[0].children[i] = uint32(1 + i);
            _params.nodes[1 + i] = _leaf(1 + i);
        }

        _params.grants = new CapitalTreePluginSetup.Grant[](5);
        _params.grants[0] = _grant(PLUGIN_REF, ANY_ADDR, TRIGGER_PERMISSION_ID);
        _params.grants[1] = _grant(PLUGIN_REF, _guardian, PAUSE_PERMISSION_ID);
        _params.grants[2] = _grant(ref(0), _manager, SET_SETTINGS_PERMISSION_ID);
        _params.grants[3] = _grant(ref(0), DAO_REF, CHECKPOINT_PERMISSION_ID);
        _params.grants[4] = _grant(ref(1 + _count), _manager, SET_SETTINGS_PERMISSION_ID);
    }

    // Components

    function _streamBudget(Stream memory _stream) private pure returns (CapitalTreePluginSetup.Component memory) {
        return _component(
            STREAM_BUDGET,
            abi.encodeCall(
                StreamBudget.initialize,
                (IDAO(DAO_REF), _stream.token, _stream.amountPerEpoch, _stream.maxBudget, _stream.epochInterval)
            )
        );
    }

    /// @dev OpenFill offers its whole input, so the stream's cap is the auction's only limit
    function _cappedStreamBudget(Stream memory _stream) private pure returns (CapitalTreePluginSetup.Component memory) {
        if (_stream.maxBudget == 0) revert UncappedStream();
        return _streamBudget(_stream);
    }

    /// @dev Bound to component 0, the budget
    function _openFill(Swap memory _swap) private pure returns (CapitalTreePluginSetup.Component memory) {
        return _component(
            OPEN_FILL,
            abi.encodeCall(
                OpenFillAction.initialize,
                (IDAO(DAO_REF), ICheckpointedBudget(ref(0)), _swap.demandedToken, _swap.demandPerFill)
            )
        );
    }

    function _burn() private pure returns (CapitalTreePluginSetup.Component memory) {
        return _component(BURN, abi.encodeCall(BurnAction.initialize, (IDAO(DAO_REF))));
    }

    function _transfer(address _to) private pure returns (CapitalTreePluginSetup.Component memory) {
        return _component(TRANSFER, abi.encodeCall(TransferAction.initialize, (IDAO(DAO_REF), _to)));
    }

    function _weightSplitter(uint32[] memory _weights) private pure returns (CapitalTreePluginSetup.Component memory) {
        return _component(WEIGHT_SPLITTER, abi.encodeCall(WeightSplitter.initialize, (IDAO(DAO_REF), _weights)));
    }

    function _component(bytes32 _id, bytes memory _initData)
        private
        pure
        returns (CapitalTreePluginSetup.Component memory)
    {
        return CapitalTreePluginSetup.Component(_id, _initData);
    }

    // Tree

    function _leaf(uint256 _index) private pure returns (Node memory _node) {
        _node.action = INodeAction(ref(_index));
    }

    function _then(uint256 _index, uint32 _child) private pure returns (Node memory _node) {
        _node.action = INodeAction(ref(_index));
        _node.children = new uint32[](1);
        _node.children[0] = _child;
    }

    /// @dev For flows of a stream budget (component 0) and an OpenFill (component 1) at the root.
    ///      Leaves `_extra` empty slots at the end for the recipe's own grants.
    function _swapGrants(address _manager, address _guardian, uint256 _extra)
        private
        pure
        returns (CapitalTreePluginSetup.Grant[] memory _grants)
    {
        _grants = new CapitalTreePluginSetup.Grant[](6 + _extra);
        _grants[0] = _grant(PLUGIN_REF, ANY_ADDR, TRIGGER_PERMISSION_ID);
        _grants[1] = _grant(PLUGIN_REF, _guardian, PAUSE_PERMISSION_ID);
        _grants[2] = _grant(ref(0), _manager, SET_SETTINGS_PERMISSION_ID);
        _grants[3] = _grant(ref(1), _manager, SET_SETTINGS_PERMISSION_ID);
        _grants[4] = _grant(ref(0), DAO_REF, CHECKPOINT_PERMISSION_ID);
        _grants[5] = _grant(ref(0), ref(1), CHECKPOINT_PERMISSION_ID);
    }

    function _grant(address _where, address _who, bytes32 _id)
        private
        pure
        returns (CapitalTreePluginSetup.Grant memory)
    {
        return CapitalTreePluginSetup.Grant(_where, _who, _id);
    }
}
