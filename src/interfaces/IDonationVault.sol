// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @notice An asset-backed vault with donations that increase backing without minting shares.
interface IDonationVault is IERC4626 {
    function donate(uint256 assets) external;
}
