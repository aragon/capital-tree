# Single Budget Cap Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use /executing-plans to implement this plan task-by-task.

**Goal:** OpenFill offers its whole input and has no cap of its own; the stream's `maxBudget` is the only limit, so the plugin no longer needs to know which nodes are fed by the budget.

**Architecture:** `OpenFillAction` drops `minDemandedPerOffered` and `maxOffered()`: it offers whatever it receives for a flat `demandPerFill`, and keeps its budget only to restart it when the demand changes. Since OpenFill no longer takes part of its input, only the root may (MerkleClaim), so the plugin replaces the `_budgetFed` bitmap with `index == 0`, and the bound-action check only asks that the action use the flow's budget. `script/Recipes.sol` rejects an OpenFill recipe whose stream has no cap, because that cap now sets the worst price.

**Tech Stack:** Solidity 0.8.28, Foundry (forge test, forge fmt), Aragon OSx, plain ES modules for the playground.

---

## Decisions (discussion of 2026-11-06)

- **One cap, owned by the budget.** With a flat demand, OpenFill's floor (`minDemandedPerOffered`) and the stream's `maxBudget` were the same constraint stated twice and had to agree. OpenFill drops its own. The worst price is `demandPerFill ÷ the most the node can receive`: the stream's `maxBudget` times OpenFill's share of it through the nodes above. Example: 50,000 B per fill with `maxBudget` = 1,250 A gives 40 B per A, today's floor in `installs/buy-and-burn.example.json`.
- **OpenFill keeps its budget for the restart.** `setDemandPerFill` still calls `writeCheckpoint`, so a new demand never applies to what accrued under the old one. `setMaxBudget` needs no restart: it syncs first and stores the capped amount, so lowering the cap drops the amount to it and raising it continues smoothly.
- **OpenFill can sit anywhere.** Its input is always derived from the budget through the nodes above it, so the cap carries through weights, splitters and fixed outputs. The recipe must be configured so the cap bounds the input.
- **Only the root takes part of its input.** OpenFill now takes all of it; MerkleClaim stays at the root through its own `NotTheWholeBudget`. A node below a branch without an action must take its whole input, like every other node.
- **A bound action must use the flow's budget**, wherever it sits (`BudgetMismatch`). The position check goes.
- **Recipes reject an uncapped stream** for buy-and-burn and buyback (`Recipes.UncappedStream`). Payroll keeps allowing `maxBudget = 0`.
- **Accepted side effect:** the restart resets the whole stream, so siblings sharing it (grants under a split) lose what accrued since the last trigger. The tokens stay in the DAO.

Verified in a scratchpad prototype before writing this plan: `forge fmt --check` clean, 210 tests pass, 6 skipped (baseline today: 212 pass, 6 skipped; Task 1 removes 4 OpenFill tests, Tasks 2 and 3 add 2).

Run every command from the repo root.

---

### Task 1: OpenFill offers its whole input

About 45 minutes. The initializer loses a parameter, so every caller changes in this one task or nothing compiles.

**Files:**
- Modify: `src/actions/OpenFillAction.sol` (whole file)
- Modify: `src/lib/constants.sol:25-26`
- Modify: `src/budgets/FundedStreamBudget.sol:48`, `src/budgets/FundedStreamBudget.sol:158`
- Modify: `script/open-fill/DeployFlow.sol:55-60`, `script/Recipes.sol:48-52`, `script/Recipes.sol:169-183`, `script/Install.s.sol:106-112`
- Modify: `installs/buy-and-burn.example.json`, `installs/buyback.example.json`, `metadata/components/OpenFillAction.json`
- Test: `test/OpenFillAction.t.sol`, `test/helpers/Fixture.sol`, `test/NativeEth.t.sol`, `test/invariant/PipelineInvariant.t.sol`, `test/CapitalPipelinePlugin.t.sol:300-312`, `test/CapitalPipelinePluginSetup.t.sol:272-274`, `test/Installation.t.sol:96-97`, `test/Installation.t.sol:130-134`

**Step 1: Write the failing test**

In `test/OpenFillAction.t.sol`, replace `test_MaxOfferedHoldsTheMinimumPrice` and `test_BuildCapsTheOfferAtMaxOffered` (lines 26-37) with:

```solidity
    function test_BuildOffersTheWholeInput() public view {
        (Movement memory _movement,) = action.build(filler, "", _input(50 ether));

        assertEq(_movement.inAmount, 50 ether, "no cap of its own");
        assertEq(address(_movement.outToken), address(tokenB));
        assertEq(_movement.outAmount, DEMAND);
        assertEq(_movement.beneficiary, alice, "carries the beneficiary on");
    }
```

**Step 2: Run it to make sure it fails**

Run: `forge test --match-test test_BuildOffersTheWholeInput`
Expected: FAIL with `no cap of its own: 20000000000000000000 != 50000000000000000000`

**Step 3: Rewrite the action**

Replace `src/actions/OpenFillAction.sol` with:

