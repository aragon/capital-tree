// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

/// @dev Pauses and unpauses the plugin
bytes32 constant PAUSE_PERMISSION_ID = keccak256("PAUSE_PERMISSION");

/// @dev Changes a component's settings: a stream's rate and cap, an open fill's demand, a
///      splitter's weights, a Merkle root
bytes32 constant SET_SETTINGS_PERMISSION_ID = keccak256("SET_SETTINGS_PERMISSION");

/// @dev Calls `trigger()` on the plugin
bytes32 constant TRIGGER_PERMISSION_ID = keccak256("TRIGGER_PERMISSION");

/// @dev Replaces the flow tree. DAO only: an action can return arbitrary DAO actions.
bytes32 constant CONFIGURE_PERMISSION_ID = keccak256("CONFIGURE_PERMISSION");

/// @dev Restarts a stream budget from zero
bytes32 constant CHECKPOINT_PERMISSION_ID = keccak256("CHECKPOINT_PERMISSION");

/// @dev Records a Merkle claim; granted to the DAO, which executes it when the claim's budget commits
bytes32 constant RECORD_CLAIM_PERMISSION_ID = keccak256("RECORD_CLAIM_PERMISSION");

/// @dev Ratios are fractions of 1_000_000
uint256 constant RATIO_BASE = 1_000_000;
