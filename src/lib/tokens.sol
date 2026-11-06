// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";

/// @notice A DAO action that sends `_amount` of ERC20 `_token` to `_to`
function transferAction(IERC20 _token, address _to, uint256 _amount) pure returns (Action memory) {
    return Action({to: address(_token), value: 0, data: abi.encodeCall(IERC20.transfer, (_to, _amount))});
}
