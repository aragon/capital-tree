// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BalanceBudget} from "../../src/budgets/BalanceBudget.sol";
import {OpenFillAction} from "../../src/actions/OpenFillAction.sol";
import {BaseHandler} from "./base/BaseHandler.sol";
import {BaseInvariant} from "./base/BaseInvariant.sol";
import {BalanceBudgetHandler} from "./handlers/BalanceBudgetHandler.sol";

contract BalanceBudgetInvariantTest is BaseInvariant {
    function setUp() public override {
        super.setUp();
        budget = _deployBalanceBudget(tokenA);
        // A placeholder flow: the handler installs a random tree right away
        plugin = _deployPlugin(budget, _one(keep));
        handler = new BalanceBudgetHandler(_deps(OpenFillAction(address(0))));

        bytes4[] memory _selectors = new bytes4[](3);
        _selectors[0] = BalanceBudgetHandler.trigger.selector;
        _selectors[1] = BaseHandler.rebuildTree.selector;
        _selectors[2] = BaseHandler.setWeights.selector;
        _target(_selectors);
    }

    /// The budget is always the DAO's live balance
    function invariant_AvailableIsDaoBalance() public view {
        assertEq(_available(budget), tokenA.balanceOf(address(dao)));
    }
}