```solidity
// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IDAO} from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";
import {Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import {
    DaoAuthorizableUpgradeable
} from "@aragon/osx-commons-contracts/src/permission/auth/DaoAuthorizableUpgradeable.sol";
import {INodeAction} from "../interfaces/INodeAction.sol";
import {IBudget, ICheckpointedBudget} from "../interfaces/IBudget.sol";
import {IFiller} from "../interfaces/IFiller.sol";
import {Input, Movement} from "../lib/types.sol";
import {MANAGER_PERMISSION_ID} from "../lib/constants.sol";

/// @title OpenFillAction
/// @notice Take-it-or-leave-it swap priced as a Dutch auction. It offers its whole input; the DAO
///         demands a flat `demandPerFill` back; any filler can take it.
/// @dev The price obtained is `demandPerFill / offered`, so it worsens as the offer grows. The
///      action has no cap of its own: the recipe sets the worst price through the cap of the
///      stream that feeds it (`FundedStreamBudget.maxBudget`) and the nodes above it. The worst
///      price is `demandPerFill` over the most the node can receive.
///      Changing `demandPerFill` restarts the budget, so a filler cannot take an offer that
///      accumulated under the old demand at the new one.
///      `demandPerFill` is a minimum. On a node marked `forwardSurplus`, the children get everything
///      the filler sent; otherwise they get `demandPerFill` and the rest stays in the DAO.
contract OpenFillAction is INodeAction, DaoAuthorizableUpgradeable {
    /// @inheritdoc INodeAction
    /// @dev The budget restarted when `demandPerFill` changes
    IBudget public budget;

    /// @notice The token the DAO must receive back
    IERC20 public demandedToken;

    /// @notice How much of the demanded token must come back per fill
    uint256 public demandPerFill;

    /// @notice Emitted when the demand is set or updated
    event DemandPerFillUpdated(uint256 demandPerFill);

    /// @notice Thrown when the budget is address(0)
    error NoBudget();

    /// @notice Thrown when the demanded token is not a contract
    error InvalidToken();

    /// @notice Thrown when the demanded token is the budget's token
    error SameToken();

    /// @notice Thrown when the demand is zero (it would give the offered token away)
    error ZeroDemand();

    /// @notice Thrown when the DAO holds less of the demanded token than the fill requires
    error DemandNotMet(uint256 required, uint256 actual);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @param _dao The DAO executing the fills
    /// @param _budget The flow's budget; this action restarts it when the demand changes
    /// @param _demandedToken The ERC20 token the DAO must receive back
    /// @param _demandPerFill How much of the demanded token must come back per fill
    function initialize(IDAO _dao, ICheckpointedBudget _budget, IERC20 _demandedToken, uint256 _demandPerFill)
        external
        initializer
    {
        if (address(_budget) == address(0)) revert NoBudget();
        if (address(_demandedToken).code.length == 0) revert InvalidToken();
        if (_demandedToken == _budget.token()) revert SameToken();

        __DaoAuthorizableUpgradeable_init(_dao);

        budget = _budget;
        demandedToken = _demandedToken;
        _setDemandPerFill(_demandPerFill);
    }

    // INodeAction

    /// @inheritdoc INodeAction
    /// @dev No additional preconditions.
    function preconditions(address, Input calldata) external view virtual {}

    /// @inheritdoc INodeAction
    /// @dev ERC20 offer of the whole input: approve it to the caller, call it back, clear the approval.
    function build(address _caller, bytes calldata _data, Input calldata _input)
        external
        view
        virtual
        returns (Movement memory _movement, Action[] memory _actions)
    {
        _movement = Movement({
            inToken: _input.token,
            inAmount: _input.amount,
            outToken: demandedToken,
            outAmount: demandPerFill,
            beneficiary: _input.beneficiary
        });

        bytes memory _callback =
            abi.encodeCall(IFiller.fillOffer, (_input.token, _input.amount, demandedToken, demandPerFill, _data));

        address _in = address(_input.token);
        _actions = new Action[](3);
        _actions[0] = Action({to: _in, value: 0, data: abi.encodeCall(IERC20.approve, (_caller, _input.amount))});
        _actions[1] = Action({to: _caller, value: 0, data: _callback});
        _actions[2] = Action({to: _in, value: 0, data: abi.encodeCall(IERC20.approve, (_caller, 0))});
    }

    /// @inheritdoc INodeAction
    /// @dev Reverts the whole trigger unless the DAO received at least `outAmount`
    function postconditions(address, Movement calldata _movement)
        external
        view
        virtual
        returns (Action[] memory _actions)
    {
        uint256 _minBalance = _movement.outToken.balanceOf(address(dao())) + _movement.outAmount;

        _actions = new Action[](1);
        _actions[0] = Action({
            to: address(this), value: 0, data: abi.encodeCall(this.assertReceived, (_movement.outToken, _minBalance))
        });
    }

    /// @notice Reverts unless the DAO holds at least `_minBalance` of `_token`
    /// @dev Executed by the DAO as the postcondition of a fill. View, so harmless to call from anywhere.
    function assertReceived(IERC20 _token, uint256 _minBalance) external view virtual {
        uint256 _balance = _token.balanceOf(address(dao()));
        if (_balance < _minBalance) revert DemandNotMet(_minBalance, _balance);
    }

    // Manager settings

    /// @notice Updates how much must come back per fill, and restarts the auction
    function setDemandPerFill(uint256 _demandPerFill) external virtual auth(MANAGER_PERMISSION_ID) {
        _setDemandPerFill(_demandPerFill);
        _restartAuction();
    }

    // Internal

    /// @dev Bound at init to an ICheckpointedBudget, so the cast is safe
    function _restartAuction() internal virtual {
        ICheckpointedBudget(address(budget)).writeCheckpoint();
    }

    function _setDemandPerFill(uint256 _demandPerFill) internal virtual {
        if (_demandPerFill == 0) revert ZeroDemand();
        demandPerFill = _demandPerFill;
        emit DemandPerFillUpdated(_demandPerFill);
    }
}
```

