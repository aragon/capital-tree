// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import {ProxyLib} from "@aragon/osx-commons-contracts/src/utils/deployment/ProxyLib.sol";
import {CapitalPipelinePlugin} from "../src/CapitalPipelinePlugin.sol";
import {FundedStreamBudget} from "../src/budgets/FundedStreamBudget.sol";
import {BalanceBudget} from "../src/budgets/BalanceBudget.sol";
import {OpenFillAction} from "../src/actions/OpenFillAction.sol";
import {IBudget} from "../src/interfaces/IBudget.sol";
import {INodeAction} from "../src/interfaces/INodeAction.sol";
import {Asset} from "../src/lib/types.sol";
import {Fixture} from "./helpers/Fixture.sol";

contract NativeEthTest is Fixture {
    IERC20 internal constant NATIVE = IERC20(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);

    function test_RevertWhen_BalanceBudgetUsesNative() public {
        BalanceBudget _budget = BalanceBudget(ProxyLib.deployMinimalProxy(address(new BalanceBudget()), ""));
        vm.expectRevert(BalanceBudget.InvalidToken.selector);
        _budget.initialize(dao, NATIVE);
    }

    function test_RevertWhen_StreamUsesNative() public {
        FundedStreamBudget _budget =
            FundedStreamBudget(ProxyLib.deployMinimalProxy(address(new FundedStreamBudget()), ""));
        vm.expectRevert(FundedStreamBudget.InvalidToken.selector);
        _budget.initialize(dao, NATIVE, RATE, 0, EPOCH);
    }

    function test_RevertWhen_TokenIsUnset() public {
        FundedStreamBudget _budget =
            FundedStreamBudget(ProxyLib.deployMinimalProxy(address(new FundedStreamBudget()), ""));
        vm.expectRevert(FundedStreamBudget.InvalidToken.selector);
        _budget.initialize(dao, IERC20(address(0)), RATE, 0, EPOCH);
    }

    function test_RevertWhen_OpenFillDemandsNative() public {
        FundedStreamBudget _budget = _deployBudget(RATE, 0);
        OpenFillAction _action = OpenFillAction(ProxyLib.deployMinimalProxy(address(new OpenFillAction()), ""));
        vm.expectRevert(OpenFillAction.InvalidToken.selector);
        _action.initialize(dao, _budget, NATIVE, DEMAND);
    }

    function test_RevertWhen_NodeSendsEthWithoutSelector() public {
        _assertValueRejected(NativeAction.Mode.Work);
    }

    function _assertValueRejected(NativeAction.Mode _mode) internal {
        vm.deal(address(dao), 1 ether);
        NativeAction _action = new NativeAction(address(dao), _mode);
        CapitalPipelinePlugin _plugin = _deployPlugin(_deployBalanceBudget(tokenA), _chain(_action, keep));
        vm.expectRevert(abi.encodeWithSelector(CapitalPipelinePlugin.MissingFunctionSelector.selector, 0, 0));
        _plugin.trigger("", noData);
        assertEq(address(dao).balance, 1 ether);
        assertEq(tokenA.balanceOf(address(dao)), DAO_A);
    }

    function test_RevertWhen_BudgetCommitHasNoSelectorRollsBackTree() public {
        vm.deal(address(dao), 1 ether);
        NativeCommitBudget _budget = new NativeCommitBudget(address(dao), tokenA);
        CapitalPipelinePlugin _plugin = _deployPlugin(_budget, _one(_deployTransfer(alice)));
        vm.expectRevert(
            abi.encodeWithSelector(CapitalPipelinePlugin.MissingFunctionSelector.selector, type(uint256).max, 0)
        );
        _plugin.trigger("", noData);
        assertEq(address(dao).balance, 1 ether);
        assertEq(tokenA.balanceOf(address(dao)), DAO_A);
        assertEq(tokenA.balanceOf(alice), 0, "earlier node transfer rolled back");
    }

    function testFuzz_RevertWhen_ValueCallHasTruncatedSelector(uint8 _length) public {
        _length = uint8(bound(_length, 0, 3));
        vm.deal(address(dao), 1 ether);
        PayableTarget _target = new PayableTarget();
        NativeAction _action = new NativeAction(address(dao), NativeAction.Mode.Work);
        _action.setCall(address(_target), new bytes(_length));
        CapitalPipelinePlugin _plugin = _deployPlugin(_deployBalanceBudget(tokenA), _chain(_action, keep));
        vm.expectRevert(abi.encodeWithSelector(CapitalPipelinePlugin.MissingFunctionSelector.selector, 0, 0));
        _plugin.trigger("", noData);
        assertEq(address(dao).balance, 1 ether);
        assertEq(address(_target).balance, 0);
    }

    function test_NodeCallsPayableFunctionWithDaoEth() public {
        _assertPayableCall(NativeAction.Mode.Work, false);
    }

    function test_PayableCallbackCannotReenterTrigger() public {
        _assertPayableCall(NativeAction.Mode.Work, true);
    }

    function _assertPayableCall(NativeAction.Mode _mode, bool _reenter) internal {
        vm.deal(address(dao), 2 ether);
        PayableTarget _target = new PayableTarget();
        NativeAction _action = new NativeAction(address(dao), _mode);
        _action.setCall(address(_target), abi.encodeCall(PayableTarget.pay, ()));
        CapitalPipelinePlugin _plugin = _deployPlugin(_deployBalanceBudget(tokenA), _chain(_action, keep));
        if (_reenter) _target.setPlugin(_plugin);
        _plugin.trigger("", noData);
        assertEq(address(dao).balance, 1 ether);
        assertEq(address(_target).balance, 1 ether);
        assertEq(_target.sender(), address(dao));
        assertEq(tokenA.balanceOf(address(dao)), DAO_A, "ERC20 movement does not account for ETH fees");
        if (_reenter) {
            assertEq(
                _target.reentryError(), abi.encodeWithSignature("Error(string)", "ReentrancyGuard: reentrant call")
            );
        }
    }

    function test_BudgetCommitCallsPayableFunctionWithDaoEth() public {
        vm.deal(address(dao), 2 ether);
        PayableTarget _target = new PayableTarget();
        NativeCommitBudget _budget = new NativeCommitBudget(address(dao), tokenA);
        _budget.setCall(address(_target), abi.encodeCall(PayableTarget.pay, ()));
        CapitalPipelinePlugin _plugin = _deployPlugin(_budget, _one(_deployTransfer(alice)));
        _plugin.trigger("", noData);
        assertEq(address(dao).balance, 1 ether);
        assertEq(address(_target).balance, 1 ether);
        assertEq(_target.sender(), address(dao));
        assertEq(tokenA.balanceOf(alice), DAO_A);
    }

    function test_Erc20FlowLeavesNativeBalanceUntouched() public {
        vm.deal(address(dao), 1 ether);
        CapitalPipelinePlugin _plugin = _deployPlugin(_deployBalanceBudget(tokenA), _one(_deployTransfer(alice)));
        _plugin.trigger("", noData);
        assertEq(tokenA.balanceOf(alice), DAO_A);
        assertEq(address(dao).balance, 1 ether);
    }
}

