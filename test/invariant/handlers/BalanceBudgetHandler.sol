// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseHandler} from "../base/BaseHandler.sol";

/// @notice Random trees and triggers on a BalanceBudget flow. The root receives the DAO's whole
///         balance of A; trees stay on A (no OpenFill nodes).
contract BalanceBudgetHandler is BaseHandler {
    uint256 internal constant INITIAL_DEPOSIT = 5_000 ether;

    constructor(Deps memory _deps) BaseHandler(_deps) {
        _deposit(INITIAL_DEPOSIT);
    }

    /// @dev Anyone may trigger. Funds arrive here rather than in a separate action, so most calls are
    ///      triggers: an empty DAO is always topped up (an empty root just reverts with
    ///      `EmptyInput(0)`), and half the time more arrives on top, so the amount split varies.
    function trigger(uint256 _actorSeed, uint256 _topUp) external {
        address _caller = address(uint160(bound(_actorSeed, 1, 1_000)));

        // If dao has no balance, deposit before triggering
        if (tokens[A].balanceOf(address(dao)) == 0) _deposit(_topUp);

        // Half the time, deposit some more
        uint256 _more = uint256(keccak256(abi.encode(_topUp)));
        if (_more % 2 == 0) _deposit(_more);

        // The budget is the whole balance
        _trigger(_caller, tokens[A].balanceOf(address(dao)), _actorSeed);
    }
}
