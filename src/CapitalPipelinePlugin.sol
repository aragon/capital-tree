// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {IDAO} from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";
import {IExecutor, Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import {PluginCloneable} from "@aragon/osx-commons-contracts/src/plugin/PluginCloneable.sol";
import {
    DaoAuthorizableUpgradeable
} from "@aragon/osx-commons-contracts/src/permission/auth/DaoAuthorizableUpgradeable.sol";
import {IBudget} from "./interfaces/IBudget.sol";
import {INodeAction} from "./interfaces/INodeAction.sol";
import {ISplitter} from "./interfaces/ISplitter.sol";
import {Input, Movement, Node, Record} from "./lib/types.sol";
import {
    TRIGGER_PERMISSION_ID,
    CONFIGURE_PERMISSION_ID,
    MANAGER_PERMISSION_ID,
    RATIO_BASE,
    MAX_NODES
} from "./lib/constants.sol";

/// @title CapitalPipelinePlugin
/// @notice Runs one flow: a budget feeding a tree of actions. The budget gives the root its input
///         once; every node passes its output to its children (split by fixed weights or a
///         splitter when there are several); leaves consume what they receive (transfer, burn,
///         keep). The budget commits once, after the whole tree ran.
/// @dev Every node that receives something must succeed: every node takes exactly its input, and
///      leaves output nothing. Anything else reverts the whole trigger. A node that receives nothing reverts it too, unless it's marked
///      `skipWhenEmpty`: then neither it nor anything below it runs.
///      Each node with an action is built (view) right after its parent ran and executes in its
///      own `dao.execute`, followed by the action's postconditions (read-only calls the plugin
///      makes, such as recipient checks) and balance checks: the DAO spent no more than the node's
///      input and received at least its declared output. The children get that declared output, or
///      everything that arrived when the node is marked `forwardSurplus`.
contract CapitalPipelinePlugin is PluginCloneable, PausableUpgradeable, ReentrancyGuardUpgradeable {
    /// @notice What the flow may spend; read at the start, committed at the end
    IBudget public budget;

    Node[] internal _nodes;

    /// @dev Makes every execution ID unique
    uint256 internal _nonce;

    event FlowUpdated(IBudget budget, Node[] nodes);
    event NodeExecuted(uint256 indexed nodeIndex, address indexed caller, bytes32 executionId, Record record);
    event BudgetCommitted(bytes32 executionId);

    // Configuration errors
    error NoBudget();
    error ForeignComponent(address component);
    error InvalidNodeCount(uint256 count);
    error SkippableRoot();
    error MissingAction(uint256 nodeIndex);
    error InvalidChild(uint256 nodeIndex, uint256 childIndex);
    error UnreachableNode(uint256 nodeIndex);
    error InvalidWeights(uint256 nodeIndex);
    error InvalidSplitter(uint256 nodeIndex);
    error BudgetMismatch(uint256 nodeIndex);
    error InvalidForwardSurplus(uint256 nodeIndex);

    // Trigger errors
    error DataLengthMismatch(uint256 expected, uint256 actual);
    error EmptyInput(uint256 nodeIndex);
    error InputTokenMismatch(uint256 nodeIndex);
    error InAmountExceedsInput(uint256 nodeIndex, uint256 inAmount, uint256 input);
    error NodeIncomplete(uint256 nodeIndex, uint256 inAmount, uint256 input);
    error InvalidSplit(uint256 nodeIndex);
    error LeafLeftOutput(uint256 nodeIndex, uint256 outAmount);
    error InvalidOutToken(uint256 nodeIndex);
    error OutputBelowInput(uint256 nodeIndex, uint256 outAmount, uint256 inAmount);
    error BeneficiaryChanged(uint256 nodeIndex);
    error MissingFunctionSelector(uint256 nodeIndex, uint256 actionIndex);
    error CheckSendsValue(uint256 nodeIndex, uint256 checkIndex);
    error ActionTargetsDao(uint256 nodeIndex, uint256 actionIndex);
    error ActionTargetsPlugin(uint256 nodeIndex, uint256 actionIndex);
    error UnexpectedBalance(uint256 nodeIndex, address token, uint256 expected, uint256 actual);

    function initialize(IDAO _dao, IBudget _budget, Node[] calldata _newNodes) external initializer {
        __PluginCloneable_init(_dao);
        __Pausable_init();
        __ReentrancyGuard_init();
        _setFlow(_budget, _newNodes);
    }

    /// @notice Runs the flow
    /// @param _budgetData Passed to the budget (a Merkle claim's proof); empty for most budgets
    /// @param _data Empty, or one entry per node (passed to that node's action)
    function trigger(bytes calldata _budgetData, bytes[] calldata _data)
        external
        nonReentrant
        whenNotPaused
        auth(TRIGGER_PERMISSION_ID)
    {
        uint256 _len = _nodes.length;
        if (_data.length != 0 && _data.length != _len) revert DataLengthMismatch(_len, _data.length);

        uint256 _callNonce = _nonce++;
        (uint256 _amount, address _beneficiary) = budget.available(msg.sender, _budgetData);
        _runNode(0, Input(budget.token(), _amount, _beneficiary), _data, _callNonce);
        _commitBudget(_callNonce, _budgetData);
    }

    /// @notice Replaces the flow. DAO only: an action can return arbitrary DAO actions.
    function setFlow(IBudget _budget, Node[] calldata _newNodes) external nonReentrant auth(CONFIGURE_PERMISSION_ID) {
        _setFlow(_budget, _newNodes);
    }

    /// @notice Stops the flow until `unpause`
    function pause() external auth(MANAGER_PERMISSION_ID) {
        _pause();
    }

    /// @notice Resumes the flow
    function unpause() external auth(MANAGER_PERMISSION_ID) {
        _unpause();
    }

    function nodes() external view returns (Node[] memory) {
        return _nodes;
    }

    // Running the tree

    /// @dev Runs node `_index` on `_input`, then its children, depth first
    function _runNode(uint256 _index, Input memory _input, bytes[] calldata _data, uint256 _callNonce) internal {
        Node storage _node = _nodes[_index];
        if (_input.amount == 0) {
            // Skipping a node skips everything below it
            if (_node.skipWhenEmpty) return;
            revert EmptyInput(_index);
        }

        Record memory _record;
        if (address(_node.action) == address(0)) {
            // A branch without an action passes its input on: nothing runs, so nothing moves
            _record.expected = Movement(_input.token, _input.amount, _input.token, _input.amount, _input.beneficiary);
            _record.forwarded = _input.amount;
        } else {
            bytes calldata _nodeData = _data.length == 0 ? msg.data[0:0] : _data[_index];
            _record = _runAction(_index, _node.action, _input, _nodeData, _node.children.length == 0, _callNonce);
        }

        _runChildren(_index, _node, _record, _data, _callNonce);
    }

    /// @dev The children share `_record.forwarded`
    function _runChildren(
        uint256 _index,
        Node storage _node,
        Record memory _record,
        bytes[] calldata _data,
        uint256 _callNonce
    ) internal {
        uint256 _count = _node.children.length;
        if (_count == 0) return;
        if (_count == 1) {
            _runNode(_node.children[0], _childInput(_record, _record.forwarded), _data, _callNonce);
            return;
        }

        ISplitter _splitter = _node.splitter;
        uint256[] memory _amounts = address(_splitter) == address(0)
            ? _weighted(_record.forwarded, _node.weights)
            : _split(_index, _splitter, _record, _count);
        for (uint256 k; k < _count; ++k) {
            _runNode(_node.children[k], _childInput(_record, _amounts[k]), _data, _callNonce);
        }
    }

    function _runAction(
        uint256 _index,
        INodeAction _action,
        Input memory _input,
        bytes calldata _data,
        bool _leaf,
        uint256 _callNonce
    ) internal returns (Record memory _record) {
        (Movement memory _movement, Action[] memory _actions, Action[] memory _checks) =
            _buildAction(_index, _action, _input, _data, _leaf);

        (uint256 _inBefore, uint256 _outBefore) = _snapshot(_movement);
        bytes32 _executionId = keccak256(abi.encode(address(this), _callNonce, _index));
        _execute(_index, _actions, _executionId);
        _runChecks(_index, _checks);
        _verify(_index, _movement, _inBefore, _outBefore);
        _record = _measure(_index, _movement, _inBefore, _outBefore);

        emit NodeExecuted(_index, msg.sender, _executionId, _record);
    }

    /// @dev Calls the action's hooks in order and checks its movement against the node's input
    function _buildAction(uint256 _index, INodeAction _action, Input memory _input, bytes calldata _data, bool _leaf)
        internal
        view
        returns (Movement memory _movement, Action[] memory _actions, Action[] memory _checks)
    {
        _action.preconditions(msg.sender, _input);
        (_movement, _actions) = _action.build(msg.sender, _data, _input);

        if (_movement.inAmount > _input.amount) {
            revert InAmountExceedsInput(_index, _movement.inAmount, _input.amount);
        }
        if (_movement.inAmount < _input.amount) {
            revert NodeIncomplete(_index, _movement.inAmount, _input.amount);
        }
        if (_movement.inToken != _input.token) revert InputTokenMismatch(_index);
        if (_leaf && _movement.outAmount != 0) revert LeafLeftOutput(_index, _movement.outAmount);
        _checkOutput(_index, _movement);
        _movement.beneficiary = _keepBeneficiary(_index, _input.beneficiary, _movement.beneficiary);

        _checks = _action.postconditions(msg.sender, _movement);
    }

    /// @dev An output that will be measured must be a token, and a node that forwards its surplus
    ///      with one token passes its whole input on
    function _checkOutput(uint256 _index, Movement memory _movement) internal view {
        bool _forwards = _nodes[_index].forwardSurplus;
        if ((_movement.outAmount != 0 || _forwards) && address(_movement.outToken).code.length == 0) {
            revert InvalidOutToken(_index);
        }
        if (_forwards && _movement.outToken == _movement.inToken && _movement.outAmount < _movement.inAmount) {
            revert OutputBelowInput(_index, _movement.outAmount, _movement.inAmount);
        }
    }

    function _execute(uint256 _index, Action[] memory _actions, bytes32 _executionId) internal {
        if (_actions.length == 0) return;

        address _dao = address(dao());
        for (uint256 i; i < _actions.length; ++i) {
            // Value-bearing calls must include a selector. This does not validate the target
            // or bound native spending: configured actions are trusted to authorize that spend.
            if (_actions[i].value != 0 && _actions[i].data.length < 4) {
                revert MissingFunctionSelector(_index, i);
            }
            if (_actions[i].to == _dao) revert ActionTargetsDao(_index, i);
            if (_actions[i].to == address(this)) revert ActionTargetsPlugin(_index, i);
        }
        IExecutor(_dao).execute(_executionId, _actions, 0);
    }

    /// @dev Right after the node's `dao.execute`. Read-only, so a check can't move funds or change
    ///      state; a failed check reverts the whole trigger with its own error.
    function _runChecks(uint256 _index, Action[] memory _checks) internal view {
        for (uint256 i; i < _checks.length; ++i) {
            if (_checks[i].value != 0) revert CheckSendsValue(_index, i);
            Address.functionStaticCall(_checks[i].to, _checks[i].data);
        }
    }

    /// @dev After the whole tree ran, so a stream checkpoint sees the final balance
    function _commitBudget(uint256 _callNonce, bytes calldata _budgetData) internal {
        Action[] memory _actions = budget.commitActions(msg.sender, _budgetData);
        if (_actions.length == 0) return;

        bytes32 _executionId = keccak256(abi.encode(address(this), _callNonce, type(uint256).max));
        _execute(_nodes.length, _actions, _executionId);
        emit BudgetCommitted(_executionId);
    }

    // Balance checks

    function _snapshot(Movement memory _movement) internal view returns (uint256 _inBefore, uint256 _outBefore) {
        address _dao = address(dao());
        _inBefore = _movement.inToken.balanceOf(_dao);
        if (_measuresOut(_movement)) _outBefore = _movement.outToken.balanceOf(_dao);
    }

    /// @dev Whether the output is a token of its own to measure. `_checkOutput` makes sure it is one
    ///      whenever the node declares an output or forwards its surplus.
    function _measuresOut(Movement memory _movement) internal view returns (bool) {
        return _movement.outToken != _movement.inToken && address(_movement.outToken).code.length != 0;
    }

    /// @dev The DAO spent at most `inAmount` and received at least `outAmount`
    function _verify(uint256 _index, Movement memory _movement, uint256 _inBefore, uint256 _outBefore) internal view {
        if (_movement.outToken == _movement.inToken) {
            _checkDao(_index, _movement.inToken, _inBefore + _movement.outAmount, _movement.inAmount);
        } else {
            _checkDao(_index, _movement.inToken, _inBefore, _movement.inAmount);
            if (_movement.outAmount != 0) _checkDao(_index, _movement.outToken, _outBefore + _movement.outAmount, 0);
        }
    }

    /// @dev What the node really did, from the DAO's balances, and what its children share:
    ///      `outAmount`, or everything that arrived when the node forwards its surplus. With one token
    ///      only the net change is visible. `_verify` and `OutputBelowInput` keep `forwarded` at or
    ///      above `outAmount`.
    function _measure(uint256 _index, Movement memory _movement, uint256 _inBefore, uint256 _outBefore)
        internal
        view
        returns (Record memory _record)
    {
        _record.expected = _movement;
        address _dao = address(dao());
        uint256 _inAfter = _movement.inToken.balanceOf(_dao);
        if (_inAfter < _inBefore) _record.spent = _inBefore - _inAfter;

        bool _oneToken = _movement.outToken == _movement.inToken;
        if (_oneToken) {
            if (_inAfter > _inBefore) _record.received = _inAfter - _inBefore;
        } else if (_measuresOut(_movement)) {
            uint256 _outAfter = _movement.outToken.balanceOf(_dao);
            if (_outAfter > _outBefore) _record.received = _outAfter - _outBefore;
        }

        if (!_nodes[_index].forwardSurplus) _record.forwarded = _movement.outAmount;
        else if (_oneToken) _record.forwarded = _movement.inAmount + _record.received;
        else _record.forwarded = _record.received;
    }

    /// @dev Reverts unless `balance + spent >= target`
    function _checkDao(uint256 _index, IERC20 _token, uint256 _target, uint256 _spent) internal view {
        uint256 _actual = _token.balanceOf(address(dao()));
        if (_actual + _spent < _target) {
            revert UnexpectedBalance(_index, address(_token), _target > _spent ? _target - _spent : 0, _actual);
        }
    }

    // Helpers

    function _childInput(Record memory _record, uint256 _amount) internal pure returns (Input memory) {
        return Input(_record.expected.outToken, _amount, _record.expected.beneficiary);
    }

    /// @dev Splits `_amount` by `_weights`; the rounding remainder goes to the largest weight
    function _weighted(uint256 _amount, uint32[] storage _weights) internal view returns (uint256[] memory _amounts) {
        uint256 _count = _weights.length;
        _amounts = new uint256[](_count);

        uint256 _assigned;
        uint256 _largest;
        for (uint256 k; k < _count; ++k) {
            _amounts[k] = (_amount * _weights[k]) / RATIO_BASE;
            _assigned += _amounts[k];
            if (_weights[k] > _weights[_largest]) _largest = k;
        }
        _amounts[_largest] += _amount - _assigned;
    }

    /// @dev The splitter's amounts, which must be one per child and add up to what the children share
    function _split(uint256 _index, ISplitter _splitter, Record memory _record, uint256 _count)
        internal
        view
        returns (uint256[] memory _amounts)
    {
        _amounts = _splitter.split(msg.sender, _record, _count);
        if (_amounts.length != _count) revert InvalidSplit(_index);

        uint256 _sum;
        for (uint256 k; k < _count; ++k) {
            _sum += _amounts[k];
        }
        if (_sum != _record.forwarded) revert InvalidSplit(_index);
    }

    /// @dev Once set, the beneficiary carries on; an action may leave it unset but not change it
    function _keepBeneficiary(uint256 _index, address _current, address _proposed) internal pure returns (address) {
        if (_current == address(0) || _proposed == _current) return _proposed;
        if (_proposed == address(0)) return _current;
        revert BeneficiaryChanged(_index);
    }

    // Configuration

    function _setFlow(IBudget _budget, Node[] calldata _newNodes) internal {
        if (address(_budget) == address(0)) revert NoBudget();
        _checkOwnDao(address(_budget));
        uint256 _len = _newNodes.length;
        if (_len == 0 || _len > MAX_NODES) revert InvalidNodeCount(_len);
        // A trigger with nothing to do reverts
        if (_newNodes[0].skipWhenEmpty) revert SkippableRoot();

        delete _nodes;
        bool[] memory _hasParent = new bool[](_len);
        for (uint256 i; i < _len; ++i) {
            _checkNode(i, _newNodes[i], _budget, _hasParent);

            Node storage _stored = _nodes.push();
            _stored.action = _newNodes[i].action;
            _stored.children = _newNodes[i].children;
            _stored.weights = _newNodes[i].weights;
            _stored.splitter = _newNodes[i].splitter;
            _stored.skipWhenEmpty = _newNodes[i].skipWhenEmpty;
            _stored.forwardSurplus = _newNodes[i].forwardSurplus;
        }
        for (uint256 i = 1; i < _len; ++i) {
            if (!_hasParent[i]) revert UnreachableNode(i);
        }
        budget = _budget;

        emit FlowUpdated(_budget, _newNodes);
    }

    /// @dev Children come after their parent and have exactly one parent, so the nodes form a tree
    ///      rooted at node 0 with no cycles. A branch splits by weights summing to RATIO_BASE, or by
    ///      a splitter of this DAO with no weights. A bound action must be bound to the flow's budget.
    function _checkNode(uint256 _index, Node calldata _node, IBudget _budget, bool[] memory _hasParent) internal view {
        uint256 _count = _node.children.length;
        if (address(_node.action) == address(0)) {
            if (_count < 2) revert MissingAction(_index);
        } else {
            _checkOwnDao(address(_node.action));
            IBudget _bound = _node.action.budget();
            if (address(_bound) != address(0) && _bound != _budget) revert BudgetMismatch(_index);
        }
        // Only an action can receive more than it declared, and only children can be given it
        if (_node.forwardSurplus && (address(_node.action) == address(0) || _count == 0)) {
            revert InvalidForwardSurplus(_index);
        }

        for (uint256 k; k < _count; ++k) {
            uint256 _child = _node.children[k];
            if (_child <= _index || _child >= _hasParent.length || _hasParent[_child]) {
                revert InvalidChild(_index, _child);
            }
            _hasParent[_child] = true;
        }

        if (address(_node.splitter) != address(0)) {
            if (_count < 2 || _node.weights.length != 0) revert InvalidSplitter(_index);
            _checkOwnDao(address(_node.splitter));
            return;
        }
        if (_count < 2) {
            if (_node.weights.length != 0) revert InvalidWeights(_index);
            return;
        }
        if (_node.weights.length != _count) revert InvalidWeights(_index);
        uint256 _sum;
        for (uint256 k; k < _count; ++k) {
            if (_node.weights[k] == 0) revert InvalidWeights(_index);
            _sum += _node.weights[k];
        }
        if (_sum != RATIO_BASE) revert InvalidWeights(_index);
    }

    /// @dev Every component is a clone initialized for this plugin's DAO. Implementations (bound to
    ///      no DAO) and other DAOs' components are rejected.
    function _checkOwnDao(address _component) internal view {
        if (DaoAuthorizableUpgradeable(_component).dao() != dao()) revert ForeignComponent(_component);
    }
}
