// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {INodeAction} from "../interfaces/INodeAction.sol";
import {ISplitter} from "../interfaces/ISplitter.sol";

/// @notice An amount of a token. A node's input is the asset it receives (the budget at the root, a
///         share of its parent's output elsewhere); its output is the asset it produces for its
///         children: the least its action guarantees, checked by its postconditions, zero for a leaf.
struct Asset {
    IERC20 token;
    uint256 amount;
}

/// @notice One node of a flow tree. Node 0 is the root and receives the budget.
/// @param action What the node does with its input. May be address(0) only on a branch (2+
///        children): the node then passes its input to its children unchanged.
/// @param children Indexes of the child nodes, each greater than this node's index. None makes
///        the node a leaf, whose action must output nothing.
/// @param weights One per child when there are 2+ children, summing to RATIO_BASE. Empty otherwise,
///        or when a splitter divides the output.
/// @param splitter Divides the output among 2+ children when the flow runs, in place of weights.
///        address(0) for fixed weights.
/// @param skipWhenEmpty When the node receives 0 (a weight that rounds down, a splitter's 0, a
///        parent that produced nothing), skip it and everything below it instead of reverting.
///        Never on the root.
/// @param forwardSurplus Give the children everything that arrived, not just `outAmount`. Off by
///        default: anything above `outAmount` stays in the DAO. Only on a node with an action and
///        children. With one token, the node passes its whole input on (`outAmount ≥ inAmount`).
struct Node {
    INodeAction action;
    uint32[] children;
    uint32[] weights;
    ISplitter splitter;
    bool skipWhenEmpty;
    bool forwardSurplus;
}