**Step 4: Remove what the action no longer uses**

- `src/lib/constants.sol`: delete the last constant and its comment (nothing else uses it):

  ```solidity
  /// @dev Prices are 1e18-scaled: demanded_raw * 1e18 / offered_raw
  uint256 constant EXCHANGE_RATE_SCALE = 1e18;
  ```

  Also delete the blank line above it, so the file ends right after `uint256 constant RATIO_BASE = 1_000_000;`.
- `src/budgets/FundedStreamBudget.sol:48`: `stale balance and, in an auction, the action's \`maxOffered()\`. Proposals that spend the` becomes `stale balance and, in an auction, the stream's \`maxBudget\`. Proposals that spend the`.
- `src/budgets/FundedStreamBudget.sol:158`: `///      auction when its price terms change.` becomes `///      auction when its demand changes.`

**Step 5: Update every caller of the initializer**

`test/helpers/Fixture.sol`:

```solidity
    uint256 internal constant STREAM_CAP = 20 ether; // 1,000 B for at most 20 A: 50 B per A or better
```

replaces the `MIN_PRICE` line (49). In `_deployOpenFill`, the init call becomes
`abi.encodeCall(OpenFillAction.initialize, (dao, _budget, _demanded, DEMAND))`, and the comment on `_deployAction` (line 125) becomes
`/// @dev Demands token B. Bound to \`_budget\`, which it restarts when its demand changes.`

`test/OpenFillAction.t.sol`:
- delete `test_SetMinDemandedPerOfferedRestartsTheAuction`, `test_RevertWhen_ZeroMinimumPrice` and `test_RevertWhen_MinimumPriceTooHigh`;
- in `test_RevertWhen_DemandedTokenIsOfferedToken` and `test_RevertWhen_DemandedTokenHasNoCode`, drop the last argument: `_action.initialize(dao, budget, tokenA, DEMAND);` and `_action.initialize(dao, budget, IERC20(address(0xBEEF)), DEMAND);`.

`test/NativeEth.t.sol:43`: `_action.initialize(dao, _budget, NATIVE, DEMAND);`

`test/invariant/PipelineInvariant.t.sol`: replace `setDemandPerFill` and `setMinDemandedPerOffered` (lines 65-77) with:

```solidity
    function setDemandPerFill(uint256 _demand) external {
        // At least 20 wei so the 5% branch is never empty
        vm.prank(manager);
        action.setDemandPerFill(bound(_demand, 20, 2_000_000 ether));
    }
```

`test/CapitalPipelinePlugin.t.sol`: replace `test_AnAuctionBelowABranchMayTakePartOfItsShare` (lines 300-312) with:

```solidity
    /// The stream's cap, not the action, limits the offer
    function test_TheStreamCapLimitsTheOffer() public {
        FundedStreamBudget _budget = _deployBudget(RATE, STREAM_CAP);
        MockFiller _filler = new MockFiller(_deployPlugin(_budget, _chain(_deployAction(_budget), keep)));
        tokenB.mint(address(_filler), DEMAND);
        vm.warp(block.timestamp + 5 * EPOCH); // 50 A streamed, capped at 20

        _filler.fillWithoutData();

        assertEq(tokenA.balanceOf(address(_filler)), STREAM_CAP, "the auction offers 20 A");
        assertEq(tokenA.balanceOf(address(dao)), DAO_A - STREAM_CAP, "the rest never leaves the DAO");
        assertEq(_budget.available(), 0, "the stream restarts");
    }
```

`script/open-fill/DeployFlow.sol`: the stream is already capped at `amount` (`maxBudget` = `amount`), so the flow behaves as before. The OpenFill clone becomes:

```solidity
        d.action = OpenFillAction(
            ProxyLib.deployMinimalProxy(
                address(new OpenFillAction()), abi.encodeCall(OpenFillAction.initialize, (d.dao, d.budget, buy, demand))
            )
        );
```

