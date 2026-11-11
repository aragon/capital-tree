// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CapitalTreePluginSetup as Setup, NONE} from "../src/setup/CapitalTreePluginSetup.sol";
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
/// @notice Registry ids and install recipes for the common flows. A recipe is
///         `abi.encode(CapitalTreePluginSetup.InstallParams)`, and names its own components by
///         their index in it. Every recipe gives `_guardian` PAUSE on the plugin and `_manager`
///         SET_SETTINGS on each component with setters.
/// @dev Each recipe runs its checks, then lists its components in index order, its nodes and its
///      grants.
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

    /// @notice Stream → OpenFill → burn all the proceeds. The stream's `maxBudget` sets the worst
    ///         price: `demandPerFill / maxBudget`. Components: 0 budget, 1 OpenFill, 2 Burn.
    function buyAndBurn(address _manager, address _guardian, Stream memory _stream, Swap memory _swap)
        internal
        pure
        returns (Setup.InstallParams memory _params)
    {
        // CHECKS
        if (_stream.maxBudget == 0) revert UncappedStream();

        // COMPONENTS
        uint256[] memory _openFillDeps = new uint256[](1);
        _openFillDeps[0] = 0; // the budget
        _params.components = new Setup.Component[](3);
        _params.components[0] = Setup.Component(
            STREAM_BUDGET,
            _noDeps(),
            abi.encode(_stream.token, _stream.amountPerEpoch, _stream.maxBudget, _stream.epochInterval)
        );
        _params.components[1] =
            Setup.Component(OPEN_FILL, _openFillDeps, abi.encode(_swap.demandedToken, _swap.demandPerFill));
        _params.components[2] = Setup.Component(BURN, _noDeps(), "");

        // NODES
        _params.nodes = new Setup.RecipeNode[](2);
        // Node 0: OpenFill (component 1) → node 1
        uint32[] memory _openFillChildren = new uint32[](1);
        _openFillChildren[0] = 1;
        _params.nodes[0] = Setup.RecipeNode(1, _openFillChildren, NONE, false, false);
        // Node 1: Burn (component 2), a leaf
        _params.nodes[1] = Setup.RecipeNode(2, _noChildren(), NONE, false, false);

        // GRANTS
        _params.grants = new Setup.Grant[](6);
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
    ) internal pure returns (Setup.InstallParams memory _params) {
        // CHECKS
        if (_stream.maxBudget == 0) revert UncappedStream();

        // COMPONENTS
        uint256[] memory _openFillDeps = new uint256[](1);
        _openFillDeps[0] = 0; // the budget
        uint32[] memory _weights = new uint32[](2);
        (_weights[0], _weights[1]) = (uint32(RATIO_BASE) - _feeWeight, _feeWeight);
        _params.components = new Setup.Component[](5);
        _params.components[0] = Setup.Component(
            STREAM_BUDGET,
            _noDeps(),
            abi.encode(_stream.token, _stream.amountPerEpoch, _stream.maxBudget, _stream.epochInterval)
        );
        _params.components[1] =
            Setup.Component(OPEN_FILL, _openFillDeps, abi.encode(_swap.demandedToken, _swap.demandPerFill));
        _params.components[2] = Setup.Component(BURN, _noDeps(), "");
        _params.components[3] = Setup.Component(TRANSFER, _noDeps(), abi.encode(_fee));
        _params.components[4] = Setup.Component(WEIGHT_SPLITTER, _noDeps(), abi.encode(_weights));

        // NODES
        _params.nodes = new Setup.RecipeNode[](3);
        // Node 0: OpenFill (component 1) → nodes 1 and 2, split by the WeightSplitter (component 4)
        uint32[] memory _openFillChildren = new uint32[](2);
        (_openFillChildren[0], _openFillChildren[1]) = (1, 2);
        _params.nodes[0] = Setup.RecipeNode(1, _openFillChildren, 4, false, false);
        // Node 1: Burn (component 2), a leaf
        _params.nodes[1] = Setup.RecipeNode(2, _noChildren(), NONE, false, false);
        // Node 2: Transfer to the fee recipient (component 3), a leaf
        _params.nodes[2] = Setup.RecipeNode(3, _noChildren(), NONE, false, false);

        // GRANTS
        _params.grants = new Setup.Grant[](7);
        _params.grants[0] = _grant(_plugin(), _account(ANY_ADDR), TRIGGER_PERMISSION_ID);
        _params.grants[1] = _grant(_plugin(), _account(_guardian), PAUSE_PERMISSION_ID);
        _params.grants[2] = _grant(_component(0), _account(_manager), SET_SETTINGS_PERMISSION_ID);
        _params.grants[3] = _grant(_component(1), _account(_manager), SET_SETTINGS_PERMISSION_ID);
        _params.grants[4] = _grant(_component(0), _dao(), CHECKPOINT_PERMISSION_ID);
        _params.grants[5] = _grant(_component(0), _component(1), CHECKPOINT_PERMISSION_ID);
        _params.grants[6] = _grant(_component(4), _account(_manager), SET_SETTINGS_PERMISSION_ID);
    }

    /// @notice Stream → OpenFill → pay `_feeBps` of the proceeds to `_feeRecipient` and donate the
    ///         rest to `_vault`. The OpenFill forwards its surplus, so the fee and the donation
    ///         split everything the filler sent. The stream's `maxBudget` sets the worst price.
    ///         Components: 0 budget, 1 OpenFill, 2 VaultDonate, 3 Transfer, 4 WeightSplitter.
    function buybackAndDonate(
        address _manager,
        address _guardian,
        Stream memory _stream,
        Swap memory _swap,
        IDonationVault _vault,
        address _feeRecipient,
        uint256 _feeBps
    ) internal pure returns (Setup.InstallParams memory _params) {
        // CHECKS
        if (_feeBps == 0 || _feeBps >= 10_000) revert InvalidFeeBps();
        if (_feeRecipient == address(0)) revert InvalidFeeRecipient();
        if (_stream.maxBudget == 0) revert UncappedStream();

        // COMPONENTS
        uint256[] memory _openFillDeps = new uint256[](1);
        _openFillDeps[0] = 0; // the budget
        uint32 _feeWeight = uint32(_feeBps * RATIO_BASE / 10_000);
        uint32[] memory _weights = new uint32[](2);
        (_weights[0], _weights[1]) = (_feeWeight, uint32(RATIO_BASE) - _feeWeight);
        _params.components = new Setup.Component[](5);
        _params.components[0] = Setup.Component(
            STREAM_BUDGET,
            _noDeps(),
            abi.encode(_stream.token, _stream.amountPerEpoch, _stream.maxBudget, _stream.epochInterval)
        );
        _params.components[1] =
            Setup.Component(OPEN_FILL, _openFillDeps, abi.encode(_swap.demandedToken, _swap.demandPerFill));
        _params.components[2] = Setup.Component(VAULT_DONATE, _noDeps(), abi.encode(_vault));
        _params.components[3] = Setup.Component(TRANSFER, _noDeps(), abi.encode(_feeRecipient));
        _params.components[4] = Setup.Component(WEIGHT_SPLITTER, _noDeps(), abi.encode(_weights));

        // NODES
        _params.nodes = new Setup.RecipeNode[](3);
        // Node 0: OpenFill (component 1) → nodes 1 and 2, split by the WeightSplitter (component 4),
        // surplus included
        uint32[] memory _openFillChildren = new uint32[](2);
        (_openFillChildren[0], _openFillChildren[1]) = (1, 2);
        _params.nodes[0] = Setup.RecipeNode(1, _openFillChildren, 4, false, true);
        // Node 1: Transfer to the fee recipient (component 3), a leaf. A failed donation rolls it back.
        _params.nodes[1] = Setup.RecipeNode(3, _noChildren(), NONE, false, false);
        // Node 2: VaultDonate (component 2), a leaf
        _params.nodes[2] = Setup.RecipeNode(2, _noChildren(), NONE, false, false);

        // GRANTS
        _params.grants = new Setup.Grant[](7);
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
        returns (Setup.InstallParams memory _params)
    {
        // COMPONENTS
        _params.components = new Setup.Component[](2);
        _params.components[0] = Setup.Component(MERKLE_CLAIM, _noDeps(), abi.encode(_token, _root));
        _params.components[1] = Setup.Component(TRANSFER_TO_BENEFICIARY, _noDeps(), "");

        // NODES
        _params.nodes = new Setup.RecipeNode[](1);
        // Node 0: TransferToBeneficiary (component 1), a leaf
        _params.nodes[0] = Setup.RecipeNode(1, _noChildren(), NONE, false, false);

        // GRANTS
        _params.grants = new Setup.Grant[](4);
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
    ) internal pure returns (Setup.InstallParams memory _params) {
        // COMPONENTS
        uint256 _count = _recipients.length;
        _params.components = new Setup.Component[](2 + _count);
        _params.components[0] = Setup.Component(
            STREAM_BUDGET,
            _noDeps(),
            abi.encode(_stream.token, _stream.amountPerEpoch, _stream.maxBudget, _stream.epochInterval)
        );
        for (uint256 i; i < _count; ++i) {
            _params.components[1 + i] = Setup.Component(TRANSFER, _noDeps(), abi.encode(_recipients[i]));
        }
        _params.components[1 + _count] = Setup.Component(WEIGHT_SPLITTER, _noDeps(), abi.encode(_weights));

        // NODES
        _params.nodes = new Setup.RecipeNode[](1 + _count);
        // Node 0: a branch without an action → nodes 1 to _count, split by the WeightSplitter
        // (component 1 + _count)
        uint32[] memory _branchChildren = new uint32[](_count);
        for (uint256 i; i < _count; ++i) {
            _branchChildren[i] = uint32(1 + i);
        }
        _params.nodes[0] = Setup.RecipeNode(NONE, _branchChildren, 1 + _count, false, false);
        for (uint256 i; i < _count; ++i) {
            // Node 1 + i: Transfer to recipient i (component 1 + i), a leaf
            _params.nodes[1 + i] = Setup.RecipeNode(1 + i, _noChildren(), NONE, false, false);
        }

        // GRANTS
        _params.grants = new Setup.Grant[](5);
        _params.grants[0] = _grant(_plugin(), _account(ANY_ADDR), TRIGGER_PERMISSION_ID);
        _params.grants[1] = _grant(_plugin(), _account(_guardian), PAUSE_PERMISSION_ID);
        _params.grants[2] = _grant(_component(0), _account(_manager), SET_SETTINGS_PERMISSION_ID);
        _params.grants[3] = _grant(_component(0), _dao(), CHECKPOINT_PERMISSION_ID);
        _params.grants[4] = _grant(_component(1 + _count), _account(_manager), SET_SETTINGS_PERMISSION_ID);
    }

    // COMPONENTS

    /// @dev The dependencies of a component that has none
    function _noDeps() private pure returns (uint256[] memory) {
        return new uint256[](0);
    }

    // NODES

    /// @dev The children of a leaf
    function _noChildren() private pure returns (uint32[] memory) {
        return new uint32[](0);
    }

    // GRANTS

    /// @dev `_who` gets `_id` on `_where`, in the order of the DAO's `grant(where, who, id)`
    function _grant(Setup.Ref memory _where, Setup.Ref memory _who, bytes32 _id)
        private
        pure
        returns (Setup.Grant memory)
    {
        return Setup.Grant(_where, _who, _id);
    }

    function _component(uint256 _index) private pure returns (Setup.Ref memory) {
        return Setup.Ref(Setup.RefKind.Component, address(0), _index);
    }

    function _plugin() private pure returns (Setup.Ref memory) {
        return Setup.Ref(Setup.RefKind.Plugin, address(0), 0);
    }

    function _dao() private pure returns (Setup.Ref memory) {
        return Setup.Ref(Setup.RefKind.Dao, address(0), 0);
    }

    function _account(address _address) private pure returns (Setup.Ref memory) {
        return Setup.Ref(Setup.RefKind.Account, _address, 0);
    }
}
