// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CapitalTreePlugin} from "../../../src/CapitalTreePlugin.sol";
import {IFiller} from "../../../src/interfaces/IFiller.sol";

/// @title Buyer
/// @notice Test buyer that takes the DAO's sellToken and pays buyToken to the DAO.
/// @dev Supports full payment and one-unit underpayment. It has no DAO management permissions.
contract Buyer is IFiller {
    /// @notice The installed buy-and-hold flow this buyer triggers.
    CapitalTreePlugin public immutable plugin;

    /// @notice Connects this buyer to the flow under test.
    /// @param plugin_ Plugin running the OpenFill -> Keep tree.
    constructor(CapitalTreePlugin plugin_) {
        plugin = plugin_;
    }

    /// @notice Attempts one fill, allowing any protocol revert to reach the test handler.
    /// @dev Sends correctly sized node data. Only OpenFill reads the encoded payment choice.
    /// @param underpay If true, pay one raw unit of buyToken less than the demand; otherwise pay exactly.
    function buy(bool underpay) external {
        // @agent nice this can easily be extended w. second argument for the array length
        bytes[] memory nodeData = new bytes[](2); // OpenFill, then Keep
        nodeData[0] = abi.encode(underpay);
        plugin.trigger("", nodeData);
    }

    /// @notice Deposits purchased sellToken back into the DAO without syncing its stream.
    /// @dev Test-only funding action. It transfers existing tokens and cannot mint new supply.
    /// @param amount Raw sellToken units to return to the DAO.
    function deposit(uint256 amount) external {
        IERC20 sellToken = plugin.budget().token();
        sellToken.transfer(address(plugin.dao()), amount);
    }

    /// @notice Takes the full offer from the DAO, then pays the selected amount back.
    /// @dev Only the plugin's DAO may call this. A rejected underpayment must roll back both
    /// token transfers through the surrounding trigger transaction.
    /// @param sellToken The DAO's sellToken, temporarily approved to this buyer.
    /// @param offered Amount of sellToken available to take from the DAO, in raw token units.
    /// @param buyToken The token the DAO buys and requires as payment.
    /// @param demanded Minimum buyToken payment required by OpenFill, in raw token units.
    /// @param data ABI-encoded bool selecting whether to underpay by one raw unit of buyToken.
    function fillOffer(IERC20 sellToken, uint256 offered, IERC20 buyToken, uint256 demanded, bytes calldata data)
        external
        override
    {
        require(msg.sender == address(plugin.dao()), "only the DAO calls back");
        bool underpay = abi.decode(data, (bool));
        sellToken.transferFrom(msg.sender, address(this), offered);
        buyToken.transfer(msg.sender, underpay ? demanded - 1 : demanded);
    }
}
