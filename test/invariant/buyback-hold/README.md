# Buyback-and-hold campaigns

Run both campaigns and their regression tests:

```sh
forge test --match-path 'test/invariant/buyback-hold/*.t.sol'
```

`BuybackHoldInvariantTest` keeps the original large funding and fuzzes independent
`fill` and `advanceTime` actions. The paired helpers remain available to scenario
tests, but the fuzzer is no longer forced to alternate Alice and Bob.

`BuybackHoldDepositsInvariantTest` starts with one epoch's worth of sellToken,
below the budget cap. It also fuzzes `deposit` and `sync`. Deposits return tokens
already purchased by Alice or Bob; they never mint tokens. The three tracked
holders therefore still account for the full supply.

The handler maintains its own accrual anchor and last-observed DAO balance.
Deposits update modeled balances but cannot raise the available offer. Syncs
record deposits and discard hidden growth only when a limit clipped accrual;
uncapped syncs retain the anchor to preserve rounding. Fills reset it to zero.
Each action checks the model against the production budget and verifies protected
state and selected live permissions.

Live permission checks cover the plugin's DAO execution grant, the DAO's and
OpenFill's checkpoint grants, and each buyer's trigger, root, execution,
configuration, checkpoint, pause and component-settings permissions. They use
`dao.hasPermission`, including effective wildcard grants, rather than treating
the setup's recorded permission hash as proof of live permissions. This is not an
exhaustive check of every DAO permission or condition/data combination.

Settings, token supplies and ordinary ERC20 behavior remain fixed. Arbitrary
callbacks, reentrancy, partial pulls, overpayment, unrelated outflows and manager
changes are outside these campaigns. The deposit fixture exercises low balances
because otherwise deposits and syncs would not meaningfully stress the model.

For a deeper run, the existing CI profile uses 1,024 runs at depth 128:

```sh
FOUNDRY_PROFILE=ci forge test --match-path 'test/invariant/buyback-hold/*.t.sol'
```
