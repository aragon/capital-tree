// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {StreamBudget} from "../../../src/budgets/StreamBudget.sol";
import {IFiller} from "../../../src/interfaces/IFiller.sol";
import {BaseHandler} from "../base/BaseHandler.sol";

/// @notice Random trees with OpenFill nodes on a StreamBudget flow, plus time passing, deposits,
///         syncs and setting changes. The handler is also the filler: it triggers the flow, so the
///         DAO calls it back to fill every offer.
/// @dev Each stream action checks, in the same block, what it may do to `available()`. These are the
///      stream's documented promises, not a copy of its formula: the amount never jumps.
contract StreamBudgetHandler is BaseHandler, IFiller {
    uint256 internal constant INITIAL_DEPOSIT = 5_000 ether;

    StreamBudget internal stream;

    constructor(Deps memory _deps) BaseHandler(_deps) {
        stream = StreamBudget(address(_deps.budget));
        _deposit(INITIAL_DEPOSIT);
        stream.sync(); // the stream only sees the deposit once synced
    }

    // Actions

    /// @dev Triggers as the filler. Nothing available would only revert with `EmptyInput(0)`, so an
    ///      empty stream first gets funds and a day to accrue.
    /// @param _fillSeed Picks what the filler sends: less than the demand a quarter of the time
    ///        (the trigger must revert with `DemandNotMet`), exactly the demand, or more
    function trigger(uint256 _seed, uint256 _fillSeed) external {
        if (_available() == 0) {
            _deposit(_seed);
            stream.sync();
            vm.warp(block.timestamp + 1 days);
        }
        fillDelta = _fillDelta(_fillSeed);

        uint256 _amount = _available();
        uint256 _daoBefore = tokens[A].balanceOf(address(dao));

        if (!_trigger(address(this), _amount, _seed)) {
            assertEq(_available(), _amount, "a reverted trigger changed the stream");
            return;
        }

        // The commit restarts the stream, and the flow spent at most what it was given
        assertEq(_available(), 0, "trigger did not restart the stream");
        assertLe(_daoBefore - tokens[A].balanceOf(address(dao)), _amount, "spent more than available");
    }

    /// @dev Time passes: the amount grows by at most the rate, and never shrinks
    function warp(uint256 _seconds) external {
        _seconds = bound(_seconds, 1, 30 days);
        uint256 _before = _available();
        vm.warp(block.timestamp + _seconds);

        uint256 _maxGrowth = stream.amountPerEpoch() * _seconds / stream.epochInterval() + 1;
        assertGe(_available(), _before, "time passing lowered the amount");
        assertLe(_available(), _before + _maxGrowth, "the amount grew faster than the rate");
    }

    /// @dev A deposit doesn't move the amount: it only counts once a sync records it
    function deposit(uint256 _amount) external {
        uint256 _before = _available();
        _deposit(_amount);
        assertEq(_available(), _before, "a deposit moved the amount");
    }

    /// @dev Anyone may sync; it never moves the amount in the same block
    function sync() external {
        uint256 _before = _available();
        stream.sync();
        assertEq(_available(), _before, "sync moved the amount");
    }

    /// @dev A lower cap limits the amount at once; a higher one, or none, releases nothing hidden
    function setMaxBudget(uint256 _maxBudget) external {
        _maxBudget = bound(_maxBudget, 0, 1_000_000 ether);
        uint256 _before = _available();
        vm.prank(manager);
        stream.setMaxBudget(_maxBudget);

        uint256 _want = _maxBudget == 0 || _maxBudget > _before ? _before : _maxBudget;
        assertEq(_available(), _want, "a cap change moved the amount wrongly");
    }

    /// @dev Changes the growth per epoch or the epoch length; what already accrued stays the same
    function setRate(uint256 _seed, bool _epochLength) external {
        uint256 _before = _available();
        vm.prank(manager);
        if (_epochLength) stream.setEpochInterval(bound(_seed, 1 hours, 30 days));
        else stream.setAmountPerEpoch(bound(_seed, 1, 1_000 ether));
        assertEq(_available(), _before, "a rate change moved the amount");
    }

    /// @dev A new demand restarts the stream, so nobody fills an old offer at the new demand
    function setDemandPerFill(uint256 _demand) external {
        _demand = bound(_demand, 1, 1_000_000 ether);
        vm.prank(manager);
        openFill.setDemandPerFill(_demand);
        demand = _demand;
        assertEq(_available(), 0, "a demand change did not restart the stream");
    }

    // Filler

    /// @inheritdoc IFiller
    /// @dev Takes the whole offer and mints `demand + fillDelta` B to the DAO
    function fillOffer(IERC20 _offered, uint256 _offeredAmount, IERC20, uint256 _demandedAmount, bytes calldata)
        external
    {
        assertEq(msg.sender, address(dao), "only the DAO fills");
        assertEq(_demandedAmount, demand, "the action demands what the model thinks");
        _offered.transferFrom(address(dao), address(this), _offeredAmount);
        tokens[B].mint(address(dao), uint256(int256(_demandedAmount) + fillDelta));
    }

    // Helpers

    function _available() internal view returns (uint256) {
        return stream.available(address(this), "");
    }

    /// @dev Under the demand a quarter of the time, exactly the demand a quarter, over it half
    function _fillDelta(uint256 _seed) internal view returns (int256) {
        uint256 _mode = _seed % 4;
        uint256 _size = _seed >> 8;
        if (_mode == 0) return -int256(1 + _size % demand);
        if (_mode == 1) return 0;
        return int256(_size % 1_000 ether);
    }
}
