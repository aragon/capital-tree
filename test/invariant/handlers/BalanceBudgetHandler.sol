// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {DAO} from "@aragon/osx/core/dao/DAO.sol";
import {CapitalTreePlugin} from "../../../src/CapitalTreePlugin.sol";
import {WeightSplitter} from "../../../src/splitters/WeightSplitter.sol";
import {IBudget} from "../../../src/interfaces/IBudget.sol";
import {INodeAction} from "../../../src/interfaces/INodeAction.sol";
import {Node} from "../../../src/lib/types.sol";
import {ERC20Mock} from "../../mocks/ERC20Mock.sol";
import {BaseHandler} from "../base/BaseHandler.sol";

contract BalanceBudgetHandler is BaseHandler {
    uint256 internal constant MAX_DEPTH = 3;
    uint256 internal constant MAX_CHILDREN = 3;
    uint256 internal constant INITIAL_DEPOSIT = 5_000 ether;
    uint256 internal constant BENEFICIARY_COUNT = 3;

    enum Kind {
        Branch,
        Transfer,
        Burn,
        Keep,
        Beneficiary // pays the address in its node data, chosen per trigger
    }

    /// @dev One node of the model. Weights are the model's own copy, never read from the splitter.
    struct ModelNode {
        Kind kind;
        bool skip;
        uint256 recipient; // index into `recipients`, for a Transfer leaf
        WeightSplitter splitter; // for a Branch
        uint32[] children;
        uint32[] weights;
    }

    /// @dev What a trigger should do, computed by walking the model
    struct Outcome {
        uint256[] toRecipient;
        uint256[] toBeneficiary;
        uint256 burned;
        uint256 kept;
        bool reverts;
        bytes reason; // the revert data expected, when `reverts`
    }

    CapitalTreePlugin internal plugin;
    IBudget internal budget;
    ERC20Mock internal tokenA;
    address internal outside;

    // Leaves, shared by every tree: a component only has to belong to the DAO
    address[] internal recipients;
    address[] internal beneficiaries;
    INodeAction[] internal transfers; // transfers[i] pays recipients[i]
    INodeAction internal burn;
    INodeAction internal keep;
    INodeAction internal toBeneficiary;

    // The model of the installed tree
    ModelNode[] internal tree;

    // Ghosts: where token A should be
    uint256 public ghostDeposited;
    uint256[] internal ghostReceived; // per recipient
    uint256[] internal ghostToBeneficiary; // per beneficiary
    uint256 public ghostReceivedTotal; // recipients and beneficiaries
    uint256 public ghostBurned;
    uint256 public ghostOutflow;
    uint256 public ghostDao;

    // Call summary
    uint256 public triggers;
    uint256 public expectedReverts;
    uint256 public rebuilds;

    constructor(
        CapitalTreePlugin _plugin,
        IBudget _budget,
        ERC20Mock _tokenA,
        DAO _dao,
        address _root,
        address _manager,
        address[] memory _recipients,
        INodeAction[] memory _transfers,
        INodeAction _burn,
        INodeAction _keep,
        INodeAction _toBeneficiary
    ) BaseHandler(_dao, _root, _manager) {
        (plugin, budget, tokenA) = (_plugin, _budget, _tokenA);
        (recipients, transfers, burn, keep, toBeneficiary) = (_recipients, _transfers, _burn, _keep, _toBeneficiary);
        ghostReceived = new uint256[](_recipients.length);

        for (uint256 b; b < BENEFICIARY_COUNT; ++b) {
            beneficiaries.push(makeAddr(string.concat("beneficiary", vm.toString(b))));
        }
        ghostToBeneficiary = new uint256[](BENEFICIARY_COUNT);

        // Funds for the flow
        _tokenA.mint(address(_dao), INITIAL_DEPOSIT);
        ghostDeposited = INITIAL_DEPOSIT;
        ghostDao = _tokenA.balanceOf(address(_dao));
        outside = makeAddr("outside");
    }

    // Actions

    /// @dev Anyone may trigger. The model predicts whether it succeeds and where the funds go.
    ///      Funds arrive here rather than in a separate action, so most calls are triggers: an
    ///      empty DAO is always topped up (an empty root just reverts with `EmptyInput(0)`), and
    ///      half the time more arrives on top, so the amount split varies.
    ///      Every Beneficiary node names a random beneficiary in its node data.
    function trigger(uint256 _actorSeed, uint256 _topUp) external {
        address _caller = address(uint160(bound(_actorSeed, 1, 1_000)));

        // If dao has no balance, deposit before triggering
        if (tokenA.balanceOf(address(dao)) == 0) _deposit(_topUp);

        // Half the time, deposit some more
        uint256 _more = uint256(keccak256(abi.encode(_topUp)));
        if (_more % 2 == 0) _deposit(_more);

        uint256 _amount = tokenA.balanceOf(address(dao));

        // The caller picks each beneficiary; the model reads the same picks
        uint256[] memory _beneficiaryOf = new uint256[](tree.length);
        bytes[] memory _data = new bytes[](tree.length);
        for (uint256 i; i < tree.length; ++i) {
            if (tree[i].kind != Kind.Beneficiary) continue;
            _beneficiaryOf[i] = uint256(keccak256(abi.encode(_actorSeed, i))) % beneficiaries.length;
            _data[i] = abi.encode(beneficiaries[_beneficiaryOf[i]]);
        }

        Outcome memory _o = _expected(_amount, _beneficiaryOf);
        if (_o.reverts) {
            _assertRevertChangesNothing(_caller, _data, _o.reason);
            return;
        }

        vm.prank(_caller);
        plugin.trigger("", _data);
        triggers++;

        for (uint256 r; r < recipients.length; ++r) {
            ghostReceived[r] += _o.toRecipient[r];
            ghostReceivedTotal += _o.toRecipient[r];
        }

        for (uint256 b; b < beneficiaries.length; ++b) {
            ghostToBeneficiary[b] += _o.toBeneficiary[b];
            ghostReceivedTotal += _o.toBeneficiary[b];
        }

        ghostBurned += _o.burned;
        ghostDao = _o.kept;

        // The budget is the whole balance: after a trigger only the kept shares are left
        assertEq(tokenA.balanceOf(address(dao)), _o.kept, "dao keeps only the keep leaves' shares");
    }

    /// @notice Replaces the flow with a random valid tree
    /// @dev Built depth first: every node takes the next index when it's created, so every child
    ///      comes after its parent and has exactly one parent. The root may be a leaf (a one-node flow).
    function rebuildTree(uint256 _seed) public {
        delete tree;
        _build(uint256(keccak256(abi.encode(_seed))), 0);

        vm.prank(address(dao));
        plugin.setFlow(budget, _toNodes());
        rebuilds++;
    }

    /// @dev The manager replaces a random node's weights, when it's a branch; the count stays the same
    function setWeights(uint256 _nodeSeed, uint256 _seed) external {
        ModelNode storage _node = tree[_nodeSeed % tree.length];
        if (_node.kind != Kind.Branch) return;
        uint32[] memory _w = _randomWeights(_node.children.length, _seed);
        vm.prank(manager);
        _node.splitter.setWeights(_w);
        _node.weights = _w;
    }

    /// @dev New funds reach the DAO, 1 wei to 1M tokens
    function _deposit(uint256 _amount) internal {
        _amount = bound(_amount, 1, 1_000_000 ether);
        tokenA.mint(address(dao), _amount);
        ghostDeposited += _amount;
        ghostDao += _amount;
    }

    // Views for the invariants

    function recipientCount() external view returns (uint256) {
        return recipients.length;
    }

    function recipientAt(uint256 _r) external view returns (address) {
        return recipients[_r];
    }

    function received(uint256 _r) external view returns (uint256) {
        return ghostReceived[_r];
    }

    function beneficiaryCount() external view returns (uint256) {
        return beneficiaries.length;
    }

    function beneficiaryAt(uint256 _b) external view returns (address) {
        return beneficiaries[_b];
    }

    function receivedByBeneficiary(uint256 _b) external view returns (uint256) {
        return ghostToBeneficiary[_b];
    }

    function nodeCount() external view returns (uint256) {
        return tree.length;
    }

    // Model

    /// @dev Where `_amount` should go, or why the trigger should revert
    /// @param _beneficiaryOf The beneficiary each Beneficiary node names in the trigger's data
    function _expected(uint256 _amount, uint256[] memory _beneficiaryOf) internal view returns (Outcome memory _o) {
        _o.toRecipient = new uint256[](recipients.length);
        _o.toBeneficiary = new uint256[](beneficiaries.length);

        _walk(0, _amount, _beneficiaryOf, _o);
    }

    /// @dev Same order as the plugin: a node checks its input, runs, then its children left to right,
    ///      depth first. The first strict node that gets 0 reverts the whole trigger.
    function _walk(uint256 _i, uint256 _amount, uint256[] memory _beneficiaryOf, Outcome memory _o)
        internal
        view
    {
        if (_o.reverts) return;
        ModelNode storage _node = tree[_i];
        if (_amount == 0) {
            if (_node.skip) return; // skips the whole subtree
            (_o.reverts, _o.reason) = (true, abi.encodeWithSelector(CapitalTreePlugin.EmptyInput.selector, _i));
            return;
        }

        Kind _kind = _node.kind;

        if (_kind == Kind.Branch) {
            uint256[] memory _shares = _split(_amount, _node.weights);
            for (uint256 k; k < _node.children.length; ++k) {
                _walk(_node.children[k], _shares[k], _beneficiaryOf, _o);
            }
            return;
        }

        if (_kind == Kind.Transfer) {
            _o.toRecipient[_node.recipient] += _amount;
            return;
        }

        if (_kind == Kind.Beneficiary) {
            _o.toBeneficiary[_beneficiaryOf[_i]] += _amount;
            return;
        }

        if (_kind == Kind.Burn) {
            _o.burned += _amount;
            return;
        }

        // Keep: the amount stays in the DAO
        _o.kept += _amount;
    }

    // Tree building

    /// @dev Adds a node and, if it's a branch, its whole subtree. Returns the node's index.
    function _build(uint256 _seed, uint256 _depth) internal returns (uint32 _index) {
        _index = uint32(tree.length);
        tree.push();
        ModelNode storage _node = tree[_index];

        // 50% of nodes are skippable. If such a node receives 0, it and its children are skipped.
        // A non-skippable node that receives 0 makes the whole trigger revert.
        // The root can't be skippable (`setFlow` reverts with `SkippableRoot`).
        _node.skip = _index != 0 && (_seed >> 16) % 2 == 0;

        // A branch half the time, unless it's already as deep as allowed
        if (_depth == MAX_DEPTH || _seed % 2 == 1) {
            _node.kind = Kind((_seed >> 8) % 4 + 1); // Transfer, Burn, Keep or Beneficiary

            if (_node.kind == Kind.Transfer) {
                _node.recipient = (_seed >> 24) % recipients.length;
            }

            return _index;
        }

        // A branch: 2..MAX_CHILDREN children, each building its own subtree
        uint256 _childCount = 2 + (_seed >> 32) % (MAX_CHILDREN - 1);
        _node.kind = Kind.Branch;
        for (uint256 k; k < _childCount; ++k) {
            uint32 _child = _build(uint256(keccak256(abi.encode(_seed, k))), _depth + 1);
            tree[_index].children.push(_child);
        }
        tree[_index].weights = _randomWeights(_childCount, _seed >> 64);
        tree[_index].splitter = _deploySplitter(tree[_index].weights);
    }

    function _toNodes() internal view returns (Node[] memory _nodes) {
        _nodes = new Node[](tree.length);
        for (uint256 i; i < tree.length; ++i) {
            ModelNode storage _node = tree[i];
            _nodes[i].children = _node.children;
            _nodes[i].skipWhenEmpty = _node.skip;
            Kind _kind = _node.kind;
            if (_kind == Kind.Branch) _nodes[i].splitter = _node.splitter;
            else if (_kind == Kind.Transfer) _nodes[i].action = transfers[_node.recipient];
            else if (_kind == Kind.Beneficiary) _nodes[i].action = toBeneficiary;
            else if (_kind == Kind.Burn) _nodes[i].action = burn;
            else _nodes[i].action = keep;
        }
    }

    // Reverts

    /// @param _reason The exact revert data expected
    function _assertRevertChangesNothing(address _caller, bytes[] memory _data, bytes memory _reason) internal {
        uint256 _daoBefore = tokenA.balanceOf(address(dao));
        uint256 _supplyBefore = tokenA.totalSupply();
        uint256[] memory _recipientsBefore = new uint256[](recipients.length);
        for (uint256 r; r < recipients.length; ++r) {
            _recipientsBefore[r] = tokenA.balanceOf(recipients[r]);
        }
        uint256[] memory _beneficiariesBefore = new uint256[](beneficiaries.length);
        for (uint256 b; b < beneficiaries.length; ++b) {
            _beneficiariesBefore[b] = tokenA.balanceOf(beneficiaries[b]);
        }

        vm.prank(_caller);
        try plugin.trigger("", _data) {
            fail("trigger should have reverted");
        } catch (bytes memory _actual) {
            assertEq(_actual, _reason, "unexpected revert reason");
        }
        expectedReverts++;

        assertEq(tokenA.balanceOf(address(dao)), _daoBefore, "revert moved dao funds");
        assertEq(tokenA.totalSupply(), _supplyBefore, "revert burned");
        for (uint256 r; r < recipients.length; ++r) {
            assertEq(tokenA.balanceOf(recipients[r]), _recipientsBefore[r], "revert paid a recipient");
        }
        for (uint256 b; b < beneficiaries.length; ++b) {
            assertEq(tokenA.balanceOf(beneficiaries[b]), _beneficiariesBefore[b], "revert paid a beneficiary");
        }
    }
}
