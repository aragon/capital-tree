// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IDAO} from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";
import {PermissionLib} from "@aragon/osx-commons-contracts/src/permission/PermissionLib.sol";
import {IPluginSetup} from "@aragon/osx-commons-contracts/src/plugin/setup/IPluginSetup.sol";
import {PluginSetup} from "@aragon/osx-commons-contracts/src/plugin/setup/PluginSetup.sol";
import {CapitalTreePlugin} from "../CapitalTreePlugin.sol";
import {ComponentRegistry} from "../registry/ComponentRegistry.sol";
import {IBudget} from "../interfaces/IBudget.sol";
import {IComponent} from "../interfaces/IComponent.sol";
import {INodeAction} from "../interfaces/INodeAction.sol";
import {ISplitter} from "../interfaces/ISplitter.sol";
import {Node} from "../lib/types.sol";
import {CONFIGURE_PERMISSION_ID} from "../lib/constants.sol";

/// @title CapitalTreePluginSetup
/// @notice Installs a budget and a tree. Each node declares its own action and splitter; each
///         declaration creates a fresh registered clone, even when two declarations are identical.
/// @dev Grants belong to the contract they target. Recipients are actual addresses. An action's
///      budgetPermissions grant that action permissions on the flow's budget.
///      CREATE2 salts bind addresses to the DAO, the complete recipe and its preparation count.
contract CapitalTreePluginSetup is PluginSetup {
    /// @notice A permission on the contract containing this grant
    struct Grant {
        address who;
        bytes32 permissionId;
    }

    /// @notice A budget or splitter to deploy from the registry
    struct Component {
        bytes32 id;
        bytes settings;
        Grant[] permissions;
    }

    /// @notice An action to deploy for one node
    /// @param budgetPermissions Permissions this action receives on the flow's budget
    struct Action {
        bytes32 id;
        bytes settings;
        Grant[] permissions;
        bytes32[] budgetPermissions;
    }

    /// @notice A node with its own action and splitter. ID zero means absent; all other fields of
    ///         an absent declaration must be empty. Children are node indexes, as in runtime Node.
    struct RecipeNode {
        Action action;
        uint32[] children;
        Component splitter;
        bool skipWhenEmpty;
        bool forwardSurplus;
    }

    /// @notice A complete installation: one budget, its execution tree, and grants on the plugin
    struct InstallParams {
        Component budget;
        RecipeNode[] nodes;
        Grant[] pluginPermissions;
    }

    /// @dev The permission the deployed plugin needs to execute actions through its DAO
    bytes32 internal constant EXECUTE_PERMISSION_ID = keccak256("EXECUTE_PERMISSION");

    /// @notice Registry supplying the implementations cloned by this setup
    ComponentRegistry public immutable registry;

    /// @notice Hash of the complete, concrete Grant list returned during preparation
    mapping(address plugin => bytes32) public permissionsHash;

    /// @notice Preparation count, keyed by keccak256(abi.encode(dao, keccak256(data)))
    mapping(bytes32 daoRecipe => uint256) public preparations;

    /// @notice The required budget declaration has ID zero
    error MissingBudget();

    /// @notice An absent action or splitter contains settings or permissions that would be ignored
    error InvalidAbsentComponent();

    /// @notice A recipe attempts to grant CONFIGURE, which setup reserves for the DAO on the plugin
    error ReservedPermission(bytes32 permissionId);

    /// @notice Uninstall data differs from the complete original permission list
    error PermissionsMismatch();

    /// @notice Uninstallation names a DAO other than the one bound to this plugin
    error WrongDao();

    /// @param _registry Registry of implementations available to recipes
    constructor(ComponentRegistry _registry) PluginSetup(address(new CapitalTreePlugin())) {
        registry = _registry;
    }

    /// @inheritdoc IPluginSetup
    /// @dev Helpers contain the budget, then each node's action and splitter, skipping absent ones.
    ///      Actions receive [budget] as their initializer dependencies; budgets and splitters receive [].
    function prepareInstallation(address _dao, bytes calldata _data)
        external
        returns (address plugin, PreparedSetupData memory preparedSetupData)
    {
        InstallParams memory _recipe = abi.decode(_data, (InstallParams));
        if (_recipe.budget.id == bytes32(0)) revert MissingBudget();

        // Different DAOs or recipes get different addresses. The counter also allows the same
        // DAO to prepare the same recipe again without colliding with its previous clones.
        bytes32 _key = _recipeKey(_dao, _data);
        bytes32 _salt = keccak256(abi.encode(_key, preparations[_key]++));

        plugin = Clones.cloneDeterministic(implementation(), _salt);
        address _budget = _clone(_dao, _recipe.budget.id, _recipe.budget.settings, new address[](0), _salt, 0);

        address[] memory _deployedContracts = new address[](_countContracts(_recipe.nodes));
        _deployedContracts[0] = _budget;

        Node[] memory _nodes = _deployNodes(_dao, _recipe.nodes, _salt, _deployedContracts);
        CapitalTreePlugin(plugin).initialize(IDAO(_dao), IBudget(_budget), _nodes);

        preparedSetupData.helpers = _deployedContracts;
        preparedSetupData.permissions = _permissions(_dao, plugin, _recipe, _budget, _nodes);
        permissionsHash[plugin] = keccak256(abi.encode(preparedSetupData.permissions));
    }

    /// @inheritdoc IPluginSetup
    /// @dev Payload data is the original MultiTargetPermission[] returned at preparation and emitted
    ///      by the processor. Verify that exact list before changing its operations to Revoke.
    function prepareUninstallation(address _dao, SetupPayload calldata _payload)
        external
        view
        returns (PermissionLib.MultiTargetPermission[] memory _permissionsToRevoke)
    {
        _permissionsToRevoke = abi.decode(_payload.data, (PermissionLib.MultiTargetPermission[]));

        if (keccak256(abi.encode(_permissionsToRevoke)) != permissionsHash[_payload.plugin]) {
            revert PermissionsMismatch();
        }

        if (address(CapitalTreePlugin(_payload.plugin).dao()) != _dao) revert WrongDao();

        for (uint256 i; i < _permissionsToRevoke.length; ++i) {
            _permissionsToRevoke[i].operation = PermissionLib.Operation.Revoke;
        }
    }

    /// @notice Predicts the plugin of the DAO's index-th preparation of the complete encoded recipe
    /// @param _dao Installing DAO
    /// @param _data The exact abi.encode(InstallParams) bytes passed to preparation
    /// @param _index Zero-based preparation count for this DAO and recipe
    /// @return The plugin address that preparation will deploy
    function pluginAddress(address _dao, bytes calldata _data, uint256 _index) external view returns (address) {
        bytes32 _key = _recipeKey(_dao, _data);
        return Clones.predictDeterministicAddress(implementation(), keccak256(abi.encode(_key, _index)));
    }

    /// @dev Identifies a DAO and its exact recipe bytes. Used by both preparation and prediction
    ///      so their salt calculations agree; a different recipe cannot take this recipe's address.
    /// @param _dao Installing DAO
    /// @param _data Encoded installation recipe
    /// @return Key of this DAO/recipe pair in preparations
    function _recipeKey(address _dao, bytes calldata _data) internal pure returns (bytes32) {
        return keccak256(abi.encode(_dao, keccak256(_data)));
    }

    // Deployment

    /// @dev Counts contracts to allocate Aragon's helpers array: one budget, plus every present
    ///      action and splitter. This only counts; deployment checks absent declarations separately.
    /// @param _nodes Recipe nodes, whose nonzero action/splitter IDs each contribute one contract
    /// @return _count Number of deployed component addresses, excluding the plugin
    function _countContracts(RecipeNode[] memory _nodes) internal pure returns (uint256 _count) {
        _count = 1; // budget
        for (uint256 i; i < _nodes.length; ++i) {
            if (_nodes[i].action.id != bytes32(0)) ++_count;
            if (_nodes[i].splitter.id != bytes32(0)) ++_count;
        }
    }

    /// @dev Deploys each node's contracts and copies its tree fields into the runtime node.
    ///      The plugin validates the resulting tree when initialized.
    /// @param _dao Installing DAO
    /// @param _recipeNodes Nodes declaring their own action and splitter
    /// @param _salt This preparation's salt
    /// @param _deployedContracts Preallocated output array with the budget already at index 0.
    ///        Filled in node order, action before splitter, skipping absent contracts.
    /// @return _nodes Runtime nodes containing deployed contract addresses
    function _deployNodes(
        address _dao,
        RecipeNode[] memory _recipeNodes,
        bytes32 _salt,
        address[] memory _deployedContracts
    ) internal returns (Node[] memory _nodes) {
        address _budget = _deployedContracts[0];
        uint256 _nextContract = 1;
        uint256 len = _recipeNodes.length;

        _nodes = new Node[](len);
        for (uint256 i; i < len; ++i) {
            RecipeNode memory _recipeNode = _recipeNodes[i];

            // @agent do all of these need to be run if the node doesn't have an action nor splitter
            _nodes[i].action = _deployAction(_dao, _recipeNode.action, _budget, _salt, _nextContract);
            if (address(_nodes[i].action) != address(0)) {
                _deployedContracts[_nextContract++] = address(_nodes[i].action);
            }

            _nodes[i].splitter = _deploySplitter(_dao, _recipeNode.splitter, _salt, _nextContract);
            if (address(_nodes[i].splitter) != address(0)) {
                _deployedContracts[_nextContract++] = address(_nodes[i].splitter);
            }

            _nodes[i].children = _recipeNode.children;
            _nodes[i].skipWhenEmpty = _recipeNode.skipWhenEmpty;
            _nodes[i].forwardSurplus = _recipeNode.forwardSurplus;
        }
    }

    /// @dev Checks the declaration, then deploys and initializes a present action with [budget].
    /// @param _dao Installing DAO
    /// @param _action Action declaration belonging to one node
    /// @param _budget The already initialized flow budget
    /// @param _salt This preparation's salt
    /// @param _index Position this contract will occupy in the deployed-contract array
    /// @return The action clone, or address zero for a valid absent declaration
    // @agent I think we already extract the budget so why not pass to avoid inline dependencies declaration
    function _deployAction(address _dao, Action memory _action, address _budget, bytes32 _salt, uint256 _index)
        internal
        returns (INodeAction)
    {
        _checkActionDeclaration(_action);
        if (_action.id == bytes32(0)) return INodeAction(address(0));

        address[] memory _dependencies = new address[](1);
        _dependencies[0] = _budget;
        return INodeAction(_clone(_dao, _action.id, _action.settings, _dependencies, _salt, _index));
    }

    /// @dev Checks the declaration, then deploys and initializes a present splitter with no dependencies.
    /// @param _dao Installing DAO
    /// @param _splitter Splitter declaration belonging to one node
    /// @param _salt This preparation's salt
    /// @param _index Position this contract will occupy in the deployed-contract array
    /// @return The splitter clone, or address zero for a valid absent declaration
    function _deploySplitter(address _dao, Component memory _splitter, bytes32 _salt, uint256 _index)
        internal
        returns (ISplitter)
    {
        _checkSplitterDeclaration(_splitter);
        if (_splitter.id == bytes32(0)) return ISplitter(address(0));

        return ISplitter(_clone(_dao, _splitter.id, _splitter.settings, new address[](0), _salt, _index));
    }

    // Declaration checks

    /// @dev ID zero means absent, so settings and both permission arrays must also be empty.
    ///      Present actions are checked by registry lookup, initialization and plugin validation.
    /// @param _action Declaration to check before deploying a node's action
    function _checkActionDeclaration(Action memory _action) internal pure {
        if (
            _action.id == bytes32(0)
                && (_action.settings.length != 0
                    || _action.permissions.length != 0
                    || _action.budgetPermissions.length != 0)
        ) revert InvalidAbsentComponent();
    }

    /// @dev ID zero means absent, so settings and permissions must also be empty.
    ///      Present splitters are checked by registry lookup, initialization and plugin validation.
    /// @param _splitter Declaration to check before deploying a node's splitter
    function _checkSplitterDeclaration(Component memory _splitter) internal pure {
        if (_splitter.id == bytes32(0) && (_splitter.settings.length != 0 || _splitter.permissions.length != 0)) {
            revert InvalidAbsentComponent();
        }
    }

    /// @dev Creates a fresh registered clone and always invokes the common initializer. The
    ///      deployment index distinguishes identical declarations within the same preparation.
    /// @param _dao DAO passed to the initializer
    /// @param _id Registered implementation ID
    /// @param _settings Component-specific ABI-encoded settings
    /// @param _deps Initializer dependencies: [budget] for actions, [] for budgets and splitters
    /// @param _salt This preparation's salt
    /// @param _index Zero-based deployment position, with the budget at zero
    /// @return _component The initialized clone's address
    function _clone(
        address _dao,
        bytes32 _id,
        bytes memory _settings,
        address[] memory _deps,
        bytes32 _salt,
        uint256 _index
    ) internal returns (address _component) {
        _component = Clones.cloneDeterministic(registry.implementation(_id), keccak256(abi.encode(_salt, _index)));
        IComponent(_component).initialize(IDAO(_dao), _deps, _settings);
    }

    // Permissions

    /// @dev Allocates the complete permission list and fills it in order: standard permissions,
    ///      plugin grants, budget grants, then each node's action, splitter and budget permissions.
    /// @param _dao Installing DAO, receiving CONFIGURE on the plugin
    /// @param _plugin Deployed plugin, receiving EXECUTE on the DAO
    /// @param _recipe Attached grants and action-to-budget permission IDs
    /// @param _budget Deployed budget address
    /// @param _nodes Deployed nodes in the same order as the recipe
    /// @return _perms Concrete Grant operations for the processor to apply
    function _permissions(
        address _dao,
        address _plugin,
        InstallParams memory _recipe,
        address _budget,
        Node[] memory _nodes
    ) internal pure returns (PermissionLib.MultiTargetPermission[] memory _perms) {
        _perms = new PermissionLib.MultiTargetPermission[](_countPermissions(_recipe));

        _perms[0] = _grant(_dao, _plugin, EXECUTE_PERMISSION_ID);
        _perms[1] = _grant(_plugin, _dao, CONFIGURE_PERMISSION_ID);

        // @agent what's going on hhere? we call this twice?
        uint256 _next = _writeGrants(_perms, 2, _plugin, _recipe.pluginPermissions);
        _next = _writeGrants(_perms, _next, _budget, _recipe.budget.permissions);

        for (uint256 i; i < _recipe.nodes.length; ++i) {
            RecipeNode memory _node = _recipe.nodes[i];
            address _action = address(_nodes[i].action);
            address _splitter = address(_nodes[i].splitter);

            _next = _writeGrants(_perms, _next, _action, _node.action.permissions);
            _next = _writeGrants(_perms, _next, _splitter, _node.splitter.permissions);
            _next = _writeBudgetPermissions(_perms, _next, _budget, _action, _node.action.budgetPermissions);
        }
    }

    /// @dev Solidity memory arrays need their length before entries can be written. Count the two
    ///      standard grants and every declared grant once; this does not validate their contents.
    /// @param _recipe Installation recipe whose permission list will be allocated
    /// @return _count Exact length required by _permissions
    function _countPermissions(InstallParams memory _recipe) internal pure returns (uint256 _count) {
        // @agent comment on the magic #
        _count = 2 + _recipe.pluginPermissions.length + _recipe.budget.permissions.length;
        for (uint256 i; i < _recipe.nodes.length; ++i) {
            _count += _recipe.nodes[i].action.permissions.length;
            _count += _recipe.nodes[i].splitter.permissions.length;
            _count += _recipe.nodes[i].action.budgetPermissions.length;
        }
    }

    /// @dev Attaches the known target address to each recipe grant and writes it into the output.
    ///      CONFIGURE is reserved for the standard DAO-on-plugin grant, never a recipe grant.
    /// @param _perms Preallocated permission array, modified in memory
    /// @param _next First free position to write
    /// @param _where Deployed contract these grants belong to
    /// @param _grants Recipient/permission pairs attached to that contract's declaration
    /// @return First free position after the written grants
    function _writeGrants(
        PermissionLib.MultiTargetPermission[] memory _perms,
        uint256 _next,
        address _where,
        Grant[] memory _grants
    ) internal pure returns (uint256) {
        for (uint256 i; i < _grants.length; ++i) {
            Grant memory _g = _grants[i];
            // @agent do we need this?
            if (_g.permissionId == CONFIGURE_PERMISSION_ID) revert ReservedPermission(_g.permissionId);
            _perms[_next++] = _grant(_where, _g.who, _g.permissionId);
        }
        return _next;
    }

    /// @dev Writes the permissions a node's action receives on the flow budget, rejecting CONFIGURE.
    /// @param _perms Preallocated permission array, modified in memory
    /// @param _next First free position to write
    /// @param _budget Budget granting the permissions
    /// @param _action Deployed action receiving them
    /// @param _permissionIds Permission IDs declared in the action's budgetPermissions
    /// @return First free position after the written permissions
    function _writeBudgetPermissions(
        PermissionLib.MultiTargetPermission[] memory _perms,
        uint256 _next,
        address _budget,
        address _action,
        bytes32[] memory _permissionIds
    ) internal pure returns (uint256) {
        for (uint256 i; i < _permissionIds.length; ++i) {
            bytes32 _id = _permissionIds[i];
            if (_id == CONFIGURE_PERMISSION_ID) revert ReservedPermission(_id);
            _perms[_next++] = _grant(_budget, _action, _id);
        }
        return _next;
    }

    /// @dev Builds one unconditional Aragon Grant operation. Recipe-specific restrictions are
    ///      checked by the writers; this also constructs the standard EXECUTE and CONFIGURE grants.
    /// @param _where Contract on which the permission applies
    /// @param _who Account or contract receiving the permission
    /// @param _id Permission identifier
    /// @return Concrete permission with operation Grant and no condition
    function _grant(address _where, address _who, bytes32 _id)
        internal
        pure
        returns (PermissionLib.MultiTargetPermission memory)
    {
        return PermissionLib.MultiTargetPermission({
            operation: PermissionLib.Operation.Grant,
            where: _where,
            who: _who,
            condition: PermissionLib.NO_CONDITION,
            permissionId: _id
        });
    }
}