contract NativeAction is INodeAction {
    enum Mode {
        Work,
        Output
    }

    address public immutable dao;
    Mode public immutable mode;
    address public target = address(0xBEEF);
    bytes public callData;

    function setCall(address _target, bytes calldata _data) external {
        target = _target;
        callData = _data;
    }

    constructor(address _dao, Mode _mode) {
        dao = _dao;
        mode = _mode;
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
        IERC20 _token = mode == Mode.Output ? IERC20(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE) : _input.token;
        _output = Asset(_token, _input.amount);
        if (mode == Mode.Work) _actions = _sendEth();
    }

    function postconditions(address, Asset calldata, Asset calldata, bytes calldata) external pure {}

    function _sendEth() internal view returns (Action[] memory _actions) {
        _actions = new Action[](1);
        _actions[0] = Action(target, 1 ether, callData);
    }
}

contract NativeCommitBudget is IBudget {
    address public immutable dao;
    IERC20 public immutable token;
    address public target = address(0xBEEF);
    bytes public callData;

    function setCall(address _target, bytes calldata _data) external {
        target = _target;
        callData = _data;
    }

    constructor(address _dao, IERC20 _token) {
        dao = _dao;
        token = _token;
    }

    function available(address, bytes calldata) external view returns (uint256) {
        return token.balanceOf(dao);
    }

    function fundActions(address, bytes calldata) external pure returns (Action[] memory) {}

    function commitActions(address, bytes calldata) external view returns (Action[] memory _actions) {
        _actions = new Action[](1);
        _actions[0] = Action(target, 1 ether, callData);
    }
}

contract PayableTarget {
    address public sender;
    CapitalPipelinePlugin public plugin;
    bytes public reentryError;

    function setPlugin(CapitalPipelinePlugin _plugin) external {
        plugin = _plugin;
    }

    function pay() external payable {
        sender = msg.sender;
        if (address(plugin) != address(0)) {
            try plugin.trigger("", new bytes[](0)) {}
            catch (bytes memory _reason) {
                reentryError = _reason;
            }
        }
    }
}
