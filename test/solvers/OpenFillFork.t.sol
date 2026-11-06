// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {DAO} from "@aragon/osx/core/dao/DAO.sol";
import {Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OpenFillQuotes} from "../../script/open-fill/Quotes.s.sol";
import {PublicOpenFillQuotes} from "../../script/open-fill/PublicQuotes.s.sol";
import {DeployFork} from "../../script/open-fill/DeployFork.s.sol";

// SwapRouter02 ABI for the direct Uniswap route.
interface IV3SwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

contract GenericOpenFillForkTest is Test {
    IERC20 constant WETH = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IERC20 constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    address constant ROUTER = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;
    address immutable CALLER = vm.addr(0xB0B);
    uint256 constant AMOUNT = 1 ether;
    DeployFork.Deployment d;
    OpenFillQuotes quotes;

    function setUp() public {
        // Explicit opt-in keeps ordinary forge test runs offline, even if the shell has RPC keys.
        if (!vm.envOr("RUN_FORK_TESTS", false)) return;
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            rpc = string.concat("https://eth-mainnet.g.alchemy.com/v2/", vm.envString("ALCHEMY_API_KEY"));
        }
        uint256 forkBlock = vm.envOr("FORK_BLOCK", uint256(0));
        if (forkBlock == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, forkBlock);
        // Runtime only: current routes can use Osaka opcodes; compilation stays on Cancun.
        vm.setEvmVersion(vm.envOr("FORK_EVM_VERSION", string("osaka")));
        console2.log("Mainnet fork block", block.number);
        // Accrue before the fork's timestamp, so live API deadlines remain valid.
        uint256 forkTimestamp = block.timestamp;
        DeployFork deployment = new DeployFork();
        vm.warp(forkTimestamp - deployment.EPOCH());
        d = deployment.run(CALLER);
        deal(address(WETH), address(d.dao), AMOUNT);
        d.budget.sync();
        vm.warp(forkTimestamp);
        quotes = new OpenFillQuotes();
    }

    modifier forkEnabled() {
        vm.skip(!vm.envOr("RUN_FORK_TESTS", false));
        _;
    }

    modifier liveQuotesEnabled() {
        vm.skip(!vm.envOr("RUN_LIVE_QUOTES", false));
        _;
    }

    /// @notice Executes a fixed WETH/USDC route on mainnet's forked SwapRouter02; no quote API.
    function test_Fork_UniswapWethToUsdc() public forkEnabled {
        bytes memory data = _uniswapData(address(d.dao));
        vm.expectCall(ROUTER, abi.encodePacked(IV3SwapRouter.exactInputSingle.selector));
        // A fully spent allowance is already zero; also require the explicit approval reset.
        vm.expectCall(address(WETH), abi.encodeCall(IERC20.approve, (ROUTER, 0)));

        uint256 demandedBefore = _executeFill(data, 0);

        _assertFilled(demandedBefore);
        assertEq(WETH.allowance(address(d.solver), ROUTER), 0, "router allowance cleared after fill");
    }

    function test_Fork_ZeroExLiveQuote() public forkEnabled liveQuotesEnabled {
        vm.skip(bytes(vm.envOr("ZERO_EX_API_KEY", string(""))).length == 0);
        _quoteEnvironment();
        (bytes memory data, uint256 value) = quotes.zeroEx();
        uint256 demandedBefore = _executeFill(data, value);

        _assertFilled(demandedBefore);
    }

    function test_Fork_OneInchLiveQuote() public forkEnabled liveQuotesEnabled {
        vm.skip(bytes(vm.envOr("ONEINCH_API_KEY", string(""))).length == 0);
        _quoteEnvironment();
        (bytes memory data, uint256 value) = quotes.oneInch();
        uint256 demandedBefore = _executeFill(data, value);

        _assertFilled(demandedBefore);
    }

    function test_Fork_KyberSwapLiveQuote() public forkEnabled liveQuotesEnabled {
        _quoteEnvironment();
        (bytes memory data, uint256 value) = (new PublicOpenFillQuotes()).kyberSwap();
        uint256 demandedBefore = _executeFill(data, value);

        _assertFilled(demandedBefore);
    }

    function test_Fork_VeloraLiveQuote() public forkEnabled liveQuotesEnabled {
        _quoteEnvironment();
        (bytes memory data, uint256 value) = (new PublicOpenFillQuotes()).velora();
        uint256 demandedBefore = _executeFill(data, value);

        _assertFilled(demandedBefore);
    }

    function test_Fork_MisdirectedOutputRollsBack() public forkEnabled {
        // The swap itself succeeds, but sending output elsewhere fails the DAO's balance check.
        bytes memory data = _uniswapData(CALLER);
        uint256 callerBefore = USDC.balanceOf(CALLER);
        bytes[] memory perNode = quotes.forNode(d.plugin.nodes().length, 0, data);
        vm.prank(CALLER, CALLER);
        vm.expectRevert(abi.encodeWithSelector(DAO.ActionFailed.selector, 3));
        d.solver.trigger(perNode);
        assertEq(WETH.balanceOf(address(d.dao)), AMOUNT);
        assertEq(USDC.balanceOf(address(d.dao)), 0);
        assertEq(USDC.balanceOf(CALLER), callerBefore);
        assertEq(WETH.balanceOf(address(d.solver)), 0);
        assertEq(WETH.allowance(address(d.dao), address(d.solver)), 0);
        assertEq(WETH.allowance(address(d.solver), ROUTER), 0);
    }

    // Helpers

    function _executeFill(bytes memory data, uint256 value) internal returns (uint256 demandedBefore) {
        assertEq(value, 0, "ERC20 solver requires zero call value");
        demandedBefore = d.action.demandPerFill();
        bytes[] memory perNode = quotes.forNode(d.plugin.nodes().length, 0, data);
        vm.prank(CALLER, CALLER);
        d.solver.trigger(perNode);
        console2.log("WETH sold (wei)", AMOUNT);
        console2.log("USDC received (6 decimals)", USDC.balanceOf(address(d.dao)));
    }

    function _assertFilled(uint256 demandedBefore) internal view {
        assertEq(WETH.balanceOf(address(d.dao)), 0);
        assertGt(demandedBefore, 0);
        assertGe(USDC.balanceOf(address(d.dao)), demandedBefore);
        assertEq(WETH.balanceOf(address(d.solver)), 0);
        assertEq(USDC.balanceOf(address(d.solver)), 0);
        assertEq(WETH.allowance(address(d.dao), address(d.solver)), 0);
        assertEq(d.budget.available(), 0);
        assertEq(d.budget.baseTimestamp(), block.timestamp);
    }

    function _uniswapData(address receiver) internal view returns (bytes memory) {
        Action[] memory calls = new Action[](4);
        calls[0] =
            Action(address(WETH), 0, abi.encodeCall(IERC20.transferFrom, (address(d.dao), address(d.solver), AMOUNT)));
        calls[1] = Action(address(WETH), 0, abi.encodeCall(IERC20.approve, (ROUTER, AMOUNT)));
        calls[2] = Action(
            ROUTER,
            0,
            abi.encodeCall(
                IV3SwapRouter.exactInputSingle,
                (IV3SwapRouter.ExactInputSingleParams({
                        tokenIn: address(WETH),
                        tokenOut: address(USDC),
                        fee: 500,
                        recipient: receiver,
                        amountIn: AMOUNT,
                        amountOutMinimum: 100e6,
                        sqrtPriceLimitX96: 0
                    }))
            )
        );
        calls[3] = Action(address(WETH), 0, abi.encodeCall(IERC20.approve, (ROUTER, 0)));
        return abi.encode(calls);
    }

    function _quoteEnvironment() internal {
        vm.setEnv("QUOTE_CHAIN_ID", "1");
        vm.setEnv("SELL_TOKEN", vm.toString(address(WETH)));
        vm.setEnv("BUY_TOKEN", vm.toString(address(USDC)));
        vm.setEnv("SELL_AMOUNT", vm.toString(AMOUNT));
        vm.setEnv("SOLVER_ADDRESS", vm.toString(address(d.solver)));
        vm.setEnv("DAO_ADDRESS", vm.toString(address(d.dao)));
        vm.setEnv("TX_ORIGIN", vm.toString(CALLER));
    }
}
