// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

/// @notice An asset-backed vault with donations that increase backing without minting shares.
/// @dev Implemented by Katana's AvKATVault. `donate` is not part of standard ERC4626.
interface IDonationVault {
    function asset() external view returns (address);
    function totalAssets() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function donate(uint256 assets) external;
}