`script/Recipes.sol`: drop `uint256 minDemandedPerOffered;` from `struct Swap`, and the init call in `_openFill` becomes:

```solidity
            abi.encodeCall(
                OpenFillAction.initialize,
                (IDAO(DAO_REF), ICheckpointedBudget(ref(0)), _swap.demandedToken, _swap.demandPerFill)
            )
```

`script/Install.s.sol`, in `_swap`:

```solidity
        return Recipes.Swap({
            demandedToken: IERC20(_config.readAddress(".swap.demandedToken")),
            demandPerFill: _config.readUint(".swap.demandPerFill")
        });
```

`test/CapitalPipelinePluginSetup.t.sol:273`: `return Recipes.Swap({demandedToken: IERC20(tokenB), demandPerFill: DEMAND});`

`test/Installation.t.sol`:
- line 97: `Recipes.Swap memory _swap = Recipes.Swap(IERC20(tokenB), DEMAND);`
- in `_buyAndBurnConfig`, delete the two lines `'","minDemandedPerOffered":"',` and `vm.toString(MIN_PRICE),`.

`installs/buy-and-burn.example.json` and `installs/buyback.example.json`: delete the `"minDemandedPerOffered": "40000000000000000000"` entry and the comma before it, so `"swap"` ends with `"demandPerFill": "50000000000000000000000"`. Task 3 sets their stream cap.

`metadata/components/OpenFillAction.json`:
- `description` becomes `"Dutch-auction swap: offers its whole input for a flat demandPerFill of the demanded token, and any filler can take it. It has no cap of its own: feed it from a stream with a maxBudget, which sets the worst price (demandPerFill over the most the node can receive). Restarts its budget when the manager changes demandPerFill, so it needs CHECKPOINT_PERMISSION_ID on that budget."`
- the `budget` input's description becomes `"The flow's stream budget, restarted when the demand changes. In a recipe: ref(i) of the budget component."`
- delete the `minDemandedPerOffered` input (the last entry of `initialize.inputs`). `test/Metadata.t.sol` checks the remaining types against the new initializer.

**Step 6: Format and run everything**

Run: `forge fmt src test script && forge test`
Expected: `208 tests passed, 0 failed, 6 skipped`. `forge fmt` puts the `DeployFlow` call on one line, as shown above.

Then: `grep -rn "maxOffered\|minDemandedPerOffered\|MIN_PRICE\|EXCHANGE_RATE_SCALE" src test script installs metadata`
Expected: no output.

**Step 7: Commit**

```bash
git add src/actions/OpenFillAction.sol src/lib/constants.sol src/budgets/FundedStreamBudget.sol \
  script/open-fill/DeployFlow.sol script/Recipes.sol script/Install.s.sol installs metadata test
git commit -m "Let OpenFill offer its whole input and leave the cap to the stream

With a flat demand, OpenFill's minimum price and the stream's maxBudget were
the same limit stated twice, and they had to agree. The stream's cap now sets
the worst price on its own, so OpenFill no longer takes part of its input.
It keeps its budget only to restart it when the demand changes."
```

---

### Task 2: Only the root takes part of its input

About 20 minutes. OpenFill no longer needs the budget-fed exception, so the `_budgetFed` bitmap goes.

**Files:**
- Modify: `src/CapitalPipelinePlugin.sol:30-34`, `:46-48`, `:203-207`, `:350-353`, `:383-400`, `:405-457`
- Modify: `src/interfaces/INodeAction.sol:14-16`, `:22-23`
- Test: `test/CapitalPipelinePlugin.t.sol`

**Step 1: Write the failing tests**

In `test/CapitalPipelinePlugin.t.sol`, replace `test_ABoundActionCanSitBelowNestedBranchesWithoutAction` and `test_RevertWhen_ABoundActionIsBelowAnAction` (lines 158-177) with:

```solidity
    function test_RevertWhen_ABoundActionBelowTheRootUsesAnotherBudget() public {
        Node[] memory _tree = new Node[](4);
        _tree[0] = _branch(NO_ACTION, 1, 500_000, 2, 500_000);
        _tree[1] = _leaf(keep);
        _tree[2] = _then(action, 3);
        _tree[3] = _leaf(keep);

        _expectInitRevert(
            _deployBudget(RATE, 0), _tree, abi.encodeWithSelector(CapitalPipelinePlugin.BudgetMismatch.selector, 2)
        );
    }
```

Add right before `test_RevertWhen_FillerUnderDelivers`:

```solidity
    /// OpenFill offers whatever its parent passes on, wherever it sits
    function test_AnAuctionBelowAnActionOffersItsWholeInput() public {
        Node[] memory _tree = new Node[](3);
        (_tree[0], _tree[1], _tree[2]) = (_then(_bad(BadAction.Mode.Pass), 1), _then(action, 2), _leaf(keep));
        MockFiller _filler = new MockFiller(_deployPlugin(budget, _tree));
        tokenB.mint(address(_filler), DEMAND);

        _filler.fillWithoutData();

        assertEq(tokenA.balanceOf(address(_filler)), RATE, "the filler gets the whole 10 A");
        assertEq(tokenB.balanceOf(address(dao)), DAO_B + DEMAND, "the proceeds stay in the treasury");
    }
```

