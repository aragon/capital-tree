// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ERC721Holder} from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";

interface IReviewAvKat {
    function totalAssets() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function deposit(uint256 assets, address receiver) external returns (uint256);
    function previewRedeem(uint256 shares) external view returns (uint256);
    function withdrawTokenId(uint256 assets, address receiver, address owner) external returns (uint256);
    function donate(uint256 assets) external;
}

interface IReviewEscrow {
    function lockNFT() external view returns (address);
    function minDeposit() external view returns (uint256);
    function beginWithdrawal(uint256 tokenId) external;
    function withdraw(uint256 tokenId) external;
}

interface IReviewExitQueue {
    function minCooldown() external view returns (uint48);
    function minLock() external view returns (uint48);
    function timeToMinLock(uint256 tokenId) external view returns (uint48);
    function getTimeBasedFee(uint256 elapsed) external view returns (uint256);
}

/// @notice Live deployment behavior at the review block; synthetic funding only.
contract AvKatSecurityReviewForkTest is Test, ERC721Holder {
    IERC20 constant KAT = IERC20(0x7F1f4b4b29f5058fA32CC7a97141b8D7e5ABDC2d);
    IReviewAvKat constant VAULT = IReviewAvKat(0x7231dbaCdFc968E07656D12389AB20De82FbfCeB);
    IReviewEscrow constant ESCROW = IReviewEscrow(0x4d6fC15Ca6258b168225D283262743C623c13Ead);
    IReviewExitQueue constant QUEUE = IReviewExitQueue(0x6dE9cAAb658C744aD337Ca5d92D084c97ffF578d);

    function setUp() public {
        if (!vm.envOr("RUN_KATANA_FORK_TESTS", false)) return;
        vm.createSelectFork(vm.envOr("KATANA_RPC_URL", string("https://rpc.katana.network")), 47_671_550);
    }

    modifier forkEnabled() {
        vm.skip(!vm.envOr("RUN_KATANA_FORK_TESTS", false));
        _;
    }

    function test_Fork_DirectTransferDoesNotIncreaseAccountedAssets() public forkEnabled {
        uint256 assets = VAULT.totalAssets();
        deal(address(KAT), address(this), 1 ether);
        KAT.transfer(address(VAULT), 1 ether);
        assertEq(VAULT.totalAssets(), assets);
    }

    function test_Fork_ExplicitDonateIncreasesAssetsWithoutMintingShares() public forkEnabled {
        uint256 assets = VAULT.totalAssets();
        uint256 shares = VAULT.totalSupply();
        deal(address(KAT), address(this), 1000 ether);
        KAT.approve(address(VAULT), 1000 ether);
        VAULT.donate(1000 ether);
        assertEq(VAULT.totalAssets(), assets + 1000 ether);
        assertEq(VAULT.totalSupply(), shares);
    }

    function test_Fork_DonationBelowEscrowMinimumReverts() public forkEnabled {
        assertEq(ESCROW.minDeposit(), 230 ether);
        deal(address(KAT), address(this), 230 ether);
        KAT.approve(address(VAULT), 230 ether);
        vm.expectRevert(bytes4(keccak256("AmountTooSmall()")));
        VAULT.donate(230 ether - 1);
    }

    function test_Fork_DepositDonateRedeemCannotRecoverLiquidKatAtomically() public forkEnabled {
        deal(address(KAT), address(this), 2000 ether);
        KAT.approve(address(VAULT), 2000 ether);
        uint256 shares = VAULT.deposit(1000 ether, address(this));
        VAULT.donate(1000 ether);
        uint256 backing = VAULT.previewRedeem(shares);
        assertGt(backing, 1000 ether);
        uint256 tokenId = VAULT.withdrawTokenId(backing, address(this), address(this));
        IERC721(ESCROW.lockNFT()).approve(address(ESCROW), tokenId);
        assertEq(KAT.balanceOf(address(this)), 0, "vault withdrawal returns an NFT, not liquid KAT");
        assertEq(QUEUE.minCooldown(), 1);
        assertEq(QUEUE.minLock(), 1);
        assertEq(QUEUE.getTimeBasedFee(0), 2500);
        // Whether the split inherits an old start or a fresh one, exit cannot finish atomically.
        uint256 unlock = QUEUE.timeToMinLock(tokenId);
        if (unlock > block.timestamp) {
            vm.expectRevert();
            ESCROW.beginWithdrawal(tokenId);
            vm.warp(unlock);
        }
        ESCROW.beginWithdrawal(tokenId);
        vm.expectRevert(bytes4(keccak256("CannotExit()")));
        ESCROW.withdraw(tokenId);
        assertEq(KAT.balanceOf(address(this)), 0);
        // In a later timestamp, exit is possible, but a ~25% fee hits the whole position.
        vm.warp(block.timestamp + QUEUE.minCooldown());
        ESCROW.withdraw(tokenId);
        assertLt(KAT.balanceOf(address(this)), 751 ether);
        assertGt(KAT.balanceOf(address(this)), 749 ether);
    }
}
