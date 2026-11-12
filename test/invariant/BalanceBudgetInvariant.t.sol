// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console2} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {BalanceBudget} from "../../src/budgets/BalanceBudget.sol";
import {CapitalTreePlugin} from "../../src/CapitalTreePlugin.sol";
import {INodeAction} from "../../src/interfaces/INodeAction.sol";
import {Fixture} from "../helpers/Fixture.sol";
import {BalanceBudgetHandler} from "./handlers/BalanceBudgetHandler.sol";

/// @notice Random BalanceBudget flows fuzzed by `BalanceBudgetHandler`, checked against its model
contract BalanceBudgetInvariantTest is Fixture {
    BalanceBudgetHandler internal handler;
    BalanceBudget internal budget;
    CapitalTreePlugin internal plugin;

    function setUp() public override {
        super.setUp();
        budget = _deployBalanceBudget(tokenA);

        // A placeholder flow: the handler installs a random tree right away
        plugin = _deployPlugin(budget, _one(keep));

        address[] memory _recipients = new address[](3);
        (_recipients[0], _recipients[1], _recipients[2]) = (alice, bob, carol);

        INodeAction[] memory _transfers = new INodeAction[](3);
        for (uint256 r; r < 3; ++r) {
            _transfers[r] = _deployTransfer(_recipients[r]);
        }

        handler = new BalanceBudgetHandler(
            plugin, budget, tokenA, dao, address(this), manager, _recipients, _transfers, burn, keep, toBeneficiary
        );
        handler.rebuildTree(0);

        bytes4[] memory _selectors = new bytes4[](3);
        _selectors[0] = BalanceBudgetHandler.trigger.selector;
        _selectors[1] = BalanceBudgetHandler.rebuildTree.selector;
        _selectors[2] = BalanceBudgetHandler.setWeights.selector;
        targetSelector(StdInvariant.FuzzSelector({addr: address(handler), selectors: _selectors}));
        targetContract(address(handler));
    }

    /// Each recipient got exactly what the model's walk of the trees gave them
    function invariant_RecipientsMatchModel() public view {
        for (uint256 r; r < handler.recipientCount(); ++r) {
            assertEq(tokenA.balanceOf(handler.recipientAt(r)), handler.received(r));
        }
    }

    /// Each beneficiary got exactly what the Beneficiary nodes that named it were given
    function invariant_BeneficiariesMatchModel() public view {
        for (uint256 b; b < handler.beneficiaryCount(); ++b) {
            assertEq(tokenA.balanceOf(handler.beneficiaryAt(b)), handler.receivedByBeneficiary(b));
        }
    }

    /// The DAO holds exactly what the model says: kept shares, plus deposits, minus outflows
    function invariant_DaoBalanceMatchesModel() public view {
        assertEq(tokenA.balanceOf(address(dao)), handler.ghostDao());
    }

    /// Only burn leaves burn, and only their shares
    function invariant_SupplyOnlyDropsByBurnShare() public view {
        assertEq(tokenA.totalSupply(), DAO_A + handler.ghostDeposited() - handler.ghostBurned());
        console2.log(handler.ghostBurned());
    }

    /// Every A ever minted is accounted for
    function invariant_Conservation() public view {
        assertEq(
            tokenA.balanceOf(address(dao)) + handler.ghostReceivedTotal() + handler.ghostBurned()
                + handler.ghostOutflow(),
            DAO_A + handler.ghostDeposited()
        );
    }

    /// The flow never touches another token
    function invariant_OtherTokenUntouched() public view {
        assertEq(tokenB.balanceOf(address(dao)), DAO_B);
    }

    /// The budget is always the DAO's live balance
    function invariant_AvailableIsDaoBalance() public view {
        assertEq(_available(budget), tokenA.balanceOf(address(dao)));
    }

    /// The installed flow is the model's tree: triggers never reconfigure it
    function invariant_FlowMatchesModel() public view {
        assertEq(address(plugin.budget()), address(budget));
        assertEq(plugin.nodes().length, handler.nodeCount());
    }

    /// Call summary (run with -vv): checks the fuzzer reaches successful triggers, not only reverts
    function afterInvariant() external view {
        console2.log("triggers", handler.triggers());
        console2.log("expected reverts", handler.expectedReverts());
        console2.log("rebuilds", handler.rebuilds());
    }
}
