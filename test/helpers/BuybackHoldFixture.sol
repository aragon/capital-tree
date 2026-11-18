// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {TestToken} from "./TestToken.sol";
import {DAO} from "@aragon/osx/core/dao/DAO.sol";
import {ProxyLib} from "@aragon/osx-commons-contracts/src/utils/deployment/ProxyLib.sol";
import {IPluginSetup} from "@aragon/osx-commons-contracts/src/plugin/setup/IPluginSetup.sol";
import {CapitalTreePlugin} from "../../src/CapitalTreePlugin.sol";
import {StreamBudget} from "../../src/budgets/StreamBudget.sol";
import {OpenFillAction} from "../../src/actions/OpenFillAction.sol";
import {KeepAction} from "../../src/actions/KeepAction.sol";
import {CapitalTreePluginSetup as Setup} from "../../src/setup/CapitalTreePluginSetup.sol";
import {ComponentRegistry as Registry} from "../../src/registry/ComponentRegistry.sol";
import {TRIGGER_PERMISSION_ID} from "../../src/lib/constants.sol";
import {Buyer} from "../invariant/buyback-hold/Buyer.sol";
import {FillHandler, ALICE, BOB} from "../invariant/buyback-hold/FillHandler.sol";

/// @notice Shared production installation, buyer funding and handler targeting for buyback campaigns.
abstract contract BuybackHoldFixture is Test {
    /// @dev Raw units of sellToken added to the offer per epoch; `ether` supplies the 18-decimal scaling.
    uint256 internal constant AMOUNT_PER_EPOCH = 10 ether;
    /// @dev Maximum offer of sellToken, reached after two epochs of uninterrupted accrual.
    uint256 internal constant MAX_BUDGET = 20 ether;
    /// @dev Duration of one accrual epoch, in seconds.
    uint256 internal constant EPOCH_INTERVAL = 1 days;
    /// @dev Raw units of buyToken required from a buyer for each successful fill.
    uint256 internal constant DEMAND = 1_000 ether;

    DAO internal dao;
    Setup internal setup;
    CapitalTreePlugin internal plugin;
    StreamBudget internal budget;
    OpenFillAction internal openFill;

    /// @dev The token the DAO sells. Each campaign chooses its initial fixed supply.
    TestToken internal sellToken;
    /// @dev The token the DAO buys, distributed to the DAO, Alice and Bob before testing starts.
    TestToken internal buyToken;

    /// @dev The two competing buyers, ordered as Alice (ALICE) and Bob (BOB).
    Buyer[2] internal buyers;
    /// @dev Addresses of the deployed buyer contracts, reused in funding and balance checks.
    address internal ALICE_SOLVER;
    address internal BOB_SOLVER;

    /// @dev Test driver exposing the two operations Foundry may fuzz.
    FillHandler internal handler;

    /// @dev Deployed addresses monitored for residual allowances and unexpected balances.
    address[] internal checkedAddresses;

    /// @notice Installs the shared flow, then registers the campaign's independent actions.
    /// @dev Creates the handler at the initial checkpoint time, then advances one epoch so the
    /// first attempt has a positive offer. Paired scenario helpers are not fuzz targets.
    function setUp() public virtual {
        _install();
        handler =
            new FillHandler({setup_: setup, plugin_: plugin, buyers_: buyers, checkedAddresses_: checkedAddresses});
        handler.advanceTime({secondsLater: uint32(EPOCH_INTERVAL)}); // the first buyer has something to buy

        targetSelector(StdInvariant.FuzzSelector({addr: address(handler), selectors: _handlerSelectors()}));
        targetContract(address(handler));
    }

    /// @dev Baseline campaign: time and one buyer's attempt can occur in any order.
    function _handlerSelectors() internal pure virtual returns (bytes4[] memory selectors) {
        selectors = new bytes4[](2);
        selectors[0] = FillHandler.fill.selector;
        selectors[1] = FillHandler.advanceTime.selector;
    }

    /// @dev The deposit campaign overrides this to make the stream balance-limited.
    function _initialSellSupply() internal pure virtual returns (uint256) {
        return 1_000_000 ether;
    }

    /// @notice Deploys and funds a fixed buy-and-hold installation using the production setup contract.
    /// @dev The test contract holds DAO root permission. Setup grants the plugin execution rights,
    /// allows public triggering and supplies the required checkpoint permissions. A DAO checkpoint
    /// starts accrual. Implementations and deployed instances are included in checkedAddresses.
    function _install() internal {
        vm.warp(1_000_000);
        address daoImplementation = address(new DAO());
        dao = DAO(
            payable(ProxyLib.deployUUPSProxy({
                    _logic: daoImplementation,
                    _initCalldata: abi.encodeCall(DAO.initialize, ("", address(this), address(0), ""))
                }))
        );
        sellToken = new TestToken({symbol_: "A", holder: address(dao), supply: _initialSellSupply()});
        buyToken = new TestToken({symbol_: "B", holder: address(this), supply: 20_000_500 ether});

        Registry.Registration[] memory entries = new Registry.Registration[](3);
        entries[0] = Registry.Registration({
            id: "StreamBudget@1", implementation: address(new StreamBudget()), metadata: "test"
        });
        entries[1] = Registry.Registration({
            id: "OpenFillAction@1", implementation: address(new OpenFillAction()), metadata: "test"
        });
        entries[2] =
            Registry.Registration({id: "KeepAction@1", implementation: address(new KeepAction()), metadata: "test"});
        Registry registry = new Registry({_managingDao: dao, _initial: entries});
        setup = new Setup({_registry: registry});

        // Declare exactly the recipe under test: StreamBudget -> OpenFill -> Keep.
        Setup.InstallParams memory recipe;
        recipe.budget.id = "StreamBudget@1";
        recipe.budget.settings = abi.encode(sellToken, AMOUNT_PER_EPOCH, MAX_BUDGET, EPOCH_INTERVAL);
        recipe.nodes = new Setup.RecipeNode[](2);
        recipe.nodes[0].action.id = "OpenFillAction@1";
        recipe.nodes[0].action.settings = abi.encode(buyToken, DEMAND);
        recipe.nodes[0].children = new uint32[](1);
        recipe.nodes[0].children[0] = 1;
        recipe.nodes[1].action.id = "KeepAction@1";
        recipe.pluginPermissions = new Setup.Grant[](1);
        recipe.pluginPermissions[0] =
            Setup.Grant({who: address(type(uint160).max), permissionId: TRIGGER_PERMISSION_ID});

        (address installed, IPluginSetup.PreparedSetupData memory prepared) =
            setup.prepareInstallation({_dao: address(dao), _data: abi.encode(recipe)});
        dao.applyMultiTargetPermissions(prepared.permissions);

        plugin = CapitalTreePlugin(installed);
        budget = StreamBudget(prepared.helpers[0]);
        openFill = OpenFillAction(prepared.helpers[1]);

        assertEq(budget.amountPerEpoch(), AMOUNT_PER_EPOCH);
        assertEq(budget.maxBudget(), MAX_BUDGET);
        assertEq(budget.epochInterval(), EPOCH_INTERVAL);
        assertEq(openFill.demandPerFill(), DEMAND);

        vm.prank(address(dao));
        budget.writeCheckpoint(); // start the clock

        buyers[ALICE] = new Buyer({plugin_: plugin});
        buyers[BOB] = new Buyer({plugin_: plugin});
        ALICE_SOLVER = address(buyers[ALICE]);
        BOB_SOLVER = address(buyers[BOB]);
        vm.label({account: ALICE_SOLVER, newLabel: "Alice Solver"});
        vm.label({account: BOB_SOLVER, newLabel: "Bob Solver"});

        buyToken.transfer({to: address(dao), amount: 500 ether}); // pre-existing buyToken must remain in the DAO
        buyToken.transfer({to: ALICE_SOLVER, amount: 10_000_000 ether});
        buyToken.transfer({to: BOB_SOLVER, amount: 10_000_000 ether});

        // These addresses are checked for leftover DAO allowances and unexpected balances.
        // There is no special index ordering or proxy/implementation offset.
        checkedAddresses.push(address(dao));
        checkedAddresses.push(ALICE_SOLVER);
        checkedAddresses.push(BOB_SOLVER);
        checkedAddresses.push(address(plugin));
        checkedAddresses.push(address(setup));
        checkedAddresses.push(address(registry));
        checkedAddresses.push(address(sellToken));
        checkedAddresses.push(address(buyToken));
        checkedAddresses.push(daoImplementation);
        checkedAddresses.push(setup.implementation());
        for (uint256 i; i < prepared.helpers.length; ++i) {
            checkedAddresses.push(prepared.helpers[i]);
        }
        for (uint256 i; i < entries.length; ++i) {
            checkedAddresses.push(entries[i].implementation);
        }
        _checkInitialAllowances();
    }

    /// @dev The handler checks live permissions at construction and after every action.
    /// Installation must also leave all monitored DAO token allowances at zero.
    function _checkInitialAllowances() internal view {
        for (uint256 i; i < checkedAddresses.length; ++i) {
            assertEq(sellToken.allowance({owner: address(dao), spender: checkedAddresses[i]}), 0);
            assertEq(buyToken.allowance({owner: address(dao), spender: checkedAddresses[i]}), 0);
        }
    }
}
