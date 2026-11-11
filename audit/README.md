# OpenFill buyback audit

Initial reconnaissance: 2026-11-06. This records scope, the execution model, and questions for the deeper exploit review. It is not a completed audit or a list of confirmed findings.

Baseline: V2 working tree at commit `9574bf53bc08cdf214d46dc580615f631cb946d9` (`poc generic solver`). Existing uncommitted changes were included in the inspection and preserved. The tracked Solidity change is a comment in `OpenFillAction.sol`; `TODO.md` and `docs/generic-solver.md` were also present as untracked context. Dependency versions are recorded in `../foundry.lock`.

The review prioritizes unauthorized treasury loss, payment bypass, permission escalation, and economically meaningful disruption of buybacks. Findings should describe an executable attack, its prerequisites, the resulting loss or disruption, and a reproducible test. Low-severity and informational observations will not be used to pad the report. Items already mentioned in `TODO.md` require independent validation and impact assessment.

The DAO holds the funds and trusts the installed capital-flow implementations. Their public functions remain attack surface. Working assumptions are that governance and manager keys are trusted to select components and economic settings, while fillers, solver callers, callback calldata, and transaction ordering are adversarial. The review will examine whether public calls can exercise privileged capabilities indirectly.

The initial scope covers the shipped buyback and buy-and-burn recipes, OpenFill placements below budget-splitting branches, and interactions with other installed components that can affect a buyback. It includes the pipeline executor, stream budget, OpenFill, downstream burn/transfer/keep actions, generic solver, setup and recipe permissions, and the relevant vendored OSx authorization/execution code. Other components matter where an attacker can compose their public functions with this flow.

| Execution step                                                                      | Security boundary to investigate                                                                                               |
| ----------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| `CapitalPipelinePlugin.trigger` reads the budget once.                              | A public caller chooses timing and per-node data; allocations must remain valid throughout execution.                          |
| `OpenFillAction.build` offers `min(input.amount, maxOffered())` for a fixed demand. | The filler must not influence token selection, price enforcement, or the allowed spend beyond authorized terms.                |
| The DAO approves the caller, invokes its callback, and clears approval.             | The callback can make arbitrary external calls while a treasury allowance exists. Native offers instead arrive as call value.  |
| OpenFill and the plugin check DAO balances.                                         | Measured receipt must represent an economically valid payment; checking a balance increase alone does not identify its source. |
| Children burn, transfer, or retain the declared output.                             | Existing treasury holdings, branch allocations, fees, and surplus must not be exploitable across nodes.                        |
| The DAO checkpoints the stream after the tree completes.                            | Public synchronization, other treasury movements, and component composition must not permit repeated or excessive spending.    |

The local OSx DAO and the pipeline both guard execution against reentrancy. A proposed attack through another flow must account for the DAO-wide guard; merely naming cross-contract reentrancy is insufficient. Public view hooks do not themselves execute their returned DAO actions. The generic solver deliberately exposes arbitrary calls and sweeping to anyone, so its permissionless design alone is not a treasury vulnerability.

The highest-priority investigations are:

1. **Payment attribution:** whether a filler can trigger a DAO-owned claim, reward, vesting release, or other receivable during its callback and have that inflow satisfy the demand while taking the offered asset. This depends on the surrounding integrations and is not yet a demonstrated deployment exploit.
2. **Allowance and callback composition:** whether partial pulls, callback nesting, token behavior, or public functions on other installed components leave reusable authority or allow spending outside the quoted trade.
3. **Stream accounting under adversarial timing:** whether synchronization, treasury outflows and replenishment, or shared component state can create excess offers or material disruption. Fractional-accrual rounding is already mentioned in `TODO.md`; severity depends on supported token units, rates, and attack cost.
4. **End-to-end economics and authorization:** whether valid tree compositions, downstream processing, or installation/lifecycle calls let an unprivileged actor violate the configured buyback policy despite local checks passing.

Two scope questions remain:

1. **Which chains and token pairs should be supported?** In particular, is native ETH included in this audit, or is the ERC20/WETH-only direction in `TODO.md` authoritative? Concrete tokens determine which approval, transfer, burn, and balance behaviors are realistic.
2. **What surrounds the DAO?** Is there a concrete deployment/configuration, or should the review model multiple installed flows and integrations with permissionless claims, rewards, or vesting payments to the DAO? These details determine whether an unrelated DAO-owned inflow can be used as apparent fill payment.

Unless corrected, the current implementation is the baseline: native paths remain included, governance and managers are trusted, each stream is intended for one flow as documented, the configured floor applies to gross demanded tokens before fees, and children receive the declared demand while any overdelivery stays in the DAO. Public interactions across installed components remain in scope.

Baseline validation used Solidity 0.8.28 and Foundry 1.7.1-dev:

```sh
RUN_FORK_TESTS=false RUN_LIVE_QUOTES=false forge test --offline
```

Result: **166 passed, 0 failed, 6 skipped** across 15 suites. The six skipped tests require fork opt-in. No fork, live quote, or new exploit proof was run during this reconnaissance. The existing invariant handler uses a funded mock filler; its passing results do not establish safety against arbitrary adversarial callbacks. Full baseline output is in [baseline-tests.log](baseline-tests.log).
