// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Fixture} from "./helpers/Fixture.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import {CapitalTreePlugin} from "../src/CapitalTreePlugin.sol";
import {StreamBudget} from "../src/budgets/StreamBudget.sol";
import {BalanceBudget} from "../src/budgets/BalanceBudget.sol";
import {OpenFillAction} from "../src/actions/OpenFillAction.sol";
import {GenericFillSolver} from "../src/solvers/GenericFillSolver.sol";
import {WeightSplitter} from "../src/splitters/WeightSplitter.sol";
import {Node} from "../src/lib/types.sol";
import {SET_SETTINGS_PERMISSION_ID} from "../src/lib/constants.sol";

/// @dev Anyone can release the receivable, but only the DAO can receive it.
contract ReviewDaoReceivable {
    IERC20 immutable token;
    address immutable beneficiary;

    constructor(IERC20 _token, address _beneficiary) {
        token = _token;
        beneficiary = _beneficiary;
    }

    function claim() external {
        token.transfer(beneficiary, token.balanceOf(address(this)));
    }
}

/// @notice Executable checks of the supplied 2026-11-11 manual review. No production changes.
contract SecurityReviewTest is Fixture {
    function _fillCalls(uint256 offered, uint256 paid) internal view returns (Action[] memory calls) {
        calls = new Action[](2);
        calls[0] =
            Action(address(tokenA), 0, abi.encodeCall(IERC20.transferFrom, (address(dao), address(this), offered)));
        calls[1] = Action(address(tokenB), 0, abi.encodeCall(IERC20.transfer, (address(dao), paid)));
    }

    function test_M01_DaoReceivableFundsFillAndEntireSurplusIsForwarded() public {
        StreamBudget budget = _deployBudget(RATE, STREAM_CAP);
        Node[] memory tree = _chain(_deployAction(budget), _deployTransfer(alice));
        tree[0].forwardSurplus = true;
        CapitalTreePlugin plugin = _deployPlugin(budget, tree);
        GenericFillSolver solver = new GenericFillSolver(address(this), plugin);
        ReviewDaoReceivable receivable = new ReviewDaoReceivable(tokenB, address(dao));
        tokenB.mint(address(receivable), 3 * DEMAND);
        Action[] memory calls = _fillCalls(RATE, 0);
        calls[1] = Action(address(receivable), 0, abi.encodeCall(ReviewDaoReceivable.claim, ()));
        bytes[] memory data = new bytes[](2);
        data[0] = abi.encode(calls);
        vm.warp(block.timestamp + EPOCH);
        assertEq(tokenB.balanceOf(address(solver)), 0);
        solver.trigger(data);
        assertEq(tokenA.balanceOf(address(this)), RATE);
        assertEq(tokenB.balanceOf(address(solver)), 0);
        assertEq(tokenB.balanceOf(address(receivable)), 0);
        assertEq(tokenB.balanceOf(alice), 3 * DEMAND);
        assertEq(tokenB.balanceOf(address(dao)), DAO_B);
    }

    function test_M03_ManagerCanSellEntireTreasuryForDust() public {
        StreamBudget budget = _deployBudget(RATE, STREAM_CAP);
        OpenFillAction action = _deployAction(budget);
        GenericFillSolver solver = new GenericFillSolver(address(this), _deployPlugin(budget, _chain(action, keep)));
        vm.startPrank(manager);
        budget.setAmountPerEpoch(type(uint128).max);
        budget.setMaxBudget(0);
        action.setDemandPerFill(20);
        vm.stopPrank();
        tokenB.mint(address(solver), 20);
        vm.warp(block.timestamp + 1);
        bytes[] memory data = new bytes[](2);
        data[0] = abi.encode(_fillCalls(DAO_A, 20));
        solver.trigger(data);
        assertEq(tokenA.balanceOf(address(dao)), 0);
        assertEq(tokenA.balanceOf(address(this)), DAO_A);
        assertEq(tokenB.balanceOf(address(dao)), DAO_B + 20);
    }

    function test_L01_WeightsRepriceAccruedAuctionWithoutCheckpoint() public {
        StreamBudget budget = _deployBudget(RATE, STREAM_CAP);
        OpenFillAction action = _deployAction(budget);
        Node[] memory tree = new Node[](4);
        tree[0] = _branch(NO_ACTION, 1, 500_000, 2, 500_000);
        tree[1] = _then(action, 3);
        tree[2] = _leaf(_deployTransfer(alice));
        tree[3] = _leaf(keep);
        GenericFillSolver solver = new GenericFillSolver(address(this), _deployPlugin(budget, tree));
        dao.grant(address(tree[0].splitter), manager, SET_SETTINGS_PERMISSION_ID);
        tokenB.mint(address(solver), DEMAND);
        vm.warp(block.timestamp + EPOCH);
        uint256 checkpoint = budget.baseTimestamp();
        uint32[] memory weights = new uint32[](2);
        (weights[0], weights[1]) = (900_000, 100_000);
        vm.prank(manager);
        WeightSplitter(address(tree[0].splitter)).setWeights(weights);
        assertEq(budget.baseTimestamp(), checkpoint);
        assertEq(_available(budget), RATE);
        bytes[] memory data = new bytes[](4);
        data[1] = abi.encode(_fillCalls(RATE * 9 / 10, DEMAND));
        solver.trigger(data);
        assertEq(tokenA.balanceOf(address(this)), RATE * 9 / 10);
        assertEq(tokenA.balanceOf(alice), RATE / 10);
    }

    function test_L03_DaoExecutionCanSweepIdleSolverWithoutOperator() public {
        StreamBudget budget = _deployBudget(RATE, STREAM_CAP);
        GenericFillSolver solver =
            new GenericFillSolver(bob, _deployPlugin(budget, _chain(_deployAction(budget), keep)));
        tokenB.mint(address(solver), DEMAND);
        Action[] memory callback = new Action[](1);
        callback[0] = Action(address(tokenB), 0, abi.encodeCall(IERC20.transfer, (alice, DEMAND)));
        Action[] memory execution = new Action[](1);
        execution[0] = Action(
            address(solver),
            0,
            abi.encodeCall(GenericFillSolver.fillOffer, (tokenA, 0, tokenB, 0, abi.encode(callback)))
        );
        dao.grant(address(dao), address(this), dao.EXECUTE_PERMISSION_ID());
        dao.execute(bytes32(0), execution, 0);
        assertEq(tokenB.balanceOf(alice), DEMAND);
        assertEq(tokenB.balanceOf(address(solver)), 0);
    }

    function test_L04_BalanceBudgetFillsButDemandSetterReverts() public {
        BalanceBudget budget = _deployBalanceBudget(tokenA);
        OpenFillAction action = _deployOpenFill(StreamBudget(address(budget)), tokenB);
        GenericFillSolver solver = new GenericFillSolver(address(this), _deployPlugin(budget, _chain(action, keep)));
        tokenB.mint(address(solver), DEMAND);
        bytes[] memory data = new bytes[](2);
        data[0] = abi.encode(_fillCalls(DAO_A, DEMAND));
        solver.trigger(data);
        vm.prank(manager);
        vm.expectRevert();
        action.setDemandPerFill(20);
        assertEq(action.demandPerFill(), DEMAND);
    }

    function test_L04_SameInputOutputCanFillIfInputPlusDemandIsReturned() public {
        StreamBudget budget = _deployBudget(RATE, STREAM_CAP);
        OpenFillAction first = _deployAction(budget);
        OpenFillAction second = _deployAction(budget);
        GenericFillSolver solver =
            new GenericFillSolver(address(this), _deployPlugin(budget, _chain(first, second, keep)));
        tokenB.mint(address(solver), 2 * DEMAND);
        bytes[] memory data = new bytes[](3);
        data[0] = abi.encode(_fillCalls(RATE, DEMAND));
        Action[] memory calls = new Action[](2);
        calls[0] =
            Action(address(tokenB), 0, abi.encodeCall(IERC20.transferFrom, (address(dao), address(solver), DEMAND)));
        calls[1] = Action(address(tokenB), 0, abi.encodeCall(IERC20.transfer, (address(dao), 2 * DEMAND)));
        data[1] = abi.encode(calls);
        vm.warp(block.timestamp + EPOCH);
        solver.trigger(data);
        assertEq(tokenB.balanceOf(address(dao)), DAO_B + 2 * DEMAND);
        assertEq(tokenB.balanceOf(address(solver)), 0);
    }
}
