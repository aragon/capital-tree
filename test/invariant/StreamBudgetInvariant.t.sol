// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {StreamBudget} from "../../src/budgets/StreamBudget.sol";
import {OpenFillAction} from "../../src/actions/OpenFillAction.sol";
import {BaseHandler} from "./base/BaseHandler.sol";
import {BaseInvariant} from "./base/BaseInvariant.sol";
import {StreamBudgetHandler} from "./handlers/StreamBudgetHandler.sol";

/// @notice Random StreamBudget flows with OpenFill nodes, fuzzed by `StreamBudgetHandler`
contract StreamBudgetInvariantTest is BaseInvariant {
    StreamBudget internal stream;

    function setUp() public override {
        super.setUp();
        stream = _deployBudget(RATE, STREAM_CAP);
        budget = stream;
        OpenFillAction _openFill = _deployAction(stream);
        // A placeholder flow: the handler installs a random tree right away
        plugin = _deployPlugin(budget, _one(keep));
        handler = new StreamBudgetHandler(_deps(_openFill));

        bytes4[] memory _selectors = new bytes4[](9);
        _selectors[0] = StreamBudgetHandler.trigger.selector;
        _selectors[1] = BaseHandler.rebuildTree.selector;
        _selectors[2] = BaseHandler.setWeights.selector;
        _selectors[3] = StreamBudgetHandler.warp.selector;
        _selectors[4] = StreamBudgetHandler.deposit.selector;
        _selectors[5] = StreamBudgetHandler.sync.selector;
        _selectors[6] = StreamBudgetHandler.setMaxBudget.selector;
        _selectors[7] = StreamBudgetHandler.setRate.selector;
        _selectors[8] = StreamBudgetHandler.setDemandPerFill.selector;
        _target(_selectors);
    }

    /// The amount never exceeds the balance last recorded, the live balance, or the cap
    function invariant_StreamBounds() public view {
        uint256 _amount = _available(stream);
        assertLe(_amount, stream.lastSeenBalance(), "above the recorded balance");
        assertLe(_amount, tokenA.balanceOf(address(dao)), "above the dao balance");
        if (stream.maxBudget() != 0) assertLe(_amount, stream.maxBudget(), "above the cap");
    }

    /// The filler holds exactly the A it was offered
    function invariant_FillerHoldsWhatItWasOffered() public view {
        assertEq(tokenA.balanceOf(address(handler)), handler.ghostToFiller());
    }

    /// No approval to the filler outlives a fill
    function invariant_NoApprovalSurvives() public view {
        assertEq(tokenA.allowance(address(dao), address(handler)), 0);
    }
}