Add right before `test_RevertWhen_AChildSkips`:

```solidity
    /// Only the root may take part of its input, even below a branch without an action
    function test_RevertWhen_ANodeBelowABranchTakesPartOfItsInput() public {
        CapitalPipelinePlugin _plugin = _deployPlugin(
            _deployBalanceBudget(tokenA), _fork(NO_ACTION, 500_000, _bad(BadAction.Mode.TakeHalf), 500_000, keep)
        );

        vm.expectRevert(abi.encodeWithSelector(CapitalPipelinePlugin.NodeIncomplete.selector, 1, DAO_A / 4, DAO_A / 2));
        _plugin.trigger(noData);
    }
```

**Step 2: Run them to make sure the new behavior fails**

Run: `forge test --match-test "BoundActionBelowTheRoot|AnAuctionBelowAnAction|BelowABranchTakesPart"`
Expected: 1 pass and 2 failures:
- `test_AnAuctionBelowAnActionOffersItsWholeInput`: `BudgetMismatch(1)`
- `test_RevertWhen_ANodeBelowABranchTakesPartOfItsInput`: `LeafLeftOutput(1, 25000000000000000000) != NodeIncomplete(1, 25000000000000000000, 50000000000000000000)`

`test_RevertWhen_ABoundActionBelowTheRootUsesAnotherBudget` already passes: it guards the half of `BudgetMismatch` that stays.

**Step 3: Replace the bitmap in the plugin**

In `src/CapitalPipelinePlugin.sol`:

1. Contract `@dev` (lines 30-34) becomes:

   ```solidity
   /// @dev Every node that receives something must succeed: the root takes a non-zero amount up to its
   ///      input, every other node takes exactly its input, and leaves output nothing. Anything else
   ///      reverts the whole trigger. A node that receives nothing reverts it too, unless it's marked
   ///      `skipWhenEmpty`: then neither it nor anything below it runs.
   ```

2. Delete the `_budgetFed` storage variable and its two-line comment (lines 46-48). The plugin is a clone, not upgradeable, so only new installs see the new layout.

3. In `_buildAction`, the take-all check becomes:

   ```solidity
           // The root may take less than the budget allows (but something): the rest never left the
           // DAO. Every other node takes all of it.
           if (_movement.inAmount == 0 || (_index != 0 && _movement.inAmount != _input.amount)) {
               revert NodeIncomplete(_index, _movement.inAmount, _input.amount);
           }
   ```

4. Delete `_isBudgetFed` and its comment (lines 350-353).

5. In `_setFlow`, delete `uint256 _fed = 1; // the root receives the budget` and `_budgetFed = _fed;`, and the loop's first line becomes `_checkNode(i, _newNodes[i], _budget, _hasParent);`.

6. `_checkNode` no longer threads `_fed`. Its head becomes:

   ```solidity
       /// @dev Children come after their parent and have exactly one parent, so the nodes form a tree
       ///      rooted at node 0 with no cycles. A branch splits by weights summing to RATIO_BASE, or by
       ///      a splitter of this DAO with no weights. A bound action must be bound to the flow's budget.
       function _checkNode(uint256 _index, Node calldata _node, IBudget _budget, bool[] memory _hasParent) internal view {
           uint256 _count = _node.children.length;
           if (address(_node.action) == address(0)) {
               if (_count < 2) revert MissingAction(_index);
           } else {
               _checkOwnDao(address(_node.action));
               IBudget _bound = _node.action.budget();
               if (address(_bound) != address(0) && _bound != _budget) revert BudgetMismatch(_index);
           }
   ```

   In the rest of the function: delete `if (_passesBudgetOn) _fed |= 1 << _child;` from the children loop, turn both `return _fed;` inside the splitter and `_count < 2` branches into `return;`, and delete the final `return _fed;`.

In `src/interfaces/INodeAction.sol`:

```solidity
    /// @notice The budget this action is bound to, or address(0) if it works with any input.
    ///         A bound action must be bound to the flow's budget.
    function budget() external view returns (IBudget);
```

and the first line of `build`'s notice becomes:

```solidity
    /// @notice What the node spends from `input` (`inAmount`: the root may take less than its input,
    ///         every other node all of it), what it produces (`outToken`/`outAmount`,
```

**Step 4: Format and run everything**

Run: `forge fmt src test && forge test`
Expected: `209 tests passed, 0 failed, 6 skipped`

Then: `grep -rn "budgetFed\|fed by the budget\|_passesBudgetOn" src test`
Expected: no output.

**Step 5: Commit**

