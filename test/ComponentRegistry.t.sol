// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {DaoUnauthorized} from "@aragon/osx-commons-contracts/src/permission/auth/auth.sol";
import {ComponentRegistry} from "../src/registry/ComponentRegistry.sol";
import {KeepAction} from "../src/actions/KeepAction.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {Recipes} from "../script/Recipes.sol";
import {Fixture, METADATA_URIS} from "./helpers/Fixture.sol";

contract ComponentRegistryTest is Fixture {
    ComponentRegistry internal registry;
    address internal newKeep;

    function setUp() public override {
        super.setUp();
        (registry,) = new Deploy().deploy(dao, METADATA_URIS);
        newKeep = address(new KeepAction());
        dao.grant(address(registry), manager, registry.REGISTER_PERMISSION_ID());
    }

    function test_RegistersTheInitialComponents() public view {
        address _openFill = registry.implementation(Recipes.OPEN_FILL);
        assertGt(_openFill.code.length, 0);
    }

    function testFuzz_ManagingDaoRegistersMore(bytes32 id, bytes memory metadata) public {
        (address existing,) = registry.entries(id);
        vm.assume(existing == address(0));
        vm.prank(manager);
        registry.register(ComponentRegistry.Registration(id, newKeep, metadata));

        assertEq(registry.implementation(id), newKeep);
        (, bytes memory _metadata) = registry.entries(id);
        assertEq(_metadata, metadata);
    }

    function test_RevertWhen_TheIdIsTaken() public {
        vm.expectRevert(abi.encodeWithSelector(ComponentRegistry.AlreadyRegistered.selector, Recipes.KEEP));
        vm.prank(manager);
        registry.register(ComponentRegistry.Registration(Recipes.KEEP, newKeep, ""));
    }

    function test_RevertWhen_RegisterUnauthorized() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                DaoUnauthorized.selector,
                address(dao),
                address(registry),
                address(this),
                registry.REGISTER_PERMISSION_ID()
            )
        );
        registry.register(ComponentRegistry.Registration("KeepAction@2", newKeep, ""));
    }

    function testFuzz_RevertWhen_TheImplementationHasNoCode(address implementation) public {
        vm.assume(implementation.code.length == 0);
        vm.expectRevert(abi.encodeWithSelector(ComponentRegistry.NotAContract.selector, implementation));
        vm.prank(manager);
        registry.register(ComponentRegistry.Registration("KeepAction@2", implementation, ""));
    }

    function testFuzz_RevertWhen_TheIdIsUnknown(bytes32 id) public {
        (address existing,) = registry.entries(id);
        vm.assume(existing == address(0));
        vm.expectRevert(abi.encodeWithSelector(ComponentRegistry.UnknownComponent.selector, id));
        registry.implementation(id);
    }
}
