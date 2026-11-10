// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CapitalTreePlugin} from "../../src/CapitalTreePlugin.sol";
import {IFiller} from "../../src/interfaces/IFiller.sol";

/// @notice A filler for the playground: takes the open-fill offer of any flow and pays the demanded
///         amount from its own balance. Anyone can make it fill.
contract PlaygroundFiller is IFiller {
    /// @notice Triggers `_plugin`, which must have an OpenFillAction, and takes its offer
    function fill(CapitalTreePlugin _plugin) external {
        _plugin.trigger("", new bytes[](0));
    }

    /// @inheritdoc IFiller
    /// @dev Called by the DAO: pulls the offer and sends the demanded amount back
    function fillOffer(
        IERC20 _offeredToken,
        uint256 _offeredAmount,
        IERC20 _demandedToken,
        uint256 _demandedAmount,
        bytes calldata
    ) external {
        _offeredToken.transferFrom(msg.sender, address(this), _offeredAmount);

        _demandedToken.transfer(msg.sender, _demandedAmount);
    }
}