```bash
git add src/CapitalPipelinePlugin.sol src/interfaces/INodeAction.sol test/CapitalPipelinePlugin.t.sol
git commit -m "Let only the root take part of its input

OpenFill now takes its whole input, so MerkleClaim at the root is the only
node that takes part of it. The budget-fed bitmap goes, and a bound action
only has to use the flow's budget: OpenFill can sit anywhere in the tree."
```

---

### Task 3: OpenFill recipes need a capped stream

About 20 minutes. The stream's cap is now the auction's only limit, so the recipes refuse to install without one.

**Files:**
- Modify: `script/Recipes.sol`, `installs/buy-and-burn.example.json`, `installs/buyback.example.json`
- Test: `test/Installation.t.sol`, `test/CapitalPipelinePluginSetup.t.sol:268-270`

**Step 1: Write the failing test**

In `test/Installation.t.sol`:

- `_buyAndBurnConfig` takes the cap: `function _buyAndBurnConfig(uint256 _maxBudget) internal view returns (string memory) {`, and its `'","maxBudget":"0","epochInterval":"',` line becomes three lines:

  ```solidity
              '","maxBudget":"',
              vm.toString(_maxBudget),
              '","epochInterval":"',
  ```

- The three existing callers pass `STREAM_CAP`: `_buyAndBurnConfig(STREAM_CAP)` in `test_DaoInstallsBuyAndBurnWithTheProposalActions`, `test_RevertWhen_SomeoneElseAppliesTheInstallation` and `test_ConfigBuildsTheSameRecipe`. In the last one the stream becomes `Recipes.Stream(IERC20(tokenA), RATE, STREAM_CAP, EPOCH)`.
- Add before `test_RevertWhen_TheRecipeIsUnknown`:

  ```solidity
      /// OpenFill has no cap of its own: without the stream's, an auction has no worst price
      function test_RevertWhen_AnAuctionStreamHasNoCap() public {
          vm.expectRevert(Recipes.UncappedStream.selector);
          installer.recipe(_buyAndBurnConfig(0));
      }
  ```

In `test/CapitalPipelinePluginSetup.t.sol`, `_stream()` uses the cap:

```solidity
        return
            Recipes.Stream({token: IERC20(tokenA), amountPerEpoch: RATE, maxBudget: STREAM_CAP, epochInterval: EPOCH});
```

**Step 2: Run it to make sure it fails**

Run: `forge test --match-test test_RevertWhen_AnAuctionStreamHasNoCap`
Expected: compile error `Member "UncappedStream" not found or not visible after argument-dependent lookup in type(library Recipes)`.

**Step 3: Reject an uncapped stream in the OpenFill recipes**

In `script/Recipes.sol`, after `ANY_ADDR`:

```solidity
    /// @notice Thrown when an OpenFill recipe's stream has no cap, so its auction has no worst price
    error UncappedStream();
```

Both OpenFill recipes build their budget with `_cappedStreamBudget(_stream)` instead of `_streamBudget(_stream)`, and say why in their notice:

```solidity
    /// @notice Stream → OpenFill → burn all the proceeds. The stream's `maxBudget` sets the worst
    ///         price: `demandPerFill / maxBudget`. Components: 0 budget, 1 OpenFill, 2 Burn.
```

```solidity
    /// @notice Stream → OpenFill → burn the proceeds, except `_feeWeight` (of RATIO_BASE) to `_fee`.
    ///         The stream's `maxBudget` sets the worst price: `demandPerFill / maxBudget`.
    ///         Components: 0 budget, 1 OpenFill, 2 Burn, 3 Transfer.
```

Add before `_openFill`:

```solidity
    /// @dev OpenFill offers its whole input, so the stream's cap is the auction's only limit
    function _cappedStreamBudget(Stream memory _stream)
        private
        pure
        returns (CapitalPipelinePluginSetup.Component memory)
    {
        if (_stream.maxBudget == 0) revert UncappedStream();
        return _streamBudget(_stream);
    }
```

`payroll` keeps `_streamBudget`: a stream without a cap is fine when nothing prices it.

**Step 4: Give the examples a cap**

In `installs/buy-and-burn.example.json` and `installs/buyback.example.json`, `"maxBudget": "0"` becomes `"maxBudget": "1250000000000000000000"`: 50,000 B for at most 1,250 A, the same 40 B per A floor the examples had. `installs/payroll.example.json` stays at `"0"`.

**Step 5: Run everything**

Run: `forge fmt test script && forge test`
Expected: `210 tests passed, 0 failed, 6 skipped`

**Step 6: Commit**

```bash
git add script/Recipes.sol installs test/Installation.t.sol test/CapitalPipelinePluginSetup.t.sol
git commit -m "Refuse OpenFill recipes whose stream has no cap

OpenFill has no limit of its own any more: the stream's maxBudget is the most
it can offer, so it sets the worst price. An uncapped stream would let the
offer grow without bound."
```

---

### Task 4: Playground

About 15 minutes. The playground encodes OpenFill's initializer, so it breaks without this task.

