// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import {DaoUnauthorized} from "@aragon/osx-commons-contracts/src/permission/auth/auth.sol";
import {ProxyLib} from "@aragon/osx-commons-contracts/src/utils/deployment/ProxyLib.sol";
import {StreamBudget} from "../src/budgets/StreamBudget.sol";
import {OpenFillAction} from "../src/actions/OpenFillAction.sol";
import {IFiller} from "../src/interfaces/IFiller.sol";
import {Asset} from "../src/lib/types.sol";
import {SET_SETTINGS_PERMISSION_ID} from "../src/lib/constants.sol";
import {Fixture} from "./helpers/Fixture.sol";

contract OpenFillActionTest is Fixture {
    StreamBudget internal budget;
    OpenFillAction internal action;
    address internal filler = makeAddr("filler");

    function setUp() public override {
        super.setUp();
        budget = _deployBudget(RATE, 0);
        action = _deployAction(budget);
    }

    function test_BuildOffersTheWholeInput() public view {
        (Asset memory _output, Action[] memory _actions) = action.build(filler, "", _input(50 ether));

        assertEq(_actions[0].data, abi.encodeCall(IERC20.approve, (filler, 50 ether)), "no cap of its own");
        assertEq(address(_output.token), address(tokenB));
        assertEq(_output.amount, DEMAND);
    }

    function test_BuildApprovesCallsBackAndClearsApproval() public view {
        (, Action[] memory _actions) = action.build(filler, "solver-data", _input(10 ether));

        assertEq(_actions.length, 3);
        assertEq(_actions[0].to, address(tokenA));
        assertEq(_actions[0].data, abi.encodeCall(IERC20.approve, (filler, 10 ether)));
        assertEq(_actions[1].to, filler);
        assertEq(
            _actions[1].data,
            abi.encodeCall(IFiller.fillOffer, (IERC20(tokenA), 10 ether, IERC20(tokenB), DEMAND, "solver-data"))
        );
        assertEq(_actions[2].to, address(tokenA));
        assertEq(_actions[2].data, abi.encodeCall(IERC20.approve, (filler, 0)));
    }

    function test_PostconditionsCheckTheDaoReceivedTheDemand() public {
        Asset memory _in = _input(10 ether);
        (Asset memory _output,) = action.build(filler, "", _in);
        bytes memory _snapshot = action.preconditions(filler, "", _in, _output);
        assertEq(_snapshot, abi.encode(DAO_A, DAO_B));

        vm.expectRevert(abi.encodeWithSelector(OpenFillAction.DemandNotMet.selector, DAO_B + DEMAND, DAO_B));
        action.postconditions(filler, _in, _output, _snapshot);

        tokenB.mint(address(dao), DEMAND);
        action.postconditions(filler, _in, _output, _snapshot);
    }

    function test_SetDemandPerFillRestartsTheAuction() public {
        vm.warp(block.timestamp + EPOCH);
        assertEq(_available(budget), RATE);

        vm.prank(manager);
        action.setDemandPerFill(500 ether);

        assertEq(action.demandPerFill(), 500 ether);
        assertEq(_available(budget), 0);
    }

    function test_RevertWhen_SetterUnauthorized() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                DaoUnauthorized.selector, address(dao), address(action), address(this), SET_SETTINGS_PERMISSION_ID
            )
        );
        action.setDemandPerFill(1);
    }

    function test_RevertWhen_DemandedTokenIsOfferedToken() public {
        OpenFillAction _action = _clone();
        vm.expectRevert(OpenFillAction.SameToken.selector);
        _action.initialize(dao, budget, tokenA, DEMAND);
    }

    function test_RevertWhen_DemandedTokenHasNoCode() public {
        OpenFillAction _action = _clone();
        vm.expectRevert(OpenFillAction.InvalidToken.selector);
        _action.initialize(dao, budget, IERC20(address(0xBEEF)), DEMAND);
    }

    function test_RevertWhen_ZeroDemand() public {
        vm.expectRevert(OpenFillAction.ZeroDemand.selector);
        vm.prank(manager);
        action.setDemandPerFill(0);
    }

    function _input(uint256 _available) internal view returns (Asset memory) {
        return Asset({token: tokenA, amount: _available});
    }

    function _clone() internal returns (OpenFillAction) {
        return OpenFillAction(ProxyLib.deployMinimalProxy(address(new OpenFillAction()), ""));
    }
}
