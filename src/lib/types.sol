// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {INodeAction} from "../interfaces/INodeAction.sol";
import {ISplitter} from "../interfaces/ISplitter.sol";

/// @notice What a node receives: the budget at the root, a share of its parent's output elsewhere
/// @param beneficiary Who the amount belongs to, once an action sets it (a Merkle claim).
///        Carried down every branch; it can't be changed once set.
struct Input {
    IERC20 token;
    uint256 amount;
    address beneficiary;
}

/// @notice What a node spends from its input and what it produces for its children
/// @param beneficiary The input's beneficiary, or the one the node sets when there was none
struct Movement {
    IERC20 inToken;
    uint256 inAmount;
    IERC20 outToken;
    uint256 outAmount;
    address beneficiary;
}

/// @notice What a node expected and what really happened, measured on the DAO's balances after it
///         ran. Passed to the node's splitter and emitted in `NodeExecuted`.
/// @param expected The movement the node's action declared (a pass-through for a branch without one)
/// @param spent Input token that left the DAO during the node. With one token, the net loss.
/// @param received Output token that came into the DAO during the node. With one token, the net gain.
/// @param forwarded What the children share: `expected.outAmount`, or everything that arrived when
///        the node is marked `forwardSurplus`
struct Record {
    Movement expected;
    uint256 spent;
    uint256 received;
    uint256 forwarded;
}

/// @notice One node of a flow tree. Node 0 is the root and receives the budget.
/// @param action What the node does with its input. May be address(0) only on a branch (2+
///        children): the node then passes its input to its children unchanged.
/// @param children Indexes of the child nodes, each greater than this node's index. None makes
///        the node a leaf, whose action must output nothing.
/// @param splitter Divides the output among the children when there are 2+ (a `WeightSplitter` for
///        fixed weights). address(0) otherwise.
/// @param skipWhenEmpty When the node receives 0 (a splitter's 0, a weight that rounds down, a
///        parent that produced nothing), skip it and everything below it instead of reverting.
///        Never on the root.
/// @param forwardSurplus Give the children everything that arrived, not just `outAmount`. Off by
///        default: anything above `outAmount` stays in the DAO. Only on a node with an action and
///        children. With one token, the node passes its whole input on (`outAmount ≥ inAmount`).
struct Node {
    INodeAction action;
    uint32[] children;
    ISplitter splitter;
    bool skipWhenEmpty;
    bool forwardSurplus;
}
