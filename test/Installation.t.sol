// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IDAO} from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";
import {Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import {ProxyLib} from "@aragon/osx-commons-contracts/src/utils/deployment/ProxyLib.sol";
import {PluginRepo} from "@aragon/osx/framework/plugin/repo/PluginRepo.sol";
import {PluginRepoFactory} from "@aragon/osx/framework/plugin/repo/PluginRepoFactory.sol";
import {PluginRepoRegistry} from "@aragon/osx/framework/plugin/repo/PluginRepoRegistry.sol";
import {PluginSetupProcessor} from "@aragon/osx/framework/plugin/setup/PluginSetupProcessor.sol";
import {ENSSubdomainRegistrar} from "@aragon/osx/framework/utils/ens/ENSSubdomainRegistrar.sol";
import {CapitalTreePlugin} from "../src/CapitalTreePlugin.sol";
import {StreamBudget} from "../src/budgets/StreamBudget.sol";
import {IBudget} from "../src/interfaces/IBudget.sol";
import {CapitalTreePluginSetup} from "../src/setup/CapitalTreePluginSetup.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {Install} from "../script/Install.s.sol";
import {Recipes} from "../script/Recipes.sol";
import {Fixture, METADATA_URIS} from "./helpers/Fixture.sol";
import {MockFiller} from "./mocks/MockFiller.sol";

/// @notice Deploy, publish and install through Aragon's own framework contracts, deployed locally
///         without ENS (the plugin repo is published with an empty subdomain)
contract InstallationTest is Fixture {
    PluginSetupProcessor internal psp;
    CapitalTreePluginSetup internal setup;
    PluginRepo internal repo;
    Install internal installer;

    function setUp() public override {
        super.setUp();

        PluginRepoRegistry _registry = PluginRepoRegistry(
            ProxyLib.deployUUPSProxy(
                address(new PluginRepoRegistry()),
                abi.encodeCall(PluginRepoRegistry.initialize, (IDAO(address(dao)), ENSSubdomainRegistrar(address(0))))
            )
        );
        PluginRepoFactory _factory = new PluginRepoFactory(_registry);
        dao.grant(address(_registry), address(_factory), _registry.REGISTER_PLUGIN_REPO_PERMISSION_ID());
        psp = new PluginSetupProcessor(_registry);

        Deploy _deploy = new Deploy();
        (, setup) = _deploy.deploy(dao, METADATA_URIS);
        repo = _deploy.publish(_factory, setup, "", manager, METADATA_URIS);
        installer = new Install();
    }

    function test_PublishesTheSetupAsVersionOneDotOne() public view {
        PluginRepo.Version memory _version = repo.getLatestVersion(1);

        assertEq(_version.pluginSetup, address(setup));
        assertEq(_version.tag.build, 1);
        assertEq(_version.buildMetadata, "ipfs://build");
        assertTrue(repo.isGranted(address(repo), manager, repo.MAINTAINER_PERMISSION_ID(), ""), "maintainer");
    }

    /// The proposal's actions install a buy-and-burn flow, which then burns a fill's proceeds
    function test_DaoInstallsBuyAndBurnWithTheProposalActions() public {
        (address _plugin, Action[] memory _actions) =
            installer.install(psp, repo, address(dao), _buyAndBurnConfig(STREAM_CAP));

        dao.grant(address(dao), address(dao), dao.ROOT_PERMISSION_ID()); // as Aragon's DAOFactory does
        dao.grant(address(dao), address(this), dao.EXECUTE_PERMISSION_ID()); // stands in for a passed proposal
        dao.execute(bytes32(0), _actions, 0);

        MockFiller _filler = new MockFiller(CapitalTreePlugin(_plugin));
        tokenB.mint(address(_filler), DEMAND);
        uint256 _supply = tokenB.totalSupply();
        vm.warp(block.timestamp + EPOCH);

        _filler.fill("");

        assertEq(tokenB.totalSupply(), _supply - DEMAND, "proceeds burned");
        assertEq(tokenB.balanceOf(address(dao)), DAO_B);
        assertFalse(dao.hasPermission(address(dao), address(psp), dao.ROOT_PERMISSION_ID(), ""), "ROOT revoked");
    }

    /// The stream starts when the proposal executes, not when the installation is prepared
    function test_TheStreamDoesNotGrowWhileTheProposalIsVoted() public {
        (address _plugin, Action[] memory _actions) =
            installer.install(psp, repo, address(dao), _buyAndBurnConfig(STREAM_CAP));
        IBudget _budget = CapitalTreePlugin(_plugin).budget();

        vm.warp(block.timestamp + 7 days);
        _executeProposal(_actions);
        assertEq(_available(_budget), 0, "no backlog from the vote");

        vm.warp(block.timestamp + EPOCH);
        assertEq(_available(_budget), RATE);
    }

    /// A proposal without the start action installs a flow that pays nothing, instead of a backlog
    function test_WithoutTheStartActionNothingFlows() public {
        (address _plugin, Action[] memory _actions) =
            installer.install(psp, repo, address(dao), _buyAndBurnConfig(STREAM_CAP));
        Action[] memory _withoutStart = new Action[](3);
        for (uint256 i; i < 3; ++i) {
            _withoutStart[i] = _actions[i];
        }

        _executeProposal(_withoutStart);
        vm.warp(block.timestamp + 7 days);

        assertEq(_available(CapitalTreePlugin(_plugin).budget()), 0);
    }

    /// Someone who prepares another recipe first can't take the plugin address the proposal names
    function test_FrontRunningThePreparationDoesNotChangeWhatTheProposalInstalls() public {
        string memory _honest = _buyAndBurnConfig(STREAM_CAP);
        uint256 _beforeSending = vm.snapshotState();
        (address _printed, Action[] memory _actions) = installer.install(psp, repo, address(dao), _honest);
        vm.revertToState(_beforeSending);

        (address _attacker,) = installer.install(psp, repo, address(dao), _buyAndBurnConfig(STREAM_CAP * 1000));
        (address _plugin,) = installer.install(psp, repo, address(dao), _honest);
        dao.grant(address(dao), address(dao), dao.ROOT_PERMISSION_ID());
        dao.grant(address(dao), address(this), dao.EXECUTE_PERMISSION_ID());
        dao.execute(bytes32(0), _actions, 0);

        assertEq(_plugin, _printed, "the honest plugin is where the proposal says");
        assertTrue(dao.hasPermission(address(dao), _printed, dao.EXECUTE_PERMISSION_ID(), ""), "honest installed");
        assertFalse(dao.hasPermission(address(dao), _attacker, dao.EXECUTE_PERMISSION_ID(), ""), "attacker not");
        assertEq(StreamBudget(address(CapitalTreePlugin(_printed).budget())).maxBudget(), STREAM_CAP);
    }

    function test_RevertWhen_SomeoneElseAppliesTheInstallation() public {
        (, Action[] memory _actions) = installer.install(psp, repo, address(dao), _buyAndBurnConfig(STREAM_CAP));

        vm.prank(alice);
        (bool _ok, bytes memory _reason) = _actions[1].to.call(_actions[1].data);

        assertFalse(_ok);
        assertEq(
            _reason,
            abi.encodeWithSelector(
                PluginSetupProcessor.SetupApplicationUnauthorized.selector,
                address(dao),
                alice,
                psp.APPLY_INSTALLATION_PERMISSION_ID()
            )
        );
    }

    function test_ConfigBuildsTheSameRecipe() public view {
        Recipes.Stream memory _stream = Recipes.Stream(IERC20(tokenA), RATE, STREAM_CAP, EPOCH);
        Recipes.Swap memory _swap = Recipes.Swap(IERC20(tokenB), DEMAND);

        assertEq(
            abi.encode(installer.recipe(_buyAndBurnConfig(STREAM_CAP))),
            abi.encode(Recipes.buyAndBurn(manager, guardian, _stream, _swap))
        );
    }

    function test_EveryExampleConfigBuildsItsRecipe() public view {
        assertEq(installer.recipe(_example("buy-and-burn")).components.length, 3);
        assertEq(installer.recipe(_example("buyback")).components.length, 5);
        CapitalTreePluginSetup.InstallParams memory _donate = installer.recipe(_example("buyback-and-donate"));
        assertEq(_donate.components.length, 5);
        assertEq(_donate.components[2].id, Recipes.VAULT_DONATE);
        assertEq(_donate.components[3].id, Recipes.TRANSFER);
        assertEq(_donate.components[4].id, Recipes.WEIGHT_SPLITTER);
        assertEq(_donate.nodes.length, 3);
        assertTrue(_donate.nodes[0].forwardSurplus);
        assertEq(installer.recipe(_example("merkle-claim")).components.length, 2);
        assertEq(installer.recipe(_example("payroll")).components.length, 4);
    }

    /// OpenFill has no cap of its own: without the stream's, an auction has no worst price
    function test_RevertWhen_AnAuctionStreamHasNoCap() public {
        vm.expectRevert(Recipes.UncappedStream.selector);
        installer.recipe(_buyAndBurnConfig(0));
    }

    function test_RevertWhen_TheRecipeIsUnknown() public {
        vm.expectRevert(abi.encodeWithSelector(Install.UnknownRecipe.selector, "swapEverything"));
        installer.recipe(
            string.concat(
                '{"recipe":"swapEverything","manager":"0x0000000000000000000000000000000000000001",',
                '"guardian":"0x0000000000000000000000000000000000000002"}'
            )
        );
    }

    // Helpers

    function _executeProposal(Action[] memory _actions) internal {
        dao.grant(address(dao), address(dao), dao.ROOT_PERMISSION_ID()); // as Aragon's DAOFactory does
        dao.grant(address(dao), address(this), dao.EXECUTE_PERMISSION_ID()); // stands in for a passed proposal
        dao.execute(bytes32(0), _actions, 0);
    }

    function _buyAndBurnConfig(uint256 _maxBudget) internal view returns (string memory) {
        return string.concat(
            '{"recipe":"buyAndBurn","manager":"',
            vm.toString(manager),
            '","guardian":"',
            vm.toString(guardian),
            '","stream":{"token":"',
            vm.toString(address(tokenA)),
            '","amountPerEpoch":"',
            vm.toString(RATE),
            '","maxBudget":"',
            vm.toString(_maxBudget),
            '","epochInterval":"',
            vm.toString(EPOCH),
            '"},"swap":{"demandedToken":"',
            vm.toString(address(tokenB)),
            '","demandPerFill":"',
            vm.toString(DEMAND),
            '"}}'
        );
    }

    function _example(string memory _name) internal view returns (string memory) {
        return vm.readFile(string.concat("installs/", _name, ".example.json"));
    }
}
