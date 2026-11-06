# Forward Surplus: Design

Date: 2026-11-06
Status: implemented (both phases) on `feat/forward-received-output`, replacing the forward-by-default change made there first.
Exploration: the "Pipeline Output Options" page (options A to E, worked examples, ways to trick the system, preview research): https://claude.ai/artifact/XThNjmFGnKBnq5QuDdPNGP

## Goal

Let a node pass its children what really arrived, not only what it declared, but only where the DAO opts in. Every other node keeps today's behavior, so tokens nobody expected never move down the tree.

## Background

- Today the children get the declared `outAmount`. Anything above it, such as a filler's overpayment or a claim's income above its preview, stays in the DAO with no node routing it.
- Many operations have no exact preview that a `view` `build()` can call: swaps on Uniswap v3/v4, Balancer and aggregators; CRV and BAL gauge emissions, COMP and Comet rewards; Pendle and legacy Curve gauge rewards; Yearn V3 redemptions; stETH and aToken delivery (1–2 wei off). For those, only a balance measurement after execute gives the real amount.
- Forwarding by default is unsafe. A balance measurement also counts tokens the node didn't earn, such as treasury tokens pulled in during the node by a permissionless vesting release.

## Decisions

| Topic | Decision |
|---|---|
| Who chooses | The recipe, per node: `Node.forwardSurplus`, set by the DAO at install or with `setFlow`. Default `false`. |
| Declared node (default) | The children get `outAmount`, as today. Anything above it stays in the DAO. |
| Forwarding node | The children get everything that arrived: the output token's balance increase with two tokens, `inAmount + net change` with one. |
| One-token forwarding node | Passes its whole input on: `outAmount ≥ inAmount`. Anything above `inAmount` is a minimum it expects to receive. Keeping part of the input takes a split and a Keep leaf. |
| Where it's allowed | Only on a node with an action and at least one child. |
| Actions | No change. An action declares a minimum in `outAmount`, as today. |
| Record | Phase 2: the node's splitter and `NodeExecuted` see what the node expected and what really happened. Children don't get it. |

## Behavior

### What the children share

```
forwarded(node) =
  forwardSurplus == false      → movement.outAmount                                (today)
  forwardSurplus, two tokens   → outBalanceAfter − outBalanceBefore                (≥ outAmount, checked)
  forwardSurplus, one token    → movement.inAmount + (balanceAfter − balanceBefore) (≥ outAmount, checked)
```

Weights and splitters divide `forwarded`, and `_split` checks that the amounts add up to `forwarded` instead of `outAmount`.

With one token, the after-execute check `balanceAfter + inAmount ≥ balanceBefore + outAmount` and the build check `outAmount ≥ inAmount` together guarantee a net change ≥ 0, so `forwarded` never underflows and is never below `outAmount`.

### Checks

| When | Check | Error |
|---|---|---|
| `setFlow` | `forwardSurplus` only on a node with an action and at least one child | `InvalidForwardSurplus(nodeIndex)` (new) |
| build, forwarding node, one token | `outAmount ≥ inAmount` | `OutputBelowInput(nodeIndex, outAmount, inAmount)` (new) |
| build, forwarding node, two tokens | `outToken` is a token, even when `outAmount` is 0 | `InvalidOutToken` (existing, now also with `outAmount` 0) |
| after execute | Two tokens: spent ≤ `inAmount` and received ≥ `outAmount`. One token: net change ≥ `outAmount − inAmount` | `UnexpectedBalance` (unchanged) |

### Snapshot

The output token is snapshotted when it differs from the input token and either `outAmount != 0` or the node forwards surplus. This fixes a gap on this branch: a two-token node that declares `outAmount = 0` (no minimum) is never measured, so its children get 0.

### Plugin flow

```
_runAction(index, node, input)
  (movement, actions) = _buildAction(...)                 // + OutputBelowInput, wider InvalidOutToken
  (inBefore, outBefore) = _snapshot(movement, node.forwardSurplus)
  _execute(actions)
  _verify(movement, inBefore, outBefore)                   // unchanged
  forwarded = _forwarded(movement, node.forwardSurplus, inBefore, outBefore)
  emit NodeExecuted(...)
_runChildren(index, node, movement, forwarded)              // weights and splitters divide `forwarded`
```

### Examples

| Node | `forwardSurplus` | Children get |
|---|---|---|
| OpenFill, demand 1,000 B, the filler sends 1,050 B | false | 1,000 B; 50 B stay in the DAO |
| The same | true | 1,050 B |
| Harvest with no preview: 100 A in, claims 3 A, out = 100 | true | 103 A |
| The same | false | 100 A; 3 A stay in the DAO |
| Cap: 100 A in, out = 30 | false | 30 A |
| The same | true | Reverts with `OutputBelowInput` |
| Harvest with a 3 A preview, out = 103, and 50 treasury A pulled in during the claim | false | 103 A; 50 A stay in the DAO |
| The same | true | 153 A: the 50 A leak to the children |

## Phase 2: the parent's record

```solidity
struct Record {
    Movement expected;  // what build() declared
    uint256 spent;      // input token that left the DAO during the node
    uint256 received;   // output token that came into the DAO during the node
    uint256 forwarded;  // what the children share
}

interface ISplitter {
    function split(address caller, Record calldata parent, uint256 childCount)
        external view returns (uint256[] memory amounts);
}

event NodeExecuted(uint256 indexed nodeIndex, address indexed caller, bytes32 executionId, Record record);
```

Measurement:

- **Two tokens:** `spent = max(0, inBefore − inAfter)`, `received = outAfter − outBefore`. Measured on declared nodes too, when the output is a token, so the record is real even when the children get `outAmount`.
- **One token:** with `net = after − before`, `spent = max(0, −net)` and `received = max(0, net)`. The record holds net amounts: a node that pays 10 and gets 20 back records 0 spent and 10 received.
- **Branch without an action:** `spent = 0`, `received = 0`, `forwarded` = its input.

What it enables: a surplus splitter that sends `expected.outAmount` one way and `forwarded − expected.outAmount` another, and indexers that see declared and real amounts per node.

The record isn't passed to child actions. An earlier draft added `Input.parent`, but no action reads it, and it would have changed every action's ABI and added 8 words to every `preconditions` and `build` call. A child that needs its parent's numbers can get the field back when it exists.

It's a separate phase because it changes the ABI of `ISplitter` and the event. Every splitter and the playground's ABI change with it. Phase 1 stands on its own.

## Interactions

- **`skipWhenEmpty`:** unchanged. A forwarding node that declared 0 and received nothing passes 0, which skips or reverts as today.
- **Budget-fed nodes** (OpenFill at the root or below action-less branches): `inAmount` may be less than the input. `forwarded` uses `inAmount`, so the untaken part never counts.
- **Beneficiary, pause, reentrancy, budget commit:** unchanged.
- **Native ETH:** `tokenBalance` already handles `NATIVE`.
- **Storage:** the new bool packs into the slot that already holds `splitter` and `skipWhenEmpty`. The plugin is a clone, not upgradeable, so only new installs see the new layout.

## Changes, file by file

Phase 1:

- `src/lib/types.sol`: `Node.forwardSurplus` with its natspec.
- `src/CapitalPipelinePlugin.sol`: store the field; `InvalidForwardSurplus` in `_checkNode`; `OutputBelowInput` and the wider `InvalidOutToken` in `_buildAction`; the `_snapshot` condition; `_received` becomes `_forwarded`; `_runChildren` and `_split` use `forwarded`; natspec.
- `src/setup/CapitalPipelinePluginSetup.sol`: pass the field through when resolving nodes.
- `metadata/build.json`: the field, after `skipWhenEmpty`.
- `playground/lib.js`: `forwardSurplus: false` in `encodeRecipe`.
- `src/interfaces/INodeAction.sol`, `src/actions/OpenFillAction.sol`: reword the natspec this branch changed, from "children get everything that arrived" to "children get `outAmount`, or everything that arrived on a node that forwards surplus".
- `README.md`, `docs/plans/2026-11-04-capital-pipeline-design.md`: the Node term, the rules, the OpenFill section and the error lists.

Phase 2:

- `src/lib/types.sol`: `Record`.
- `src/interfaces/ISplitter.sol`, test splitters (`CapSplitter`, `FixedSplitter`): the new `split` signature.
- `src/CapitalPipelinePlugin.sol`: build the record, pass it to the splitter, emit it.
- `playground/abis.json`: regenerate.

## Testing (Foundry)

Phase 1:

1. A declared OpenFill node with a filler that overpays 50 B: the children get 1,000 B and the DAO keeps 50 B, as today.
2. The four overpayment tests already on this branch (single child, weights, splitter, native ETH) set `forwardSurplus` on the OpenFill node.
3. A one-token forwarding node with income (a new mock action that pulls tokens in): the children get `inAmount + net`. The same node declared: the children get `outAmount`.
4. A one-token forwarding node with `outAmount < inAmount`: `OutputBelowInput`.
5. A one-token forwarding node that loses tokens: `UnexpectedBalance`.
6. A two-token forwarding node that declares `outAmount = 0`: the children get what arrived.
7. `forwardSurplus` on a leaf and on a branch without an action: `InvalidForwardSurplus` at `setFlow`.
8. Setup: the field survives `PluginSetup` resolution.
9. Invariants: the handler's tree sets `forwardSurplus` on its OpenFill node, so "proceeds are split exactly" still holds when the filler overpays.

Phase 2:

1. A splitter receives the node's record (expected 1,000 B, received 1,050 B, forwarded 1,050 B), and a surplus splitter sends the 50 B to Keep.
2. `NodeExecuted` emits the record, on a forwarding node and on a declared one (received 1,050 B, forwarded 1,000 B).
3. With one token the record holds the net change: paying 10 and getting 20 back records 0 spent and 10 received.
4. A branch without an action gives its splitter a record of 0 spent, 0 received, and its input as forwarded.

## Out of scope

Separate changes:

- **OpenFill accepts the DAO's own tokens as payment.** A filler can trigger a permissionless release of the DAO's tokens inside `fillOffer`. Fix: pull the filler's payment with `transferFrom`. It exists today; on a forwarding node the released tokens would also be forwarded.
- A per-node cap on the surplus, if forwarding nodes need one.
- Actions that declare they can't preview their output, so `setFlow` refuses them on a declared node.
- Playground graph-editor toggles for `forwardSurplus` and `skipWhenEmpty`.
- OpenFill below other actions (chained swaps).
- The invariant handler's `bound()` bug, where `setDemandPerFill`'s bounds can cross.

## Effort

- Phase 1: about half a day, including tests and docs.
- Phase 2: about 3 hours.

## Resolved questions

1. Phase 2 (the record) ships together with phase 1.
2. The errors are `InvalidForwardSurplus` and `OutputBelowInput`.
3. The record goes to the splitter and the event only, not to child actions (`Input` is unchanged).