**Files:**
- Modify: `playground/graph.js:10`, `:24`, `:43-45`
- Modify: `playground/lib.js:145-153`, `:166-175`, `:381-385`, `:426`
- Modify: `playground/app.js:63`, `:183`
- Modify: `playground/style.css:129`, `playground/README.md:43`

**Step 1: Make OpenFill an action that can sit anywhere**

`playground/graph.js`:
- `OpenFillAction: "root",` becomes `OpenFillAction: "action",`
- `ports` gains the kind: `({ budget: [0, 1], root: [1, 1], action: [1, 1], branch: [1, 1], leaf: [1, 0] })`
- in `defaultData`, the stream gets the cap that gives the default OpenFill a 50 B per A floor, and OpenFill loses its minimum price:

  ```js
      FundedStreamBudget: { token: tokenA, amountPerEpoch: "10e18", maxBudget: "20e18", epochInterval: "86400" },
  ```

  ```js
      OpenFillAction: { demandedToken: tokenB, demandPerFill: "1000e18" },
  ```

`playground/style.css`, after the `.root .box-kind` line:

```css
.action .box-kind { color: var(--root); }
```

`playground/app.js`:
- the palette groups OpenFill on its own: `["Root actions", ["OpenFillAction@1", "MerkleClaimAction@1"]],` becomes

  ```js
    ["Root actions", ["MerkleClaimAction@1"]],
    ["Actions", ["OpenFillAction@1"]],
  ```

- a flow gets the fill button when any node is an OpenFill:

  ```js
        if (f.nodes.some((n) => n.name === "OpenFillAction")) run = `<button data-fill="${f.plugin}">Fill with the playground filler</button>`;
  ```

**Step 2: Recipes and details**

`playground/lib.js`:

```js
const stream = (token, maxBudget = "0") =>
  component("FundedStreamBudget@1", { token, amountPerEpoch: "10e18", maxBudget, epochInterval: "86400" });
// 1,000 B for at most 20 A (the stream's cap): 50 B per A or better
const openFill = (tokenB) =>
  component("OpenFillAction@1", { budget: "ref(0)", demandedToken: tokenB, demandPerFill: "1000e18" });
```

- "Buy and burn" and "Buyback with a fee" use `stream(tokenA, "20e18")`; "Payroll" keeps `stream(tokenA)`.
- In `describeComponent`, the stream shows its cap and OpenFill stops reading `maxOffered`:

  ```js
      if (name === "FundedStreamBudget") {
        details.push(`${units(await get("amountPerEpoch"))} ${sym} per ${await get("epochInterval")}s`);
        const cap = await get("maxBudget");
        if (cap > 0n) details.push(`capped at ${units(cap)} ${sym}`);
      }
  ```

  ```js
      details.push(`demands ${units(await get("demandPerFill"))} ${demanded} per fill`);
      details.push("offers its whole input");
  ```

- the `fill` comment becomes `/** The playground filler takes the flow's OpenFill offer, paying from its own balance */`.

`playground/README.md:43`: the root-action row splits in two:

```markdown
| Root action | input, output | MerkleClaimAction (bound to the budget) |
| Action | input, output | OpenFillAction (anywhere; the stream's cap limits its offer) |
```

**Step 3: Check the syntax**

Run: `for f in playground/graph.js playground/lib.js playground/app.js; do node --check "$f" && echo "$f ok"; done`
Expected: three `ok` lines.

Optional, needs a Sepolia RPC (about 10 minutes): run `playground/up.sh`, open http://127.0.0.1:5173/playground/, install "Buy and burn", advance a day, and press "Fill with the playground filler". The stream shows `capped at 20 A`, and 10 A are sold for 1,000 B.

**Step 4: Commit**

```bash
git add playground
git commit -m "Show OpenFill as an action that can sit anywhere in the playground

OpenFill lost its minimum price, so the playground's recipes cap the stream
instead and the box no longer reads maxOffered."
```

---

### Task 5: Docs

About 30 minutes.

**Files:**
- Modify: `README.md:96`, `:110`, `:178-193`, `:327-330`, `:429`
- Modify: `docs/plans/2026-11-04-capital-pipeline-design.md:23`, `:37`, `:58`, `:127`, `:132`, `:137`, `:139`, `:162`

**Step 1: README**

