// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import {DAO} from "@aragon/osx/core/dao/DAO.sol";
import {IDonationVault} from "../../src/interfaces/IDonationVault.sol";
import {GenericFillSolver} from "../../src/solvers/GenericFillSolver.sol";
import {WeightSplitter} from "../../src/splitters/WeightSplitter.sol";
import {Node} from "../../src/lib/types.sol";
import {Recipes} from "../../script/Recipes.sol";
import {BuybackDonateFixture} from "../helpers/BuybackDonateFixture.sol";

interface ISushiV3Router {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256);
}

interface ISushiQuoterV2 {
    struct QuoteExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }
    function quoteExactInputSingle(QuoteExactInputSingleParams calldata params)
        external
        returns (uint256, uint160, uint32, uint256);
}

interface IAvKatVault is IDonationVault {
    function paused() external view returns (bool);
}

/// @notice Real Katana USDC -> Sushi V3 -> KAT -> AvKATVault.donate, in one trigger.
/// @dev Only initial USDC funding is synthetic. No KAT deal, mocked swap, or modified vault state.
///      The negative test explicitly injects a donate revert to verify atomic rollback.
contract AvKatBuybackForkTest is BuybackDonateFixture {
    IERC20 constant USDC = IERC20(0x203A662b0BD271A6ed5a60EdFbd04bFce608FD36);
    IERC20 constant KAT = IERC20(0x7F1f4b4b29f5058fA32CC7a97141b8D7e5ABDC2d);
    IAvKatVault constant VAULT = IAvKatVault(0x7231dbaCdFc968E07656D12389AB20De82FbfCeB);
    address constant ROUTER = 0x4e1d81A3E627b9294532e990109e4c21d217376C;
    ISushiQuoterV2 constant QUOTER = ISushiQuoterV2(0x92dea23ED1C683940fF1a2f8fE23FE98C5d3041c);
    uint256 constant FORK_BLOCK = 47_557_066;
    uint256 constant USDC_IN = 10e6;
    uint24 constant POOL_FEE = 500;
    GenericFillSolver internal solver;
    uint256 internal demanded;

    function setUp() public override {
        if (!vm.envOr("RUN_KATANA_FORK_TESTS", false)) return;
        vm.createSelectFork(
            vm.envOr("KATANA_RPC_URL", string("https://rpc.katana.network")), vm.envOr("KATANA_FORK_BLOCK", FORK_BLOCK)
        );
        uint256 _forkTimestamp = block.timestamp;
        super.setUp();
        vm.warp(_forkTimestamp);
        assertEq(block.chainid, 747474);
        assertEq(VAULT.asset(), address(KAT));
        assertFalse(VAULT.paused());
        assertGt(VAULT.totalSupply(), 0);
        console2.log("Katana fork block", block.number);
        (demanded,,,) = QUOTER.quoteExactInputSingle(
            ISushiQuoterV2.QuoteExactInputSingleParams(address(USDC), address(KAT), USDC_IN, POOL_FEE, 0)
        );
        assertGt(demanded, 0);
        _installDonation(Recipes.Stream(USDC, USDC_IN, USDC_IN, EPOCH), Recipes.Swap(KAT, demanded), VAULT, 10);
        solver = new GenericFillSolver(address(this), plugin);
        // Fund AFTER budget initialization to exercise the revenue-arrival sync path.
        deal(address(USDC), address(dao), USDC_IN);
        budget.sync();
        vm.warp(_forkTimestamp + EPOCH);
    }

    modifier forkEnabled() {
        vm.skip(!vm.envOr("RUN_KATANA_FORK_TESTS", false));
        _;
    }

    function test_Fork_TenBpFeeThenDonateAll() public forkEnabled {
        _fillAndAssert(10);
    }

    function test_Fork_OneBpFeeInKat() public forkEnabled {
        Node[] memory _nodes = plugin.nodes();
        uint32[] memory _weights = new uint32[](2);
        (_weights[0], _weights[1]) = (100, 999_900);
        vm.prank(manager);
        WeightSplitter(address(_nodes[0].splitter)).setWeights(_weights);
        _fillAndAssert(1);
    }

    function test_Fork_VaultRevertRollsBackRealSwap() public forkEnabled {
        uint256 _assets = VAULT.totalAssets();
        uint256 _feeBefore = KAT.balanceOf(fee);
        uint256 _checkpoint = budget.baseTimestamp();
        uint256 _poolUsdc = USDC.balanceOf(0x10045367E619Caae6f60CC80046c43c6cD55f629);
        bytes[] memory _data = _swapData();
        vm.mockCallRevert(
            address(VAULT), abi.encodeWithSelector(IDonationVault.donate.selector), abi.encode("vault unavailable")
        );
        vm.expectCall(ROUTER, abi.encodePacked(ISushiV3Router.exactInputSingle.selector));
        vm.expectRevert(abi.encodeWithSelector(DAO.ActionFailed.selector, 1));
        solver.trigger(_data);
        assertEq(USDC.balanceOf(address(dao)), USDC_IN);
        assertEq(KAT.balanceOf(address(dao)), 0);
        assertEq(VAULT.totalAssets(), _assets);
        assertEq(KAT.balanceOf(fee), _feeBefore, "fee also rolled back");
        assertEq(USDC.balanceOf(0x10045367E619Caae6f60CC80046c43c6cD55f629), _poolUsdc);
        assertEq(budget.baseTimestamp(), _checkpoint);
        assertEq(budget.available(address(solver), ""), USDC_IN);
        _assertAllowancesCleared();
    }

    function _fillAndAssert(uint256 _feeBps) internal {
        uint256 _assets = VAULT.totalAssets();
        uint256 _supply = VAULT.totalSupply();
        uint256 _perShare = VAULT.convertToAssets(1 ether);
        uint256 _feeBefore = KAT.balanceOf(fee);
        uint256 _feeAmount = demanded * _feeBps / 10_000;
        uint256 _donated = demanded - _feeAmount;

        vm.expectCall(ROUTER, abi.encodePacked(ISushiV3Router.exactInputSingle.selector));
        vm.expectCall(address(VAULT), abi.encodeCall(IDonationVault.donate, (_donated)));
        solver.trigger(_swapData());

        assertEq(USDC.balanceOf(address(dao)), 0);
        assertEq(KAT.balanceOf(address(dao)), 0);
        assertEq(KAT.balanceOf(fee), _feeBefore + _feeAmount, "Aragon fee paid in KAT");
        assertEq(VAULT.totalAssets(), _assets + _donated);
        assertEq(VAULT.totalSupply(), _supply, "no new avKAT minted");
        assertEq(IERC20(address(VAULT)).balanceOf(address(dao)), 0);
        assertGt(VAULT.convertToAssets(1 ether), _perShare, "existing shares gained backing");
        assertEq(budget.available(address(solver), ""), 0);
        assertEq(budget.baseTimestamp(), block.timestamp);
        _assertAllowancesCleared();

        console2.log("USDC spent (6 decimals)", USDC_IN);
        console2.log("KAT bought (18 decimals)", demanded);
        console2.log("KAT donated (18 decimals)", _donated);
        console2.log("KAT fee (18 decimals)", _feeAmount);
    }

    function _assertAllowancesCleared() internal view {
        assertEq(USDC.allowance(address(dao), address(solver)), 0);
        assertEq(USDC.allowance(address(solver), ROUTER), 0);
        assertEq(KAT.allowance(address(dao), address(VAULT)), 0);
        assertEq(USDC.balanceOf(address(solver)), 0);
        assertEq(KAT.balanceOf(address(solver)), 0);
    }

    function _swapData() internal view returns (bytes[] memory _data) {
        Action[] memory _calls = new Action[](4);
        _calls[0] =
            Action(address(USDC), 0, abi.encodeCall(IERC20.transferFrom, (address(dao), address(solver), USDC_IN)));
        _calls[1] = Action(address(USDC), 0, abi.encodeCall(IERC20.approve, (ROUTER, USDC_IN)));
        _calls[2] = Action(
            ROUTER,
            0,
            abi.encodeCall(
                ISushiV3Router.exactInputSingle,
                (ISushiV3Router.ExactInputSingleParams(
                        address(USDC), address(KAT), POOL_FEE, address(dao), block.timestamp, USDC_IN, demanded, 0
                    ))
            )
        );
        _calls[3] = Action(address(USDC), 0, abi.encodeCall(IERC20.approve, (ROUTER, 0)));
        _data = new bytes[](plugin.nodes().length);
        _data[0] = abi.encode(_calls);
    }
}
