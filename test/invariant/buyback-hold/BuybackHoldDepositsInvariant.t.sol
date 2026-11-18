// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BuybackHoldFixture} from "../../helpers/BuybackHoldFixture.sol";
import {FillHandler, ALICE, BOB} from "./FillHandler.sol";

/// @notice Balance-limited buyback campaign with independently interleaved fills, time, deposits and syncs.
/// @dev Buyers recycle purchased sellToken into the DAO; no minting, unrelated outflows or settings changes.
contract BuybackHoldDepositsInvariantTest is BuybackHoldFixture {
    function _initialSellSupply() internal pure override returns (uint256) {
        return AMOUNT_PER_EPOCH; // Below MAX_BUDGET so deposits and lastSeenBalance matter.
    }

    function _handlerSelectors() internal pure override returns (bytes4[] memory selectors) {
        selectors = new bytes4[](4);
        selectors[0] = FillHandler.fill.selector;
        selectors[1] = FillHandler.advanceTime.selector;
        selectors[2] = FillHandler.deposit.selector;
        selectors[3] = FillHandler.sync.selector;
    }

    function invariant_BalancesAndBudgetMatchExpectations() public view {
        handler.checkState();
    }

    /// @notice A deposit after an empty-stream backlog stays unavailable until sync and fresh accrual.
    function test_DepositCannotUnlockHiddenAccrual() public {
        handler.fill({buyerIndex: ALICE, underpay: false});
        handler.advanceTime({secondsLater: uint32(2 * EPOCH_INTERVAL)});
        handler.deposit({buyerIndex: ALICE, amount: AMOUNT_PER_EPOCH / 2});
        assertEq(budget.available(address(0), ""), 0);
        assertEq(budget.lastSeenBalance(), 0);

        handler.sync();
        assertEq(budget.available(address(0), ""), 0);
        assertEq(budget.baseAmount(), 0);
        assertEq(budget.baseTimestamp(), block.timestamp);
        assertEq(budget.lastSeenBalance(), AMOUNT_PER_EPOCH / 2);
        handler.advanceTime({secondsLater: uint32(EPOCH_INTERVAL)});
        handler.fill({buyerIndex: BOB, underpay: false});
        assertEq(sellToken.balanceOf(BOB_SOLVER), AMOUNT_PER_EPOCH / 2);
        assertEq(sellToken.balanceOf(ALICE_SOLVER), AMOUNT_PER_EPOCH / 2);
    }

    /// @notice A clipped sync carries forward a nonzero offer and allows only new growth afterward.
    function test_SyncCarriesNonzeroOfferAndRejectedFillPreservesIt() public {
        handler.fill({buyerIndex: ALICE, underpay: false});
        handler.deposit({buyerIndex: ALICE, amount: AMOUNT_PER_EPOCH / 2});
        handler.sync();
        handler.advanceTime({secondsLater: uint32(2 * EPOCH_INTERVAL)});
        assertEq(budget.available(address(0), ""), AMOUNT_PER_EPOCH / 2);

        handler.deposit({buyerIndex: ALICE, amount: AMOUNT_PER_EPOCH / 2});
        assertEq(budget.available(address(0), ""), AMOUNT_PER_EPOCH / 2);
        handler.sync();
        assertEq(budget.baseAmount(), AMOUNT_PER_EPOCH / 2);
        assertEq(budget.baseTimestamp(), block.timestamp);

        handler.fill({buyerIndex: BOB, underpay: true});
        assertEq(handler.revertedFills(), 1);
        assertEq(budget.baseAmount(), AMOUNT_PER_EPOCH / 2);
        handler.advanceTime({secondsLater: uint32(EPOCH_INTERVAL / 2)});
        handler.fill({buyerIndex: BOB, underpay: false});
        assertEq(sellToken.balanceOf(BOB_SOLVER), AMOUNT_PER_EPOCH);
    }

    /// @notice Repeated uncapped syncs must not discard the fractional part of accrual.
    function test_UncappedSyncPreservesFractionalAccrual() public {
        handler.fill({buyerIndex: ALICE, underpay: false});
        handler.deposit({buyerIndex: ALICE, amount: AMOUNT_PER_EPOCH});
        handler.sync();
        uint256 anchor = budget.baseTimestamp();
        handler.advanceTime({secondsLater: 1});
        handler.sync();
        handler.advanceTime({secondsLater: 1});
        handler.sync();
        assertEq(budget.baseTimestamp(), anchor);
        assertEq(budget.baseAmount(), 0);
        assertEq(budget.available(address(0), ""), 2 * AMOUNT_PER_EPOCH / EPOCH_INTERVAL);
    }

    /// @notice Reaching a balance limit exactly does not hide growth and must not reset the anchor.
    function test_SyncAtExactBalanceLimitKeepsAnchor() public {
        handler.fill({buyerIndex: ALICE, underpay: false});
        handler.deposit({buyerIndex: ALICE, amount: AMOUNT_PER_EPOCH / 2});
        handler.sync();
        uint256 anchor = budget.baseTimestamp();
        handler.advanceTime({secondsLater: uint32(EPOCH_INTERVAL / 2)});
        handler.deposit({buyerIndex: ALICE, amount: AMOUNT_PER_EPOCH / 2});
        handler.sync();
        assertEq(budget.baseTimestamp(), anchor);
        assertEq(budget.baseAmount(), 0);
        handler.advanceTime({secondsLater: uint32(EPOCH_INTERVAL / 2)});
        assertEq(budget.available(address(0), ""), AMOUNT_PER_EPOCH);
    }

    /// @notice Depositing more than a buyer owns is bounded by its modeled balance; empty buyers deposit zero.
    function test_DepositUsesOnlyExistingBuyerTokens() public {
        handler.deposit({buyerIndex: BOB, amount: type(uint256).max});
        assertEq(sellToken.balanceOf(BOB_SOLVER), 0);
        handler.fill({buyerIndex: ALICE, underpay: false});
        handler.deposit({buyerIndex: ALICE, amount: type(uint256).max});
        assertEq(sellToken.balanceOf(ALICE_SOLVER), 0);
        assertEq(sellToken.balanceOf(address(dao)), AMOUNT_PER_EPOCH);
        assertEq(sellToken.totalSupply(), AMOUNT_PER_EPOCH);
    }
}
