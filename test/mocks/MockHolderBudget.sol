// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import {IBudget} from "../../src/interfaces/IBudget.sol";

/// @notice A budget whose tokens sit in itself, like a vault or a claimable position. Its fund
///         action has the DAO call `release`, which sends `delivered` to the DAO. `delivered`
///         starts at `amount`; tests change it to deliver less or more.
contract MockHolderBudget is IBudget {
    address public immutable dao;
    IERC20 public immutable token;
    uint256 public immutable amount;
    uint256 public delivered;
    /// @dev Where the fund action points: this budget, unless a test changes it
    address public fundTarget;

    constructor(address _dao, IERC20 _token, uint256 _amount) {
        (dao, token, amount, delivered, fundTarget) = (_dao, _token, _amount, _amount, address(this));
    }

    function setDelivered(uint256 _delivered) external {
        delivered = _delivered;
    }

    function setFundTarget(address _target) external {
        fundTarget = _target;
    }

    function available(address, bytes calldata) external view returns (uint256) {
        return amount;
    }

    function fundActions(address, bytes calldata) external view returns (Action[] memory _actions) {
        _actions = new Action[](1);
        _actions[0] = Action(fundTarget, 0, abi.encodeCall(this.release, ()));
    }

    function release() external {
        require(msg.sender == dao, "only the DAO");
        token.transfer(dao, delivered);
    }

    function commitActions(address, bytes calldata) external pure returns (Action[] memory) {}
}
