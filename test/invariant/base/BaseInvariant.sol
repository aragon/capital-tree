// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console2} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {CapitalTreePlugin} from "../../../src/CapitalTreePlugin.sol";
import {OpenFillAction} from "../../../src/actions/OpenFillAction.sol";
import {IBudget} from "../../../src/interfaces/IBudget.sol";
import {INodeAction} from "../../../src/interfaces/INodeAction.sol";
import {Fixture} from "../../helpers/Fixture.sol";
import {ERC20Mock} from "../../mocks/ERC20Mock.sol";
import {BaseHandler} from "./BaseHandler.sol";

/// @notice The invariants every flow must keep, whatever its budget, checked for both tokens
abstract contract BaseInvariant is Fixture {
    BaseHandler internal handler;
    CapitalTreePlugin internal plugin;
    IBudget internal budget;

    /// @dev What a handler needs: alice, bob and carol as Transfer recipients, the fixture's leaves
    function _deps(OpenFillAction _openFill) internal returns (BaseHandler.Deps memory _d) {
        _d.recipients = new address[](3);
        (_d.recipients[0], _d.recipients[1], _d.recipients[2]) = (alice, bob, carol);
        _d.transfers = new INodeAction[](3);
        for (uint256 r; r < 3; ++r) {
            _d.transfers[r] = _deployTransfer(_d.recipients[r]);
        }
        (_d.dao, _d.root, _d.manager, _d.plugin, _d.budget) = (dao, address(this), manager, plugin, budget);
        (_d.tokenA, _d.tokenB) = (tokenA, tokenB);
        (_d.burn, _d.keep, _d.toBeneficiary, _d.openFill) = (burn, keep, toBeneficiary, _openFill);
    }

    /// @dev Fuzzes only `_selectors` on the handler, after installing a first random tree
    function _target(bytes4[] memory _selectors) internal {
        handler.rebuildTree(0);
        targetSelector(StdInvariant.FuzzSelector({addr: address(handler), selectors: _selectors}));
        targetContract(address(handler));
    }

    /// Each recipient got exactly what the model's walk of the trees gave them
    function invariant_RecipientsMatchModel() public view {
        for (uint256 t; t < 2; ++t) {
            for (uint256 r; r < handler.recipientCount(); ++r) {
                assertEq(_token(t).balanceOf(handler.recipientAt(r)), handler.receivedByRecipient(t, r), "recipient");
            }
        }
    }

    /// Each beneficiary got exactly what the Beneficiary nodes that named it were given
    function invariant_BeneficiariesMatchModel() public view {
        for (uint256 t; t < 2; ++t) {
            for (uint256 b; b < handler.beneficiaryCount(); ++b) {
                assertEq(_token(t).balanceOf(handler.beneficiaryAt(b)), handler.receivedByBeneficiary(t, b), "beneficiary");
            }
        }
    }

    /// The DAO holds exactly what the model says
    function invariant_DaoBalanceMatchesModel() public view {
        for (uint256 t; t < 2; ++t) {
            assertEq(_token(t).balanceOf(address(dao)), handler.ghostDao(t), "dao");
        }
    }

    /// Only burn leaves burn, and only their shares
    function invariant_SupplyMatchesModel() public view {
        for (uint256 t; t < 2; ++t) {
            assertEq(_token(t).totalSupply(), handler.ghostMinted(t) - handler.ghostBurned(t), "supply");
        }
    }

    /// Nobody outside the flow holds a token: the DAO, the recipients, the beneficiaries, the
    /// filler and the sink (outflows outside the flow) hold the whole supply. Real balances only, no model.
    function invariant_NoTokenLeavesTheFlow() public view {
        for (uint256 t; t < 2; ++t) {
            ERC20Mock _tok = _token(t);
            uint256 _held = _tok.balanceOf(address(dao)) + _tok.balanceOf(handler.filler())
                + _tok.balanceOf(handler.sink());
            for (uint256 r; r < handler.recipientCount(); ++r) {
                _held += _tok.balanceOf(handler.recipientAt(r));
            }
            for (uint256 b; b < handler.beneficiaryCount(); ++b) {
                _held += _tok.balanceOf(handler.beneficiaryAt(b));
            }
            assertEq(_held, _tok.totalSupply(), "tokens outside the flow");
        }
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

    function _token(uint256 _t) internal view returns (ERC20Mock) {
        return _t == 0 ? tokenA : tokenB;
    }
}
