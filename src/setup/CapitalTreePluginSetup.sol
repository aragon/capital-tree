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

// A recipe node without an action or without a splitter
uint256 constant NONE = type(uint256).max;

/// @title CapitalTreePluginSetup
/// @notice Installs any flow from a recipe: the components to clone (by registry id), the tree and
///         the permissions. A recipe names its own contracts by position: component 0 is the
///         budget, and each node's action and splitter, a component's dependencies and the grants
///         refer to components by their index in the recipe.
/// @dev Every component is a fresh clone of a registered implementation, initialized through
///      `IComponent` with the installing DAO, the components it depends on and its own settings.
///      Components are initialized in recipe order and may only depend on earlier ones. The tree
///      only ever names the recipe's own clones.
///      The setup always grants EXECUTE (the plugin on the DAO) and CONFIGURE (the DAO on the
///      plugin); recipe grants may only target the plugin or its components, and never CONFIGURE.
///
///      Clone addresses are CREATE2 addresses salted with the DAO, the recipe and how many times
///      that DAO has prepared that recipe. The plugin address a proposal applies therefore pins
///      the recipe: a different recipe, prepared first to front-run the proposal, lands at a
///      different address instead of taking the one the proposal names. `pluginAddress` lets
///      voters check the address against the published recipe.
contract CapitalTreePluginSetup is PluginSetup {
    /// @notice A component to clone
    /// @param id Its registry id, e.g. "StreamBudget@1"
    /// @param deps Indexes of the earlier components it depends on, passed to it as addresses in this order
    /// @param settings Passed to its `initialize` as is, in the shape the component documents
    struct Component {
        bytes32 id;
        uint256[] deps;
        bytes settings;
    }

    /// @notice A node of the tree (see `Node`), naming its action and splitter by component index
    /// @param action The Action component, or `NONE` on a branch that only splits
    /// @param splitter The Splitter component when the node has 2+ children, `NONE` otherwise
    struct RecipeNode {
        uint256 action;
        uint32[] children;
        uint256 splitter;
        bool skipWhenEmpty;
        bool forwardSurplus;
    }

    /// @notice What a grant names: an address outside the installation, or one of its contracts
    enum RefKind {
        Account,
        Dao,
        Plugin,
        Component
    }

    /// @param account The address, for `Account` (a manager, a guardian, ANY_ADDR)
    /// @param index The recipe index, for `Component`
    struct Ref {
        RefKind kind;
        address account;
        uint256 index;
    }

    /// @param where The plugin or one of the recipe's components
    struct Grant {
        Ref where;
        Ref who;
        bytes32 permissionId;
    }

    /// @param components The first one is the flow's budget
    struct InstallParams {
        Component[] components;
        RecipeNode[] nodes;
        Grant[] grants;
    }

    /// @dev The installation's addresses, which references resolve to
    struct Context {
        address dao;
        address plugin;
        address[] components;
    }

    /// @dev EXECUTE_PERMISSION_ID on the OSx DAO
    bytes32 internal constant EXECUTE_PERMISSION_ID = keccak256("EXECUTE_PERMISSION");

    /// @notice Where component implementations come from
    ComponentRegistry public immutable registry;

    /// @notice Hash of each installed plugin's recipe grants, so uninstalling revokes exactly them
    mapping(address plugin => bytes32) public grantsHash;

    /// @notice How many times each DAO has prepared each recipe, by `keccak256(abi.encode(dao, keccak256(data)))`.
    ///         Keeps every preparation's addresses unique, so the same recipe can be prepared again.
    mapping(bytes32 daoRecipe => uint256) public preparations;

    /// @notice Thrown when a recipe refers to a component index it doesn't have
    error UnknownReference(uint256 index);

    /// @notice Thrown when a component depends on itself or on a later component
    error DependencyNotEarlier(uint256 component, uint256 dependency);

    error GrantOutsideInstallation(RefKind where);
    error ReservedPermission(bytes32 permissionId);
    error GrantsMismatch();

    constructor(ComponentRegistry _registry) PluginSetup(address(new CapitalTreePlugin())) {
        registry = _registry;
    }

    /// @inheritdoc IPluginSetup
    /// @dev `_data` is `abi.encode(InstallParams)`. Helpers are the components, in recipe order.
    function prepareInstallation(address _dao, bytes calldata _data)
        external
        returns (address plugin, PreparedSetupData memory preparedSetupData)
    {
        InstallParams memory _params = abi.decode(_data, (InstallParams));
        bytes32 _daoRecipe = _daoRecipeKey(_dao, _data);
        bytes32 _salt = _pluginSalt(_daoRecipe, preparations[_daoRecipe]++);

        plugin = Clones.cloneDeterministic(implementation(), _salt);
        address[] memory _components = _clone(_params.components, _salt);
        for (uint256 i; i < _components.length; ++i) {
            Component memory _component = _params.components[i];
            IComponent(_components[i])
                .initialize(IDAO(_dao), _dependencies(i, _component.deps, _components), _component.settings);
        }
        CapitalTreePlugin(plugin)
            .initialize(IDAO(_dao), IBudget(_slot(0, _components)), _resolveNodes(_params.nodes, _components));

        grantsHash[plugin] = keccak256(abi.encode(_params.grants));
        preparedSetupData.helpers = _components;
        preparedSetupData.permissions =
            _permissions(PermissionLib.Operation.Grant, _params.grants, Context(_dao, plugin, _components));
    }

    /// @inheritdoc IPluginSetup
    /// @dev `_payload.data` is `abi.encode(Grant[])`: the recipe grants used at installation
    function prepareUninstallation(address _dao, SetupPayload calldata _payload)
        external
        view
        returns (PermissionLib.MultiTargetPermission[] memory)
    {
        Grant[] memory _grants = abi.decode(_payload.data, (Grant[]));
        if (keccak256(abi.encode(_grants)) != grantsHash[_payload.plugin]) revert GrantsMismatch();

        Context memory _ctx = Context(_dao, _payload.plugin, _payload.currentHelpers);
        return _permissions(PermissionLib.Operation.Revoke, _grants, _ctx);
    }

    /// @notice The plugin address of `_dao`'s `_index`-th preparation of `_data`, counting from 0
    /// @param _data The recipe as passed to `prepareInstallation`: `abi.encode(InstallParams)`
    function pluginAddress(address _dao, bytes calldata _data, uint256 _index) external view returns (address) {
        return Clones.predictDeterministicAddress(implementation(), _pluginSalt(_daoRecipeKey(_dao, _data), _index));
    }

    // Internal

    /// @dev Component `i` is salted with the plugin's salt and its index
    function _clone(Component[] memory _components, bytes32 _salt) internal returns (address[] memory _clones) {
        _clones = new address[](_components.length);
        for (uint256 i; i < _components.length; ++i) {
            _clones[i] =
                Clones.cloneDeterministic(registry.implementation(_components[i].id), keccak256(abi.encode(_salt, i)));
        }
    }

    /// @dev The addresses of component `_index`'s dependencies: earlier components, already initialized
    function _dependencies(uint256 _index, uint256[] memory _deps, address[] memory _components)
        internal
        pure
        returns (address[] memory _addresses)
    {
        _addresses = new address[](_deps.length);
        for (uint256 k; k < _deps.length; ++k) {
            if (_deps[k] >= _index) revert DependencyNotEarlier(_index, _deps[k]);
            _addresses[k] = _components[_deps[k]];
        }
    }

    function _resolveNodes(RecipeNode[] memory _nodes, address[] memory _components)
        internal
        pure
        returns (Node[] memory _resolved)
    {
        _resolved = new Node[](_nodes.length);
        for (uint256 i; i < _nodes.length; ++i) {
            RecipeNode memory _node = _nodes[i];
            _resolved[i] = Node(
                INodeAction(_optionalSlot(_node.action, _components)),
                _node.children,
                ISplitter(_optionalSlot(_node.splitter, _components)),
                _node.skipWhenEmpty,
                _node.forwardSurplus
            );
        }
    }

    /// @dev Component `_index`, which must exist
    function _slot(uint256 _index, address[] memory _components) internal pure returns (address) {
        if (_index >= _components.length) revert UnknownReference(_index);
        return _components[_index];
    }

    /// @dev Like `_slot`, but `NONE` gives address(0)
    function _optionalSlot(uint256 _index, address[] memory _components) internal pure returns (address) {
        return _index == NONE ? address(0) : _slot(_index, _components);
    }

    function _daoRecipeKey(address _dao, bytes calldata _data) internal pure returns (bytes32) {
        return keccak256(abi.encode(_dao, keccak256(_data)));
    }

    function _pluginSalt(bytes32 _daoRecipe, uint256 _index) internal pure returns (bytes32) {
        return keccak256(abi.encode(_daoRecipe, _index));
    }

    /// @dev EXECUTE and CONFIGURE, then the recipe grants
    function _permissions(PermissionLib.Operation _op, Grant[] memory _grants, Context memory _ctx)
        internal
        pure
        returns (PermissionLib.MultiTargetPermission[] memory _perms)
    {
        _perms = new PermissionLib.MultiTargetPermission[](2 + _grants.length);
        _perms[0] = _permission(_op, _ctx.dao, _ctx.plugin, EXECUTE_PERMISSION_ID);
        _perms[1] = _permission(_op, _ctx.plugin, _ctx.dao, CONFIGURE_PERMISSION_ID);

        for (uint256 i; i < _grants.length; ++i) {
            Grant memory _grant = _grants[i];
            if (_grant.permissionId == CONFIGURE_PERMISSION_ID) revert ReservedPermission(_grant.permissionId);
            RefKind _where = _grant.where.kind;
            if (_where != RefKind.Plugin && _where != RefKind.Component) revert GrantOutsideInstallation(_where);

            _perms[2 + i] =
                _permission(_op, _resolve(_grant.where, _ctx), _resolve(_grant.who, _ctx), _grant.permissionId);
        }
    }

    function _permission(PermissionLib.Operation _op, address _where, address _who, bytes32 _id)
        internal
        pure
        returns (PermissionLib.MultiTargetPermission memory)
    {
        return PermissionLib.MultiTargetPermission({
            operation: _op, where: _where, who: _who, condition: PermissionLib.NO_CONDITION, permissionId: _id
        });
    }

    /// @dev The address a reference names
    function _resolve(Ref memory _ref, Context memory _ctx) internal pure returns (address) {
        if (_ref.kind == RefKind.Account) return _ref.account;
        if (_ref.kind == RefKind.Dao) return _ctx.dao;
        if (_ref.kind == RefKind.Plugin) return _ctx.plugin;
        if (_ref.index >= _ctx.components.length) revert UnknownReference(_ref.index);
        return _ctx.components[_ref.index];
    }
}
