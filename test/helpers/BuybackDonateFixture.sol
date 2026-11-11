// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IPluginSetup} from "@aragon/osx-commons-contracts/src/plugin/setup/IPluginSetup.sol";
import {CapitalTreePlugin} from "../../src/CapitalTreePlugin.sol";
import {CapitalTreePluginSetup} from "../../src/setup/CapitalTreePluginSetup.sol";
import {StreamBudget} from "../../src/budgets/StreamBudget.sol";
import {VaultDonateAction} from "../../src/actions/VaultDonateAction.sol";
import {IDonationVault} from "../../src/interfaces/IDonationVault.sol";
import {Deploy} from "../../script/Deploy.s.sol";
import {Recipes} from "../../script/Recipes.sol";
import {Fixture, METADATA_URIS} from "./Fixture.sol";

abstract contract BuybackDonateFixture is Fixture {
    CapitalTreePlugin internal plugin;
    StreamBudget internal budget;
    VaultDonateAction internal donation;

    function _installDonation(
        Recipes.Stream memory _stream,
        Recipes.Swap memory _swap,
        IDonationVault _vault,
        uint256 _feeBps
    ) internal {
        (, CapitalTreePluginSetup _setup) = new Deploy().deploy(dao, METADATA_URIS);
        (address _plugin, IPluginSetup.PreparedSetupData memory _prepared) = _setup.prepareInstallation(
            address(dao), abi.encode(Recipes.buybackAndDonate(manager, guardian, _stream, _swap, _vault, fee, _feeBps))
        );
        dao.applyMultiTargetPermissions(_prepared.permissions);
        plugin = CapitalTreePlugin(_plugin);
        budget = StreamBudget(_prepared.helpers[0]);
        vm.prank(address(dao));
        budget.writeCheckpoint(); // the install proposal starts the stream
        donation = VaultDonateAction(address(plugin.nodes()[2].action));
    }
}
