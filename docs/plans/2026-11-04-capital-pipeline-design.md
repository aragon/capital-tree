# Capital Pipeline: Design

Date: 2026-11-04 (updated 2026-11-05)
Status: v1 (steps), v2 (stages) and v3 (trees) implemented. Recipe installation with a component registry validated, implementation in progress on `feat/flow-stages`.
Reference implementation: `../capital-router`

## Goal

One composable shape for every treasury flow: a budget feeding a tree of explicit actions. Each action can split its output into branches through a splitter (fixed weights or custom shares), and every branch ends in a leaf that consumes what it receives (transfer, burn, keep). Every action exposes preconditions and postconditions; managers tune parameters after install; the DAO owns the shape of the tree.

## Decisions

| Topic | Decision |
|---|---|
| Entrypoint | One `trigger(bytes budgetData, bytes[] nodeData)`: data for the budget (a Merkle claim's proof), and one entry per node. |
| Flow shape | One flow per plugin: a budget and a tree of nodes, committed once at the end. |
| Execution | Each node with an action runs in its own `dao.execute`, planned right after its parent ran. |
| Success | Every node must succeed. Anything else reverts the whole trigger. |
| Branches | A splitter divides the output when the flow runs: `WeightSplitter` for fixed weights, or a custom one. The tree stores no weights. The DAO changes splitters with `setFlow`. |
| Leaves | Explicit actions: `Transfer`, `TransferToBeneficiary`, `Burn`, `Keep`. A list of recipients is a branch of `Transfer` leaves. |
| Claims | Merkle only, as a budget (`MerkleClaimBudget`): cumulative leaves, one claim per trigger, only the account itself can claim. The root receives exactly what's owed. |
| Budgets | `FundedStreamBudget` for streams, `BalanceBudget` for "whatever the DAO holds", `MerkleClaimBudget` for claims. |
| Swap pricing | Flat demand inside `OpenFillAction`, which offers its whole input. The stream's `maxBudget` caps the offer, so it sets the worst price; OpenFill recipes refuse an uncapped stream. |
| Manager power | Free within installed flows (one `MANAGER_PERMISSION_ID`); the tree itself is DAO-only. |
| Pause and reentrancy | OpenZeppelin `PausableUpgradeable` and `ReentrancyGuardUpgradeable`. |
| Assets | ERC20 only; use WETH for ether. Budgets and OpenFill reject a token that isn't a contract (`InvalidToken`), including `address(0)` and the old native sentinel `0xEeee…EEeE`. A node's DAO actions may still send the DAO's own ETH to a payable function, as long as the call has a selector (`MissingFunctionSelector`). |
| Independent flows | Separate plugins, triggered separately. |
| Installation | One setup installs any tree from a recipe. Implementations come from a write-once `ComponentRegistry`. |
| Components | Every component is a clone bound to one DAO; implementations are locked and never used directly. |

## Architecture

### Example tree

```
budget  FundedStreamBudget(A)             10 A released this epoch
└─ OpenFill (A → B)                       bound to the budget; a filler pays 1,000 B for all 10 A
   ├─ 95% → Burn                          leaf: burns 950 B
   └─  5% → Transfer(feeAddr)             leaf: sends 50 B; postcondition checks it arrived
commit  writeCheckpoint                   once, after the whole tree
```

### Interfaces

```solidity
struct Asset { IERC20 token; uint256 amount; }   // a node's input, and the output it declares for its children
struct Node { INodeAction action; uint32[] children; ISplitter splitter; bool skipWhenEmpty; bool forwardSurplus; }

interface IBudget {
    function token() external view returns (IERC20);
    function available(address caller, bytes calldata data) external view returns (uint256 amount);   // the root's input
    function fundActions(address caller, bytes calldata data) external view returns (Action[] memory);  // brings it into the DAO, before the root
    function commitActions(address caller, bytes calldata data) external view returns (Action[] memory);  // once, at the end
}

interface INodeAction {
    function budget() external view returns (IBudget);   // the flow's budget when bound, or address(0)
    // output: the least the action accepts, zero for a leaf; the node spends its whole input
    function build(address caller, bytes calldata data, Asset calldata input)
        external view returns (Asset memory output, Action[] memory actions);
    // after build, before the work: revert = blocked; returns what postconditions compares against
    function preconditions(address caller, bytes calldata data, Asset calldata input, Asset calldata output)
        external view returns (bytes memory snapshot);
    // right after the node's dao.execute: revert = the work went wrong by the action's own standard
    function postconditions(address caller, Asset calldata input, Asset calldata output, bytes calldata snapshot)
        external view;
}

interface ISplitter {
    // one amount per child, in order, summing to output.amount
    function split(address caller, Asset calldata output, uint256 childCount)
        external view returns (uint256[] memory amounts);
}
```

### The tree

- Node 0 is the root and receives the budget. Children always have a higher index than their parent and exactly one parent, so the nodes form a tree with no cycles.
- A node with 2+ children is a branch: its output is split by its `splitter`. Other nodes have none. A branch may have no action, in which case it splits its input unchanged.
- A splitter only returns amounts, one per child in order, adding up to the output. It can't pick other nodes, so the shape checks made at `setFlow` still hold. Whether it returns one amount per child is only checked at trigger.
- `WeightSplitter` holds fixed weights (one per child, non-zero, summing to 1,000,000) and gives the rounding remainder to the largest weight. `setWeights` needs `MANAGER_PERMISSION_ID`, which recipes grant to the manager, and can't change the number of weights (`WeightCountChanged`).
- A node marked `skipWhenEmpty` that receives 0 (a weight that rounds down, a splitter's 0, a parent that produced nothing) is skipped with everything below it. Any other node that receives 0 reverts. The root can't be marked.
- A node marked `forwardSurplus` gives its children everything that arrived instead of its declared output: the output token's increase with two tokens, its input plus the net change with one. Only a node with an action and children can be marked. See `2026-11-06-forward-surplus-design.md`.
- A node with no children is a leaf: its action must output nothing.
- At most 16 nodes.

### Running a trigger

```
trigger(bytes budgetData, bytes[] nodeData)             nonReentrant, whenNotPaused, auth(TRIGGER)
  nonce += 1                                            makes this trigger's execution IDs unique
  amount = budget.available(caller, budgetData)
  dao.execute(budget.fundActions(caller, budgetData))   when not empty
  run(node 0, input = { budget.token(), amount })
  the DAO lost ≤ amount of the budget's token, 0 with fund actions   else revert BudgetExceeded
  dao.execute(budget.commitActions(caller, budgetData)) once, after the whole tree

run(node, input)                                        depth first
  input == 0                     → skipWhenEmpty: skip it and its subtree; else revert EmptyInput
  no action (branch)             → output = input, passed on
  otherwise
    action.build(input) → output, acts
    leaves output 0                                                   else revert OutputWithoutChildren
    snapshot = action.preconditions(input, output)
    reject acts targeting the DAO or the plugin
    snapshot DAO balances → dao.execute(acts) → action.postconditions(input, output, snapshot) → verify DAO balances
  children share the output (split by the splitter for a branch)
            forwardSurplus: everything that arrived instead
  splitter: one amount per child, summing to output.amount     else revert InvalidSplit
  NodeExecuted emits the input and what the children share
```

### Balance checks (after every node)

The DAO spent no more than the node's input and received at least its declared output (combined into one net check when input and output are the same token), else `UnexpectedBalance`. These limits hold for any action; whatever depends on the action stays in its postconditions: whether what arrived is acceptable (a tolerance, a surplus cap), whether a recipient was paid, whether a burn was exact. An action that accepts less than it asked for declares that lower amount, so its children only spend what really arrived. Recipient checks are the leaf actions' own postconditions, called right after the node's own `dao.execute` against the snapshot their preconditions took just before it, so they never see another node's movements and a failed one reverts with its own error. Together these make each node's declared output a verified fact before its children spend it. On a node marked `forwardSurplus`, the children get the measured amount instead, which may exceed the declared output. After the whole tree, the DAO must also have lost at most `available` of the budget's token (`BudgetExceeded`).

### Example flows

```
Claim paid in another token                  Claim with a 1% fee
budget  MerkleClaimBudget(A)                 budget  MerkleClaimBudget(A)       alice: 100 A
└─ Swap (A → B)                              └─ (branch, no action)
   └─ TransferToBeneficiary                     ├─  1% → Transfer(feeAddr)
                                                └─ 99% → Swap (A → B)
                                                         └─ TransferToBeneficiary

Payroll                                      Treasury diversification
budget  FundedStreamBudget(USDC)             budget  FundedStreamBudget(WETH)
└─ (branch, no action)                       └─ OpenFill (WETH → USDC)
   ├─ 50% → Transfer(alice)                     ├─ 70% → Keep
   ├─ 30% → Transfer(bob)                       └─ 30% → Transfer(grantsSafe)
   └─ 20% → Transfer(carol)
```

Rejected shapes: an action bound to another budget (`BudgetMismatch`), weights not summing to 100% (`InvalidWeights` in `WeightSplitter.initialize`), a branch without a splitter or a splitter on a node with fewer than 2 children (`InvalidSplitter`), a split that isn't one amount per child adding up to the output (`InvalidSplit` at trigger), a skippable root (`SkippableRoot`), an action-less leaf (`MissingAction`), a leaf that outputs something (`OutputWithoutChildren` at trigger).

## Rules

1. **Preconditions and postconditions belong to the action interface.** The plugin calls all three hooks on every node with an action: `build`, then `preconditions` (which returns the snapshot the check compares against), then `postconditions` right after the work.
2. **Every node that receives something must succeed.** A node is given its whole input, the root included, and may spend at most that; what it doesn't pass on stays in the DAO. Leaves output nothing. A node that receives nothing reverts, unless it's marked `skipWhenEmpty`: then it and everything below it are skipped. The root can't be. A trigger with nothing to do reverts.
3. **The budget is read once and committed once, after the whole tree,** so a stream checkpoint sees the final balance and a claim is recorded only if the whole flow ran.
4. **Planning is view-only.** Every state change is a DAO action; each node is planned right before its own `execute`.
5. **Actions declare their output in `build`.** The declared output is the least the action accepts, and the plugin checks that it arrived. A branch's splitter divides it, and anything above it stays in the DAO, unless the recipe marks the node `forwardSurplus`: then the splitter divides everything that arrived.
6. **Payout addresses picked by the caller come from node data.** `TransferToBeneficiaryAction` pays the address in its node data, so it belongs only where the caller may direct the funds: under a `MerkleClaimBudget` (only the claiming account can trigger) or on a flow with a restricted trigger.
7. **Bound actions (OpenFill) must be bound to the flow's budget,** wherever they sit. OpenFill only restarts it when its demand changes.
8. **No action may target the DAO or the plugin itself**, so no node can grant permissions, upgrade the DAO or reconfigure the flow mid-trigger. `setFlow` is also `nonReentrant`.
9. **A parameter change never alters what has already accrued.** Stream setters sync first; `setDemandPerFill` restarts the auction; raising a stream's cap continues it from the old cap.
10. **Every component belongs to the plugin's DAO.** The plugin rejects a budget, action or splitter whose `dao()` isn't its own, so an implementation (bound to no DAO) or another DAO's component can never run in a flow.

## Components

### `CapitalPipelinePlugin` (PluginCloneable, PausableUpgradeable, ReentrancyGuardUpgradeable)

- Storage: `IBudget budget`, a `uint64` trigger nonce packed in the same slot (execution IDs: plugin address, nonce, execution index), `Node[] nodes`.
- `trigger(bytes budgetData, bytes[] nodeData)`: `auth(TRIGGER_PERMISSION_ID)` (granted to `ANY_ADDR`), `nonReentrant`, `whenNotPaused`.
- `setFlow(budget, nodes)`: `auth(CONFIGURE_PERMISSION_ID)`, DAO only, `nonReentrant`. Validates the tree.
- `pause()`, `unpause()`: `auth(MANAGER_PERMISSION_ID)`.

### Budgets

- `FundedStreamBudget`: streaming pot that never jumps, `min(baseAmount + rate × elapsed, lastSeenBalance, daoBalance, maxBudget)`. Setters sync first. Commits `writeCheckpoint()`.
- `BalanceBudget`: the DAO's whole balance of a token; commits nothing.
- `MerkleClaimBudget`: cumulative Merkle claim of `(account, cumulative)` leaves (OpenZeppelin StandardMerkleTree format). Budget data `abi.encode(account, cumulative, proof)`; only the account can claim, and it picks the payout address in the `TransferToBeneficiaryAction` node's data. Its `available` is only what's owed. Commits `recordClaim` (needs `RECORD_CLAIM_PERMISSION_ID`, granted to the DAO); `setRoot` needs `MANAGER_PERMISSION_ID`. One flow per instance: a second flow on the same budget could pay a claim again from a callback before the first records it.

### Actions

Leaves share `LeafAction`: a locked implementation, no bound budget, and an output of zero: a leaf spends its whole input.

| Action | Kind | Behaviour |
|---|---|---|
| `OpenFillAction` | anywhere, bound | Dutch-auction swap: offers its whole input, demands `demandPerFill`, calls the filler back (`IFiller.fillOffer`). Postcondition: the DAO received `demandPerFill`. `setDemandPerFill` restarts the auction. The stream's `maxBudget` caps the offer. ERC20 on both sides. |
| `TransferAction` | leaf | Sends its input to a fixed recipient; postcondition checks receipt. |
| `TransferToBeneficiaryAction` | leaf | Sends its input to the address in its node data, picked by the caller (rule 6). |
| `BurnAction` | leaf | `ERC20Burnable.burn` of its input. |
| `KeepAction` | leaf | Leaves its input in the DAO. |

### Splitters

| Splitter | Behaviour |
|---|---|
| `WeightSplitter` | Fixed weights, one per child in order, non-zero, summing to 1,000,000. The rounding remainder goes to the largest weight (the first on a tie). Weights for another number of children revert the trigger with `InvalidSplit`. `setWeights` needs `MANAGER_PERMISSION_ID`. |

### `ComponentRegistry`

One per chain, maintained by a managing DAO.

- Maps ids (`"OpenFillAction@1"`) to an implementation and its metadata. Entries are write-once, so an id always means the same code and a recipe can't change under a vote.
- The first batch is registered at deployment; later entries need `REGISTER_PERMISSION_ID` on the managing DAO.
- Metadata is an IPFS link, as in Aragon plugin repos, to a JSON in `metadata/components/`: `name`, `version`, `description` and `initialize.inputs` (ABI parameters with a `description` each), so UIs can show a recipe component as named fields. A test checks every file's input types against its contract's `initialize`, and the deploy script refuses an empty link.

### `CapitalPipelinePluginSetup`

Installs any flow from a recipe:

```solidity
struct Component { bytes32 id; bytes initData; }   // registry id and its initialize call
struct Grant { address where; address who; bytes32 permissionId; }
struct InstallParams { Component[] components; IBudget budget; Node[] nodes; Grant[] grants; }
```

Recipes name contracts that don't exist yet with placeholders: `DAO_REF`, `PLUGIN_REF` and `ref(i)` for component `i`. The setup:

1. Clones the plugin and every component from its registered implementation.
2. Initializes the components in recipe order, with the placeholders in their init data replaced. A component is listed after the ones its initializer checks.
3. Initializes the plugin with the resolved budget and tree, which the plugin validates as usual.
4. Grants `EXECUTE` and `CONFIGURE` itself, then the recipe's grants. A recipe grant may only target the plugin or the recipe's components, and never `CONFIGURE`.
5. Stores a hash of the recipe's grants. Uninstalling passes them again and revokes exactly those.

| Permission | Where | Who | Granted by |
|---|---|---|---|
| `EXECUTE_PERMISSION_ID` | DAO | plugin | setup, always |
| `CONFIGURE_PERMISSION_ID` | plugin | DAO | setup, always |
| `TRIGGER_PERMISSION_ID` | plugin | `ANY_ADDR`, or a keeper | recipe |
| `MANAGER_PERMISSION_ID` | plugin, components with setters | manager | recipe |
| `CHECKPOINT_PERMISSION_ID` | stream budget | DAO, OpenFill | recipe |
| `RECORD_CLAIM_PERMISSION_ID` | `MerkleClaimBudget` | DAO | recipe |
| `REGISTER_PERMISSION_ID` | registry | whoever the managing DAO picks | managing DAO |

`script/Recipes.sol` builds the common flows (buy and burn, buyback with a fee, Merkle claim, payroll).

Deploying and installing:

1. `script/Deploy.s.sol` deploys every implementation, the registry and the setup, then publishes the setup as version 1.1 of a new Aragon plugin repo (`PluginRepoFactory.createPluginRepoWithFirstVersion`, with the release and build metadata in `metadata/`). Once per network.
2. `script/Install.s.sol` reads a config from `installs/` (one example per recipe), builds the recipe, calls `PluginSetupProcessor.prepareInstallation` (permissionless) and prints the proposal's three actions: grant `ROOT` to the PluginSetupProcessor, `applyInstallation`, revoke `ROOT`.
3. The DAO votes and executes those actions.

Aragon's framework contracts import ENS, so `lib/ens-contracts` (v0.0.8) is a dependency for compiling them. The end-to-end test deploys Aragon's plugin repo registry, factory and PluginSetupProcessor locally without ENS (empty subdomain) and installs a buy-and-burn flow through them.

## Failure handling

- Any revert in any node, hook or balance check reverts the whole `trigger`.
- Paused plugin: `Pausable: paused`. Re-entry: `ReentrancyGuard: reentrant call`.
- Setup errors: `UnknownComponent` (registry), `UnknownReference`, `GrantOutsideInstallation`, `ReservedPermission`, `GrantsMismatch` (uninstall).
- Plugin errors: configuration (`NoBudget`, `ForeignComponent`, `InvalidNodeCount`, `SkippableRoot`, `MissingAction`, `InvalidChild`, `UnreachableNode`, `InvalidSplitter`, `BudgetMismatch`, `InvalidForwardSurplus`) and trigger (`DataLengthMismatch`, `EmptyInput`, `InvalidSplit`, `OutputWithoutChildren`, `MissingFunctionSelector`, `ActionTargetsDao`, `ActionTargetsPlugin`, `UnexpectedBalance`, `BudgetExceeded`).

## Constraints and known limits

- **OpenFill and inflows:** the balance checks see that the demanded token arrived, not who sent it. Don't use OpenFill with a demanded token that can reach the DAO without its involvement (vesting, streams, rewards claimable by anyone): a filler could pay with the DAO's own money.
- No fee-on-transfer or rebasing tokens: the balance and receipt checks reject them.
- A trigger with nothing to do reverts (empty budget, closed gate), so keepers and fillers should simulate first.
- One claim per trigger, by the account itself.
- Manager power is spend power within installed flows (prices, Merkle roots, a `WeightSplitter`'s weights). Recipients are DAO-only (`setFlow`). A splitter with its own setters gives its shares to whoever the recipe grants that permission.
- Gas: one `dao.execute` per action node (a swap paying two recipients is about 585k gas).
- At most 16 nodes, so one flow pays at most 15 recipients; longer lists go through Merkle claims.
- A share that rounds to zero reverts the trigger (every node must run), e.g. a 5% branch of less than 20 wei.
- 256 actions per `execute`, per node.
- `FundedStreamBudget` freezes after deposits until someone calls `sync()`.

## Testing (Foundry)

- **Plugin:** tree validation, flows (swap and pay two recipients, buyback with burn and fee, action-less branches, keep), every-node-must-succeed rules, guards (DAO and plugin targets, reentrancy), balance checks (lying and overspending actions). The balance and whole-input tests fail when those checks are removed.
- **Components:** budgets, OpenFill, Merkle (account-only, redirect, new rounds, insolvency, claim then swap, claim with a fee branch, claim stays open when a node can't run), leaf actions (including silent transfer failures, also to a recipient listed twice), native ETH rejected as a token, and DAO actions that send ETH.
- **Invariant:** across random fills, deposits, syncs and tweaks, the DAO's pre-existing B is never spent and proceeds are split exactly.
- **Installation:** every recipe installed through the deploy script and run end to end; fresh clones per install; recipe grants applied and revoked exactly; rejected recipes (unregistered id, unknown reference, grants on the DAO or outside contracts, `CONFIGURE`); registry write-once and permissioned; metadata files match their initializers and every component is registered with its link. The DAO-binding, grant and registry tests fail when those checks are removed.

## Future work

- Relayed (gasless) claims, with a signature from the account over every node's data.
- Pulling OpenFill payments from the filler (`transferFrom`) to remove the inflow constraint.
- A script that uploads the metadata files to IPFS and fills `metadata/uris.json`.
- An uninstall script (the setup already supports uninstalling with the recipe's grants).
- Uniswap, CowSwap and oracle-priced swap actions (working versions exist in the coverage POC).
