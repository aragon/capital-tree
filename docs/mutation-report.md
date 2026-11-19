# Mutation testing

Mutation testing changes one expression in `src/` at a time (a "mutant") and reruns the tests.
A mutant that no test catches "survives" and points at behavior the suite doesn't pin down.
Forge has it built in (`forge test --mutate`, an MVP as of Foundry 1.8).

## How to run

One contract at a time, against every test except the fork and invariant suites:

```shell
forge test --mutate src/budgets/StreamBudget.sol \
  --no-match-path '{test/**/*Fork.t.sol,test/invariant/**}' \
  --mutation-timeout 180 --json > stream-budget.json
```

- **Fork suites** need an RPC and are excluded.
- **Invariant suites** are excluded because they run single-threaded for several seconds each. With
  one mutant per CPU core in parallel, every mutant hit the timeout instead of being judged.
- The run never fails on survivors. `summary.mutation_score` and `survived_mutants` in the JSON
  are the result.
- Forge skips the other mutants of an expression once one of them survives, so killing a survivor
  can reveal new ones: rerun the contract after adding tests.

A full pass over `src/` takes about 40 minutes on 10 cores. `CapitalTreePlugin` alone takes 15.

## Results

Scores are `killed / (killed + survived)`. "Before" is the suite on `6c6010c`. "After" includes
the tests listed below.

| Contract | Mutants | Killed | Survived | Score before | Score after |
| --- | ---: | ---: | ---: | ---: | ---: |
| `CapitalTreePlugin` | 515 | 348 | 40 | 86.4% | 89.7% |
| `CapitalTreePluginSetup` | 239 | 177 | 30 | 78.2% | 85.5% |
| `StreamBudget` | 84 | 68 | 5 | 90.7% | 93.2% |
| `OpenFillAction` | 74 | 61 | 4 | 91.4% | 93.8% |
| `WeightSplitter` | 81 | 72 | 5 | 91.8% | 93.5% |
| `BurnAction` | 20 | 19 | 1 | 85.0% | 95.0% |
| `VaultDonateAction` | 20 | 20 | 0 | 78.9% | 100.0% |
| `TransferBase` | 15 | 15 | 0 | 93.3% | 100.0% |
| `TransferAction` | 5 | 4 | 1 | 80.0% | 80.0% |
| `ComponentRegistry` | 24 | 19 | 5 | 78.3% | 79.2% |
| `GenericFillSolver` | 35 | 30 | 4 | 88.2% | 88.2% |

`KeepAction`, `BaseAction` and `BaseComponent` produce no mutants. `MerkleClaimBudget`,
`BalanceBudget` and `TransferToBeneficiaryAction` are outside the [audit scope](audit-scope.md)
and weren't run.

## What still survives

Every remaining survivor was checked by hand, and none of them can change behavior:

- **Unsigned comparisons**: `x == 0` → `x <= 0`, `x != 0` → `x > 0`, and the same for `address`
  and `bytes32` against zero.
- **Loop forms**: `i < n` → `i != n`, `++i` → `i++`.
- **Conditions an earlier line already settles**: `BurnAction`'s `<` → `!=` after the `>` check,
  `StreamBudget._sync`'s `_amount < _accrued()` → `!=` (the amount never exceeds the accrual),
  `OpenFillAction.postconditions`' `>` → `>=` (a floor of zero can't fail).
- **Boundaries where both sides compute the same value**: the plugin's balance floors
  (`_target > _maxSpend` → `>=`, `_inAfter >= _inBefore` → `>`, and the like) and
  `_output.amount <= _input.amount` → `<`.
- **Combinations that can't happen**: a child both at or below its parent's index and out of
  range (`CapitalTreePlugin._checkNode`); an extra balance read when the input and output tokens
  are the same (`_readBalances`); `|` → `^` when packing the execution ID's disjoint fields.

## Tests added

Each test was checked by applying its mutant and seeing the test fail.

| Contract | What was missing | Test |
| --- | --- | --- |
| `StreamBudget` | A zero epoch interval | `test_RevertWhen_EpochIntervalIsZero` |
| `StreamBudget` | Rate setters while a cap hides growth | `testFuzz_SetAmountPerEpochKeepsWhatACapHides`, `testFuzz_SetEpochIntervalKeepsWhatACapHides` |
| `WeightSplitter` | Fewer weights than before | `test_RevertWhen_NewWeightsShrinkTheCount` |
| `OpenFillAction` | Two dependencies, a zero budget | `test_RevertWhen_DependencyCountIsNotOne`, `test_RevertWhen_BudgetIsZero` |
| `OpenFillAction` | An offer above the balance before the fill | `testFuzz_PostconditionsAcceptAnOfferAboveTheBalanceBefore` |
| `CapitalTreePlugin` | A one-token node declaring more than its input | `testFuzz_AOneTokenNodeMayDeclareMoreThanItsInput`, `testFuzz_RevertWhen_AOneTokenNodeDeclaresMoreThanArrived` |
| `CapitalTreePlugin` | A one-token node losing more than input minus output | `test_RevertWhen_AOneTokenNodeLosesMoreThanItsInputMinusItsOutput` |
| `CapitalTreePlugin` | A split adding up to more than the output | `testFuzz_RevertWhen_ASplitExceedsTheOutput` |
| `CapitalTreePlugin` | A bound budget lower than the flow's | `test_RevertWhen_TheRootIsBoundToAnotherBudgetInEitherOrder` |
| `CapitalTreePlugin` | An out-of-range child, weights for fewer children | `test_RevertWhen_AChildIsOutOfRange`, `test_RevertWhen_WeightsAreForFewerChildren` |
| `CapitalTreePlugin` | A child pointing back to the root (a cycle) | `test_RevertWhen_AChildPointsBackToTheRoot` |
| `CapitalTreePlugin` | Empty action lists reaching the DAO | `test_EmptyActionListsSkipTheDao` |
| `CapitalTreePlugin` | A value call with arguments | `test_NodeCallsPayableFunctionWithArguments` (`NativeEth.t.sol`) |
| `CapitalTreePlugin` | The spend reported by `BudgetExceeded` | `test_BudgetExceededReportsTheWholeSpend` |
| `BurnAction` | A burn larger than the input | `testFuzz_RevertWhen_TheBurnTakesMoreThanItsInput` |
| `VaultDonateAction` | A wrong asset in either address order | `test_RevertWhen_TheInputIsNotTheVaultAssetInEitherOrder` |
| `VaultDonateAction` | A vault that already held assets; one gaining more than the donation | `test_RevertWhen_TheVaultGainsLessThanTheDonationOnTopOfItsAssets`, `testFuzz_PostconditionsAcceptMoreAssetsThanDonated` |
| `TransferBase` | A recipient ending up with more than the input | `testFuzz_TransferPostconditionAcceptsMoreThanTheInput` |
| `CapitalTreePluginSetup` | Blank entries in the prepared permissions | `testFuzz_PreparesNoBlankPermissions` |
| `CapitalTreePluginSetup` | Uninstall checks from one side only | `testFuzz_RevertWhen_UninstallNamesAnotherDao`, `testFuzz_RevertWhen_AnUninstallPermissionIdIsAltered` |

Two patterns recur in what was missing. Checks written as `a != b` were tested with one ordering
of `a` and `b`, so an ordering comparison passed. Floors were tested from an empty starting
balance, so dropping the starting balance from the sum went unnoticed.
