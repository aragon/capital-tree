// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {FundedStreamBudget} from "../../src/budgets/FundedStreamBudget.sol";
import {OpenFillAction} from "../../src/actions/OpenFillAction.sol";
import {CapitalPipelinePlugin} from "../../src/CapitalPipelinePlugin.sol";
import {Node} from "../../src/lib/types.sol";
import {Fixture} from "../helpers/Fixture.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockFiller} from "../mocks/MockFiller.sol";

/// @notice Random fills, deposits, syncs and manager tweaks. No call may revert.
/// @dev Read anything a bound needs before `vm.prank`: the prank applies to the very next call.
contract Handler is Test {
    FundedStreamBudget internal budget;
    OpenFillAction internal action;
    MockFiller internal filler;
    ERC20Mock internal tokenA;
    address internal dao;
    address internal manager;

    constructor(
        FundedStreamBudget _budget,
        OpenFillAction _action,
        MockFiller _filler,
        ERC20Mock _tokenA,
        address _dao,
        address _manager
    ) {
        (budget, action, filler, tokenA, dao, manager) = (_budget, _action, _filler, _tokenA, _dao, _manager);
    }

    function warp(uint256 _seconds) external {
        vm.warp(block.timestamp + bound(_seconds, 0, 30 days));
    }

    function fill() external {
        if (budget.available() == 0) return; // nothing on offer: a trigger would revert by design
        filler.fillWithoutData();
    }

    function overpay(uint256 _extra) external {
        filler.setFillDelta(int256(bound(_extra, 0, 1_000 ether)));
    }

    function deposit(uint256 _amount) external {
        tokenA.mint(dao, bound(_amount, 0, 1_000 ether));
    }

    function sync() external {
        budget.sync();
    }

    function setAmountPerEpoch(uint256 _rate) external {
        vm.prank(manager);
        budget.setAmountPerEpoch(bound(_rate, 0, 1_000 ether));
    }

    function setMaxBudget(uint256 _max) external {
        vm.prank(manager);
        budget.setMaxBudget(bound(_max, 0, 1_000 ether));
    }

    function setDemandPerFill(uint256 _demand) external {
        // At least 20 wei so the 5% branch is never empty
        vm.prank(manager);
        action.setDemandPerFill(bound(_demand, 20, 2_000_000 ether));
    }
}

contract PipelineInvariantTest is Fixture {
    MockFiller internal filler;

    function setUp() public override {
        super.setUp();
        FundedStreamBudget _budget = _deployBudget(RATE, 0);
        OpenFillAction _action = _deployAction(_budget);
        // Forwarding the surplus, so whatever the filler overpays is split too
        Node[] memory _tree = _splitToBurnAndFee(_action);
        _tree[0].forwardSurplus = true;
        CapitalPipelinePlugin _plugin = _deployPlugin(_budget, _tree);

        filler = new MockFiller(_plugin);
        tokenB.mint(address(filler), type(uint128).max);

        targetContract(address(new Handler(_budget, _action, filler, tokenA, address(dao), manager)));
    }

    function invariant_DaoNeverSpendsItsPreexistingB() public view {
        assertEq(tokenB.balanceOf(address(dao)), DAO_B);
    }

    function invariant_ProceedsAreSplitExactly() public view {
        assertEq(tokenB.balanceOf(BURN) + tokenB.balanceOf(fee), filler.totalDelivered());
    }

    function invariant_NoApprovalSurvives() public view {
        assertEq(tokenA.allowance(address(dao), address(filler)), 0);
    }
}
