// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import {IBudget} from "../../src/interfaces/IBudget.sol";
import {INodeAction} from "../../src/interfaces/INodeAction.sol";
import {Asset} from "../../src/lib/types.sol";

/// @notice Pulls `amountIn` and pays `amountIn * rate / 1e18` of `tokenOut` from its own balance
contract MockExchange {
    uint256 public immutable rate;

    constructor(uint256 _rate) {
        rate = _rate;
    }

    function swap(IERC20 _tokenIn, uint256 _amountIn, IERC20 _tokenOut, address _recipient) external {
        _tokenIn.transferFrom(msg.sender, address(this), _amountIn);
        _tokenOut.transfer(_recipient, _amountIn * rate / 1e18);
    }
}

/// @notice A swap node: converts its whole input at the exchange's fixed rate
contract MockSwapAction is INodeAction {
    MockExchange public immutable exchange;
    IERC20 public immutable tokenOut;
    address public immutable dao;

    constructor(MockExchange _exchange, IERC20 _tokenOut, address _dao) {
        (exchange, tokenOut, dao) = (_exchange, _tokenOut, _dao);
    }

    function budget() external pure returns (IBudget) {}

    function preconditions(address, bytes calldata, Asset calldata, Asset calldata)
        external
        pure
        returns (bytes memory)
    {}

    function build(address, bytes calldata, Asset calldata _input)
        external
        view
        returns (Asset memory _output, Action[] memory _actions)
    {
        _output = Asset(tokenOut, _input.amount * exchange.rate() / 1e18);

        _actions = new Action[](2);
        _actions[0] =
            Action(address(_input.token), 0, abi.encodeCall(IERC20.approve, (address(exchange), _input.amount)));
        _actions[1] = Action(
            address(exchange), 0, abi.encodeCall(MockExchange.swap, (_input.token, _input.amount, tokenOut, dao))
        );
    }

    function postconditions(address, Asset calldata, Asset calldata, bytes calldata) external pure {}
}
