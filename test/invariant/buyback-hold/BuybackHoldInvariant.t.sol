// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BuybackHoldFixture} from "../../helpers/BuybackHoldFixture.sol";
import {ALICE, BOB} from "./FillHandler.sol";
import {Node} from "../../../src/lib/types.sol";
import {CHECKPOINT_PERMISSION_ID} from "../../../src/lib/constants.sol";

/// @notice Fixed-funding buyback campaign plus readable regression scenarios.
/// @dev Fuzzes independent fill and advanceTime actions. Settings and supplies stay fixed.
/// Arbitrary callbacks, reentrancy, governance changes, partial pulls and surplus payment
/// remain outside this campaign. Deposit/sync sequences live in BuybackHoldDepositsInvariantTest.
contract BuybackHoldInvariantTest is BuybackHoldFixture {
    /// @notice Requires balances, availability and protected observations to match the handler's expectations.
    /// @dev Foundry checks this after handler calls; the handler also checks each individual attempt.
    function invariant_BalancesAndBudgetMatchExpectations() public view {
        handler.checkState();
    }

    /// @notice A successful fill leaves no offer for the other buyer at the same timestamp.
    function test_SameBlockWinnerConsumesOffer() public {
        // Alice succeeds; Bob finds an empty offer.
        handler.sameBlock({firstBuyer: ALICE, firstUnderpays: false, secondUnderpays: false});
        assertEq(handler.successfulFills(), 1);
        assertEq(handler.revertedFills(), 1);
        assertEq(sellToken.balanceOf(ALICE_SOLVER), AMOUNT_PER_EPOCH);
        assertEq(sellToken.balanceOf(BOB_SOLVER), 0);
    }

    /// @notice Waiting one epoch after the first fill makes another epoch's worth of sellToken available.
    function test_DelayLetsBothBuyersFill() public {
        handler.afterDelay({
            firstBuyer: ALICE, secondsLater: uint32(EPOCH_INTERVAL), firstUnderpays: false, secondUnderpays: false
        });
        assertEq(handler.successfulFills(), 2);
        assertEq(sellToken.balanceOf(ALICE_SOLVER), AMOUNT_PER_EPOCH);
        assertEq(sellToken.balanceOf(BOB_SOLVER), AMOUNT_PER_EPOCH);
    }

    /// @notice Bob may win first; Alice can then fill the amount accrued over one second.
    function test_EitherBuyerCanGoFirst() public {
        handler.afterDelay({firstBuyer: BOB, secondsLater: 1, firstUnderpays: false, secondUnderpays: false});
        assertEq(sellToken.balanceOf(BOB_SOLVER), AMOUNT_PER_EPOCH);
        assertEq(sellToken.balanceOf(ALICE_SOLVER), AMOUNT_PER_EPOCH / EPOCH_INTERVAL);
    }

    /// @notice An underpayment rolls back, leaving the same offer for the next buyer.
    function test_UnderpaymentLeavesOfferForOtherBuyer() public {
        handler.sameBlock({firstBuyer: ALICE, firstUnderpays: true, secondUnderpays: false});
        assertEq(handler.successfulFills(), 1);
        assertEq(handler.revertedFills(), 1);
        assertEq(sellToken.balanceOf(ALICE_SOLVER), 0);
        assertEq(sellToken.balanceOf(BOB_SOLVER), AMOUNT_PER_EPOCH);
    }

    /// @notice Two rejected underpayments preserve the offer, allowing a later correct payment immediately.
    function test_TwoFailuresLeaveOfferAvailable() public {
        handler.sameBlock({firstBuyer: ALICE, firstUnderpays: true, secondUnderpays: true});
        assertEq(handler.successfulFills(), 0);
        assertEq(handler.revertedFills(), 2);
        assertEq(budget.available(address(0), ""), AMOUNT_PER_EPOCH);
        handler.sameBlock({firstBuyer: BOB, firstUnderpays: false, secondUnderpays: false}); // recovery at the same timestamp
        assertEq(handler.successfulFills(), 1);
    }

    /// @notice A changed budget setting reports the specific field, even if the current offer is unaffected.
    function test_ProtectedStateReportsBudgetChange() public {
        vm.mockCall({
            callee: address(budget),
            data: abi.encodeWithSignature("maxBudget()"),
            returnData: abi.encode(MAX_BUDGET + 1)
        });
        vm.expectRevert(
            bytes(
                string.concat(
                    "budget.maxBudget changed: ", vm.toString(MAX_BUDGET + 1), " != ", vm.toString(MAX_BUDGET)
                )
            )
        );
        handler.checkState();
    }

    /// @notice Node comparisons include child indices, not just the action address.
    function test_ProtectedStateReportsNodeChildChange() public {
        Node[] memory nodes = plugin.nodes();
        nodes[0].children[0] = 0;
        vm.mockCall({callee: address(plugin), data: abi.encodeWithSignature("nodes()"), returnData: abi.encode(nodes)});
        vm.expectRevert(bytes("node 0 child 0 changed: 0 != 1"));
        handler.checkState();
    }

    /// @notice An unexpected DAO allowance identifies its spender and token.
    function test_ProtectedStateReportsAllowanceChange() public {
        vm.prank(address(dao));
        sellToken.approve({spender: address(openFill), amount: 1});
        vm.expectRevert(
            bytes(string.concat("address ", vm.toString(address(openFill)), " sellToken allowance changed: 1 != 0"))
        );
        handler.checkState();
    }

    /// @notice Token balances outside Alice, Bob and the DAO remain protected.
    function test_ProtectedStateReportsPassiveBalanceChange() public {
        vm.mockCall({
            callee: address(sellToken),
            data: abi.encodeWithSignature("balanceOf(address)", address(openFill)),
            returnData: abi.encode(uint256(1))
        });
        vm.expectRevert(
            bytes(string.concat("address ", vm.toString(address(openFill)), " sellToken balance changed: 1 != 0"))
        );
        handler.checkState();
    }

    /// @notice Alice can fill twice while Bob remains inactive.
    function test_IndependentFillLetsSameBuyerRepeat() public {
        handler.fill({buyerIndex: ALICE, underpay: false});
        handler.advanceTime({secondsLater: uint32(EPOCH_INTERVAL)});
        handler.fill({buyerIndex: ALICE, underpay: false});
        assertEq(sellToken.balanceOf(ALICE_SOLVER), 2 * AMOUNT_PER_EPOCH);
        assertEq(sellToken.balanceOf(BOB_SOLVER), 0);
        assertEq(handler.successfulFills(), 2);
    }

    /// @notice Multiple independent time advances can reach the cap before either buyer fills.
    function test_IndependentTimeAdvancesWithoutFill() public {
        handler.advanceTime({secondsLater: uint32(EPOCH_INTERVAL)});
        handler.advanceTime({secondsLater: uint32(EPOCH_INTERVAL)});
        assertEq(budget.available(address(0), ""), MAX_BUDGET);
        handler.fill({buyerIndex: BOB, underpay: false});
        assertEq(sellToken.balanceOf(BOB_SOLVER), MAX_BUDGET);
    }

    /// @notice Live permission changes are detected even when the setup's recorded hash is unchanged.
    function test_LivePermissionsDetectBuyerPrivilegeEscalation() public {
        bytes32 recordedHash = setup.permissionsHash(address(plugin));
        dao.grant({_where: address(dao), _who: ALICE_SOLVER, _permissionId: dao.ROOT_PERMISSION_ID()});
        assertEq(setup.permissionsHash(address(plugin)), recordedHash);
        vm.expectRevert(bytes("Alice root permission changed: true != false"));
        handler.checkState();
    }

    /// @notice Losing a required checkpoint grant is detected without waiting for a failing fill.
    function test_LivePermissionsDetectRevokedCheckpoint() public {
        dao.revoke({_where: address(budget), _who: address(dao), _permissionId: CHECKPOINT_PERMISSION_ID});
        vm.expectRevert(bytes("DAO checkpoint permission changed: false != true"));
        handler.checkState();
    }

    /// @notice A non-fill action also checks live permissions.
    function test_AdvanceTimeChecksLivePermissions() public {
        dao.grant({_where: address(dao), _who: BOB_SOLVER, _permissionId: dao.EXECUTE_PERMISSION_ID()});
        vm.expectRevert(bytes("Bob execute permission changed: true != false"));
        handler.advanceTime({secondsLater: 1});
    }

    /// @notice Sync at the budget cap preserves the offer and discards hidden growth.
    function test_SyncAtMaxBudgetPreservesOffer() public {
        handler.advanceTime({secondsLater: uint32(2 * EPOCH_INTERVAL)});
        handler.sync();
        assertEq(budget.available(address(0), ""), MAX_BUDGET);
        assertEq(budget.baseAmount(), MAX_BUDGET);
        assertEq(budget.baseTimestamp(), block.timestamp);
        handler.fill({buyerIndex: ALICE, underpay: false});
        assertEq(sellToken.balanceOf(ALICE_SOLVER), MAX_BUDGET);
    }
}
