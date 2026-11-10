// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {DAO} from "@aragon/osx/core/dao/DAO.sol";
import {ProxyLib} from "@aragon/osx-commons-contracts/src/utils/deployment/ProxyLib.sol";
import {VaultDonateAction} from "../src/actions/VaultDonateAction.sol";
import {IDonationVault} from "../src/interfaces/IDonationVault.sol";
import {Node} from "../src/lib/types.sol";
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

    function empty() external {
        _burn(msg.sender, balanceOf(msg.sender));
    }

    function donate(uint256 _amount) external {
        require(mode != 1, "paused");
        if (mode == 2) return;
        IERC20(asset).transferFrom(msg.sender, address(this), _amount);
        totalAssets += _amount;
        if (mode == 3) _mint(msg.sender, _amount);
    }
}

contract VaultDonateActionTest is BuybackDonateFixture {
    DonationVaultMock internal vault;
    MockFiller internal filler;

    function setUp() public override {
        super.setUp();
        vault = new DonationVaultMock(address(tokenB));
    }

    function _install(uint256 _weight) internal {
        _install(_weight, 0);
    }

    function _install(uint256 _weight, uint256 _feeBps) internal {
        _installDonation(
            Recipes.Stream(tokenA, RATE, 0, EPOCH),
            Recipes.Swap(tokenB, DEMAND, MIN_PRICE),
            IDonationVault(address(vault)),
            _weight,
            _feeBps
        );
        filler = new MockFiller(plugin);
        tokenB.mint(address(filler), DEMAND * 3);
        vm.warp(block.timestamp + EPOCH);
    }

    function test_OneBpKatFeeBeforeDonationSplit() public {
        _install(800_000, 1);
        filler.fill("");
        assertEq(tokenB.balanceOf(fee), 0.1 ether);
        _assertDonation(799.92 ether);
        assertEq(tokenB.balanceOf(address(dao)), DAO_B + 199.98 ether);
    }

    function test_TenBpKatFeeBeforeDonationSplit() public {
        _install(800_000, 10);
        filler.fill("");
        assertEq(tokenB.balanceOf(fee), 1 ether);
        _assertDonation(799.2 ether);
        assertEq(tokenB.balanceOf(address(dao)), DAO_B + 199.8 ether);
    }

    function test_FeeWithFullDonation() public {
        _install(1_000_000, 10);
        filler.fill("");
        assertEq(tokenB.balanceOf(fee), 1 ether);
        _assertDonation(999 ether);
        assertEq(tokenB.balanceOf(address(dao)), DAO_B);
    }

    function test_FeeWithHoldOnly() public {
        _install(0, 10);
        filler.fill("");
        assertEq(tokenB.balanceOf(fee), 1 ether);
        _assertDonation(0);
        assertEq(tokenB.balanceOf(address(dao)), DAO_B + 999 ether);
    }

    function test_DonationFailureAlsoRollsBackFee() public {
        _install(800_000, 10);
        vault.setMode(1);
        _expectRollback(1);
        assertEq(tokenB.balanceOf(fee), 0);
    }

    function test_FeeFailureRollsBackBuyback() public {
        _install(800_000, 10);
        vm.mockCall(address(tokenB), abi.encodeCall(IERC20.transfer, (fee, 1 ether)), abi.encode(false));
        _expectRollback(1);
        assertEq(tokenB.balanceOf(fee), 0);
    }

    function testFuzz_FeeSplitConservesProceeds(uint32 _weight, bool _tenBps) public {
        _weight = uint32(bound(_weight, 0, 1_000_000));
        uint256 _bps = _tenBps ? 10 : 1;
        _install(_weight, _bps);
        filler.fill("");
        uint256 _fee = DEMAND * _bps / 10_000;
        uint256 _donated = (DEMAND - _fee) * _weight / 1_000_000;
        assertEq(tokenB.balanceOf(fee), _fee);
        _assertDonation(_donated);
        assertEq(tokenB.balanceOf(address(dao)), DAO_B + DEMAND - _fee - _donated);
    }

    function test_InvalidFeeReverts() public {
        vm.expectRevert(Recipes.InvalidFeeBps.selector);
        this.installInvalidFee(10_000);
        vm.expectRevert(Recipes.InvalidFeeBps.selector);
        this.installInvalidFee(uint256(type(uint32).max) + 1);
    }

    function test_ZeroFeeRecipientReverts() public {
        fee = address(0);
        vm.expectRevert(Recipes.InvalidFeeRecipient.selector);
        this.installInvalidFee(10);
    }

    function installInvalidFee(uint256 _bps) external {
        _install(800_000, _bps);
    }

    function test_BuybackDonatesAllWithoutMintingShares() public {
        _install(1_000_000);
        filler.fill("");
        _assertDonation(DEMAND);
        assertEq(tokenB.balanceOf(address(dao)), DAO_B);
        assertEq(tokenA.balanceOf(address(dao)), DAO_A - RATE);
        assertEq(budget.available(), 0);
    }

    function test_BuybackDonates80PercentAndHolds20Percent() public {
        _install(800_000);
        filler.fill("");
        _assertDonation(800 ether);
        assertEq(tokenB.balanceOf(address(dao)), DAO_B + 200 ether);
    }

    function test_ZeroPercentKeepsEverything() public {
        _install(0);
        filler.fill("");
        _assertDonation(0);
        assertEq(tokenB.balanceOf(address(dao)), DAO_B + DEMAND);
    }

    function test_DaoCanChangeSplitBetweenFills() public {
        _install(800_000);
        filler.fill("");
        Node[] memory _nodes = plugin.nodes();
        _nodes[0].weights[0] = 250_000;
        _nodes[0].weights[1] = 750_000;
        vm.prank(address(dao));
        plugin.setFlow(budget, _nodes);
        vm.warp(block.timestamp + EPOCH);
        filler.fill("");
        _assertDonation(1050 ether);
        assertEq(tokenB.balanceOf(address(dao)), DAO_B + 950 ether);
    }

    function testFuzz_SplitConservesProceeds(uint32 _weight) public {
        _weight = uint32(bound(_weight, 0, 1_000_000));
        _install(_weight);
        filler.fill("");
        uint256 _donated = DEMAND * _weight / 1_000_000;
        _assertDonation(_donated);
        assertEq(tokenB.balanceOf(address(dao)), DAO_B + DEMAND - _donated);
    }

    function test_SplitRoundingDustGoesToDonation() public {
        _install(800_000);
        OpenFillAction _fill = OpenFillAction(address(plugin.nodes()[0].action));
        vm.prank(manager);
        _fill.setDemandPerFill(DEMAND + 1);
        vm.warp(block.timestamp + EPOCH);
        filler.fill("");
        _assertDonation(800 ether + 1);
        assertEq(tokenB.balanceOf(address(dao)), DAO_B + 200 ether);
    }

    function test_SurplusStaysInDao() public {
        _install(800_000);
        filler.setFillDelta(10 ether);
        filler.fill("");
        _assertDonation(800 ether);
        assertEq(tokenB.balanceOf(address(dao)), DAO_B + 210 ether);
    }

    function test_DonationFailureRollsBackFillAndCheckpoint() public {
        _install(800_000);
        vault.setMode(1);
        _expectRollback(1);
    }

    function test_NoOpDonationRollsBack() public {
        _install(800_000);
        vault.setMode(2);
        _expectRollback(3);
    }

    function test_MintedSharesRollBack() public {
        _install(800_000);
        vault.setMode(3);
        _expectRollback(3);
    }

    function test_WrongAssetReverts() public {
        vault = new DonationVaultMock(address(tokenA));
        _install(800_000);
        vm.expectRevert(VaultDonateAction.WrongAsset.selector);
        filler.fill("");
        assertEq(tokenA.balanceOf(address(dao)), DAO_A);
    }

    function test_EmptyVaultReverts() public {
        vault.empty();
        _install(800_000);
        vm.expectRevert(VaultDonateAction.EmptyVault.selector);
        filler.fill("");
    }

    function test_InvalidWeightReverts() public {
        vm.expectRevert(Recipes.InvalidDonateWeight.selector);
        this.installInvalidWeight();
    }

    function installInvalidWeight() external {
        _install(uint256(type(uint32).max) + 1);
    }

    function test_InvalidVaultReverts() public {
        VaultDonateAction _action = VaultDonateAction(ProxyLib.deployMinimalProxy(address(new VaultDonateAction()), ""));
        vm.expectRevert(VaultDonateAction.InvalidVault.selector);
        _action.initialize(dao, IDonationVault(address(0)));
    }

    function _expectRollback(uint256 _failedAction) internal {
        uint256 _timestamp = budget.baseTimestamp();
        vm.expectRevert(abi.encodeWithSelector(DAO.ActionFailed.selector, _failedAction));
        filler.fill("");
        assertEq(tokenA.balanceOf(address(dao)), DAO_A);
        assertEq(tokenB.balanceOf(address(dao)), DAO_B);
        assertEq(tokenA.balanceOf(address(filler)), 0);
        assertEq(tokenB.balanceOf(address(filler)), DEMAND * 3);
        assertEq(budget.baseTimestamp(), _timestamp);
        assertEq(budget.available(), RATE);
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
