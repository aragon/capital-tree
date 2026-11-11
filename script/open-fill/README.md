# Open fill examples

A stream → OpenFill → Keep flow filled through `GenericFillSolver`. `DeployLocal.s.sol` runs it
with mock tokens and a local router; `DeployFork.s.sol` runs it on an Ethereum mainnet fork, selling
WETH for USDC. `Quotes.s.sol` (0x, 1inch) and `PublicQuotes.s.sol` (KyberSwap, Velora) turn an
aggregator quote into the solver's callback data, `abi.encode(Action[])`, for the OpenFill node.

From the repo root, run the offline examples with:

```sh
forge test --match-path 'test/solvers/*' -vv
forge script script/open-fill/DeployLocal.s.sol:DeployLocal -vv
```

Fork and live quote tests are opt-in:

- `RUN_FORK_TESTS=true` runs `GenericOpenFillForkTest` on a mainnet fork from `MAINNET_RPC_URL`, or
  from Alchemy with `ALCHEMY_API_KEY`. `FORK_BLOCK` pins the block.
- `RUN_LIVE_QUOTES=true` adds the live quote tests, which call the APIs with `curl` through `--ffi`
  (and `jq` for KyberSwap and Velora). The 0x and 1inch tests also need `ZERO_EX_API_KEY` and
  `ONEINCH_API_KEY`.
- `just fork-tests` resolves these from `vars.yaml` and runs both; `just fork-tests false` skips the
  live quotes.
