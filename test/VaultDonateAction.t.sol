// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {DAO} from "@aragon/osx/core/dao/DAO.sol";
import {TransferBase} from "../src/actions/base/TransferBase.sol";
import {VaultDonateAction} from "../src/actions/VaultDonateAction.sol";
import {IDonationVault} from "../src/interfaces/IDonationVault.sol";
import {Recipes} from "../script/Recipes.sol";
import {BuybackDonateFixture} from "./helpers/BuybackDonateFixture.sol";
import {OpenFillAction} from "../src/actions/OpenFillAction.sol";
import {MockFiller} from "./mocks/MockFiller.sol";

contract DonationVaultMock is ERC20 {
    address public immutable asset;
    uint256 public totalAssets;
    uint256 public mode;

    constructor(address _asset) ERC20("Vault", "V") {
        asset = _asset;
        _mint(msg.sender, 100 ether);
    }

    function setMode(uint256 _mode) external {
        mode = _mode;
    }

    function donate(uint256 _amount) external {
        require(mode != 1, "paused");
        if (mode == 2) return;
        IERC20(asset).transferFrom(msg.sender, address(this), _amount);
        totalAssets += _amount;
    }
}

contract VaultDonateActionTest is BuybackDonateFixture {
    DonationVaultMock internal vault;
    MockFiller internal filler;

    function setUp() public override {
        super.setUp();
        vault = new DonationVaultMock(address(tokenB));
    }

    function _install(uint256 _feeBps) internal {
        _installDonation(
            Recipes.Stream(tokenA, RATE, STREAM_CAP, EPOCH),
            Recipes.Swap(tokenB, DEMAND),
            IDonationVault(address(vault)),
            _feeBps
        );
        filler = new MockFiller(plugin);
        tokenB.mint(address(filler), DEMAND * 3);
        vm.warp(block.timestamp + EPOCH);
    }

    function test_OneBpFeeThenDonateAll() public {
        _install(1);
        filler.fill("");
        assertEq(tokenB.balanceOf(fee), 0.1 ether);
        _assertDonation(999.9 ether);
        assertEq(tokenB.balanceOf(address(dao)), DAO_B);
    }

    function test_TenBpFeeThenDonateAll() public {
        _install(10);
        filler.fill("");
        assertEq(tokenB.balanceOf(fee), 1 ether);
        _assertDonation(999 ether);
        assertEq(tokenB.balanceOf(address(dao)), DAO_B);
    }

    function test_DonationFailureAlsoRollsBackFee() public {
        _install(10);
        vault.setMode(1);
        _expectRollback(abi.encodeWithSelector(DAO.ActionFailed.selector, 1));
        assertEq(tokenB.balanceOf(fee), 0);
    }

    function test_FeeFailureRollsBackBuyback() public {
        _install(10);
        vm.mockCall(address(tokenB), abi.encodeCall(IERC20.transfer, (fee, 1 ether)), abi.encode(false));
        _expectRollback(abi.encodeWithSelector(TransferBase.ReceiptShortfall.selector, tokenB, fee, 1 ether, 0));
        assertEq(tokenB.balanceOf(fee), 0);
    }

    function testFuzz_FeeAndDonationConserveProceeds(uint256 _bps) public {
        _bps = bound(_bps, 1, 9_999);
        _install(_bps);
        filler.fill("");
        uint256 _fee = DEMAND * _bps / 10_000;
        assertEq(tokenB.balanceOf(fee), _fee);
        _assertDonation(DEMAND - _fee);
        assertEq(tokenB.balanceOf(address(dao)), DAO_B);
        assertEq(budget.available(address(filler), ""), 0);
    }

    function test_InvalidFeeReverts() public {
        vm.expectRevert(Recipes.InvalidFeeBps.selector);
        this.installInvalidFee(0);
        vm.expectRevert(Recipes.InvalidFeeBps.selector);
        this.installInvalidFee(10_000);
        vm.expectRevert(Recipes.InvalidFeeBps.selector);
        this.installInvalidFee(uint256(type(uint32).max) + 1);
    }

    function test_UncappedStreamReverts() public {
        vm.expectRevert(Recipes.UncappedStream.selector);
        this.installUncappedStream();
    }

    function installUncappedStream() external {
        _installDonation(
            Recipes.Stream(tokenA, RATE, 0, EPOCH), Recipes.Swap(tokenB, DEMAND), IDonationVault(address(vault)), 10
        );
    }

    function test_ZeroFeeRecipientReverts() public {
        fee = address(0);
        vm.expectRevert(Recipes.InvalidFeeRecipient.selector);
        this.installInvalidFee(10);
    }

    function installInvalidFee(uint256 _bps) external {
        _install(_bps);
    }

    function test_SplitRoundingDustGoesToDonation() public {
        _install(10);
        OpenFillAction _fill = OpenFillAction(address(plugin.nodes()[0].action));
        vm.prank(manager);
        _fill.setDemandPerFill(DEMAND + 1);
        vm.warp(block.timestamp + EPOCH);
        filler.fill("");
        _assertDonation(999 ether + 1);
        assertEq(tokenB.balanceOf(fee), 1 ether);
        assertEq(tokenB.balanceOf(address(dao)), DAO_B);
    }

    function test_SurplusIsAlsoChargedAndDonated() public {
        _install(10);
        filler.setFillDelta(10 ether);
        filler.fill("");
        _assertDonation(1008.99 ether);
        assertEq(tokenB.balanceOf(fee), 1.01 ether);
        assertEq(tokenB.balanceOf(address(dao)), DAO_B);
    }

    function test_NoOpDonationRollsBack() public {
        _install(10);
        vault.setMode(2);
        _expectRollback(abi.encodeWithSelector(VaultDonateAction.AssetsNotIncreased.selector, 999 ether, 0));
    }

    function test_WrongAssetReverts() public {
        vault = new DonationVaultMock(address(tokenA));
        _install(10);
        vm.expectRevert(VaultDonateAction.WrongAsset.selector);
        filler.fill("");
        assertEq(tokenA.balanceOf(address(dao)), DAO_A);
    }

    function _expectRollback(bytes memory _reason) internal {
        uint256 _timestamp = budget.baseTimestamp();
        vm.expectRevert(_reason);
        filler.fill("");
        assertEq(tokenA.balanceOf(address(dao)), DAO_A);
        assertEq(tokenB.balanceOf(address(dao)), DAO_B);
        assertEq(tokenA.balanceOf(address(filler)), 0);
        assertEq(tokenB.balanceOf(address(filler)), DEMAND * 3);
        assertEq(budget.baseTimestamp(), _timestamp);
        assertEq(budget.available(address(filler), ""), RATE);
        assertEq(tokenB.balanceOf(fee), 0);
        assertEq(tokenA.allowance(address(dao), address(filler)), 0);
        _assertDonation(0);
    }

    function _assertDonation(uint256 _amount) internal view {
        assertEq(vault.totalAssets(), _amount);
        assertEq(tokenB.balanceOf(address(vault)), _amount);
        assertEq(vault.totalSupply(), 100 ether);
        assertEq(vault.balanceOf(address(dao)), 0);
        assertEq(tokenB.allowance(address(dao), address(vault)), 0);
    }
}
