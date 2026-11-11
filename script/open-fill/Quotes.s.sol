// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Quote/build only: no deployment, fork, broadcast or live execution.
// Returns callback bytes (abi.encode(Action[])) to place in a tree node's payload.
// These quote adapters support ERC20 pairs and zero-value router calls only.
contract OpenFillQuotes is Script {
    // Reject the native sentinel used by quote providers; flows accept ERC20 pairs only.
    IERC20 private constant NATIVE = IERC20(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);

    enum Provider {
        ZeroEx,
        OneInch
    }

    struct Request {
        uint256 chainId;
        address sellToken;
        address buyToken;
        uint256 sellAmount;
        address solver;
        address dao;
        address origin;
    }

    // Stage 1: fetch live router calldata. The solver is the taker; the DAO receives output.
    function zeroEx() external returns (bytes memory data, uint256 value) {
        Request memory r = _request();
        string memory url = string.concat(
            "https://api.0x.org/swap/allowance-holder/quote?chainId=",
            vm.toString(r.chainId),
            "&sellToken=",
            vm.toString(r.sellToken),
            "&buyToken=",
            vm.toString(r.buyToken),
            "&sellAmount=",
            vm.toString(r.sellAmount),
            "&taker=",
            vm.toString(r.solver),
            "&recipient=",
            vm.toString(r.dao),
            "&txOrigin=",
            vm.toString(r.origin),
            "&slippageBps=100"
        );
        string memory json = _get(url, Provider.ZeroEx);
        data = fromZeroEx(json, r.dao, r.solver, IERC20(r.sellToken), r.sellAmount);
        value = vm.parseUint(vm.parseJsonString(json, ".transaction.value"));
    }

    function oneInch() external returns (bytes memory data, uint256 value) {
        Request memory r = _request();
        string memory base = string.concat("https://api.1inch.com/swap/v6.1/", vm.toString(r.chainId));
        string memory spenderJson = _get(string.concat(base, "/approve/spender"), Provider.OneInch);
        string memory url = string.concat(
            base,
            "/swap?src=",
            vm.toString(r.sellToken),
            "&dst=",
            vm.toString(r.buyToken),
            "&amount=",
            vm.toString(r.sellAmount),
            "&from=",
            vm.toString(r.solver),
            "&receiver=",
            vm.toString(r.dao),
            "&origin=",
            vm.toString(r.origin),
            "&slippage=1&disableEstimate=true&allowPartialFill=false"
        );
        string memory json = _get(url, Provider.OneInch);
        data = fromOneInch(json, spenderJson, r.dao, r.solver, IERC20(r.sellToken), r.sellAmount);
        value = vm.parseUint(vm.parseJsonString(json, ".tx.value"));
    }

    // Stage 2: turn each API's response into the same callback actions.
    function fromZeroEx(string memory json, address dao, address solver, IERC20 token, uint256 amount)
        public
        pure
        returns (bytes memory)
    {
        Action memory swap = _transaction(json, ".transaction");
        address spender = vm.parseJsonAddress(json, ".allowanceTarget");
        return _encode(dao, solver, token, amount, spender, swap);
    }

    function fromOneInch(
        string memory json,
        string memory spenderJson,
        address dao,
        address solver,
        IERC20 token,
        uint256 amount
    ) public pure returns (bytes memory) {
        Action memory swap = _transaction(json, ".tx");
        address spender = vm.parseJsonAddress(spenderJson, ".address");
        return _encode(dao, solver, token, amount, spender, swap);
    }

    function _transaction(string memory json, string memory path) internal pure returns (Action memory) {
        return Action({
            to: vm.parseJsonAddress(json, string.concat(path, ".to")),
            value: vm.parseUint(vm.parseJsonString(json, string.concat(path, ".value"))),
            data: vm.parseJsonBytes(json, string.concat(path, ".data"))
        });
    }

    function _encode(address dao, address solver, IERC20 token, uint256 amount, address spender, Action memory swap)
        internal
        pure
        returns (bytes memory)
    {
        require(token != NATIVE && address(token) != address(0), "ERC20 input required");
        require(swap.value == 0, "Native ETH not supported");
        Action[] memory calls = new Action[](4);
        calls[0] = Action(address(token), 0, abi.encodeCall(IERC20.transferFrom, (dao, solver, amount)));
        calls[1] = Action(address(token), 0, abi.encodeCall(IERC20.approve, (spender, amount)));
        calls[2] = swap;
        calls[3] = Action(address(token), 0, abi.encodeCall(IERC20.approve, (spender, 0)));
        return abi.encode(calls);
    }

    /// @notice Places callback data at a node index; all other entries are empty.
    /// @dev For multiple data-bearing nodes, build the bytes[] yourself and preserve each payload.
    function forNode(uint256 nodeCount, uint256 nodeIndex, bytes memory fillData)
        public
        pure
        returns (bytes[] memory data)
    {
        require(nodeIndex < nodeCount, "Invalid node position");
        data = new bytes[](nodeCount);
        data[nodeIndex] = fillData;
    }

    function _request() internal view returns (Request memory r) {
        r = Request({
            chainId: vm.envOr("QUOTE_CHAIN_ID", uint256(1)),
            sellToken: vm.envAddress("SELL_TOKEN"),
            buyToken: vm.envAddress("BUY_TOKEN"),
            sellAmount: vm.envUint("SELL_AMOUNT"),
            solver: vm.envAddress("SOLVER_ADDRESS"),
            dao: vm.envAddress("DAO_ADDRESS"),
            origin: vm.envAddress("TX_ORIGIN")
        });
        require(
            r.sellToken != address(0) && r.buyToken != address(0) && r.sellToken != address(NATIVE)
                && r.buyToken != address(NATIVE),
            "ERC20 pair required"
        );
    }

    function _get(string memory url, Provider provider) internal returns (string memory) {
        string[] memory command = new string[](5);
        command[0] = "bash";
        command[1] = "-c";
        // Keys are read by the child process, rather than placed in Forge's FFI trace.
        if (provider == Provider.ZeroEx) {
            command[2] =
                'curl --fail --silent --show-error --max-time 30 -H "0x-api-key: ${ZERO_EX_API_KEY:?Set ZERO_EX_API_KEY}" -H "0x-version: v2" "$1"';
        } else if (provider == Provider.OneInch) {
            command[2] =
                'curl --fail --silent --show-error --max-time 30 -H "Authorization: Bearer ${ONEINCH_API_KEY:?Set ONEINCH_API_KEY}" "$1"';
        } else {
            revert("Unsupported quote provider");
        }
        command[3] = "quote";
        command[4] = url;
        return string(vm.ffi(command));
    }
}
