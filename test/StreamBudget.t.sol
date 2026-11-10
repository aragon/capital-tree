// SPDX-License-Identifier: UNLICENSED
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

    function test_GrowsAtRatePerEpoch() public {
        assertEq(_available(budget), 0);

        vm.warp(block.timestamp + EPOCH);
        assertEq(_available(budget), RATE);

        vm.warp(block.timestamp + EPOCH / 2);
        assertEq(_available(budget), RATE + RATE / 2);
    }

    function test_DepositDoesNotLiftTheCapUntilSync() public {
        vm.warp(block.timestamp + 20 * EPOCH); // 200 accrued, capped at the 100 seen
        assertEq(_available(budget), DAO_A);

        tokenA.mint(address(dao), 50 ether);
        assertEq(_available(budget), DAO_A, "deposit must not lift the cap");

        budget.sync();
        assertEq(_available(budget), DAO_A, "sync must not jump");

        vm.warp(block.timestamp + EPOCH);
        assertEq(_available(budget), DAO_A + RATE, "growth resumes from where it froze");
    }

    /// A sync every block must not freeze a stream slower than one unit per block
    function test_SyncEveryBlockKeepsTheCurve() public {
        StreamBudget _slow = _deployBudget(7000, 0); // 0.97 units per 12 s block

        for (uint256 i; i < 300; ++i) {
            vm.warp(block.timestamp + 12);
            _slow.sync();
        }

        assertEq(_available(_slow), (7000 * 3600) / EPOCH, "an hour of growth");
    }

    function test_AvailableIgnoresTheCaller() public {
        vm.warp(block.timestamp + EPOCH);

        assertEq(budget.available(alice, ""), RATE);
    }

    function test_CommitActionsWriteCheckpoint() public view {
        Action[] memory _actions = budget.commitActions(alice, "");

        assertEq(_actions.length, 1);
        assertEq(_actions[0].to, address(budget));
        assertEq(_actions[0].value, 0);
        assertEq(_actions[0].data, abi.encodeCall(budget.writeCheckpoint, ()));
    }

    function test_WriteCheckpointRestartsFromZero() public {
        vm.warp(block.timestamp + EPOCH);

        vm.prank(address(dao));
        budget.writeCheckpoint();

        assertEq(_available(budget), 0);
    }

    function test_SetAmountPerEpochKeepsWhatAccrued() public {
        vm.warp(block.timestamp + EPOCH);

        vm.prank(manager);
        budget.setAmountPerEpoch(2 * RATE);
        assertEq(_available(budget), RATE, "no change in the same block");

        vm.warp(block.timestamp + EPOCH);
        assertEq(_available(budget), RATE + 2 * RATE, "new rate from now on");
    }

    function test_RaisingMaxBudgetDoesNotJump() public {
        vm.prank(manager);
        budget.setMaxBudget(5 ether);

        vm.warp(block.timestamp + 2 * EPOCH); // 20 accrued, capped at 5
        assertEq(_available(budget), 5 ether);

        vm.prank(manager);
        budget.setMaxBudget(0);
        assertEq(_available(budget), 5 ether, "hidden accrual must not be released");

        vm.warp(block.timestamp + EPOCH);
        assertEq(_available(budget), 5 ether + RATE);
    }

    function test_SetEpochIntervalKeepsWhatAccrued() public {
        vm.warp(block.timestamp + EPOCH);

        vm.prank(manager);
        budget.setEpochInterval(2 * EPOCH);
        assertEq(_available(budget), RATE);

        vm.warp(block.timestamp + 2 * EPOCH);
        assertEq(_available(budget), 2 * RATE);
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

    function test_RevertWhen_TokenHasNoCode() public {
        StreamBudget _budget = StreamBudget(ProxyLib.deployMinimalProxy(address(new StreamBudget()), ""));

        vm.expectRevert(StreamBudget.InvalidToken.selector);
        _budget.initialize(dao, IERC20(address(0xBEEF)), RATE, 0, EPOCH);
    }
}
