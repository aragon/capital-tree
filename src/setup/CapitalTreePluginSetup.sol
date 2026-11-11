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

    struct InstallParams {
        Component budget;
        RecipeNode[] nodes;
        Grant[] pluginPermissions;
    }

    bytes32 internal constant EXECUTE_PERMISSION_ID = keccak256("EXECUTE_PERMISSION");
    ComponentRegistry public immutable registry;

    /// @notice Hash of the complete, concrete Grant list returned during preparation
    mapping(address plugin => bytes32) public permissionsHash;

    /// @notice Preparation count, keyed by keccak256(abi.encode(dao, keccak256(data)))
    mapping(bytes32 daoRecipe => uint256) public preparations;

    error MissingBudget();
    error InvalidAbsentComponent();
    error ReservedPermission(bytes32 permissionId);
    error PermissionsMismatch();
    error WrongDao();

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
        bytes32 _key = keccak256(abi.encode(_dao, keccak256(_data)));
        bytes32 _salt = keccak256(abi.encode(_key, preparations[_key]++));

        plugin = Clones.cloneDeterministic(implementation(), _salt);
        address[] memory _helpers = new address[](_helperCount(_recipe.nodes));
        _helpers[0] = _clone(_dao, _recipe.budget.id, _recipe.budget.settings, new address[](0), _salt, 0);
        Node[] memory _nodes = _deployNodes(_dao, _recipe.nodes, _salt, _helpers);
        CapitalTreePlugin(plugin).initialize(IDAO(_dao), IBudget(_helpers[0]), _nodes);

        preparedSetupData.helpers = _helpers;
        preparedSetupData.permissions = _permissions(_dao, plugin, _recipe, _helpers[0], _nodes);
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
    function pluginAddress(address _dao, bytes calldata _data, uint256 _index) external view returns (address) {
        bytes32 _key = keccak256(abi.encode(_dao, keccak256(_data)));
        return Clones.predictDeterministicAddress(implementation(), keccak256(abi.encode(_key, _index)));
    }

    // Deployment

    function _helperCount(RecipeNode[] memory _nodes) internal pure returns (uint256 _count) {
        _count = 1; // budget
        for (uint256 i; i < _nodes.length; ++i) {
            RecipeNode memory _node = _nodes[i];
            if (_node.action.id != bytes32(0)) {
                ++_count;
            } else if (
                _node.action.settings.length != 0 || _node.action.permissions.length != 0
                    || _node.action.budgetPermissions.length != 0
            ) {
                revert InvalidAbsentComponent();
            }
            if (_node.splitter.id != bytes32(0)) {
                ++_count;
            } else if (_node.splitter.settings.length != 0 || _node.splitter.permissions.length != 0) {
                revert InvalidAbsentComponent();
            }
        }
    }

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

    function _deployNodes(address _dao, RecipeNode[] memory _recipeNodes, bytes32 _salt, address[] memory _helpers)
        internal
        returns (Node[] memory _nodes)
    {
        _nodes = new Node[](_recipeNodes.length);
        address[] memory _budgetDependency = new address[](1);
        _budgetDependency[0] = _helpers[0];
        uint256 _nextHelper = 1;
        for (uint256 i; i < _recipeNodes.length; ++i) {
            RecipeNode memory _recipeNode = _recipeNodes[i];
            address _action;
            address _splitter;
            if (_recipeNode.action.id != bytes32(0)) {
                _action = _clone(
                    _dao, _recipeNode.action.id, _recipeNode.action.settings, _budgetDependency, _salt, _nextHelper
                );
                _helpers[_nextHelper++] = _action;
            }
            if (_recipeNode.splitter.id != bytes32(0)) {
                _splitter = _clone(
                    _dao, _recipeNode.splitter.id, _recipeNode.splitter.settings, new address[](0), _salt, _nextHelper
                );
                _helpers[_nextHelper++] = _splitter;
            }
            _nodes[i] = Node(
                INodeAction(_action),
                _recipeNode.children,
                ISplitter(_splitter),
                _recipeNode.skipWhenEmpty,
                _recipeNode.forwardSurplus
            );
        }
    }

    // Permissions

    function _permissions(
        address _dao,
        address _plugin,
        InstallParams memory _recipe,
        address _budget,
        Node[] memory _nodes
    ) internal pure returns (PermissionLib.MultiTargetPermission[] memory _perms) {
        uint256 _count = 2 + _recipe.pluginPermissions.length + _recipe.budget.permissions.length;
        for (uint256 i; i < _recipe.nodes.length; ++i) {
            RecipeNode memory _node = _recipe.nodes[i];
            _count += _node.action.permissions.length + _node.action.budgetPermissions.length
            + _node.splitter.permissions.length;
        }
        _perms = new PermissionLib.MultiTargetPermission[](_count);
        _perms[0] = _grant(_dao, _plugin, EXECUTE_PERMISSION_ID);
        _perms[1] = _grant(_plugin, _dao, CONFIGURE_PERMISSION_ID);
        uint256 _next = _appendGrants(_perms, 2, _plugin, _recipe.pluginPermissions);
        _next = _appendGrants(_perms, _next, _budget, _recipe.budget.permissions);
        for (uint256 i; i < _recipe.nodes.length; ++i) {
            RecipeNode memory _node = _recipe.nodes[i];
            address _action = address(_nodes[i].action);
            _next = _appendGrants(_perms, _next, _action, _node.action.permissions);
            _next = _appendGrants(_perms, _next, address(_nodes[i].splitter), _node.splitter.permissions);
            for (uint256 j; j < _node.action.budgetPermissions.length; ++j) {
                bytes32 _id = _node.action.budgetPermissions[j];
                if (_id == CONFIGURE_PERMISSION_ID) revert ReservedPermission(_id);
                _perms[_next++] = _grant(_budget, _action, _id);
            }
        }
    }

    function _appendGrants(
        PermissionLib.MultiTargetPermission[] memory _perms,
        uint256 _next,
        address _where,
        Grant[] memory _grants
    ) internal pure returns (uint256) {
        for (uint256 i; i < _grants.length; ++i) {
            Grant memory _g = _grants[i];
            if (_g.permissionId == CONFIGURE_PERMISSION_ID) revert ReservedPermission(_g.permissionId);
            _perms[_next++] = _grant(_where, _g.who, _g.permissionId);
        }
        return _next;
    }

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
