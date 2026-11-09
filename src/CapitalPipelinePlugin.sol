// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
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
import {Asset, Node} from "./lib/types.sol";
import {TRIGGER_PERMISSION_ID, CONFIGURE_PERMISSION_ID, MANAGER_PERMISSION_ID, MAX_NODES} from "./lib/constants.sol";

/// @title CapitalPipelinePlugin
/// @notice Runs one flow: a budget feeding a tree of actions. The budget gives the root its input
///         once; every node passes its output to its children (split by a splitter when there are
///         several); leaves consume what they receive (transfer, burn, keep). The budget commits
///         once, after the whole tree ran.
/// @dev Every node that receives something must succeed: every node takes exactly its input, and
///      leaves output nothing. Anything else reverts the whole trigger. A node that receives nothing reverts it too, unless it's marked
///      `skipWhenEmpty`: then neither it nor anything below it runs.
///      Each node with an action is built (view) right after its parent ran and executes in its
///      own `dao.execute`, followed by the action's postconditions (such as recipient checks) and
///      balance checks: the DAO spent no more than the node's input and received at least its
///      declared output. The children get that declared output, or
///      everything that arrived when the node is marked `forwardSurplus`.
contract CapitalPipelinePlugin is PluginCloneable, PausableUpgradeable, ReentrancyGuardUpgradeable {
    /// @notice What the flow may spend; read at the start, committed at the end
    IBudget public budget;
    /// @dev Makes every execution ID unique, even for two triggers in one block. Counts triggers;
    ///      it can't change during one (`nonReentrant`), so the nodes read it from storage. Shares
    ///      `budget`'s slot, which every trigger reads anyway: keep the two declarations together.
    uint96 internal _nonce;

    Node[] internal _nodes;

    event FlowUpdated(IBudget budget, Node[] nodes);
    /// @param output What the children got: the declared output, or everything that arrived when the
    ///        node forwards its surplus
    event NodeExecuted(
        uint256 indexed nodeIndex, address indexed caller, bytes32 executionId, Asset input, Asset output
    );
    event BudgetCommitted(bytes32 executionId);

    // Configuration errors
    error NoBudget();
    error ForeignComponent(address component);
    error InvalidNodeCount(uint256 count);
    error SkippableRoot();
    error MissingAction(uint256 nodeIndex);
    error InvalidChild(uint256 nodeIndex, uint256 childIndex);
    error UnreachableNode(uint256 nodeIndex);
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
    /// @notice A leaf's action produced an output, but a leaf has no children to pass it to
    error OutputWithoutChildren(uint256 nodeIndex, uint256 amount);
    error MissingFunctionSelector(uint256 nodeIndex, uint256 actionIndex);
    error ActionTargetsDao(uint256 nodeIndex, uint256 actionIndex);
    error ActionTargetsPlugin(uint256 nodeIndex, uint256 actionIndex);
    error UnexpectedBalance(uint256 nodeIndex, address token, uint256 expected, uint256 actual);
    /// @notice The tree spent more of the budget's token than the budget made available
    error BudgetExceeded(uint256 available, uint256 spent);

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
        if (_data.length != 0 && _data.length != _len) {
            revert DataLengthMismatch(_len, _data.length);
        }

        ++_nonce;
        IERC20 _token = budget.token();
        uint256 _amount = budget.available(msg.sender, _budgetData);

        uint256 _before = _token.balanceOf(address(dao()));
        _runNode(0, Asset(_token, _amount), _data);
        _checkBudgetSpend(_token, _amount, _before);

        _commitBudget(_budgetData);
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
    function _runNode(uint256 _index, Asset memory _input, bytes[] calldata _data) internal {
        Node storage _node = _nodes[_index];
        if (_input.amount == 0) {
            // Skipping a node skips everything below it
            if (_node.skipWhenEmpty) return;
            revert EmptyInput(_index);
        }
        
        Asset memory _output;
        if (address(_node.action) == address(0)) {
            // If node has no action, the input becomes an output.
            _output = Asset(_input.token, _input.amount);
        } else {
            bytes calldata _nodeData = _data.length == 0 ? msg.data[0:0] : _data[_index];
            _output = _runAction(_index, _node.action, _input, _nodeData, _node.children.length == 0);
        }

        _runChildren(_index, _node, _output, _data);
    }

    /// @dev The children share `_output.amount`, each getting it as its input
    function _runChildren(uint256 _index, Node storage _node, Asset memory _output, bytes[] calldata _data)
        internal
    {
        uint256 _count = _node.children.length;
        if (_count == 0) return;
        if (_count == 1) {
            _runNode(_node.children[0], Asset(_output.token, _output.amount), _data);
            return;
        }

        uint256[] memory _amounts = _split(_index, _node.splitter, _output, _count);
        for (uint256 k; k < _count; ++k) {
            _runNode(_node.children[k], Asset(_output.token, _amounts[k]), _data);
        }
    }

    function _runAction(
        uint256 _index,
        INodeAction _action,
        Asset memory _input,
        bytes calldata _data,
        bool _leaf
    ) internal returns (Asset memory _output) {
        Action[] memory _actions;
        bytes memory _actionSnapshot;
        (_output, _actions, _actionSnapshot) = _buildAction(_index, _action, _input, _data, _leaf);
        (uint256 _inBefore, uint256 _outBefore) = _snapshot(_input, _output);

        bool _forwards = _nodes[_index].forwardSurplus;
        uint256 _before = _forwards ? _output.token.balanceOf(address(dao())) : 0;

        bytes32 _executionId = keccak256(abi.encode(address(this), _nonce, _index));
        _execute(_index, _actions, _executionId);
        _action.postconditions(msg.sender, _input, _output, _actionSnapshot);
        _verify(_index, _input, _output, _inBefore, _outBefore);

        // Give the children everything that arrived, not just the declared amount
        if (_forwards) _output.amount = _arrived(_input, _output, _before);

        emit NodeExecuted(_index, msg.sender, _executionId, _input, _output);
    }

    /// @dev Builds the node, then calls the action's preconditions on its output.
    ///      The node spends its whole input; the action's postconditions check that it did.
    function _buildAction(uint256 _index, INodeAction _action, Asset memory _input, bytes calldata _data, bool _leaf)
        internal
        view
        returns (Asset memory _output, Action[] memory _actions, bytes memory _actionSnapshot)
    {
        (_output, _actions) = _action.build(msg.sender, _data, _input);

        // `_leaf` means the node has no children: it's at the bottom of the tree.
        // `_output.amount` is how much the node says it produces for its children.
        // A leaf has no children to give anything to. So if a leaf says "I produce 250 GOV", 
        // those 250 GOV would arrive in the DAO and nobody would receive them.
        if (_leaf && _output.amount != 0) {
            revert OutputWithoutChildren(_index, _output.amount);
        }


        _actionSnapshot = _action.preconditions(msg.sender, _data, _input, _output);
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

    // Balance checks

    /// @dev The DAO's balances a node is checked against: its input token, and its output token
    ///      when that's another one and the node declares some
    function _snapshot(Asset memory _input, Asset memory _output)
        internal
        view
        returns (uint256 _inBefore, uint256 _outBefore)
    {
        address _dao = address(dao());
        _inBefore = _input.token.balanceOf(_dao);
        if (_output.token != _input.token && _output.amount != 0) _outBefore = _output.token.balanceOf(_dao);
    }

    /// @dev The node spent at most its input, and at least its declared output arrived: whatever
    ///      the action accepts, its children only get what really arrived. With one token only the
    ///      net change is visible: the DAO lost at most `input - output`.
    function _verify(uint256 _index, Asset memory _input, Asset memory _output, uint256 _inBefore, uint256 _outBefore)
        internal
        view
    {
        if (_output.token == _input.token) {
            _checkDao(_index, _input.token, _inBefore + _output.amount, _input.amount);
        } else {
            _checkDao(_index, _input.token, _inBefore, _input.amount);
            if (_output.amount != 0) _checkDao(_index, _output.token, _outBefore + _output.amount, 0);
        }
    }

    /// @dev Reverts unless `balance + spent >= target`
    function _checkDao(uint256 _index, IERC20 _token, uint256 _target, uint256 _spent) internal view {
        uint256 _actual = _token.balanceOf(address(dao()));
        if (_actual + _spent < _target) {
            revert UnexpectedBalance(_index, address(_token), _target > _spent ? _target - _spent : 0, _actual);
        }
    }

    /// @dev Whatever the nodes did, the whole tree spent at most what the budget made available.
    ///      Each action checks its own node; this catches anything that slips between them.
    function _checkBudgetSpend(IERC20 _token, uint256 _available, uint256 _before) internal view {
        uint256 _after = _token.balanceOf(address(dao()));
        if (_after + _available < _before) {
            // Safe: the condition implies `_before > _available`
            revert BudgetExceeded(_available, _before - _after);
        }
    }

    /// @dev After the whole tree ran, so a stream checkpoint sees the final balance
    function _commitBudget(bytes calldata _budgetData) internal {
        Action[] memory _actions = budget.commitActions(msg.sender, _budgetData);
        if (_actions.length == 0) return;

        bytes32 _executionId = keccak256(abi.encode(address(this), _nonce, type(uint256).max));
        _execute(_nodes.length, _actions, _executionId);
        emit BudgetCommitted(_executionId);
    }

    /// @dev What the children get from a forwarding node. With one token the input never left the
    ///      DAO, so it counts too: input + net change.
    function _arrived(Asset memory _input, Asset memory _output, uint256 _before) internal view returns (uint256) {
        uint256 _after = _output.token.balanceOf(address(dao()));

        // Example: the DAO holds 5000 USDC, 100 of them are the node's input. The node pays a
        // 2 USDC fee, so the DAO holds 4998. `4998 - 5000` loses the node's 100; adding the
        // input back gives `(4998 + 100) - 5000 = 98`, what's left for the children.
        if (_output.token == _input.token) _after += _input.amount;
        return _after > _before ? _after - _before : 0;
    }

    // Helpers

    /// @dev The splitter's amounts, which must be one per child and add up to what the children share
    function _split(uint256 _index, ISplitter _splitter, Asset memory _output, uint256 _count)
        internal
        view
        returns (uint256[] memory _amounts)
    {
        _amounts = _splitter.split(msg.sender, _output, _count);
        if (_amounts.length != _count) revert InvalidSplit(_index);

        uint256 _sum;
        for (uint256 k; k < _count; ++k) {
            _sum += _amounts[k];
        }
        if (_sum != _output.amount) revert InvalidSplit(_index);
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
    ///      rooted at node 0 with no cycles. A branch (2+ children) splits by a splitter of this DAO;
    ///      other nodes have none. A bound action must be bound to the flow's budget.
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

        bool _hasSplitter = address(_node.splitter) != address(0);
        if (_hasSplitter != (_count >= 2)) revert InvalidSplitter(_index);
        if (_hasSplitter) _checkOwnDao(address(_node.splitter));
    }

    /// @dev Every component is a clone initialized for this plugin's DAO. Implementations (bound to
    ///      no DAO) and other DAOs' components are rejected.
    function _checkOwnDao(address _component) internal view {
        if (DaoAuthorizableUpgradeable(_component).dao() != dao()) revert ForeignComponent(_component);
    }
}
