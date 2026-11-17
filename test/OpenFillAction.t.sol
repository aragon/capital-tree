// SPDX-License-Identifier: MIT
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

    function testFuzz_BuildOffersTheWholeInput(uint256 _amount) public view {
        (Asset memory _output, Action[] memory _actions) = action.build(filler, "", _input(_amount));
        assertEq(_actions[0].data, abi.encodeCall(IERC20.approve, (filler, _amount)), "no cap of its own");
        assertEq(address(_output.token), address(tokenB));
        assertEq(_output.amount, DEMAND);
    }

    function testFuzz_BuildApprovesCallsBackAndClearsApproval(address _filler, uint256 _amount, bytes memory _data)
        public
        view
    {
        (, Action[] memory _actions) = action.build(_filler, _data, _input(_amount));
        assertEq(_actions.length, 3);
        assertEq(_actions[0].to, address(tokenA));
        assertEq(_actions[0].data, abi.encodeCall(IERC20.approve, (_filler, _amount)));
        assertEq(_actions[1].to, _filler);
        assertEq(
            _actions[1].data,
            abi.encodeCall(IFiller.fillOffer, (IERC20(tokenA), _amount, IERC20(tokenB), DEMAND, _data))
        );
        assertEq(_actions[2].to, address(tokenA));
        assertEq(_actions[2].data, abi.encodeCall(IERC20.approve, (_filler, 0)));
        for (uint256 i; i < _actions.length; ++i) {
            assertEq(_actions[i].value, 0);
        }
    }

    function testFuzz_PostconditionsCheckTheDaoReceivedTheDemand(uint128 _demand, uint128 _delivered) public {
        _demand = uint128(bound(_demand, 1, type(uint128).max));
        vm.prank(manager);
        action.setDemandPerFill(_demand);
        Asset memory _in = _input(10 ether);
        (Asset memory _output,) = action.build(filler, "", _in);
        bytes memory _snapshot = action.preconditions(filler, "", _in, _output);
        assertEq(_snapshot, abi.encode(DAO_A, DAO_B));
        tokenB.mint(address(dao), _delivered);
        if (_delivered < _demand) {
            vm.expectRevert(
                abi.encodeWithSelector(OpenFillAction.DemandNotMet.selector, DAO_B + _demand, DAO_B + _delivered)
            );
        }
        action.postconditions(filler, _in, _output, _snapshot);
    }

    function testFuzz_SetDemandPerFillRestartsTheAuction(uint256 _demand, uint64 _elapsed) public {
        _demand = bound(_demand, 1, type(uint256).max);
        vm.warp(block.timestamp + _elapsed);
        vm.prank(manager);
        action.setDemandPerFill(_demand);
        assertEq(action.demandPerFill(), _demand);
        assertEq(_available(budget), 0);
        assertEq(budget.baseTimestamp(), block.timestamp);
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
        _action.initialize(dao, _deps(address(budget)), abi.encode(tokenA, DEMAND));
    }

    function test_RevertWhen_DemandedTokenHasNoCode() public {
        OpenFillAction _action = _clone();
        vm.expectRevert(OpenFillAction.InvalidToken.selector);
        _action.initialize(dao, _deps(address(budget)), abi.encode(IERC20(address(0xBEEF)), DEMAND));
    }

    function test_RevertWhen_ZeroDemand() public {
        vm.expectRevert(OpenFillAction.ZeroDemand.selector);
        vm.prank(manager);
        action.setDemandPerFill(0);
    }

    function testFuzz_PostconditionsRejectExcessOfferSpend(uint256 _offered, uint256 _spent) public {
        _offered = bound(_offered, 0, DAO_A);
        _spent = bound(_spent, 0, DAO_A);
        Asset memory _in = _input(_offered);
        (Asset memory _output,) = action.build(filler, "", _in);
        bytes memory _snapshot = action.preconditions(filler, "", _in, _output);
        vm.prank(address(dao));
        tokenA.transfer(filler, _spent);
        tokenB.mint(address(dao), DEMAND);
        if (_spent > _offered) {
            vm.expectRevert(
                abi.encodeWithSelector(OpenFillAction.OfferExceeded.selector, DAO_A - _offered, DAO_A - _spent)
            );
        }
        action.postconditions(filler, _in, _output, _snapshot);
    }

    /// Paying the demand without taking the offer must work for every representable balance.
    function testFuzz_PostconditionsAcceptUntouchedOffer(uint256 _balance, uint256 _offered) public {
        _balance = bound(_balance, 1, type(uint256).max);
        _offered = bound(_offered, 0, _balance);
        deal(address(tokenA), address(dao), _balance, true);
        Asset memory _in = _input(_offered);
        (Asset memory _output,) = action.build(filler, "", _in);
        bytes memory _snapshot = action.preconditions(filler, "", _in, _output);
        tokenB.mint(address(dao), DEMAND);
        action.postconditions(filler, _in, _output, _snapshot);
    }

    /// No offered tokens were spent, so a guard that adds the offer to the balance would overflow.
    function test_Regression_UntouchedLargeOfferOverflowsBalanceGuard() public {
        uint256 _amount = type(uint256).max / 2 + 1;
        deal(address(tokenA), address(dao), _amount, true);
        Asset memory _in = _input(_amount);
        (Asset memory _output,) = action.build(filler, "", _in);
        bytes memory _snapshot = action.preconditions(filler, "", _in, _output);
        tokenB.mint(address(dao), DEMAND);
        action.postconditions(filler, _in, _output, _snapshot);
    }

    function _input(uint256 _available) internal view returns (Asset memory) {
        return Asset({token: tokenA, amount: _available});
    }

    function _clone() internal returns (OpenFillAction) {
        return OpenFillAction(ProxyLib.deployMinimalProxy(address(new OpenFillAction()), ""));
    }
}
