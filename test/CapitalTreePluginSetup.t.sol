// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    DaoAuthorizableUpgradeable
} from "@aragon/osx-commons-contracts/src/permission/auth/DaoAuthorizableUpgradeable.sol";
import {IPluginSetup} from "@aragon/osx-commons-contracts/src/plugin/setup/IPluginSetup.sol";
import {PermissionLib} from "@aragon/osx-commons-contracts/src/permission/PermissionLib.sol";
import {CapitalTreePluginSetup} from "../src/setup/CapitalTreePluginSetup.sol";
import {IComponent} from "../src/interfaces/IComponent.sol";
import {CapitalTreePlugin} from "../src/CapitalTreePlugin.sol";
import {IBudget} from "../src/interfaces/IBudget.sol";
import {Node} from "../src/lib/types.sol";
import {StreamBudget} from "../src/budgets/StreamBudget.sol";
import {ComponentRegistry} from "../src/registry/ComponentRegistry.sol";
import {WeightSplitter} from "../src/splitters/WeightSplitter.sol";
import {
    TRIGGER_PERMISSION_ID,
    CONFIGURE_PERMISSION_ID,
    PAUSE_PERMISSION_ID,
    SET_SETTINGS_PERMISSION_ID,
    CHECKPOINT_PERMISSION_ID
} from "../src/lib/constants.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {Recipes} from "../script/Recipes.sol";
import {Fixture, METADATA_URIS} from "./helpers/Fixture.sol";
import {MockFiller} from "./mocks/MockFiller.sol";
import {CapSplitter} from "./mocks/MockSplitter.sol";

