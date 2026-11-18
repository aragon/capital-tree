// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title TestToken
/// @notice Ordinary 18-decimal ERC20 with its entire supply minted at deployment.
/// @dev Exposes no mint function, so a buyer cannot create tokens during a fill.
contract TestToken is ERC20 {
    /// @notice Creates the token and gives its initial supply to one holder.
    /// @param symbol_ Used as both the token's name and symbol.
    /// @param holder Address receiving the entire initial supply.
    /// @param supply Initial supply in raw token units.
    constructor(string memory symbol_, address holder, uint256 supply) ERC20(symbol_, symbol_) {
        _mint(holder, supply);
    }
}
