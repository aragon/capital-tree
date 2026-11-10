// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IPluginSetup} from "@aragon/osx-commons-contracts/src/plugin/setup/IPluginSetup.sol";
import {CapitalPipelinePlugin} from "../../src/CapitalPipelinePlugin.sol";
import {CapitalPipelinePluginSetup} from "../../src/setup/CapitalPipelinePluginSetup.sol";
import {FundedStreamBudget} from "../../src/budgets/FundedStreamBudget.sol";
import {VaultDonateAction} from "../../src/actions/VaultDonateAction.sol";
import {IDonationVault} from "../../src/interfaces/IDonationVault.sol";
import {Deploy} from "../../script/Deploy.s.sol";
import {Recipes} from "../../script/Recipes.sol";
import {Fixture, METADATA_URIS} from "./Fixture.sol";

abstract contract BuybackDonateFixture is Fixture {
    CapitalPipelinePlugin internal plugin;
    FundedStreamBudget internal budget;
    VaultDonateAction internal donation;

    function _installDonation(
        Recipes.Stream memory _stream,
        Recipes.Swap memory _swap,
        IDonationVault _vault,
        uint256 _weight
    ) internal {
        _installDonation(_stream, _swap, _vault, _weight, 0);
    }

    function _installDonation(
        Recipes.Stream memory _stream,
        Recipes.Swap memory _swap,
        IDonationVault _vault,
        uint256 _weight,
        uint256 _feeBps
    ) internal {
        (, CapitalPipelinePluginSetup _setup) = new Deploy().deploy(dao, METADATA_URIS);
        (address _plugin, IPluginSetup.PreparedSetupData memory _prepared) = _setup.prepareInstallation(
            address(dao), abi.encode(Recipes.buybackAndDonate(manager, _stream, _swap, _vault, _weight, fee, _feeBps))
        );
        dao.applyMultiTargetPermissions(_prepared.permissions);
        plugin = CapitalPipelinePlugin(_plugin);
        budget = FundedStreamBudget(_prepared.helpers[0]);
        donation = VaultDonateAction(_prepared.helpers[2]);
    }
}
