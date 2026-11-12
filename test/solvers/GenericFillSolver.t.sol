// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DAO} from "@aragon/osx/core/dao/DAO.sol";
import {Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import {DaoUnauthorized} from "@aragon/osx-commons-contracts/src/permission/auth/auth.sol";
import {CapitalTreePlugin} from "../../src/CapitalTreePlugin.sol";
import {StreamBudget} from "../../src/budgets/StreamBudget.sol";
import {OpenFillAction} from "../../src/actions/OpenFillAction.sol";
import {GenericFillSolver} from "../../src/solvers/GenericFillSolver.sol";
import {Node} from "../../src/lib/types.sol";
import {TRIGGER_PERMISSION_ID} from "../../src/lib/constants.sol";
import {Fixture} from "../helpers/Fixture.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";

contract GenericFillSolverTest is Fixture {
    StreamBudget internal budget;
    OpenFillAction internal action;
    CapitalTreePlugin internal plugin;
    GenericFillSolver internal solver;

    function setUp() public override {
        super.setUp();
        budget = _deployBudget(RATE, 0);
        action = _deployAction(budget);
        plugin = _deployPlugin(budget, _chain(action, keep));
        solver = new GenericFillSolver(address(this), plugin);
        tokenB.mint(address(solver), DEMAND);
        vm.warp(block.timestamp + EPOCH);
    }

    function test_ConstructorSetsAuthorizedAndPlugin() public view {
        assertEq(solver.authorized(), address(this));
        assertEq(address(solver.plugin()), address(plugin));
    }

    function testFuzz_FillPaysDaoClearsAllowanceAndCommitsStream(uint256 offered, uint128 extra) public {
        offered = bound(offered, 0, RATE);
        tokenB.mint(address(solver), extra);
        solver.trigger(_data(_calls(offered, DEMAND + extra, address(dao))));

        assertEq(tokenA.balanceOf(address(dao)), DAO_A - offered);
        assertEq(tokenB.balanceOf(address(dao)), DAO_B + DEMAND + extra);
        assertEq(tokenA.balanceOf(address(solver)), offered);
        assertEq(tokenB.balanceOf(address(solver)), 0);
        assertEq(tokenA.allowance(address(dao), address(solver)), 0);
        assertEq(_available(budget), 0);
        assertEq(budget.lastSeenBalance(), DAO_A - offered);
        assertEq(budget.baseTimestamp(), block.timestamp);
    }

    function test_FillRunsDownstreamBurnAndFeeNodes() public {
        plugin = _deployPlugin(budget, _splitToBurnAndFee(action));
        solver = new GenericFillSolver(address(this), plugin);
        tokenB.mint(address(solver), DEMAND);

        solver.trigger(_data(_calls(RATE, DEMAND, address(dao))));

        assertEq(tokenB.balanceOf(BURN), DEMAND * 95 / 100);
        assertEq(tokenB.balanceOf(fee), DEMAND * 5 / 100);
        assertEq(tokenB.balanceOf(address(dao)), DAO_B);
        assertEq(_available(budget), 0);
    }

    function test_CallbackDataAtNonRootNode() public {
        Node[] memory tree = new Node[](4);
        tree[0] = _branch(NO_ACTION, 1, 500_000, 2, 500_000);
        tree[1] = _leaf(_deployTransfer(alice));
        tree[2] = _then(action, 3);
        tree[3] = _leaf(keep);
        plugin = _deployPlugin(budget, tree);
        solver = new GenericFillSolver(address(this), plugin);
        tokenB.mint(address(solver), DEMAND);
        bytes[] memory data = new bytes[](4);
        data[2] = abi.encode(_calls(RATE / 2, DEMAND, address(dao)));

        solver.trigger(data);

        assertEq(tokenA.balanceOf(alice), RATE / 2);
        assertEq(tokenA.balanceOf(address(solver)), RATE / 2);
        assertEq(tokenB.balanceOf(address(dao)), DAO_B + DEMAND);
        assertEq(tokenA.allowance(address(dao), address(solver)), 0);
        assertEq(budget.lastSeenBalance(), DAO_A - RATE);
        assertEq(_available(budget), 0);
    }

    function test_MultipleOpenFillNodesKeepSeparatePayloads() public {
        Node[] memory tree = new Node[](5);
        tree[0] = _branch(NO_ACTION, 1, 400_000, 3, 600_000);
        tree[1] = _then(action, 2);
        tree[2] = _leaf(keep);
        tree[3] = _then(action, 4);
        tree[4] = _leaf(keep);
        plugin = _deployPlugin(budget, tree);
        solver = new GenericFillSolver(address(this), plugin);
        tokenB.mint(address(solver), DEMAND);
        tokenB.mint(address(solver), DEMAND);
        bytes[] memory data = new bytes[](5);
        data[1] = abi.encode(_calls(RATE * 4 / 10, DEMAND, address(dao)));
        data[3] = abi.encode(_calls(RATE * 6 / 10, DEMAND, address(dao)));

        solver.trigger(data);

        assertEq(tokenA.balanceOf(address(solver)), RATE);
        assertEq(tokenB.balanceOf(address(dao)), DAO_B + 2 * DEMAND);
        assertEq(tokenA.allowance(address(dao), address(solver)), 0);
        assertEq(budget.lastSeenBalance(), DAO_A - RATE);
        assertEq(_available(budget), 0);
    }

    function testFuzz_RevertWhen_UnderpaidRestoresBalancesAndStream(uint256 paid) public {
        paid = bound(paid, 0, DEMAND - 1);
        bytes[] memory data = _data(_calls(RATE, paid, address(dao)));
        uint256 checkpoint = budget.baseTimestamp();

        vm.expectRevert(abi.encodeWithSelector(OpenFillAction.DemandNotMet.selector, DAO_B + DEMAND, DAO_B + paid));
        solver.trigger(data);

        _assertUnfilled(checkpoint);
    }

    function testFuzz_RevertWhen_ACallbackCallFailsRollsBackEarlierCalls(uint128 excess) public {
        uint256 payment = DEMAND + uint256(excess) + 1;
        // The input pull succeeds, then paying more B than the solver owns fails.
        bytes[] memory data = _data(_calls(RATE, payment, address(dao)));
        uint256 checkpoint = budget.baseTimestamp();

        vm.expectRevert(abi.encodeWithSelector(DAO.ActionFailed.selector, 1));
        solver.trigger(data);

        _assertUnfilled(checkpoint);
    }

    function testFuzz_RevertWhen_StaleQuotePullsMoreThanTheOffer(uint128 excess) public {
        bytes[] memory data = _data(_calls(RATE + uint256(excess) + 1, DEMAND, address(dao)));
        uint256 checkpoint = budget.baseTimestamp();

        vm.expectRevert(abi.encodeWithSelector(DAO.ActionFailed.selector, 1));
        solver.trigger(data);

        _assertUnfilled(checkpoint);
    }

    function test_RevertWhen_PayloadOmitsLeafNode() public {
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encode(_calls(RATE, DEMAND, address(dao)));

        vm.expectRevert(abi.encodeWithSelector(CapitalTreePlugin.DataLengthMismatch.selector, 2, 1));
        solver.trigger(data);
    }

    function test_RevertWhen_CallbackContainsOuterArrayEncoding() public {
        bytes[] memory data = _data(_calls(RATE, DEMAND, address(dao)));
        data[0] = abi.encode(data);

        vm.expectRevert(abi.encodeWithSelector(DAO.ActionFailed.selector, 1));
        solver.trigger(data);
    }

    function test_RevertWhen_CallbackDataIsEmpty() public {
        // An empty node data array is valid for the plugin, but this solver needs an encoded Action[].
        vm.expectRevert(abi.encodeWithSelector(DAO.ActionFailed.selector, 1));
        solver.trigger(new bytes[](0));
    }

    function test_RevertWhen_DaoCallbackDataIsEmpty() public {
        vm.expectRevert();
        vm.prank(address(dao));
        solver.fillOffer(tokenA, RATE, tokenB, DEMAND, "");
    }

    function test_DaoCallbackAcceptsEncodedEmptyBatchAsNoOp() public {
        bytes memory data = abi.encode(new Action[](0));
        vm.prank(address(dao));
        solver.fillOffer(tokenA, RATE, tokenB, DEMAND, data);
        _assertUnfilled(budget.baseTimestamp());
    }

    function test_RevertWhen_EncodedEmptyBatchDoesNotPayDao() public {
        bytes[] memory data = _data(new Action[](0));
        uint256 checkpoint = budget.baseTimestamp();
        // The solver accepts an empty batch, but OpenFill still requires payment.
        vm.expectRevert(abi.encodeWithSelector(OpenFillAction.DemandNotMet.selector, DAO_B + DEMAND, DAO_B));
        solver.trigger(data);
        _assertUnfilled(checkpoint);
    }

    function test_RevertWhen_BatchReentersThePlugin() public {
        Action[] memory calls = new Action[](1);
        calls[0] = Action(address(plugin), 0, abi.encodeCall(plugin.trigger, ("", new bytes[](0))));
        bytes[] memory data = _data(calls);
        uint256 checkpoint = budget.baseTimestamp();

        vm.expectRevert(abi.encodeWithSelector(DAO.ActionFailed.selector, 1));
        solver.trigger(data);

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
        solver.trigger(data);
    }

    function test_RevertWhen_PluginPaused() public {
        vm.prank(manager);
        plugin.pause();
        bytes[] memory data = _data(_calls(RATE, DEMAND, address(dao)));

        vm.expectRevert("Pausable: paused");
        solver.trigger(data);
    }

    function testFuzz_RevertWhen_TriggerReceivesEth(uint128 value) public {
        vm.assume(value > 0);
        bytes memory data = abi.encodeCall(solver.trigger, (_data(_calls(RATE, DEMAND, address(dao)))));
        vm.deal(address(this), value);
        (bool ok,) = address(solver).call{value: value}(data);
        assertFalse(ok);
        assertEq(address(this).balance, value);
        assertEq(address(solver).balance, 0);
        _assertUnfilled(budget.baseTimestamp());
    }

    function testFuzz_RevertWhen_DaoCallbackReceivesEth(uint128 value) public {
        vm.assume(value > 0);
        bytes memory data = abi.encodeCall(solver.fillOffer, (tokenA, 0, tokenB, 0, abi.encode(new Action[](0))));
        vm.deal(address(dao), value);
        vm.prank(address(dao));
        (bool ok,) = address(solver).call{value: value}(data);
        assertFalse(ok);
        assertEq(address(dao).balance, value);
        assertEq(address(solver).balance, 0);
    }

    function testFuzz_BatchIgnoresActionValueEvenWithForcedBalance(uint128 value, uint256 amount) public {
        amount = bound(amount, 1, DEMAND);
        vm.deal(address(solver), value);
        Action[] memory calls = new Action[](2);
        calls[0] = Action(address(tokenB), 0, abi.encodeCall(IERC20.transfer, (alice, amount)));
        calls[1] = Action(bob, value, "");
        bytes memory data = abi.encode(calls);
        vm.prank(address(dao));
        solver.fillOffer(tokenA, 0, tokenB, 0, data);
        assertEq(address(solver).balance, value);
        assertEq(bob.balance, 0);
        assertEq(tokenB.balanceOf(alice), amount);
        assertEq(tokenB.balanceOf(address(solver)), DEMAND - amount);
    }

    function testFuzz_RevertWhen_PlainEthTransfer(uint128 value) public {
        vm.assume(value > 0);
        vm.deal(address(this), value);
        (bool ok,) = address(solver).call{value: value}("");
        assertFalse(ok);
        assertEq(address(solver).balance, 0);
    }

    function test_RevertWhen_DirectCallbackIsNotFromDao() public {
        bytes memory data = abi.encode(_calls(RATE, DEMAND, address(dao)));
        vm.expectRevert(GenericFillSolver.Unauthorized.selector);
        vm.prank(bob);
        solver.fillOffer(tokenA, RATE, tokenB, DEMAND, data);

        // The plugin coordinates execution, but the DAO is the callback sender.
        vm.expectRevert(GenericFillSolver.Unauthorized.selector);
        vm.prank(address(plugin));
        solver.fillOffer(tokenA, RATE, tokenB, DEMAND, data);

        vm.expectRevert(GenericFillSolver.Unauthorized.selector);
        solver.fillOffer(tokenA, RATE, tokenB, DEMAND, data);
        _assertUnfilled(budget.baseTimestamp());
    }

    function testFuzz_RevertWhen_DaoCallbackCallFailsReportsIndexAndRollsBack(uint8 prefix) public {
        prefix = uint8(bound(prefix, 1, 16));
        Action[] memory calls = new Action[](uint256(prefix) + 1);
        for (uint256 i; i < prefix; ++i) {
            calls[i] = Action(address(tokenB), 0, abi.encodeCall(IERC20.transfer, (alice, 1)));
        }
        calls[prefix] = Action(address(tokenB), 0, abi.encodeCall(IERC20.transfer, (alice, DEMAND)));
        bytes memory data = abi.encode(calls);

        vm.expectRevert(abi.encodeWithSelector(GenericFillSolver.CallFailed.selector, uint256(prefix)));
        vm.prank(address(dao));
        solver.fillOffer(tokenA, 0, tokenB, 0, data);

        assertEq(tokenB.balanceOf(alice), 0);
        assertEq(tokenB.balanceOf(address(solver)), DEMAND);
    }

    function testFuzz_RevertWhen_UnauthorizedTrigger(address caller) public {
        vm.assume(caller != address(this) && caller != address(solver));
        bytes[] memory data = _data(_calls(RATE, DEMAND, address(dao)));
        vm.expectRevert(GenericFillSolver.Unauthorized.selector);
        vm.prank(caller);
        solver.trigger(data);
        _assertUnfilled(budget.baseTimestamp());
    }

    function testFuzz_RevertWhen_UnauthorizedSweep(address caller) public {
        vm.assume(caller != address(this) && caller != address(solver));
        vm.expectRevert(GenericFillSolver.Unauthorized.selector);
        vm.prank(caller);
        solver.sweep(tokenB, bob);
        assertEq(tokenB.balanceOf(address(solver)), DEMAND);
    }

    function test_AuthorizedCallerSweepsTokens() public {
        solver.sweep(tokenB, alice);
        assertEq(tokenB.balanceOf(alice), DEMAND);
        assertEq(tokenB.balanceOf(address(solver)), 0);
    }

    function testFuzz_SweepArbitraryTokenAndRecipient(address recipient, uint128 amount, uint128 existing) public {
        vm.assume(recipient != address(0) && recipient != address(solver));
        // A fresh token outside the flow's offered/demanded pair.
        ERC20Mock other = new ERC20Mock("Other", "OTHER");
        other.mint(address(solver), uint256(amount));
        other.mint(recipient, uint256(existing));

        solver.sweep(other, recipient);

        assertEq(other.balanceOf(address(solver)), 0);
        assertEq(other.balanceOf(recipient), uint256(existing) + uint256(amount));
        assertEq(tokenB.balanceOf(address(solver)), DEMAND, "other tokens untouched");
    }

    function testFuzz_PermissionedBatchSweepsErc20Surplus(uint128 surplus) public {
        tokenB.mint(address(solver), surplus);
        Action[] memory calls = new Action[](3);
        Action[] memory fill = _calls(RATE, DEMAND, address(dao));
        calls[0] = fill[0];
        calls[1] = fill[1];
        calls[2] = Action(address(solver), 0, abi.encodeCall(solver.sweep, (tokenB, alice)));

        solver.trigger(_data(calls));

        assertEq(tokenB.balanceOf(address(dao)), DAO_B + DEMAND);
        assertEq(tokenB.balanceOf(alice), surplus);
        assertEq(tokenB.balanceOf(address(solver)), 0);
        assertEq(_available(budget), 0);
    }

    function test_RevertWhen_AuthorizedAddressIsZero() public {
        vm.expectRevert(GenericFillSolver.InvalidAuthorized.selector);
        new GenericFillSolver(address(0), plugin);
    }

    function test_WhitelistedSolverDoesNotExposeTriggerToOtherCallers() public {
        dao.revoke(address(plugin), ANY_ADDR, TRIGGER_PERMISSION_ID);
        dao.grant(address(plugin), address(solver), TRIGGER_PERMISSION_ID);
        bytes[] memory data = _data(_calls(RATE, DEMAND, address(dao)));

        vm.expectRevert(GenericFillSolver.Unauthorized.selector);
        vm.prank(bob);
        solver.trigger(data);
        _assertUnfilled(budget.baseTimestamp());

        solver.trigger(data);
        assertEq(tokenB.balanceOf(address(dao)), DAO_B + DEMAND);
        assertEq(_available(budget), 0);
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
        assertEq(_available(budget), RATE);
        assertEq(budget.baseTimestamp(), checkpoint);
    }
}
