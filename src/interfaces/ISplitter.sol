// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {Record} from "../lib/types.sol";

/// @title ISplitter
/// @notice Divides a branch's output among its children when the flow runs (`WeightSplitter` for
///         fixed weights). The children stay explicit nodes: a splitter only decides how much each gets.
/// @dev Splitters are clones initialized for one DAO and expose it as `dao()`
///      (`DaoAuthorizableUpgradeable`). The plugin rejects splitters bound to another DAO or to none.
interface ISplitter {
    /// @notice One amount per child, in the order of the node's children, summing to
    ///         `parent.forwarded`. A child that gets 0 reverts the trigger, unless it's marked
    ///         `skipWhenEmpty`.
    /// @param parent What the node expected and what really happened, so a splitter can tell the
    ///        expected output (`parent.expected.outAmount`) from a surplus
    function split(address caller, Record calldata parent, uint256 childCount)
        external
        view
        returns (uint256[] memory amounts);
}
