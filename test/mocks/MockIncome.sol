// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import {IBudget} from "../../src/interfaces/IBudget.sol";
import {INodeAction} from "../../src/interfaces/INodeAction.sol";
import {Input, Movement} from "../../src/lib/types.sol";

/// @notice Holds tokens and pays them out when asked, like a claim or a vesting release
contract IncomeSource {
    function pay(IERC20 _token, address _to, uint256 _amount) external {
        _token.transfer(_to, _amount);
    }
}

/// @notice A node action that takes its whole input, claims `income` of its output token from a
///         source and sends `loss` of its input token away. With one token it declares
///         `outAmount = input + extra`; with another output token, `outAmount = extra`.
contract IncomeAction is INodeAction {
    IncomeSource public immutable source;
    address public immutable dao;
    /// @dev address(0): the output is the input token
    IERC20 public immutable outToken;
    uint256 public immutable income;
    uint256 public immutable loss;
    int256 public immutable extra;

    constructor(IncomeSource _source, address _dao, IERC20 _outToken, uint256 _income, uint256 _loss, int256 _extra) {
        (source, dao, outToken, income, loss, extra) = (_source, _dao, _outToken, _income, _loss, _extra);
    }

    function budget() external pure returns (IBudget) {}

    function preconditions(address, bytes calldata, Movement calldata) external pure returns (bytes memory) {}

    function build(address, bytes calldata, Input calldata _input)
        external
        view
        returns (Movement memory _movement, Action[] memory _actions)
    {
        IERC20 _out = address(outToken) == address(0) ? _input.token : outToken;
        int256 _base = _out == _input.token ? int256(_input.amount) : int256(0);
        _movement = Movement(_input.token, _input.amount, _out, uint256(_base + extra), _input.beneficiary);

        _actions = new Action[](2);
        _actions[0] = Action(address(source), 0, abi.encodeCall(IncomeSource.pay, (_out, dao, income)));
        _actions[1] = Action(address(_input.token), 0, abi.encodeCall(IERC20.transfer, (address(source), loss)));
    }

    function postconditions(address, Movement calldata, bytes calldata) external pure {}
}
