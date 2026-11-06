// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Vm} from "forge-std/Vm.sol";
import {OpenFillQuotes} from "./Quotes.s.sol";

// Public API examples for the Ethereum WETH -> USDC fork fixture. Requires curl and jq.
contract PublicOpenFillQuotes is OpenFillQuotes {
    function kyberSwap() external returns (bytes memory data, uint256 value) {
        Request memory r = _request();
        _mainnetPair(r);
        string memory base = "https://aggregator-api.kyberswap.com/ethereum/api/v1";
        string memory route = _http(
            string.concat(
                base,
                "/routes?tokenIn=",
                vm.toString(r.sellToken),
                "&tokenOut=",
                vm.toString(r.buyToken),
                "&amountIn=",
                vm.toString(r.sellAmount)
            ),
            ""
        );
        string memory body = string.concat(
            '{"routeSummary":',
            _object(route, "$response.data.routeSummary"),
            ',"sender":"',
            vm.toString(r.solver),
            '","recipient":"',
            vm.toString(r.dao),
            '","slippageTolerance":100,"enableGasEstimation":false}'
        );
        string memory built = _http(string.concat(base, "/route/build"), body);
        address router = vm.parseJsonAddress(built, ".data.routerAddress");
        // ERC20 input: no native value is required.
        Action memory swap = Action(router, 0, vm.parseJsonBytes(built, ".data.data"));
        return (_encode(r.dao, r.solver, IERC20(r.sellToken), r.sellAmount, router, swap), 0);
    }

    function velora() external returns (bytes memory data, uint256 value) {
        Request memory r = _request();
        _mainnetPair(r);
        string memory route = _http(
            string.concat(
                "https://api.paraswap.io/prices?srcToken=",
                vm.toString(r.sellToken),
                "&destToken=",
                vm.toString(r.buyToken),
                "&amount=",
                vm.toString(r.sellAmount),
                "&srcDecimals=18&destDecimals=6&side=SELL&network=1&version=6.2"
            ),
            ""
        );
        string memory body = string.concat(
            '{"priceRoute":',
            _object(route, "$response.priceRoute"),
            ',"srcToken":"',
            vm.toString(r.sellToken),
            '","destToken":"',
            vm.toString(r.buyToken),
            '","srcAmount":"',
            vm.toString(r.sellAmount),
            '","userAddress":"',
            vm.toString(r.solver),
            '","receiver":"',
            vm.toString(r.dao),
            '","txOrigin":"',
            vm.toString(r.origin),
            '","srcDecimals":18,"destDecimals":6,"slippage":100}'
        );
        // Funding and approvals happen inside fillOffer, so standalone API simulation cannot succeed.
        string memory built = _http("https://api.paraswap.io/transactions/1?ignoreChecks=true", body);
        Action memory swap = _transaction(built, "");
        address spender = vm.parseJsonAddress(route, ".priceRoute.tokenTransferProxy");
        return (_encode(r.dao, r.solver, IERC20(r.sellToken), r.sellAmount, spender, swap), swap.value);
    }

    function _mainnetPair(Request memory r) internal pure {
        require(
            r.chainId == 1 && r.sellToken == 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2
                && r.buyToken == 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48,
            "Ethereum WETH/USDC example only"
        );
    }

    function _http(string memory url, string memory body) internal returns (string memory) {
        string[] memory command = new string[](6);
        command[0] = "bash";
        command[1] = "-euc";
        command[2] = bytes(body).length == 0
            ? 'curl --fail-with-body --silent --show-error --max-time 30 "$1"'
            : 'curl --fail-with-body --silent --show-error --max-time 30 -H "Content-Type: application/json" --data-raw "$2" "$1"';
        command[3] = "quote";
        command[4] = url;
        command[5] = body;
        Vm.FfiResult memory result = vm.tryFfi(command);
        require(result.exitCode == 0, string.concat("Quote API: ", string(result.stdout), string(result.stderr)));
        return string(result.stdout);
    }

    // Preserve the API's full route JSON, including fields we do not interpret in Solidity.
    function _object(string memory json, string memory filter) internal returns (string memory) {
        string[] memory command = new string[](6);
        command[0] = "jq";
        command[1] = "-cne";
        command[2] = "--argjson";
        command[3] = "response";
        command[4] = json;
        command[5] = filter;
        return string(vm.ffi(command));
    }
}