contract CapitalTreePluginSetupTest is Fixture {
    bytes internal installationPermissions;
    ComponentRegistry internal registry;
    CapitalTreePluginSetup internal setup;

    function setUp() public override {
        super.setUp();
        (registry, setup) = new Deploy().deploy(dao, METADATA_URIS);
    }

    // =========================================================================================
    // Recipes
    // =========================================================================================

    function test_BuyAndBurnBurnsEverything() public {
        (CapitalTreePlugin _plugin,) = _install(Recipes.buyAndBurn(manager, guardian, _stream(), _swap()));
        MockFiller _filler = _newFiller(_plugin);
        uint256 _supply = tokenB.totalSupply();

        _filler.fill("");

        assertEq(tokenB.totalSupply(), _supply - DEMAND);
        assertEq(tokenB.balanceOf(address(dao)), DAO_B);
    }

    function test_BuybackBurnsAndPaysTheFee() public {
        (CapitalTreePlugin _plugin,) = _install(_buyback());
        MockFiller _filler = _newFiller(_plugin);
        uint256 _supply = tokenB.totalSupply();

        _filler.fill("");

        assertEq(tokenB.totalSupply(), _supply - 950 ether);
        assertEq(tokenB.balanceOf(fee), 50 ether);
        assertEq(tokenB.balanceOf(address(dao)), DAO_B);
    }

    /// The recipe marks the swap node forwardSurplus, so the 100 B the filler overpays are split too
    function test_InstallsAForwardingNode() public {
        CapitalTreePluginSetup.InstallParams memory _params = _buyback();
        _params.nodes[0].forwardSurplus = true;
        (CapitalTreePlugin _plugin,) = _install(_params);
        MockFiller _filler = _newFiller(_plugin);
        _filler.setFillDelta(100 ether);
        uint256 _supply = tokenB.totalSupply();

        _filler.fill("");

        assertTrue(_plugin.nodes()[0].forwardSurplus);
        assertEq(tokenB.totalSupply(), _supply - 1045 ether, "95% of 1,100 B burned");
        assertEq(tokenB.balanceOf(fee), 55 ether);
        assertEq(tokenB.balanceOf(address(dao)), DAO_B);
    }

    function test_MerkleClaimPaysTheAccount() public {
        bytes32 _aliceLeaf = _leafHash(alice, 10 ether);
        bytes32 _bobLeaf = _leafHash(bob, 30 ether);
        (CapitalTreePlugin _plugin,) =
            _install(Recipes.merkleClaim(manager, guardian, IERC20(tokenA), _hashPair(_aliceLeaf, _bobLeaf)));

        bytes32[] memory _proof = new bytes32[](1);
        _proof[0] = _bobLeaf;
        // The TransferToBeneficiary root pays the address in its node data
        bytes[] memory _data = new bytes[](1);
        _data[0] = abi.encode(alice);

        vm.prank(alice);
        _plugin.trigger(abi.encode(alice, 10 ether, _proof), _data);

        assertEq(tokenA.balanceOf(alice), 10 ether);
    }

    function test_PayrollPaysEachRecipient() public {
        (CapitalTreePlugin _plugin,) =
            _install(Recipes.payroll(manager, guardian, _stream(), _pair(alice, bob), _weights()));
        vm.warp(block.timestamp + EPOCH);

        _plugin.trigger("", noData);

        assertEq(tokenA.balanceOf(alice), 9.5 ether);
        assertEq(tokenA.balanceOf(bob), 0.5 ether);
    }

    /// The recipe lets the manager change the shares
    function test_TheManagerChangesThePayrollWeights() public {
        (CapitalTreePlugin _plugin, address[] memory _helpers) =
            _install(Recipes.payroll(manager, guardian, _stream(), _pair(alice, bob), _weights()));
        WeightSplitter _splitter = WeightSplitter(address(_plugin.nodes()[0].splitter));
        uint32[] memory _swapped = new uint32[](2);
        (_swapped[0], _swapped[1]) = (300_000, 700_000);

        vm.prank(manager);
        _splitter.setWeights(_swapped);
        vm.warp(block.timestamp + EPOCH);
        _plugin.trigger("", noData);

        assertEq(tokenA.balanceOf(alice), 3 ether);
        assertEq(tokenA.balanceOf(bob), 7 ether);
    }

    /// A payroll whose branch caps alice at 3 A with a custom splitter in place of the weight splitter
    function test_InstallsASplitter() public {
        dao.grant(address(registry), address(this), registry.REGISTER_PERMISSION_ID());
        registry.register(ComponentRegistry.Registration("CapSplitter@1", address(new CapSplitter()), ""));
        CapitalTreePluginSetup.InstallParams memory _params =
            Recipes.payroll(manager, guardian, _stream(), _pair(alice, bob), _weights());
        _params.nodes[0].splitter = CapitalTreePluginSetup.Component(
            "CapSplitter@1", abi.encode(3 ether), new CapitalTreePluginSetup.Grant[](0)
        );
        _params.nodes[2].skipWhenEmpty = true;

        (CapitalTreePlugin _plugin, address[] memory _helpers) = _install(_params);
        vm.warp(block.timestamp + EPOCH);
        _plugin.trigger("", noData);

        assertEq(address(_plugin.nodes()[0].splitter), _helpers[1]);
        assertTrue(_plugin.nodes()[2].skipWhenEmpty);
        assertEq(tokenA.balanceOf(alice), 3 ether);
        assertEq(tokenA.balanceOf(bob), RATE - 3 ether);
    }

    // =========================================================================================
    // Components and permissions
    // =========================================================================================

    function test_EveryComponentIsAFreshCloneOfTheDao() public {
        (, address[] memory _first) = _install(_buyback());
        (, address[] memory _second) = _install(_buyback());

        for (uint256 i; i < _first.length; ++i) {
            assertTrue(_first[i] != _second[i], "a new clone per install");
            assertEq(address(DaoAuthorizableUpgradeable(_first[i]).dao()), address(dao));
        }
        assertTrue(_first[1] != registry.implementation(Recipes.OPEN_FILL), "never the implementation");
    }

    function test_TheFirstComponentIsTheBudget() public {
        (CapitalTreePlugin _plugin, address[] memory _helpers) = _install(_buyback());

        assertEq(address(_plugin.budget()), _helpers[0]);
    }

    /// A proposal names the plugin by address, so the address must pin the recipe
    function test_PluginAddressComesFromTheDaoAndTheRecipe() public {
        bytes memory _data = abi.encode(_buyback());

        (CapitalTreePlugin _first,) = _install(_buyback());
        (CapitalTreePlugin _second,) = _install(_buyback());

        assertEq(address(_first), setup.pluginAddress(address(dao), _data, 0), "first preparation");
        assertEq(address(_second), setup.pluginAddress(address(dao), _data, 1), "second preparation");
        assertEq(setup.preparations(keccak256(abi.encode(address(dao), keccak256(_data)))), 2);
    }

    /// A recipe of the same shape with another fee recipient, prepared first, lands elsewhere
    function test_AnotherRecipeCantTakeTheRecipesAddress() public {
        address _expected = setup.pluginAddress(address(dao), abi.encode(_buyback()), 0);

        CapitalTreePluginSetup.InstallParams memory _other =
            Recipes.buyback(manager, guardian, _stream(), _swap(), alice, 50_000);
        (CapitalTreePlugin _attacker,) = _install(_other);
        (CapitalTreePlugin _plugin,) = _install(_buyback());

        assertTrue(address(_attacker) != _expected, "the other recipe lands elsewhere");
        assertEq(address(_plugin), _expected, "the recipe keeps its address");
    }

    function test_GrantsTheRecipePermissions() public {
        (CapitalTreePlugin _plugin, address[] memory _helpers) = _install(_buyback());

        _assertPermissions(address(_plugin), _helpers, true);
        assertFalse(
            dao.hasPermission(address(_plugin), manager, CONFIGURE_PERMISSION_ID, ""), "manager can't set the flow"
        );
        assertFalse(dao.hasPermission(address(_plugin), manager, PAUSE_PERMISSION_ID, ""), "manager can't pause");
    }

    function test_UninstallRevokesEverything() public {
        (CapitalTreePlugin _plugin, address[] memory _helpers) = _install(_buyback());
        PermissionLib.MultiTargetPermission[] memory _original =
            abi.decode(installationPermissions, (PermissionLib.MultiTargetPermission[]));
        assertEq(setup.permissionsHash(address(_plugin)), keccak256(installationPermissions));
        dao.applyMultiTargetPermissions(_prepareUninstall(_plugin, _helpers, _original));
        _assertPermissions(address(_plugin), _helpers, false);
        assertFalse(dao.hasPermission(address(_plugin.nodes()[0].splitter), manager, SET_SETTINGS_PERMISSION_ID, ""));
    }

    function test_UninstallUsesOriginalPermissionsAfterFlowChanges() public {
        (CapitalTreePlugin _plugin, address[] memory _helpers) = _install(_buyback());
        Node[] memory _nodes = _plugin.nodes();
        address _originalAction = address(_nodes[1].action);
        _nodes[1].action = _deployKeep(dao);
        IBudget _budget = _plugin.budget();
        vm.prank(address(dao));
        _plugin.setFlow(_budget, _nodes);
        assertTrue(address(_plugin.nodes()[1].action) != _originalAction);
        dao.applyMultiTargetPermissions(
            _prepareUninstall(
                _plugin, _helpers, abi.decode(installationPermissions, (PermissionLib.MultiTargetPermission[]))
            )
        );
        _assertPermissions(address(_plugin), _helpers, false);
    }

    function test_RevertWhen_UninstallPermissionsAreAltered() public {
        (CapitalTreePlugin _plugin, address[] memory _helpers) = _install(_buyback());
        for (uint256 i; i < 7; ++i) {
            PermissionLib.MultiTargetPermission[] memory _perms =
                abi.decode(installationPermissions, (PermissionLib.MultiTargetPermission[]));
            if (i == 0) _perms[0].where = alice;
            if (i == 1) _perms[0].who = alice;
            if (i == 2) _perms[0].permissionId = bytes32(0);
            if (i == 3) _perms[0].operation = PermissionLib.Operation.Revoke;
            if (i == 4) _perms[0].condition = alice;
            if (i == 5) (_perms[0], _perms[1]) = (_perms[1], _perms[0]);
            if (i == 6) _perms = new PermissionLib.MultiTargetPermission[](0);
            vm.expectRevert(CapitalTreePluginSetup.PermissionsMismatch.selector);
            _prepareUninstall(_plugin, _helpers, _perms);
        }
    }

    function test_RevertWhen_UninstallNamesAnotherDao() public {
        (CapitalTreePlugin _plugin, address[] memory _helpers) = _install(_buyback());
        vm.expectRevert(CapitalTreePluginSetup.WrongDao.selector);
        setup.prepareUninstallation(
            alice, IPluginSetup.SetupPayload(address(_plugin), _helpers, installationPermissions)
        );
    }

    function test_IdenticalDeclarationsCreateIsolatedActionsAndSplitters() public {
        CapitalTreePluginSetup.InstallParams memory _params =
            Recipes.payroll(manager, guardian, _stream(), _pair(alice, alice), _weights());
        CapitalTreePluginSetup.RecipeNode memory _leafNode = _params.nodes[1];
        CapitalTreePluginSetup.Component memory _splitter = _params.nodes[0].splitter;
        _params.nodes = new CapitalTreePluginSetup.RecipeNode[](7);
        for (uint256 i; i < 3; ++i) {
            _params.nodes[i].splitter = _splitter;
            _params.nodes[i].children = new uint32[](2);
            _params.nodes[i].children[0] = uint32(2 * i + 1);
            _params.nodes[i].children[1] = uint32(2 * i + 2);
        }
        for (uint256 i = 3; i < 7; ++i) {
            _params.nodes[i] = _leafNode;
        }
        (CapitalTreePlugin _plugin, address[] memory _helpers) = _install(_params);
        Node[] memory _nodes = _plugin.nodes();
        assertEq(_helpers.length, 8);
        assertTrue(address(_nodes[3].action) != address(_nodes[4].action));
        assertTrue(address(_nodes[1].splitter) != address(_nodes[2].splitter));
        uint32[] memory _changed = new uint32[](2);
        (_changed[0], _changed[1]) = (500_000, 500_000);
        vm.prank(manager);
        WeightSplitter(address(_nodes[1].splitter)).setWeights(_changed);
        assertEq(WeightSplitter(address(_nodes[2].splitter)).weights()[0], 950_000);
        assertEq(WeightSplitter(address(_nodes[1].splitter)).weights()[0], 500_000);
    }

    function test_AllClonesAreInitializedAndOpenFillUsesTheFlowBudget() public {
        (CapitalTreePlugin _plugin, address[] memory _helpers) = _install(_buyback());
        assertEq(address(_plugin.nodes()[0].action.budget()), _helpers[0]);
        for (uint256 i; i < _helpers.length; ++i) {
            vm.expectRevert("Initializable: contract is already initialized");
            IComponent(_helpers[i]).initialize(dao, new address[](0), "");
        }
    }

    /// Without any recipe grant on the budget or the action, each still gets what it needs to work
    function test_EachComponentBringsThePermissionsItNeeds() public {
        CapitalTreePluginSetup.InstallParams memory _params = _buyback();
        _params.budget.permissions = new CapitalTreePluginSetup.Grant[](0);
        _params.nodes[0].action.permissions = new CapitalTreePluginSetup.Grant[](0);
        (CapitalTreePlugin _plugin,) = _install(_params);
        address _budget = address(_plugin.budget());
        address _action = address(_plugin.nodes()[0].action);

        assertTrue(dao.hasPermission(_budget, address(dao), CHECKPOINT_PERMISSION_ID, ""), "dao checkpoint");
        assertTrue(dao.hasPermission(_budget, _action, CHECKPOINT_PERMISSION_ID, ""), "action checkpoint");
        assertFalse(dao.hasPermission(_action, manager, SET_SETTINGS_PERMISSION_ID, ""), "no manager");
    }

    function test_GrantTargetsAreAlwaysInstallationContracts() public {
        CapitalTreePluginSetup.InstallParams memory _params = _buyback();
        _params.nodes[1].action.permissions = new CapitalTreePluginSetup.Grant[](1);
        _params.nodes[1].action.permissions[0] = CapitalTreePluginSetup.Grant(alice, dao.EXECUTE_PERMISSION_ID());
        (CapitalTreePlugin _plugin,) = _install(_params);
        assertTrue(dao.hasPermission(address(_plugin.nodes()[1].action), alice, dao.EXECUTE_PERMISSION_ID(), ""));
        assertFalse(dao.hasPermission(address(dao), alice, dao.EXECUTE_PERMISSION_ID(), ""));
    }

    // Rejected recipes

    function test_RevertWhen_AComponentIsNotRegistered() public {
        CapitalTreePluginSetup.InstallParams memory _params = _buyback();
        _params.nodes[1].action.id = "Unknown@1";
        _expectInstallRevert(
            _params, abi.encodeWithSelector(ComponentRegistry.UnknownComponent.selector, bytes32("Unknown@1"))
        );
    }

    function test_RevertWhen_TheRecipeHasNoBudget() public {
        CapitalTreePluginSetup.InstallParams memory _params = _buyback();
        _params.budget.id = bytes32(0);
        _expectInstallRevert(_params, abi.encodeWithSelector(CapitalTreePluginSetup.MissingBudget.selector));
    }

    function test_RevertWhen_AnAbsentActionHasSettingsOrPermissions() public {
        for (uint256 i; i < 2; ++i) {
            CapitalTreePluginSetup.InstallParams memory _params =
                Recipes.payroll(manager, guardian, _stream(), _pair(alice, bob), _weights());
            if (i == 0) _params.nodes[0].action.settings = hex"01";
            if (i == 1) _params.nodes[0].action.permissions = new CapitalTreePluginSetup.Grant[](1);
            _expectInstallRevert(
                _params, abi.encodeWithSelector(CapitalTreePluginSetup.InvalidAbsentComponent.selector)
            );
        }
    }

    function test_RevertWhen_AnAbsentSplitterHasSettingsOrPermissions() public {
        for (uint256 i; i < 2; ++i) {
            CapitalTreePluginSetup.InstallParams memory _params = _buyback();
            if (i == 0) _params.nodes[1].splitter.settings = hex"01";
            if (i == 1) _params.nodes[1].splitter.permissions = new CapitalTreePluginSetup.Grant[](1);
            _expectInstallRevert(
                _params, abi.encodeWithSelector(CapitalTreePluginSetup.InvalidAbsentComponent.selector)
            );
        }
    }

    function test_RevertWhen_AnyRecipeGrantGivesConfigure() public {
        for (uint256 i; i < 4; ++i) {
            CapitalTreePluginSetup.InstallParams memory _params = _buyback();
            if (i == 0) _params.pluginPermissions[0].permissionId = CONFIGURE_PERMISSION_ID;
            if (i == 1) _params.budget.permissions[0].permissionId = CONFIGURE_PERMISSION_ID;
            if (i == 2) _params.nodes[0].action.permissions[0].permissionId = CONFIGURE_PERMISSION_ID;
            if (i == 3) _params.nodes[0].splitter.permissions[0].permissionId = CONFIGURE_PERMISSION_ID;
            _expectInstallRevert(
                _params,
                abi.encodeWithSelector(CapitalTreePluginSetup.ReservedPermission.selector, CONFIGURE_PERMISSION_ID)
            );
        }
    }

    // =========================================================================================
    // Helpers
    // =========================================================================================

    function _install(CapitalTreePluginSetup.InstallParams memory _params)
        internal
        returns (CapitalTreePlugin _plugin, address[] memory _helpers)
    {
        (address _pluginAddress, IPluginSetup.PreparedSetupData memory _prepared) =
            setup.prepareInstallation(address(dao), abi.encode(_params));
        installationPermissions = abi.encode(_prepared.permissions);
        dao.applyMultiTargetPermissions(_prepared.permissions);
        if (_params.budget.id == Recipes.STREAM_BUDGET) {
            vm.prank(address(dao));
            StreamBudget(_prepared.helpers[0]).writeCheckpoint(); // the install proposal starts the stream
        }

        return (CapitalTreePlugin(_pluginAddress), _prepared.helpers);
    }

    function _expectInstallRevert(CapitalTreePluginSetup.InstallParams memory _params, bytes memory _error) internal {
        bytes memory _data = abi.encode(_params);
        vm.expectRevert(_error);
        setup.prepareInstallation(address(dao), _data);
    }

    function _prepareUninstall(
        CapitalTreePlugin _plugin,
        address[] memory _helpers,
        PermissionLib.MultiTargetPermission[] memory _grants
    ) internal view returns (PermissionLib.MultiTargetPermission[] memory) {
        return setup.prepareUninstallation(
            address(dao),
            IPluginSetup.SetupPayload({plugin: address(_plugin), currentHelpers: _helpers, data: abi.encode(_grants)})
        );
    }

    /// @dev Swap 10 A for 1,000 B, then burn 95% and pay 5% to the fee address
    function _buyback() internal view returns (CapitalTreePluginSetup.InstallParams memory) {
        return Recipes.buyback(manager, guardian, _stream(), _swap(), fee, 50_000);
    }

    function _stream() internal view returns (Recipes.Stream memory) {
        return
            Recipes.Stream({token: IERC20(tokenA), amountPerEpoch: RATE, maxBudget: STREAM_CAP, epochInterval: EPOCH});
    }

    function _swap() internal view returns (Recipes.Swap memory) {
        return Recipes.Swap({demandedToken: IERC20(tokenB), demandPerFill: DEMAND});
    }

    function _pair(address _a, address _b) internal pure returns (address[] memory _recipients) {
        _recipients = new address[](2);
        (_recipients[0], _recipients[1]) = (_a, _b);
    }

    function _weights() internal pure returns (uint32[] memory _shares) {
        _shares = new uint32[](2);
        (_shares[0], _shares[1]) = (950_000, 50_000);
    }

    function _newFiller(CapitalTreePlugin _plugin) internal returns (MockFiller _mock) {
        _mock = new MockFiller(_plugin);
        tokenB.mint(address(_mock), 1_000_000 ether);
        vm.warp(block.timestamp + EPOCH);
    }

    function _leafHash(address _account, uint256 _cumulative) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(_account, _cumulative))));
    }

    function _hashPair(bytes32 _a, bytes32 _b) internal pure returns (bytes32) {
        return _a < _b ? keccak256(abi.encode(_a, _b)) : keccak256(abi.encode(_b, _a));
    }

    function _assertPermissions(address _plugin, address[] memory _helpers, bool _expected) internal view {
        (address _budget, address _action) = (_helpers[0], _helpers[1]);

        assertEq(dao.hasPermission(address(dao), _plugin, dao.EXECUTE_PERMISSION_ID(), ""), _expected, "execute");
        assertEq(dao.hasPermission(_plugin, address(0xA11CE), TRIGGER_PERMISSION_ID, ""), _expected, "trigger");
        assertEq(dao.hasPermission(_plugin, address(dao), CONFIGURE_PERMISSION_ID, ""), _expected, "configure");
        assertEq(dao.hasPermission(_plugin, guardian, PAUSE_PERMISSION_ID, ""), _expected, "pause plugin");
        assertEq(dao.hasPermission(_budget, manager, SET_SETTINGS_PERMISSION_ID, ""), _expected, "manage budget");
        assertEq(dao.hasPermission(_action, manager, SET_SETTINGS_PERMISSION_ID, ""), _expected, "manage action");
        assertEq(dao.hasPermission(_budget, address(dao), CHECKPOINT_PERMISSION_ID, ""), _expected, "dao checkpoint");
        assertEq(dao.hasPermission(_budget, _action, CHECKPOINT_PERMISSION_ID, ""), _expected, "action checkpoint");
    }
}
