// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DAO} from "@aragon/osx/core/dao/DAO.sol";
import {Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import {DaoUnauthorized} from "@aragon/osx-commons-contracts/src/permission/auth/auth.sol";
import {CapitalPipelinePlugin} from "../../src/CapitalPipelinePlugin.sol";
import {FundedStreamBudget} from "../../src/budgets/FundedStreamBudget.sol";
import {OpenFillAction} from "../../src/actions/OpenFillAction.sol";
import {GenericSwapSolver} from "../../src/solvers/GenericSwapSolver.sol";
import {Node} from "../../src/lib/types.sol";
import {NATIVE} from "../../src/lib/tokens.sol";
import {TRIGGER_PERMISSION_ID} from "../../src/lib/constants.sol";
import {Fixture} from "../helpers/Fixture.sol";

contract GenericSwapSolverTest is Fixture {
    FundedStreamBudget internal budget;
    OpenFillAction internal action;
    CapitalPipelinePlugin internal plugin;
    GenericSwapSolver internal solver;

    function setUp() public override {
        super.setUp();
        budget = _deployBudget(RATE, 0);
        action = _deployAction(budget);
        plugin = _deployPlugin(budget, _chain(action, keep));
        solver = new GenericSwapSolver();
        tokenB.mint(address(solver), DEMAND);
        vm.warp(block.timestamp + EPOCH);
    }

    function test_FillPaysDaoClearsAllowanceAndCommitsStream() public {
        solver.trigger(plugin, _data(_calls(RATE, DEMAND, address(dao))));

        assertEq(tokenA.balanceOf(address(dao)), DAO_A - RATE);
        assertEq(tokenB.balanceOf(address(dao)), DAO_B + DEMAND);
        assertEq(tokenA.balanceOf(address(solver)), RATE);
        assertEq(tokenB.balanceOf(address(solver)), 0);
        assertEq(tokenA.allowance(address(dao), address(solver)), 0);
        assertEq(budget.available(), 0);
        assertEq(budget.lastSeenBalance(), DAO_A - RATE);
        assertEq(budget.baseTimestamp(), block.timestamp);
    }

    function test_FillRunsDownstreamBurnAndFeeNodes() public {
        plugin = _deployPlugin(budget, _splitToBurnAndFee(action));

        solver.trigger(plugin, _data(_calls(RATE, DEMAND, address(dao))));

        assertEq(tokenB.balanceOf(BURN), DEMAND * 95 / 100);
        assertEq(tokenB.balanceOf(fee), DEMAND * 5 / 100);
        assertEq(tokenB.balanceOf(address(dao)), DAO_B);
        assertEq(budget.available(), 0);
    }

    function test_CallbackDataAtNonRootNode() public {
        Node[] memory tree = new Node[](4);
        tree[0] = _branch(NO_ACTION, 1, 500_000, 2, 500_000);
        tree[1] = _leaf(_deployTransfer(alice));
        tree[2] = _then(action, 3);
        tree[3] = _leaf(keep);
        plugin = _deployPlugin(budget, tree);
        bytes[] memory data = new bytes[](4);
        data[2] = abi.encode(_calls(RATE / 2, DEMAND, address(dao)));

        solver.trigger(plugin, data);

        assertEq(tokenA.balanceOf(alice), RATE / 2);
        assertEq(tokenA.balanceOf(address(solver)), RATE / 2);
        assertEq(tokenB.balanceOf(address(dao)), DAO_B + DEMAND);
        assertEq(tokenA.allowance(address(dao), address(solver)), 0);
        assertEq(budget.lastSeenBalance(), DAO_A - RATE);
        assertEq(budget.available(), 0);
    }

    function test_MultipleOpenFillNodesKeepSeparatePayloads() public {
        Node[] memory tree = new Node[](5);
        tree[0] = _branch(NO_ACTION, 1, 400_000, 3, 600_000);
        tree[1] = _then(action, 2);
        tree[2] = _leaf(keep);
        tree[3] = _then(action, 4);
        tree[4] = _leaf(keep);
        plugin = _deployPlugin(budget, tree);
        tokenB.mint(address(solver), DEMAND);
        bytes[] memory data = new bytes[](5);
        data[1] = abi.encode(_calls(RATE * 4 / 10, DEMAND, address(dao)));
        data[3] = abi.encode(_calls(RATE * 6 / 10, DEMAND, address(dao)));

        solver.trigger(plugin, data);

        assertEq(tokenA.balanceOf(address(solver)), RATE);
        assertEq(tokenB.balanceOf(address(dao)), DAO_B + 2 * DEMAND);
        assertEq(tokenA.allowance(address(dao), address(solver)), 0);
        assertEq(budget.lastSeenBalance(), DAO_A - RATE);
        assertEq(budget.available(), 0);
    }

    function test_RevertWhen_UnderpaidRestoresBalancesAndStream() public {
        bytes[] memory data = _data(_calls(RATE, DEMAND - 1, address(dao)));
        uint256 checkpoint = budget.baseTimestamp();

        vm.expectRevert(abi.encodeWithSelector(DAO.ActionFailed.selector, 3));
        solver.trigger(plugin, data);

        _assertUnfilled(checkpoint);
    }

    function test_RevertWhen_ACallbackCallFailsRollsBackEarlierCalls() public {
        // The input pull succeeds, then paying more B than the solver owns fails.
        bytes[] memory data = _data(_calls(RATE, DEMAND + 1, address(dao)));
        uint256 checkpoint = budget.baseTimestamp();

        vm.expectRevert(abi.encodeWithSelector(DAO.ActionFailed.selector, 1));
        solver.trigger(plugin, data);

        _assertUnfilled(checkpoint);
    }

    function test_RevertWhen_StaleQuotePullsMoreThanTheOffer() public {
        bytes[] memory data = _data(_calls(RATE + 1, DEMAND, address(dao)));
        uint256 checkpoint = budget.baseTimestamp();

        vm.expectRevert(abi.encodeWithSelector(DAO.ActionFailed.selector, 1));
        solver.trigger(plugin, data);

        _assertUnfilled(checkpoint);
    }

    function test_RevertWhen_PayloadOmitsLeafNode() public {
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encode(_calls(RATE, DEMAND, address(dao)));

        vm.expectRevert(abi.encodeWithSelector(CapitalPipelinePlugin.DataLengthMismatch.selector, 2, 1));
        solver.trigger(plugin, data);
    }

    function test_RevertWhen_CallbackContainsOuterArrayEncoding() public {
        bytes[] memory data = _data(_calls(RATE, DEMAND, address(dao)));
        data[0] = abi.encode(data);

        vm.expectRevert(abi.encodeWithSelector(DAO.ActionFailed.selector, 1));
        solver.trigger(plugin, data);
    }

    function test_RevertWhen_CallbackDataIsEmpty() public {
        // An empty pipeline array is valid, but this solver needs an encoded Action[].
        vm.expectRevert(abi.encodeWithSelector(DAO.ActionFailed.selector, 1));
        solver.trigger(plugin, new bytes[](0));
    }

    function test_RevertWhen_BatchReentersPipeline() public {
        Action[] memory calls = new Action[](1);
        calls[0] = Action(address(plugin), 0, abi.encodeCall(plugin.trigger, (new bytes[](0))));
        bytes[] memory data = _data(calls);
        uint256 checkpoint = budget.baseTimestamp();

        vm.expectRevert(abi.encodeWithSelector(DAO.ActionFailed.selector, 1));
        solver.trigger(plugin, data);

        _assertUnfilled(checkpoint);
    }

    function test_RevertWhen_SolverLacksTriggerPermission() public {
        dao.revoke(address(plugin), ANY_ADDR, TRIGGER_PERMISSION_ID);
        dao.grant(address(plugin), address(this), TRIGGER_PERMISSION_ID);
        bytes[] memory data = _data(_calls(RATE, DEMAND, address(dao)));

        vm.expectRevert(
            abi.encodeWithSelector(
                DaoUnauthorized.selector, address(dao), address(plugin), address(solver), TRIGGER_PERMISSION_ID
            )
        );
        solver.trigger(plugin, data);
    }

    function test_RevertWhen_PipelinePaused() public {
        vm.prank(manager);
        plugin.pause();
        bytes[] memory data = _data(_calls(RATE, DEMAND, address(dao)));

        vm.expectRevert("Pausable: paused");
        solver.trigger(plugin, data);
    }

    function test_NativeOfferFundsBatchAndSweep() public {
        vm.deal(address(dao), RATE);
        budget = _deployStream(NATIVE, RATE, 0);
        plugin = _deployPlugin(budget, _chain(_deployAction(budget), keep));
        vm.warp(block.timestamp + EPOCH);
        Action[] memory calls = new Action[](3);
        calls[0] = Action(address(tokenB), 0, abi.encodeCall(IERC20.transfer, (address(dao), DEMAND)));
        calls[1] = Action(alice, RATE - 1 ether, "");
        calls[2] = Action(address(solver), 0, abi.encodeCall(solver.sweep, (NATIVE, bob)));

        solver.trigger(plugin, _data(calls));

        assertEq(address(dao).balance, 0);
        assertEq(alice.balance, RATE - 1 ether);
        assertEq(bob.balance, 1 ether);
        assertEq(address(solver).balance, 0);
        assertEq(tokenB.balanceOf(address(dao)), DAO_B + DEMAND);
        assertEq(budget.available(), 0);
    }

    function test_NativeDemandPaidFromTriggerValue() public {
        plugin = _deployPlugin(budget, _chain(_deployOpenFill(budget, NATIVE), keep));
        Action[] memory calls = new Action[](2);
        calls[0] =
            Action(address(tokenA), 0, abi.encodeCall(IERC20.transferFrom, (address(dao), address(solver), RATE)));
        calls[1] = Action(address(dao), DEMAND, "");
        bytes[] memory data = _data(calls);
        vm.deal(address(this), DEMAND);

        solver.trigger{value: DEMAND}(plugin, data);

        assertEq(address(dao).balance, DEMAND);
        assertEq(address(solver).balance, 0);
        assertEq(address(plugin).balance, 0);
        assertEq(tokenA.balanceOf(address(solver)), RATE);
        assertEq(tokenA.allowance(address(dao), address(solver)), 0);
        assertEq(budget.available(), 0);
    }

    function test_RevertWhen_NativeUnderpaymentRestoresCallValue() public {
        plugin = _deployPlugin(budget, _chain(_deployOpenFill(budget, NATIVE), keep));
        Action[] memory calls = new Action[](2);
        calls[0] =
            Action(address(tokenA), 0, abi.encodeCall(IERC20.transferFrom, (address(dao), address(solver), RATE)));
        calls[1] = Action(address(dao), DEMAND - 1, "");
        bytes[] memory data = _data(calls);
        vm.deal(address(this), DEMAND);
        uint256 checkpoint = budget.baseTimestamp();

        vm.expectRevert(abi.encodeWithSelector(DAO.ActionFailed.selector, 3));
        solver.trigger{value: DEMAND}(plugin, data);

        assertEq(address(this).balance, DEMAND);
        assertEq(address(dao).balance, 0);
        assertEq(address(solver).balance, 0);
        _assertUnfilled(checkpoint);
    }

    function test_DirectCallbackRemainsPermissionless() public {
        Action[] memory calls = new Action[](1);
        calls[0] = Action(address(tokenB), 0, abi.encodeCall(IERC20.transfer, (alice, DEMAND)));

        vm.prank(bob);
        solver.fillOffer(tokenA, 0, tokenB, 0, abi.encode(calls));

        assertEq(tokenB.balanceOf(alice), DEMAND);
    }

    function test_RevertWhen_DirectCallFails() public {
        Action[] memory calls = new Action[](1);
        calls[0] = Action(address(tokenB), 0, abi.encodeCall(IERC20.transfer, (alice, DEMAND + 1)));

        vm.expectRevert("fillOffer: Call Failed");
        solver.fillOffer(tokenA, 0, tokenB, 0, abi.encode(calls));
    }

    function test_SweepRejectsFalseReturningToken() public {
        vm.mockCall(address(tokenB), abi.encodeCall(IERC20.transfer, (alice, DEMAND)), abi.encode(false));

        vm.expectRevert("SafeERC20: ERC20 operation did not succeed");
        solver.sweep(tokenB, alice);
    }

    function test_SweepAcceptsNoReturnToken() public {
        vm.mockCall(address(tokenB), abi.encodeCall(IERC20.transfer, (alice, DEMAND)), "");
        vm.expectCall(address(tokenB), abi.encodeCall(IERC20.transfer, (alice, DEMAND)));

        solver.sweep(tokenB, alice);
    }

    function test_RevertWhen_NativeSweepRecipientRejectsEth() public {
        vm.deal(address(solver), 1 ether);

        vm.expectRevert("Address: unable to send value, recipient may have reverted");
        solver.sweep(NATIVE, address(tokenA));

        assertEq(address(solver).balance, 1 ether);
    }

    function _calls(uint256 offered, uint256 demanded, address recipient)
        internal
        view
        returns (Action[] memory calls)
    {
        calls = new Action[](2);
        calls[0] =
            Action(address(tokenA), 0, abi.encodeCall(IERC20.transferFrom, (address(dao), address(solver), offered)));
        calls[1] = Action(address(tokenB), 0, abi.encodeCall(IERC20.transfer, (recipient, demanded)));
    }

    function _data(Action[] memory calls) internal view returns (bytes[] memory data) {
        data = new bytes[](plugin.nodes().length);
        data[0] = abi.encode(calls);
    }

    function _assertUnfilled(uint256 checkpoint) internal view {
        assertEq(tokenA.balanceOf(address(dao)), DAO_A);
        assertEq(tokenB.balanceOf(address(dao)), DAO_B);
        assertEq(tokenA.balanceOf(address(solver)), 0);
        assertEq(tokenB.balanceOf(address(solver)), DEMAND);
        assertEq(tokenA.allowance(address(dao), address(solver)), 0);
        assertEq(budget.available(), RATE);
        assertEq(budget.baseTimestamp(), checkpoint);
    }
}
