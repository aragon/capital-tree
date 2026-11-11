// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IDAO} from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";
import {ComponentRegistry} from "../src/registry/ComponentRegistry.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {Recipes} from "../script/Recipes.sol";
import {METADATA_URIS} from "./helpers/Fixture.sol";

/// @notice The metadata files describe the code they're registered with
contract MetadataTest is Test {
    /// The files give each component's dependencies and settings, as its `initialize` decodes them
    function test_EachFileMatchesItsComponent() public view {
        _assertMatches("StreamBudget", 0, "address,uint256,uint256,uint256");
        _assertMatches("BalanceBudget", 0, "address");
        _assertMatches("MerkleClaimBudget", 0, "address,bytes32");
        _assertMatches("OpenFillAction", 1, "address,uint256");
        _assertMatches("TransferAction", 0, "address");
        _assertMatches("TransferToBeneficiaryAction", 0, "");
        _assertMatches("BurnAction", 0, "");
        _assertMatches("KeepAction", 0, "");
        _assertMatches("WeightSplitter", 0, "uint32[]");
        _assertMatches("VaultDonateAction", 0, "address");
    }

    function test_UrisFileListsEveryComponent() public view {
        string memory _uris = vm.readFile("metadata/uris.json");
        string[] memory _names = vm.parseJsonKeys(_uris, ".components");

        assertEq(_names.length, 10);
        for (uint256 i; i < _names.length; ++i) {
            assertTrue(vm.exists(string.concat("metadata/components/", _names[i], ".json")), _names[i]);
        }
    }

    function test_DeployRegistersEachComponentWithItsLink() public {
        (ComponentRegistry _registry,) = new Deploy().deploy(IDAO(address(this)), METADATA_URIS);

        (, bytes memory _metadata) = _registry.entries(Recipes.OPEN_FILL);
        assertEq(_metadata, "ipfs://OpenFillAction");
        (, _metadata) = _registry.entries(Recipes.KEEP);
        assertEq(_metadata, "ipfs://KeepAction");
        (, _metadata) = _registry.entries(Recipes.VAULT_DONATE);
        assertEq(_metadata, "ipfs://VaultDonateAction");
    }

    function test_RevertWhen_AComponentHasNoLink() public {
        Deploy _deploy = new Deploy();
        string memory _uris = vm.replace(METADATA_URIS, "ipfs://KeepAction", "");

        vm.expectRevert(abi.encodeWithSelector(Deploy.MissingMetadata.selector, "components.KeepAction"));
        _deploy.deploy(IDAO(address(this)), _uris);
    }

    function _assertMatches(string memory _name, uint256 _dependencies, string memory _settingTypes) internal view {
        string memory _json = vm.readFile(string.concat("metadata/components/", _name, ".json"));
        assertEq(vm.parseJsonString(_json, ".name"), _name, "name");

        uint256 _count;
        while (vm.keyExistsJson(_json, string.concat(".dependencies[", vm.toString(_count), "]"))) ++_count;
        assertEq(_count, _dependencies, string.concat(_name, " dependencies"));

        string memory _types;
        for (uint256 i; vm.keyExistsJson(_json, _setting(i)); ++i) {
            string memory _type = vm.parseJsonString(_json, string.concat(_setting(i), ".type"));
            _types = string.concat(_types, i == 0 ? "" : ",", _type);
        }
        assertEq(_types, _settingTypes, string.concat(_name, " settings"));
    }

    function _setting(uint256 _index) internal pure returns (string memory) {
        return string.concat(".settings[", vm.toString(_index), "]");
    }
}
