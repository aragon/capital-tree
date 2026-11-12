// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Fixture} from "./helpers/Fixture.sol";
import {StreamBudget} from "../src/budgets/StreamBudget.sol";
import {OpenFillAction} from "../src/actions/OpenFillAction.sol";
import {Node} from "../src/lib/types.sol";
import {MockFiller} from "./mocks/MockFiller.sol";

/// @notice Fills after stream-cap and demand changes, including a capped stream shared with grants.
contract OpenFillStreamCapTest is Fixture {
    StreamBudget internal budget;
    OpenFillAction internal action;
    MockFiller internal filler;

    function setUp() public override {
        super.setUp();
        budget = _deployBudget(RATE, STREAM_CAP);
        action = _deployAction(budget);
        filler = new MockFiller(_deployPlugin(budget, _chain(action, keep)));
        tokenB.mint(address(filler), 10 * DEMAND);
    }

    /// A finite cap increase resumes growth from the old cap, not the elapsed-time backlog.
    function testFuzz_RaisedCapDoesNotReleaseBacklogIntoFill(uint256 _newCap, uint32 _elapsed) public {
        _newCap = bound(_newCap, STREAM_CAP + 1, DAO_A * 2);
        _elapsed = uint32(bound(_elapsed, 0, 20 * EPOCH));
        vm.warp(block.timestamp + 100 * EPOCH);
        assertEq(_available(budget), STREAM_CAP);
        vm.prank(manager);
        budget.setMaxBudget(_newCap);
        assertEq(_available(budget), STREAM_CAP);
        vm.warp(block.timestamp + _elapsed);
        filler.fillWithoutData();
        uint256 _expected = STREAM_CAP + RATE * _elapsed / EPOCH;
        if (_expected > _newCap) _expected = _newCap;
        if (_expected > DAO_A) _expected = DAO_A;
        assertEq(tokenA.balanceOf(address(filler)), _expected);
        assertEq(tokenB.balanceOf(address(dao)), DAO_B + DEMAND);
        assertEq(_available(budget), 0);
        assertEq(tokenA.allowance(address(dao), address(filler)), 0);
    }

    /// Lowering the cap below the accrued amount limits the offer in the same block.
    function testFuzz_LoweredCapImmediatelyLimitsFill(uint256 _newCap) public {
        _newCap = bound(_newCap, 1, STREAM_CAP - 1);
        vm.warp(block.timestamp + 100 * EPOCH);
        vm.prank(manager);
        budget.setMaxBudget(_newCap);
        filler.fillWithoutData();
        assertEq(tokenA.balanceOf(address(filler)), _newCap);
        assertEq(tokenB.balanceOf(address(dao)), DAO_B + DEMAND);
        assertEq(_available(budget), 0);
    }

    /// Changing demand changes the return at the cap, without introducing another offer limit.
    function testFuzz_NewDemandRestartsThenUsesTheSameStreamCap(uint256 _newDemand) public {
        _newDemand = bound(_newDemand, 1, 10 * DEMAND);
        vm.warp(block.timestamp + 100 * EPOCH);
        vm.prank(manager);
        action.setDemandPerFill(_newDemand);
        assertEq(_available(budget), 0);
        vm.warp(block.timestamp + 100 * EPOCH);
        filler.fillWithoutData();
        assertEq(tokenA.balanceOf(address(filler)), STREAM_CAP);
        assertEq(tokenB.balanceOf(address(dao)), DAO_B + _newDemand);
        assertEq(_available(budget), 0);
    }

    /// Once capped, the auction and grant divide the cap rather than the uncapped accrual.
    function testFuzz_CappedSplitLimitsTheAuctionToItsShare(uint32 _auctionWeight) public {
        _auctionWeight = uint32(bound(_auctionWeight, 1, 999_999));
        Node[] memory _tree = new Node[](4);
        _tree[0] = _branch(NO_ACTION, 1, _auctionWeight, 2, 1_000_000 - _auctionWeight);
        _tree[1] = _then(action, 3);
        _tree[2] = _leaf(_deployTransfer(alice));
        _tree[3] = _leaf(keep);
        MockFiller _splitFiller = new MockFiller(_deployPlugin(budget, _tree));
        tokenB.mint(address(_splitFiller), DEMAND);
        vm.warp(block.timestamp + 100 * EPOCH);
        _splitFiller.fillWithoutData();
        assertEq(tokenA.balanceOf(address(_splitFiller)), STREAM_CAP * _auctionWeight / 1_000_000);
        assertEq(tokenA.balanceOf(alice), STREAM_CAP - STREAM_CAP * _auctionWeight / 1_000_000);
        assertEq(tokenA.balanceOf(address(dao)), DAO_A - STREAM_CAP);
        assertEq(_available(budget), 0);
    }

    /// Recipe validation does not prevent a manager from disabling the cap after deployment.
    function test_ManagerCanRemoveCapAfterDeployment() public {
        vm.warp(block.timestamp + 100 * EPOCH);
        vm.prank(manager);
        budget.setMaxBudget(0);
        assertEq(_available(budget), STREAM_CAP);
        vm.warp(block.timestamp + 100 * EPOCH);
        filler.fillWithoutData();
        assertEq(tokenA.balanceOf(address(filler)), DAO_A);
        assertEq(tokenB.balanceOf(address(dao)), DAO_B + DEMAND);
    }
}
