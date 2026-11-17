// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import {IBudget} from "../../src/interfaces/IBudget.sol";
import {INodeAction} from "../../src/interfaces/INodeAction.sol";
import {Asset} from "../../src/lib/types.sol";

/// @notice A node action that misbehaves in one chosen way. Otherwise it passes its input through.
contract BadAction is INodeAction {
    enum Mode {
        Pass, // behaves: passes its whole input on
        Block, // preconditions revert
        Skip, // outputs nothing
        TakeHalf, // outputs half its input
        TargetDao, // returns an action whose target is the DAO
        TargetPlugin, // returns an action whose target is the plugin
        Lie, // declares 10 B of output it never produces
        Drain, // outputs nothing as a leaf but transfers twice its input away
        DrainB // outputs nothing as a leaf but transfers 1 wei of B away, whatever its input
    }

    address internal constant THIEF = address(0xBEEF);

    error Blocked();

    Mode public immutable mode;
    address public immutable dao;
    IERC20 public immutable tokenB;

    constructor(Mode _mode, address _dao, IERC20 _tokenB) {
        (mode, dao, tokenB) = (_mode, _dao, _tokenB);
    }

    function budget() external pure returns (IBudget) {}

    function preconditions(address, bytes calldata, Asset calldata, Asset calldata)
        external
        view
        returns (bytes memory)
    {
        if (mode == Mode.Block) revert Blocked();
        return "";
    }

    function build(address, bytes calldata, Asset calldata _input)
        external
        view
        returns (Asset memory _output, Action[] memory _actions)
    {
        _output = Asset(_input.token, _input.amount);
        if (mode == Mode.Skip) _output.amount = 0;
        if (mode == Mode.TakeHalf) _output.amount = _input.amount / 2;
        if (mode == Mode.Lie) _output = Asset(tokenB, 10 ether);
        if (mode == Mode.TargetDao || mode == Mode.TargetPlugin) {
            _actions = new Action[](1);
            _actions[0] = Action({to: mode == Mode.TargetDao ? dao : msg.sender, value: 0, data: ""});
        }
        if (mode == Mode.Drain) {
            _output.amount = 0;
            _actions = new Action[](1);
            _actions[0] = Action({
                to: address(_input.token), value: 0, data: abi.encodeCall(IERC20.transfer, (THIEF, 2 * _input.amount))
            });
        }
        if (mode == Mode.DrainB) {
            _output.amount = 0;
            _actions = new Action[](1);
            _actions[0] = Action({to: address(tokenB), value: 0, data: abi.encodeCall(IERC20.transfer, (THIEF, 1))});
        }
    }

    function postconditions(address, Asset calldata, Asset calldata, bytes calldata) external pure {}
}

/// @notice Has INodeAction's selectors, but its postconditions writes to storage. It doesn't
///         inherit the interface, whose hooks are views. Passes its input through, with no actions.
contract WritingCheckAction {
    address public immutable dao;
    uint256 public checks;

    constructor(address _dao) {
        dao = _dao;
    }

    function budget() external pure returns (IBudget) {}

    function build(address, bytes calldata, Asset calldata _input)
        external
        pure
        returns (Asset memory, Action[] memory)
    {
        return (Asset(_input.token, _input.amount), new Action[](0));
    }

    function preconditions(address, bytes calldata, Asset calldata, Asset calldata)
        external
        pure
        returns (bytes memory)
    {}

    function postconditions(address, Asset calldata, Asset calldata, bytes calldata) external {
        ++checks;
    }
}

/// @notice USDT-family failure mode: after `successfulTransfers` transfers, `transfer` returns
///         false without moving anything
contract FalseReturnToken is ERC20 {
    uint256 public successfulTransfers;

    constructor(uint256 _successfulTransfers) ERC20("False", "FALSE") {
        successfulTransfers = _successfulTransfers;
    }

    function mint(address _to, uint256 _amount) external {
        _mint(_to, _amount);
    }

    function transfer(address _to, uint256 _amount) public override returns (bool) {
        if (successfulTransfers == 0) return false;
        --successfulTransfers;
        return super.transfer(_to, _amount);
    }
}

/// @notice Accepts unknown calls in its fallback, like WETH9, so `burn(uint256)` succeeds without burning
contract FallbackToken is ERC20 {
    constructor() ERC20("Fallback", "FALLBACK") {}

    function mint(address _to, uint256 _amount) external {
        _mint(_to, _amount);
    }

    fallback() external {}
}
