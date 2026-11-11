# Audit scope

- **Repository**: [aragon/capital-tree](https://github.com/aragon/capital-tree)
- **Commit**: `d879ab2ece4f956ad697cb93a2eeb2d987b564f0` (branch `dev`)
- **In scope**: the `src/` folder, except the three contracts listed under [Out of scope](#out-of-scope)
- **Size**: 24 files, 1,148 nSLOC (non-blank, non-comment lines)

## What the system does

Capital Tree is an Aragon OSx plugin that runs one treasury flow per installation: a **budget**
releases an amount of one ERC20 token, and a **tree of actions** spends it. Each node runs in its
own `dao.execute`, followed by balance checks, so a node can only spend what the budget released or
what its parent really produced. Typical flows: sell a token in a Dutch auction and burn the
proceeds, buy back and donate to a vault, pay a payroll from a stream.

Read these first:

- [`README.md`](../README.md#how-it-works): how a trigger runs, what the plugin enforces, installation and permissions
- [`docs/components.md`](components.md): each component's behavior, calls and caveats
- [`docs/avkat-buyback.md`](avkat-buyback.md): one flow end to end

## In scope

| File                                   |     nSLOC | Purpose                                                                                                                                                              |
| -------------------------------------- | --------: | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `src/CapitalTreePlugin.sol`            |       271 | The plugin. Validates the tree (`setFlow`), walks it on `trigger`, executes each node through the DAO and checks balances after each node and after the whole run    |
| `src/setup/CapitalTreePluginSetup.sol` |       236 | `PluginSetup`. Deploys the plugin and every component as CREATE2 clones salted with the DAO and the recipe, and builds the permission list; verifies it on uninstall |
| `src/registry/ComponentRegistry.sol`   |        38 | Write-once registry of component implementations, maintained by a managing DAO                                                                                       |
| `src/budgets/StreamBudget.sol`         |       119 | Budget that grows at a fixed rate, capped by the DAO balance seen at the last sync, the live balance and an optional cap. Must never jump                            |
| `src/actions/OpenFillAction.sol`       |        98 | Offers its whole input for a flat demand of another token; a Dutch auction when a stream feeds it                                                                    |
| `src/actions/BurnAction.sol`           |        43 | Leaf: burns its input (`ERC20Burnable.burn`)                                                                                                                         |
| `src/actions/VaultDonateAction.sol`    |        45 | Leaf: donates its input to an ERC4626 vault without minting shares                                                                                                   |
| `src/actions/TransferAction.sol`       |        16 | Leaf: sends its input to a fixed recipient                                                                                                                           |
| `src/actions/KeepAction.sol`           |        18 | Leaf: leaves its input in the DAO                                                                                                                                    |
| `src/actions/base/TransferBase.sol`    |        42 | Shared transfer leaf logic and the recipient-balance postcondition                                                                                                   |
| `src/actions/base/BaseAction.sol`      |        15 | Default (empty) hooks for actions                                                                                                                                    |
| `src/actions/base/LeafAction.sol`      |         8 | Base for leaves: output nothing                                                                                                                                      |
| `src/splitters/WeightSplitter.sol`     |        50 | Splits a branch's output by fixed weights                                                                                                                            |
| `src/solvers/GenericFillSolver.sol`    |        40 | Minimal filler for `OpenFillAction`: triggers the plugin and runs a batch of calls in the `fillOffer` callback                                                       |
| `src/base/BaseComponent.sol`           |        11 | Base for every component: a clone bound to one DAO                                                                                                                   |
| `src/interfaces/IBudget.sol`           |        11 | Budget interface                                                                                                                                                     |
| `src/interfaces/INodeAction.sol`       |        18 | Action interface: `build`, `preconditions`, `postconditions`                                                                                                         |
| `src/interfaces/ISplitter.sol`         |         9 | Splitter interface                                                                                                                                                   |
| `src/interfaces/IComponent.sol`        |        15 | Common initializer and `requiredPermissions`                                                                                                                         |
| `src/interfaces/IFiller.sol`           |        11 | `fillOffer` callback                                                                                                                                                 |
| `src/interfaces/IDonationVault.sol`    |         5 | ERC4626 with `donate`                                                                                                                                                |
| `src/lib/types.sol`                    |        15 | `Asset` and `Node`                                                                                                                                                   |
| `src/lib/constants.sol`                |         8 | Permission IDs and `RATIO_BASE`                                                                                                                                      |
| `src/lib/tokens.sol`                   |         6 | ERC20 transfer action helper                                                                                                                                         |
| **Total**                              | **1,148** |                                                                                                                                                                      |

## Out of scope

- **Three contracts in `src/`**: `src/budgets/MerkleClaimBudget.sol`, `src/budgets/BalanceBudget.sol`,
  `src/actions/TransferToBeneficiaryAction.sol`. Findings that depend on their code are out of scope.
- **`script/`**: deployment, installation and recipe scripts.
- **`test/`**: tests, mocks and fixtures.
- **`lib/`**: dependencies (see below), treated as trusted.
- Everything else: `metadata/`, `config/`, `docs/`.

## Roles and permissions

| Role                | Holds                                                           | Can                                                                         |
| ------------------- | --------------------------------------------------------------- | --------------------------------------------------------------------------- |
| DAO                 | `CONFIGURE` on the plugin; `CHECKPOINT` on the stream           | Replace the flow (`setFlow`); restart the stream. Fully trusted             |
| Plugin              | `EXECUTE` on the DAO                                            | Run the actions that the flow's components build                            |
| Triggerer           | `TRIGGER` on the plugin                                         | Run the flow. Usually anyone (`ANY_ADDR`), so untrusted                     |
| Manager             | `SET_SETTINGS` on components                                    | Change a stream's rate and cap, an open fill's demand, a splitter's weights |
| Guardian            | `PAUSE` on the plugin                                           | Pause and unpause the flow                                                  |
| `OpenFillAction`    | `CHECKPOINT` on its stream                                      | Restart the stream when its demand changes                                  |
| Registry maintainer | `REGISTER` on `ComponentRegistry` (granted by the managing DAO) | Register new implementations; entries are write-once                        |
| Solver operator     | `authorized` on a `GenericFillSolver`                           | Trigger through the solver and sweep its balance                            |
