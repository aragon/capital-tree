// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {DAO} from "@aragon/osx/core/dao/DAO.sol";
import {ProxyLib} from "@aragon/osx-commons-contracts/src/utils/deployment/ProxyLib.sol";
import {CapitalTreePlugin} from "../../../src/CapitalTreePlugin.sol";
import {OpenFillAction} from "../../../src/actions/OpenFillAction.sol";
import {WeightSplitter} from "../../../src/splitters/WeightSplitter.sol";
import {IBudget} from "../../../src/interfaces/IBudget.sol";
import {INodeAction} from "../../../src/interfaces/INodeAction.sol";
import {Node} from "../../../src/lib/types.sol";
import {RATIO_BASE, SET_SETTINGS_PERMISSION_ID} from "../../../src/lib/constants.sol";
import {ERC20Mock} from "../../mocks/ERC20Mock.sol";

/// @notice What every invariant handler shares: random trees, a model of where every token should
///         go, the running totals the invariants compare against, and the checks around a trigger.
/// @dev Two tokens: the budget's token A, and token B that OpenFill nodes buy with it. A handler
///      given no OpenFill action never builds OpenFill nodes, so its flows stay on token A.
abstract contract BaseHandler is Test {
    uint256 internal constant A = 0;
    uint256 internal constant B = 1;
    uint256 internal constant MAX_DEPTH = 3;
    uint256 internal constant MAX_CHILDREN = 3;
    uint256 internal constant BENEFICIARY_COUNT = 3;

    enum Kind {
        Branch,
        Transfer,
        Burn,
        Keep,
        Beneficiary, // pays the address in its node data, chosen per trigger
        OpenFill // sells its A to the filler for B; its one child runs on B
    }

    /// @dev One node of the model. Weights are the model's own copy, never read from the splitter.
    struct ModelNode {
        Kind kind;
        bool skip;
        bool forwardSurplus; // for an OpenFill: its child gets all the B the filler sent
        uint256 token; // the token it receives: A, or B below an OpenFill
        uint256 recipient; // index into `recipients`, for a Transfer leaf
        WeightSplitter splitter; // for a Branch
        uint32[] children;
        uint32[] weights;
    }

    /// @dev What a trigger should do, computed by walking the model
    struct Run {
        uint256[] input; // what each node receives; 0 when it's skipped or never reached
        // The DAO's B balance at this point in the trigger. Earlier nodes change it (fills add B,
        // B leaves spend it), and `DemandNotMet` reports absolute balances, not amounts.
        uint256 daoTokenBBalance;
        bool reverts;
        bytes reason; // the revert data expected, when `reverts`
    }

    /// @dev Where one token should be, over all the triggers so far
    struct Totals {
        uint256 minted; // every token that exists or was burned
        uint256 burned;
        uint256 dao;
        uint256[] recipients; // per recipient
        uint256[] beneficiaries; // per beneficiary
    }

    /// @dev What a handler is built with
    struct Deps {
        DAO dao;
        address root; // holds ROOT on the DAO, to grant permissions on new components
        address manager;
        CapitalTreePlugin plugin;
        IBudget budget;
        ERC20Mock tokenA;
        ERC20Mock tokenB;
        address[] recipients;
        INodeAction[] transfers; // transfers[i] pays recipients[i]
        INodeAction burn;
        INodeAction keep;
        INodeAction toBeneficiary;
        OpenFillAction openFill; // address(0): no OpenFill nodes
    }

    DAO internal dao;
    address internal root;
    address internal manager;
    address internal splitterImpl;
    CapitalTreePlugin internal plugin;
    IBudget internal budget;
    ERC20Mock[2] internal tokens;

    // Leaves, shared by every tree: a component only has to belong to the DAO
    address[] internal recipients;
    address[] internal beneficiaries;
    INodeAction[] internal transfers;
    INodeAction internal burn;
    INodeAction internal keep;
    INodeAction internal toBeneficiary;
    OpenFillAction internal openFill;

    // The model's copy of the OpenFill settings, and what the filler sends on top of the demand
    uint256 internal demand;
    int256 internal fillDelta;

    // The model of the installed tree
    ModelNode[] internal tree;

    // Ghosts: where every token should be
    Totals internal ghostA;
    Totals internal ghostB;
    uint256 public ghostToFiller; // A only

    // Call summary
    uint256 public triggers;
    uint256 public expectedReverts;
    uint256 public rebuilds;

    constructor(Deps memory _deps) {
        (dao, root, manager, plugin, budget) = (
            _deps.dao, 
            _deps.root, 
            _deps.manager, 
            _deps.plugin, 
            _deps.budget
        );
        tokens = [_deps.tokenA, _deps.tokenB];

        recipients = _deps.recipients;

        // store actions
        (transfers, burn, keep, toBeneficiary, openFill) = (
            _deps.transfers,
            _deps.burn,
            _deps.keep, 
            _deps.toBeneficiary, 
            _deps.openFill
        );
        
        if (address(openFill) != address(0)) {
            demand = openFill.demandPerFill();
        }
        
        splitterImpl = address(new WeightSplitter());

        for (uint256 b; b < BENEFICIARY_COUNT; ++b) {
            beneficiaries.push(makeAddr(string.concat("beneficiary", vm.toString(b))));
        }

        for (uint256 i; i < 2; ++i) {
            Totals storage _ghost = _ghostOf(i);
            _ghost.minted = tokens[i].totalSupply();
            _ghost.dao = tokens[i].balanceOf(address(dao));
            _ghost.recipients = new uint256[](recipients.length);
            _ghost.beneficiaries = new uint256[](BENEFICIARY_COUNT);
        }
    }

    // Shared actions

    /// @notice Replaces the flow with a random valid tree
    /// @dev Built depth first: every node takes the next index when it's created, so every child
    ///      comes after its parent and has exactly one parent. The root may be a leaf (a one-node flow).
    function rebuildTree(uint256 _seed) public {
        delete tree;
        _build(uint256(keccak256(abi.encode(_seed))), 0, A);

        vm.prank(address(dao));
        plugin.setFlow(budget, _toNodes());
        rebuilds++;
    }

    /// @dev The manager replaces a random node's weights, when it has a splitter (a branch, or an
    ///      OpenFill with 2+ children); the count stays the same
    function setWeights(uint256 _nodeSeed, uint256 _seed) external {
        ModelNode storage _node = tree[_nodeSeed % tree.length];
        if (address(_node.splitter) == address(0)) return;
        uint32[] memory _w = _randomWeights(_node.children.length, _seed);
        vm.prank(manager);
        _node.splitter.setWeights(_w);
        _node.weights = _w;
    }

    // Views for the invariants

    function recipientCount() external view returns (uint256) {
        return recipients.length;
    }

    function recipientAt(uint256 _r) external view returns (address) {
        return recipients[_r];
    }

    function ghostMinted(uint256 _token) external view returns (uint256) {
        return _ghostOf(_token).minted;
    }

    function ghostBurned(uint256 _token) external view returns (uint256) {
        return _ghostOf(_token).burned;
    }

    function ghostDao(uint256 _token) external view returns (uint256) {
        return _ghostOf(_token).dao;
    }

    function receivedByRecipient(uint256 _token, uint256 _r) external view returns (uint256) {
        return _ghostOf(_token).recipients[_r];
    }

    function beneficiaryCount() external view returns (uint256) {
        return beneficiaries.length;
    }

    function beneficiaryAt(uint256 _b) external view returns (address) {
        return beneficiaries[_b];
    }

    function receivedByBeneficiary(uint256 _token, uint256 _b) external view returns (uint256) {
        return _ghostOf(_token).beneficiaries[_b];
    }

    function nodeCount() external view returns (uint256) {
        return tree.length;
    }

    // Triggering

    /// @dev Triggers the flow on `_amount` of A as `_caller`. The model predicts the result first:
    ///      a revert must happen with exactly that reason and change nothing; a success must leave
    ///      the DAO holding exactly what the model says.
    /// @param _seed Picks the beneficiary each Beneficiary node names
    /// @return _ok Whether the trigger succeeded
    function _trigger(address _caller, uint256 _amount, uint256 _seed) internal returns (bool _ok) {
        // Check if tree contains transferToBeneficiaryAction:
        // If so, set the addresses for each action beneficiary. 
        uint256[] memory _beneficiaryOf = new uint256[](tree.length);
        bytes[] memory _data = new bytes[](tree.length);
        for (uint256 i; i < tree.length; ++i) {
            if (tree[i].kind != Kind.Beneficiary) continue;
            _beneficiaryOf[i] = uint256(keccak256(abi.encode(_seed, i))) % beneficiaries.length;
            _data[i] = abi.encode(beneficiaries[_beneficiaryOf[i]]);
        }
        
        Run memory _run = _simulate(_amount);
        if (_run.reverts) {
            _assertRevertChangesNothing(_caller, _data, _run.reason);
            return false;
        }

        vm.prank(_caller);
        plugin.trigger("", _data);
        triggers++;

        _record(_run.input, _beneficiaryOf);
        assertEq(tokens[A].balanceOf(address(dao)), ghostA.dao, "dao A after the trigger");
        assertEq(tokens[B].balanceOf(address(dao)), ghostB.dao, "dao B after the trigger");
        return true;
    }

    /// @dev New A reaches the DAO, 1 wei to 1M tokens
    function _deposit(uint256 _amount) internal {
        _amount = bound(_amount, 1, 1_000_000 ether);
        tokens[A].mint(address(dao), _amount);
        ghostA.minted += _amount;
        ghostA.dao += _amount;
    }

    // Model

    /// @dev What each node receives when the root gets `_amount` of A, or why the trigger reverts
    function _simulate(uint256 _amount) internal view returns (Run memory _run) {
        _run.input = new uint256[](tree.length);
        _run.daoTokenBBalance = tokens[B].balanceOf(address(dao));
        _walk(0, _amount, _run);
    }

    /// @dev Step 1, the simulation: works out what node `_i` receives and passes it on, in the
    ///      plugin's order (a node checks its input, runs, then its children left to right, depth
    ///      first). The first failure in that order is the trigger's revert. No bookkeeping here.
    function _walk(uint256 _i, uint256 _amount, Run memory _run) internal view {
        if (_run.reverts) return;
        ModelNode storage _node = tree[_i];

        if (_amount == 0) {
            if (_node.skip) return; // skips the whole subtree
            (_run.reverts, _run.reason) = (
                true, 
                abi.encodeWithSelector(CapitalTreePlugin.EmptyInput.selector, _i)
            );
            return;
        }

        _run.input[_i] = _amount;
        Kind _kind = _node.kind;

        if (_kind == Kind.Branch) {
            _walkChildren(_node, _amount, _run);
            return;
        }

        if (_kind == Kind.OpenFill) {
            uint256 _sent = _delivered();
            if (_sent < demand) {
                // OpenFill's own postcondition runs before the plugin's balance checks
                (_run.reverts, _run.reason) = (
                    true,
                    abi.encodeWithSelector(
                        OpenFillAction.DemandNotMet.selector, 
                        _run.daoTokenBBalance + demand, 
                        _run.daoTokenBBalance + _sent
                    )
                );
                return;
            }
            _run.daoTokenBBalance += _sent;

            // Without forwarding, the children share the demand and the surplus stays in the DAO
            _walkChildren(_node, _node.forwardSurplus ? _sent : demand, _run);
            return;
        }

        // A leaf. Spending B lowers the balance a later OpenFill's `DemandNotMet` reports.
        if (_node.token == B && _kind != Kind.Keep) _run.daoTokenBBalance -= _amount;
    }

    /// @dev Passes a node's output to its children: all of it to a single child, split by the
    ///      node's weights among several
    function _walkChildren(ModelNode storage _node, uint256 _output, Run memory _run) internal view {
        if (_node.children.length == 1) {
            _walk(_node.children[0], _output, _run);
            return;
        }
        uint256[] memory _shares = _split(_output, _node.weights);
        for (uint256 k; k < _node.children.length; ++k) {
            _walk(_node.children[k], _shares[k], _run);
        }
    }

    /// @dev Step 2, the bookkeeping, after the trigger succeeded: adds what every node received to
    ///      the totals of the token it received
    /// @param _beneficiaryOf The beneficiary each Beneficiary node named in the trigger's data
    function _record(uint256[] memory _input, uint256[] memory _beneficiaryOf) internal {
        for (uint256 i; i < tree.length; ++i) {
            uint256 _amount = _input[i];
            if (_amount == 0) continue; // skipped, or never reached

            ModelNode storage _node = tree[i];
            Totals storage _ghost = _node.token == A ? ghostA : ghostB;
            Kind _kind = _node.kind;

            if (_kind == Kind.Transfer) {
                _ghost.recipients[_node.recipient] += _amount;
                _ghost.dao -= _amount;
            } else if (_kind == Kind.Beneficiary) {
                _ghost.beneficiaries[_beneficiaryOf[i]] += _amount;
                _ghost.dao -= _amount;
            } else if (_kind == Kind.Burn) {
                _ghost.burned += _amount;
                _ghost.dao -= _amount;
            } else if (_kind == Kind.OpenFill) {
                // The filler takes the A and mints B to the DAO
                ghostA.dao -= _amount;
                ghostToFiller += _amount;
                ghostB.dao += _delivered();
                ghostB.minted += _delivered();
            }
            // Branch and Keep: nothing leaves the DAO
        }
    }

    /// @dev The B the filler sends for one fill
    function _delivered() internal view returns (uint256) {
        return uint256(int256(demand) + fillDelta);
    }

    /// @dev The totals of token `_t`. A storage reference: writing to it writes to `ghostA` or `ghostB`.
    function _ghostOf(uint256 _t) internal view returns (Totals storage) {
        return _t == A ? ghostA : ghostB;
    }

    // Tree building

    /// @dev Adds a node receiving token `_t` and, below it, its whole subtree. Returns the node's index.
    function _build(uint256 _seed, uint256 _depth, uint256 _t) internal returns (uint32 _index) {
        _index = uint32(tree.length);
        tree.push();
        ModelNode storage _node = tree[_index];
        _node.token = _t;

        // 50% of nodes are skippable. If such a node receives 0, it and its children are skipped.
        // A non-skippable node that receives 0 makes the whole trigger revert.
        // The root can't be skippable (`setFlow` reverts with `SkippableRoot`).
        _node.skip = _index != 0 && (_seed >> 16) % 2 == 0;

        bool _atMaxDepth = _depth == MAX_DEPTH;

        // A branch half the time, unless it's already as deep as allowed
        if (!_atMaxDepth && _seed % 2 == 0) {
            uint256 _childCount = 2 + (_seed >> 32) % (MAX_CHILDREN - 1);
            _node.kind = Kind.Branch;
            for (uint256 k; k < _childCount; ++k) {
                uint32 _child = _build(uint256(keccak256(abi.encode(_seed, k))), _depth + 1, _t);
                tree[_index].children.push(_child);
            }
            tree[_index].weights = _randomWeights(_childCount, _seed >> 64);
            tree[_index].splitter = _deploySplitter(tree[_index].weights);
            return _index;
        }

        // Otherwise, on A and when the handler has one, an OpenFill half the time. It has 1 to
        // MAX_CHILDREN children on B; with 2 or more it splits its output by its own splitter.
        bool _canFill = _t == A && address(openFill) != address(0);
        if (!_atMaxDepth && _canFill && (_seed >> 4) % 2 == 0) {
            uint256 _childCount = 1 + (_seed >> 32) % MAX_CHILDREN;
            _node.kind = Kind.OpenFill;
            _node.forwardSurplus = (_seed >> 40) % 2 == 0;
            for (uint256 k; k < _childCount; ++k) {
                uint32 _child = _build(uint256(keccak256(abi.encode(_seed, "fill", k))), _depth + 1, B);
                tree[_index].children.push(_child);
            }
            if (_childCount >= 2) {
                tree[_index].weights = _randomWeights(_childCount, _seed >> 64);
                tree[_index].splitter = _deploySplitter(tree[_index].weights);
            }
            return _index;
        }

        // A leaf
        _node.kind = Kind((_seed >> 8) % 4 + 1); // Transfer, Burn, Keep or Beneficiary
        if (_node.kind == Kind.Transfer) {
            _node.recipient = (_seed >> 24) % recipients.length;
        }
    }

    function _toNodes() internal view returns (Node[] memory _nodes) {
        _nodes = new Node[](tree.length);
        for (uint256 i; i < tree.length; ++i) {
            ModelNode storage _node = tree[i];
            _nodes[i].children = _node.children;
            _nodes[i].skipWhenEmpty = _node.skip;
            _nodes[i].forwardSurplus = _node.forwardSurplus;
            _nodes[i].splitter = _node.splitter; // set on every node with 2+ children, else address(0)
            Kind _kind = _node.kind;
            if (_kind == Kind.Branch) continue; // no action
            else if (_kind == Kind.OpenFill) _nodes[i].action = openFill;
            else if (_kind == Kind.Transfer) _nodes[i].action = transfers[_node.recipient];
            else if (_kind == Kind.Beneficiary) _nodes[i].action = toBeneficiary;
            else if (_kind == Kind.Burn) _nodes[i].action = burn;
            else _nodes[i].action = keep;
        }
    }

    /// @dev A weight splitter of the DAO, whose weights the manager can change
    function _deploySplitter(uint32[] memory _w) internal returns (WeightSplitter _splitter) {
        _splitter = WeightSplitter(
            ProxyLib.deployMinimalProxy(
                splitterImpl, abi.encodeCall(WeightSplitter.initialize, (dao, new address[](0), abi.encode(_w)))
            )
        );
        vm.prank(root);
        dao.grant(address(_splitter), manager, SET_SETTINGS_PERMISSION_ID);
    }

    /// @dev What a weight splitter should give each child: each share rounds down, and the remainder
    ///      goes to the first of the largest weights
    function _split(uint256 _amount, uint32[] memory _w) internal pure returns (uint256[] memory _amounts) {
        _amounts = new uint256[](_w.length);
        uint256 _largest;
        uint256 _sum;
        for (uint256 k; k < _w.length; ++k) {
            _amounts[k] = _amount * _w[k] / RATIO_BASE;
            _sum += _amounts[k];
            if (_w[k] > _w[_largest]) _largest = k;
        }
        _amounts[_largest] += _amount - _sum;
    }

    /// @dev `_n` non-zero weights summing to RATIO_BASE
    function _randomWeights(uint256 _n, uint256 _seed) internal pure returns (uint32[] memory _w) {
        _w = new uint32[](_n);
        uint256 _left = RATIO_BASE;
        for (uint256 k; k < _n - 1; ++k) {
            _seed = uint256(keccak256(abi.encode(_seed, k)));
            // Leave at least 1 for each child still to come
            uint256 _max = _left - (_n - 1 - k);
            _w[k] = uint32(1 + _seed % _max);
            _left -= _w[k];
        }
        _w[_n - 1] = uint32(_left);
    }

    // Reverts

    /// @dev The trigger reverts with exactly `_reason`, and no balance or supply of either token moved
    function _assertRevertChangesNothing(address _caller, bytes[] memory _data, bytes memory _reason) internal {
        uint256[2] memory _daoBefore;
        uint256[2] memory _supplyBefore;
        uint256[][2] memory _recipientsBefore;
        uint256[][2] memory _beneficiariesBefore;
        for (uint256 t; t < 2; ++t) {
            _daoBefore[t] = tokens[t].balanceOf(address(dao));
            _supplyBefore[t] = tokens[t].totalSupply();
            _recipientsBefore[t] = _balancesOf(tokens[t], recipients);
            _beneficiariesBefore[t] = _balancesOf(tokens[t], beneficiaries);
        }
        uint256 _fillerBefore = tokens[A].balanceOf(address(this));

        vm.prank(_caller);
        try plugin.trigger("", _data) {
            fail("trigger should have reverted");
        } catch (bytes memory _actual) {
            assertEq(_actual, _reason, "unexpected revert reason");
        }
        expectedReverts++;

        for (uint256 t; t < 2; ++t) {
            assertEq(tokens[t].balanceOf(address(dao)), _daoBefore[t], "revert moved dao funds");
            assertEq(tokens[t].totalSupply(), _supplyBefore[t], "revert changed the supply");
            assertEq(_balancesOf(tokens[t], recipients), _recipientsBefore[t], "revert paid a recipient");
            assertEq(_balancesOf(tokens[t], beneficiaries), _beneficiariesBefore[t], "revert paid a beneficiary");
        }
        assertEq(tokens[A].balanceOf(address(this)), _fillerBefore, "revert paid the filler");
    }

    function _balancesOf(ERC20Mock _token, address[] storage _holders)
        internal
        view
        returns (uint256[] memory _balances)
    {
        _balances = new uint256[](_holders.length);
        for (uint256 h; h < _holders.length; ++h) {
            _balances[h] = _token.balanceOf(_holders[h]);
        }
    }
}
