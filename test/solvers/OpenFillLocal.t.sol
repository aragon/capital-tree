// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DAO} from "@aragon/osx/core/dao/DAO.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {DeployFlow} from "../../script/open-fill/DeployFlow.sol";
import {OpenFillQuotes} from "../../script/open-fill/Quotes.s.sol";
import {DeployLocal, LocalRouter} from "../../script/open-fill/DeployLocal.s.sol";

contract OpenFillLocalTest is Test {
    DeployFlow.Deployment d;
    LocalRouter router;
    OpenFillQuotes quotes;

    function setUp() public {
        (d, router) = (new DeployLocal()).run();
        quotes = new OpenFillQuotes();
    }

    function test_zeroExResponseToFill() public {
        console2.log("1. Local 0x-shaped quote: spender + transaction {to, value, data}");
        vm.serializeAddress("zeroEx", "allowanceTarget", address(router.spender()));
        string memory json = vm.serializeString("zeroEx", "transaction", _transactionJson());
        console2.log("2. Encode pull -> approve spender -> swap -> clear approval");
        bytes memory data = quotes.fromZeroEx(json, address(d.dao), address(d.solver), d.sell, 100 ether);
        _fill(data);
    }

    function test_oneInchResponseToFill() public {
        console2.log("1. Local 1inch-shaped responses: approve/spender + swap.tx");
        string memory spender = vm.serializeAddress("oneInchSpender", "address", address(router.spender()));
        string memory json = vm.serializeString("oneInch", "tx", _transactionJson());
        console2.log("2. Encode pull -> approve spender -> swap -> clear approval");
        bytes memory data = quotes.fromOneInch(json, spender, address(d.dao), address(d.solver), d.sell, 100 ether);
        _fill(data);
    }

    function test_sweepSurplusAfterPayingDAO() public {
        address recipient = address(0xB0B);
        ERC20Mock(address(d.buy)).mint(address(router), 2 ether);
        Action[] memory calls = new Action[](6);
        calls[0] = Action(
            address(d.sell), 0, abi.encodeCall(IERC20.transferFrom, (address(d.dao), address(d.solver), 100 ether))
        );
        calls[1] = Action(address(d.sell), 0, abi.encodeCall(IERC20.approve, (address(router.spender()), 100 ether)));
        calls[2] = Action(
            address(router), 0, abi.encodeCall(LocalRouter.swap, (d.sell, d.buy, 100 ether, 7 ether, address(d.solver)))
        );
        calls[3] = Action(address(d.sell), 0, abi.encodeCall(IERC20.approve, (address(router.spender()), 0)));
        calls[4] = Action(address(d.buy), 0, abi.encodeCall(IERC20.transfer, (address(d.dao), 5 ether)));
        calls[5] = Action(address(d.solver), 0, abi.encodeCall(d.solver.sweep, (d.buy, recipient)));
        bytes[] memory perNode = quotes.forNode(d.plugin.nodes().length, 0, abi.encode(calls));

        d.solver.trigger(perNode);

        assertEq(d.buy.balanceOf(address(d.dao)), 5 ether);
        assertEq(d.buy.balanceOf(recipient), 2 ether);
        assertEq(d.buy.balanceOf(address(d.solver)), 0);
        assertEq(d.sell.balanceOf(address(d.solver)), 0);
        assertEq(d.sell.allowance(address(d.dao), address(d.solver)), 0);
        assertEq(d.sell.allowance(address(d.solver), address(router.spender())), 0);
    }

    function test_sweepSkipsZeroTransfer() public {
        vm.mockCallRevert(address(d.buy), abi.encodeCall(IERC20.transfer, (address(this), 0)), bytes("Zero transfer"));
        d.solver.sweep(d.buy, address(this));
    }

    function test_quoteRejectsNativeCallValue() public {
        vm.serializeAddress("paidTx", "to", address(router));
        vm.serializeString("paidTx", "value", "1000000000000000");
        string memory transaction = vm.serializeBytes(
            "paidTx", "data", abi.encodeCall(LocalRouter.swap, (d.sell, d.buy, 100 ether, 5 ether, address(d.dao)))
        );
        vm.serializeAddress("paidQuote", "allowanceTarget", address(router.spender()));
        string memory json = vm.serializeString("paidQuote", "transaction", transaction);
        vm.expectRevert("Native ETH not supported");
        quotes.fromZeroEx(json, address(d.dao), address(d.solver), d.sell, 100 ether);

        string memory spender = vm.serializeAddress("paidSpender", "address", address(router.spender()));
        string memory oneInchJson = vm.serializeString("paidOneInch", "tx", transaction);
        vm.expectRevert("Native ETH not supported");
        quotes.fromOneInch(oneInchJson, spender, address(d.dao), address(d.solver), d.sell, 100 ether);
    }

    function test_misdirectedQuoteRollsBackSwapAndCheckpoint() public {
        vm.serializeAddress("wrongTx", "to", address(router));
        vm.serializeString("wrongTx", "value", "0");
        string memory transaction = vm.serializeBytes(
            "wrongTx", "data", abi.encodeCall(LocalRouter.swap, (d.sell, d.buy, 100 ether, 5 ether, address(this)))
        );
        vm.serializeAddress("wrongQuote", "allowanceTarget", address(router.spender()));
        string memory json = vm.serializeString("wrongQuote", "transaction", transaction);
        bytes[] memory data =
            quotes.forNode(2, 0, quotes.fromZeroEx(json, address(d.dao), address(d.solver), d.sell, 100 ether));
        uint256 checkpoint = d.budget.baseTimestamp();

        vm.expectRevert(abi.encodeWithSelector(DAO.ActionFailed.selector, 3));
        d.solver.trigger(data);

        assertEq(d.sell.balanceOf(address(d.dao)), 100 ether);
        assertEq(d.buy.balanceOf(address(router)), 5 ether);
        assertEq(d.buy.balanceOf(address(this)), 0);
        assertEq(d.sell.balanceOf(address(router)), 0);
        assertEq(d.sell.allowance(address(d.dao), address(d.solver)), 0);
        assertEq(d.sell.allowance(address(d.solver), address(router.spender())), 0);
        (uint256 _available,) = d.budget.available(address(0), "");
        assertEq(_available, 100 ether);
        assertEq(d.budget.baseTimestamp(), checkpoint);
    }

    function test_quoteRejectsNativeInput() public {
        vm.serializeAddress("nativeQuote", "allowanceTarget", address(router.spender()));
        string memory json = vm.serializeString("nativeQuote", "transaction", _transactionJson());
        vm.expectRevert("ERC20 input required");
        quotes.fromZeroEx(
            json, address(d.dao), address(d.solver), IERC20(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE), 100 ether
        );
    }

    function test_forNodeRejectsInvalidIndex() public {
        vm.expectRevert("Invalid node position");
        quotes.forNode(2, 2, "");
    }

    function _transactionJson() internal returns (string memory) {
        vm.serializeAddress("tx", "to", address(router));
        vm.serializeString("tx", "value", "0");
        return vm.serializeBytes(
            "tx", "data", abi.encodeCall(LocalRouter.swap, (d.sell, d.buy, 100 ether, 5 ether, address(d.dao)))
        );
    }

    function _fill(bytes memory data) internal {
        console2.log("3. solver.trigger -> plugin.trigger -> build -> DAO -> fillOffer -> calls");
        d.solver.trigger(quotes.forNode(d.plugin.nodes().length, 0, data));
        console2.log("4. DAO received demanded tokens; balances and allowances checked");
        (uint256 _available,) = d.budget.available(address(0), "");
        assertEq(_available, 0);
        assertEq(d.budget.baseTimestamp(), block.timestamp);
        assertEq(d.sell.balanceOf(address(d.dao)), 0);
        assertEq(d.sell.balanceOf(address(router)), 100 ether);
        assertEq(d.buy.balanceOf(address(d.dao)), 5 ether);
        assertEq(d.sell.balanceOf(address(d.solver)), 0);
        assertEq(d.buy.balanceOf(address(d.solver)), 0);
        assertEq(d.sell.allowance(address(d.dao), address(d.solver)), 0);
        assertEq(d.sell.allowance(address(d.solver), address(router.spender())), 0);
    }
}