- Line 96, first plugin rule: `1. The root takes more than zero and at most its input; every other node takes exactly its input. What the root doesn't take never left the DAO.`
- Line 110, setup rule 4: `4. An action bound to a budget (OpenFill, MerkleClaim) must be bound to the flow's budget. It may sit anywhere; MerkleClaim keeps itself at the root (\`NotTheWholeBudget\`).`
- Lines 178-193, the OpenFill section, become:

  ```markdown
  #### OpenFillAction

  A take-it-or-leave-it swap priced as a Dutch auction. It offers its whole input of token A, and
  the DAO demands a flat `demandPerFill` of token B for it. Fed by a stream that grows from zero, the
  price obtained, `demandPerFill / offered`, worsens as the offer grows. The action has no cap of its
  own: the stream's `maxBudget`, times the node's share of it, is the most it can offer, so it sets
  the worst price. `script/Recipes.sol` refuses an OpenFill recipe whose stream has no cap. Whoever
  finds the trade worth it first calls `trigger()` and fills it.

  - **Moves**: offers its whole input of A and outputs `demandPerFill` of B to its children.
    On a node marked `forwardSurplus`, the children get all the B the filler sent instead.
  - **Placement**: anywhere. Below a branch, its input is its share of the budget (see "Grants and
    an auction" below); below an action, whatever that action passes on. Every node of the flow then
    waits for a fill, and changing the demand restarts the whole budget, not just the auction's share.
  - **Checks**: the DAO received at least `demandPerFill` of B, or the whole trigger reverts.
  - **Settings**: `setDemandPerFill` (`MANAGER_PERMISSION_ID`) restarts the auction, so the action
    needs `CHECKPOINT_PERMISSION_ID` on its budget. The stream's `setMaxBudget` moves the worst price:
    raising the cap lowers it.
  ```

- Lines 327-330, "Grants and an auction", become:

  ```markdown
  **Grants and an auction** (no recipe): a branch with no action splits a stream between a grants
  transfer and an auction, so the auction's offer grows at half the stream's rate, up to half the
  stream's cap. Grants are paid only when someone fills the auction, and the stream then restarts
  from zero for both. Changing the auction's demand restarts it too, so the grants lose what accrued
  since the last fill (it stays in the DAO).
  ```

- Line 429, layout table:

  ```markdown
  | `src/actions/OpenFillAction.sol`               | Open-fill swap with Dutch-auction pricing, anywhere in the tree (the stream's cap limits the offer)        |
  ```

**Step 2: Design doc** (`docs/plans/2026-11-04-capital-pipeline-design.md`, the source of truth for decisions)

- Line 23: `| Swap pricing | Flat demand inside \`OpenFillAction\`, which offers its whole input. The stream's \`maxBudget\` caps the offer, so it sets the worst price; OpenFill recipes refuse an uncapped stream. |`
- Line 37: `└─ OpenFill (A → B)                       bound to the budget; a filler pays 1,000 B for all 10 A`
- Line 58: `    function budget() external view returns (IBudget);   // the flow's budget when bound, or address(0)`
- Line 127, rejected shapes: `a bound action below a node with an action (\`BudgetMismatch\`)` becomes `an action bound to another budget (\`BudgetMismatch\`)`, and `a node that takes part of its input (\`NodeIncomplete\` at trigger)` becomes `a node other than the root that takes part of its input (\`NodeIncomplete\` at trigger)`.
- Line 132, rule 2: `A node fed by the budget (the root, or one below branches without an action) takes a non-zero amount, up to its input;` becomes `The root takes a non-zero amount, up to its input;`.
- Line 137, rule 7, becomes: `7. **Bound actions (OpenFill, MerkleClaim) must be bound to the flow's budget,** wherever they sit. OpenFill only restarts it when its demand changes. \`MerkleClaimAction\` stays at the root: below a branch its siblings would take a share of the whole budget on every claim, so it reverts unless its input is the whole budget. What the root doesn't take never left the DAO.`
- Line 139, rule 9: `price setters restart the auction` becomes `\`setDemandPerFill\` restarts the auction; raising a stream's cap continues it from the old cap`.
- Line 162, OpenFill row: `| \`OpenFillAction\` | anywhere, bound | Dutch-auction swap: offers its whole input, demands \`demandPerFill\`, calls the filler back (\`IFiller.fillOffer\`, payable). Postcondition \`assertReceived\`. \`setDemandPerFill\` restarts the auction. The stream's \`maxBudget\` caps the offer. ETH on either side. |`

**Step 3: Check nothing stale is left**

Run: `grep -n "maxOffered\|minDemandedPerOffered\|fed by\|below branches without an action" README.md docs/plans/2026-11-04-capital-pipeline-design.md`
Expected: no output.

**Step 4: Commit**

```bash
git add README.md docs/plans/2026-11-04-capital-pipeline-design.md
git commit -m "Document the single stream cap and the root-only partial take"
```

---

### Task 6: Final verification

About 5 minutes.

**Step 1:** `forge fmt --check src test script` → no output, exit 0.

**Step 2:** `forge build` → compiles without errors.

**Step 3:** `forge test` → `210 tests passed, 0 failed, 6 skipped`.

**Step 4:** `grep -rn "maxOffered\|minDemandedPerOffered\|budgetFed\|EXCHANGE_RATE_SCALE" src test script playground installs metadata README.md` → no output.

## Out of scope

- Older plan docs (`docs/plans/2026-11-04-*`, `2026-11-05-*`, `2026-11-06-forward-surplus-design.md`) keep their history as written.
- `metadata/uris.json` holds no IPFS links yet, so nothing needs re-uploading.
