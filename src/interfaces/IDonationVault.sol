// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @notice An asset-backed vault with donations that increase backing without minting shares.
interface IDonationVault is IERC4626 {
    /// @notice Pulls `assets` of the vault's asset from the caller and adds them to the backing of
    ///         existing shares, minting none
    function donate(uint256 assets) external;
}
