// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import {DaoUnauthorized} from "@aragon/osx-commons-contracts/src/permission/auth/auth.sol";
import {ProxyLib} from "@aragon/osx-commons-contracts/src/utils/deployment/ProxyLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {StreamBudget} from "../src/budgets/StreamBudget.sol";
import {SET_SETTINGS_PERMISSION_ID, CHECKPOINT_PERMISSION_ID} from "../src/lib/constants.sol";
import {Fixture} from "./helpers/Fixture.sol";

contract StreamBudgetTest is Fixture {
    StreamBudget internal budget;

    function setUp() public override {
        super.setUp();
        budget = _deployBudget(RATE, 0);
    }

    function testFuzz_GrowsAtRatePerEpoch(uint128 _rate, uint64 _interval, uint64 _elapsed, uint128 _cap) public {
        _interval = uint64(bound(_interval, 1, type(uint64).max));
        vm.startPrank(manager);
        budget.setAmountPerEpoch(_rate);
        budget.setEpochInterval(_interval);
        budget.setMaxBudget(_cap);
        vm.stopPrank();
        assertEq(_available(budget), 0);
        vm.warp(block.timestamp + _elapsed);
        uint256 _expected = uint256(_rate) * _elapsed / _interval;
        if (_expected > DAO_A) _expected = DAO_A;
        if (_cap != 0 && _expected > _cap) _expected = _cap;
        assertEq(_available(budget), _expected);
    }

    function testFuzz_FractionalAccrualBelowTheCap(uint256 _rate, uint256 _elapsed) public {
        _rate = bound(_rate, 0, DAO_A);
        _elapsed = bound(_elapsed, 0, EPOCH);
        vm.prank(manager);
        budget.setAmountPerEpoch(_rate);
        vm.warp(block.timestamp + _elapsed);
        assertEq(_available(budget), _rate * _elapsed / EPOCH);
    }

    function test_OneWeiPerEpochSurvivesRepeatedSyncs() public {
        StreamBudget _slow = _deployBudget(1, 0);
        for (uint256 i; i < 24; ++i) {
            vm.warp(block.timestamp + 1 hours);
            _slow.sync();
        }
        assertEq(_available(_slow), 1);
    }

    function testFuzz_DepositDoesNotLiftTheCapUntilSync(uint128 _deposit) public {
        vm.warp(block.timestamp + 20 * EPOCH);
        assertEq(_available(budget), DAO_A);
        tokenA.mint(address(dao), _deposit);
        assertEq(_available(budget), DAO_A, "deposit must not lift the cap");
        vm.expectEmit(address(budget));
        emit StreamBudget.Synced(DAO_A, DAO_A + _deposit, true);
        budget.sync();
        assertEq(_available(budget), DAO_A, "sync must not jump");
        vm.warp(block.timestamp + EPOCH);
        assertEq(_available(budget), DAO_A + (_deposit < RATE ? _deposit : RATE));
    }

    /// A sync every block must not freeze a stream slower than one unit per block
    function testFuzz_SyncEveryBlockKeepsTheCurve(uint32 _rate, uint8 _steps, uint32 _seconds) public {
        _rate = uint32(bound(_rate, 0, EPOCH));
        _steps = uint8(bound(_steps, 1, 100));
        _seconds = uint32(bound(_seconds, 1, EPOCH));
        StreamBudget _slow = _deployBudget(_rate, 0);
        for (uint256 i; i < _steps; ++i) {
            vm.warp(block.timestamp + _seconds);
            _slow.sync();
        }
        assertEq(_available(_slow), uint256(_rate) * _steps * _seconds / EPOCH);
    }

    function test_UncappedSyncReportsNoRebase() public {
        uint256 _start = budget.baseTimestamp();
        vm.warp(block.timestamp + EPOCH / 2);

        vm.expectEmit(address(budget));
        emit StreamBudget.Synced(RATE / 2, DAO_A, false);
        vm.prank(alice);
        budget.sync();

        assertEq(budget.baseAmount(), 0);
        assertEq(budget.baseTimestamp(), _start);
        assertEq(_available(budget), RATE / 2);
    }

    function testFuzz_AvailableIgnoresTheCaller(address _caller, bytes memory _data, uint64 _elapsed) public {
        vm.warp(block.timestamp + _elapsed);
        assertEq(budget.available(_caller, _data), _available(budget));
    }

    function testFuzz_CommitActionsWriteCheckpoint(address _caller, bytes memory _data) public view {
        Action[] memory _actions = budget.commitActions(_caller, _data);
        assertEq(_actions.length, 1);
        assertEq(_actions[0].to, address(budget));
        assertEq(_actions[0].value, 0);
        assertEq(_actions[0].data, abi.encodeCall(budget.writeCheckpoint, ()));
    }

    function testFuzz_WriteCheckpointRestartsFromZero(uint64 _elapsed) public {
        vm.warp(block.timestamp + _elapsed);
        vm.prank(address(dao));
        budget.writeCheckpoint();
        assertEq(_available(budget), 0);
        assertEq(budget.lastSeenBalance(), tokenA.balanceOf(address(dao)));
        assertEq(budget.baseTimestamp(), block.timestamp);
    }

    function testFuzz_SetAmountPerEpochKeepsWhatAccrued(uint128 _newRate, uint64 _before, uint64 _after) public {
        // Keep this setter campaign below the balance cap; full-width rates are covered above.
        _newRate = uint128(bound(_newRate, 0, DAO_A / 2));
        _before = uint64(bound(_before, 0, EPOCH));
        _after = uint64(bound(_after, 0, EPOCH));
        vm.warp(block.timestamp + _before);
        uint256 _accrued = _available(budget);
        vm.prank(manager);
        budget.setAmountPerEpoch(_newRate);
        assertEq(_available(budget), _accrued, "no change in the same block");
        assertEq(budget.baseAmount(), _accrued);
        assertEq(budget.baseTimestamp(), block.timestamp);
        vm.warp(block.timestamp + _after);
        uint256 _expected = _accrued + uint256(_newRate) * _after / EPOCH;
        assertEq(_available(budget), _expected < DAO_A ? _expected : DAO_A);
    }

    function testFuzz_RaisingMaxBudgetDoesNotJump(uint256 _cap) public {
        _cap = bound(_cap, 1, DAO_A - 1);
        vm.prank(manager);
        budget.setMaxBudget(_cap);
        vm.warp(block.timestamp + 20 * EPOCH);
        assertEq(_available(budget), _cap);
        vm.prank(manager);
        budget.setMaxBudget(0);
        assertEq(_available(budget), _cap, "hidden accrual must not be released");
        vm.warp(block.timestamp + EPOCH);
        assertEq(_available(budget), _cap + RATE < DAO_A ? _cap + RATE : DAO_A);
    }

    function testFuzz_SetEpochIntervalKeepsWhatAccrued(uint64 _interval, uint64 _before, uint64 _after) public {
        _interval = uint64(bound(_interval, 1, 2 * EPOCH));
        _before = uint64(bound(_before, 0, EPOCH));
        _after = uint64(bound(_after, 0, _interval));
        vm.warp(block.timestamp + _before);
        uint256 _accrued = _available(budget);
        vm.prank(manager);
        budget.setEpochInterval(_interval);
        assertEq(_available(budget), _accrued);
        assertEq(budget.baseAmount(), _accrued);
        assertEq(budget.baseTimestamp(), block.timestamp);
        vm.warp(block.timestamp + _after);
        uint256 _expected = _accrued + RATE * _after / _interval;
        assertEq(_available(budget), _expected < DAO_A ? _expected : DAO_A);
    }

    /// A rate setter rebases even when a cap hides growth: a lower rate must not shrink what accrued
    function testFuzz_SetAmountPerEpochKeepsWhatACapHides(uint128 _newRate) public {
        uint256 _cap = DAO_A / 2;
        _newRate = uint128(bound(_newRate, 0, 1 ether));
        vm.prank(manager);
        budget.setMaxBudget(_cap);
        vm.warp(block.timestamp + 20 * EPOCH);
        assertEq(_available(budget), _cap);

        vm.prank(manager);
        budget.setAmountPerEpoch(_newRate);
        assertEq(_available(budget), _cap);
        assertEq(budget.baseAmount(), _cap);
        assertEq(budget.baseTimestamp(), block.timestamp);
    }

    /// A longer epoch lowers the rate: it must not shrink what a cap hides either
    function testFuzz_SetEpochIntervalKeepsWhatACapHides(uint64 _interval) public {
        uint256 _cap = DAO_A / 2;
        _interval = uint64(bound(_interval, 5 * EPOCH, type(uint64).max));
        vm.prank(manager);
        budget.setMaxBudget(_cap);
        vm.warp(block.timestamp + 20 * EPOCH);
        assertEq(_available(budget), _cap);

        vm.prank(manager);
        budget.setEpochInterval(_interval);
        assertEq(_available(budget), _cap);
        assertEq(budget.baseAmount(), _cap);
        assertEq(budget.baseTimestamp(), block.timestamp);
    }

    function test_RevertWhen_EpochIntervalIsZero() public {
        vm.prank(manager);
        vm.expectRevert(StreamBudget.InvalidEpochInterval.selector);
        budget.setEpochInterval(0);

        StreamBudget _budget = StreamBudget(ProxyLib.deployMinimalProxy(address(new StreamBudget()), ""));
        vm.expectRevert(StreamBudget.InvalidEpochInterval.selector);
        _budget.initialize(dao, _noDeps(), abi.encode(tokenA, RATE, 0, 0));
    }

    function test_RevertWhen_WriteCheckpointUnauthorized() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                DaoUnauthorized.selector, address(dao), address(budget), address(this), CHECKPOINT_PERMISSION_ID
            )
        );
        budget.writeCheckpoint();
    }

    function test_RevertWhen_SetterUnauthorized() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                DaoUnauthorized.selector, address(dao), address(budget), address(this), SET_SETTINGS_PERMISSION_ID
            )
        );
        budget.setAmountPerEpoch(1);
    }

    function testFuzz_TheHighestRateNeverOverflows(uint64 _elapsed) public {
        _elapsed = uint64(bound(_elapsed, 1, type(uint64).max));
        uint256 _highest = budget.MAX_AMOUNT_PER_EPOCH();
        vm.prank(manager);
        budget.setAmountPerEpoch(_highest);
        vm.warp(block.timestamp + _elapsed);
        assertEq(_available(budget), DAO_A, "capped by the balance, not reverting");
    }

    function testFuzz_RevertWhen_TheRateCouldOverflow(uint256 _tooHigh) public {
        _tooHigh = bound(_tooHigh, budget.MAX_AMOUNT_PER_EPOCH() + 1, type(uint256).max);
        vm.prank(manager);
        vm.expectRevert(StreamBudget.InvalidAmountPerEpoch.selector);
        budget.setAmountPerEpoch(_tooHigh);
        StreamBudget _budget = StreamBudget(ProxyLib.deployMinimalProxy(address(new StreamBudget()), ""));
        vm.expectRevert(StreamBudget.InvalidAmountPerEpoch.selector);
        _budget.initialize(dao, _noDeps(), abi.encode(tokenA, _tooHigh, 0, EPOCH));
    }

    function testFuzz_NothingAccruesBeforeTheFirstCheckpoint(uint64 _voteDuration) public {
        StreamBudget _budget = StreamBudget(
            ProxyLib.deployMinimalProxy(
                address(new StreamBudget()),
                abi.encodeCall(StreamBudget.initialize, (dao, _noDeps(), abi.encode(tokenA, RATE, 0, EPOCH)))
            )
        );
        dao.grant(address(_budget), manager, SET_SETTINGS_PERMISSION_ID);
        dao.grant(address(_budget), address(dao), CHECKPOINT_PERMISSION_ID);

        vm.warp(block.timestamp + _voteDuration); // the vote
        assertEq(_available(_budget), 0, "nothing accrued during the vote");

        vm.expectEmit(address(_budget));
        emit StreamBudget.Synced(0, DAO_A, false);
        _budget.sync();
        vm.expectEmit(address(_budget));
        emit StreamBudget.Synced(0, DAO_A, false);
        vm.prank(manager);
        _budget.setAmountPerEpoch(2 * RATE);
        vm.expectEmit(address(_budget));
        emit StreamBudget.Synced(0, DAO_A, false);
        vm.prank(manager);
        _budget.setEpochInterval(EPOCH);
        assertEq(_budget.baseTimestamp(), 0, "setters must not start the clock");
        vm.warp(block.timestamp + EPOCH);
        assertEq(_available(_budget), 0, "neither a sync nor a setter starts it");

        vm.prank(address(dao));
        _budget.writeCheckpoint();
        assertEq(_available(_budget), 0, "starts from zero");

        vm.warp(block.timestamp + EPOCH);
        assertEq(_available(_budget), 2 * RATE, "then grows at the rate set before the start");
    }

    function test_RevertWhen_TokenHasNoCode() public {
        StreamBudget _budget = StreamBudget(ProxyLib.deployMinimalProxy(address(new StreamBudget()), ""));

        vm.expectRevert(StreamBudget.InvalidToken.selector);
        _budget.initialize(dao, _noDeps(), abi.encode(IERC20(address(0xBEEF)), RATE, 0, EPOCH));
    }
}
