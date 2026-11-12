// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import {StreamBudget} from "../../../src/budgets/StreamBudget.sol";
import {GenericFillSolver} from "../../../src/solvers/GenericFillSolver.sol";
import {ERC20Mock} from "../../mocks/ERC20Mock.sol";
import {BaseHandler} from "../base/BaseHandler.sol";

/// @notice Random trees with OpenFill nodes on a StreamBudget flow, plus time passing, deposits,
///         outflows, syncs and setting changes. Triggers go through a `GenericFillSolver`, which
///         the DAO calls back to fill every offer with the calls in that node's data.
contract StreamBudgetHandler is BaseHandler {
    uint256 internal constant INITIAL_DEPOSIT = 5_000 ether;

    StreamBudget internal stream;
    GenericFillSolver internal solver;

    /// @notice The most `available()` may be after the last call: what it was before the call, plus
    ///         the growth for the time that passed during it. 0 after a restart.
    uint256 public ghostCeiling;

    /// @notice A that left the DAO outside the flow
    uint256 public ghostToSink;

    // A left the DAO and no sync followed. Until one does, hidden growth may surface when funds come
    // back (the stream's documented weak spot), so `ghostCeiling` stops applying.
    bool internal unsyncedOutflow;

    // Set by an action that restarted the stream (a fill's checkpoint, a demand change)
    bool internal restarted;

    constructor(Deps memory _deps) BaseHandler(_deps) {
        stream = StreamBudget(address(_deps.budget));
        solver = new GenericFillSolver(address(this), plugin);
        filler = address(solver);
        _deposit(INITIAL_DEPOSIT);
        _sync(); // the stream only sees the deposit once synced
        ghostCeiling = _available();
    }

    /// @dev Records the ceiling for `available()` after the call. Time is the only thing that may
    ///      raise the amount, at the rate in force while it passed (no setter passes time).
    modifier recordsCeiling() {
        bool _wasUnsynced = unsyncedOutflow;
        uint256 _before = _available();
        uint256 _start = block.timestamp;
        uint256 _perEpoch = stream.amountPerEpoch();
        uint256 _interval = stream.epochInterval();

        _;

        uint256 _elapsed = block.timestamp - _start;
        // Growth rounds down, so splitting time across calls can add 1
        ghostCeiling = _before + (_elapsed == 0 ? 0 : _perEpoch * _elapsed / _interval + 1);
        if (_wasUnsynced || unsyncedOutflow) ghostCeiling = type(uint256).max;
        // A checkpoint restarts from 0 whatever came before it
        if (restarted) ghostCeiling = 0;
        restarted = false;
    }

    // Actions

    /// @dev Triggers through the solver. Nothing available would only revert with `EmptyInput(0)`, so an
    ///      empty stream first gets funds and one epoch to accrue.
    /// @param _fillSeed Picks what the filler sends: less than the demand an eighth of the time
    ///        (the trigger must revert with `DemandNotMet`), exactly the demand, or more
    function trigger(uint256 _seed, uint256 _fillSeed) external recordsCeiling {
        if (_available() == 0) {
            _deposit(_seed);
            _sync();
            vm.warp(block.timestamp + stream.epochInterval());
        }

        fillDelta = _fillDelta(_fillSeed);

        // A fill's commit writes a checkpoint. The caller is the solver whatever is passed here.
        if (_trigger(address(solver), _available(), _seed)) {
            restarted = true;
            unsyncedOutflow = false;
        }
    }

    function warp(uint256 _seconds) external recordsCeiling {
        _seconds = bound(_seconds, 1, 30 days);
        vm.warp(block.timestamp + _seconds);
    }

    /// @dev A deposit doesn't move the amount: it only counts once a sync records it
    function deposit(uint256 _amount) external recordsCeiling {
        _deposit(_amount);
    }

    /// @dev A leaves the DAO outside the flow (another proposal, say). Half the time a sync follows,
    ///      as the stream requires; without one the live balance is the cap that binds.
    function outflow(uint256 _amount, bool _thenSync) external recordsCeiling {
        uint256 _balance = tokens[A].balanceOf(address(dao));
        if (_balance == 0) return;
        _amount = bound(_amount, 1, _balance);

        vm.prank(address(dao));
        tokens[A].transfer(sink, _amount);
        ghostA.dao -= _amount;
        ghostToSink += _amount;

        if (_thenSync) _sync();
        else unsyncedOutflow = true;
    }

    /// @dev Anyone may sync; it never moves the amount in the same block
    function sync() external recordsCeiling {
        _sync();
    }

    /// @dev A lower cap limits the amount at once; a higher one, or none, releases nothing hidden
    function setMaxBudget(uint256 _maxBudget) external recordsCeiling {
        _maxBudget = bound(_maxBudget, 0, 1_000_000 ether);
        vm.prank(manager);
        stream.setMaxBudget(_maxBudget);
        unsyncedOutflow = false; // the setter syncs first
    }

    /// @dev Changes the growth per epoch or the epoch length; what already accrued stays the same
    function setRate(uint256 _seed, bool _epochLength) external recordsCeiling {
        vm.prank(manager);
        if (_epochLength) stream.setEpochInterval(bound(_seed, 1 hours, 30 days));
        else stream.setAmountPerEpoch(bound(_seed, 1, 1_000 ether));
        unsyncedOutflow = false; // the setter syncs first
    }

    /// @dev A new demand restarts the stream, so nobody fills an old offer at the new demand
    function setDemandPerFill(uint256 _demand) external recordsCeiling {
        _demand = bound(_demand, 1, 1_000_000 ether);
        vm.prank(manager);
        openFill.setDemandPerFill(_demand);
        demand = _demand;
        restarted = true;
        unsyncedOutflow = false; // the restart writes a checkpoint
    }

    // Solver

    /// @dev Only the solver's `authorized` (this handler) may trigger through it, and the plugin
    ///      sees the solver as the caller, so the offers are approved to it
    function _callTrigger(address, bytes[] memory _data)
        internal
        override
        returns (bool _success, bytes memory _returnData)
    {
        (_success, _returnData) = address(solver).call(abi.encodeCall(GenericFillSolver.trigger, (_data)));
    }

    /// @dev The batch the solver runs when the DAO calls it back: take the whole offer of A, then
    ///      pay the DAO `demand + fillDelta` of B
    function _fillData(uint256 _offered) internal view override returns (bytes memory) {
        Action[] memory _calls = new Action[](2);
        _calls[0] = Action({
            to: address(tokens[A]),
            value: 0,
            data: abi.encodeCall(IERC20.transferFrom, (address(dao), address(solver), _offered))
        });
        _calls[1] = Action({
            to: address(tokens[B]),
            value: 0,
            data: abi.encodeCall(ERC20Mock.mint, (address(dao), _paidByFiller()))
        });
        return abi.encode(_calls);
    }

    // Helpers

    function _available() internal view returns (uint256) {
        return stream.available(address(this), "");
    }

    function _sync() internal {
        stream.sync();
        unsyncedOutflow = false;
    }

    /// @dev Under the demand an eighth of the time,
    ///      exactly the demand a quarter
    ///      over it the rest
    function _fillDelta(uint256 _seed) internal view returns (int256) {
        uint256 _mode = _seed % 8;
        uint256 _size = _seed >> 8;
        if (_mode == 0) return -int256(1 + _size % demand);
        if (_mode <= 2) return 0;
        return int256(_size % 1_000 ether);
    }
}
