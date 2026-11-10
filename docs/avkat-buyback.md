# USDC buybacks that compound for avKAT holders

The flow buys KAT with treasury USDC, donates a configurable fraction to avKAT,
and leaves the rest as liquid KAT in the DAO. `donate()` increases the vault's
locked assets without minting shares, so existing avKAT holders receive the value.
It does not give the DAO a new avKAT position.

```text
DAO USDC -> FundedStreamBudget -> OpenFillAction (KAT)
                                    |-- 80% -> VaultDonateAction -> AvKATVault.donate
                                    `-- 20% -> KeepAction (KAT remains in DAO)
```

All nodes execute in the same transaction. A failed swap, donation, or
postcondition reverts the entire trigger and its budget checkpoint.

## Reproduce

```sh
forge test
RUN_KATANA_FORK_TESTS=true forge test --match-contract AvKatBuybackForkTest -vv
```

The fork suite defaults to `https://rpc.katana.network`, block **47,557,066**.
Override with `KATANA_RPC_URL` and `KATANA_FORK_BLOCK` if needed. Ordinary tests
skip the fork unless explicitly enabled. No private key, broadcast, or quote API
is needed. A public archive RPC must serve the selected block.

The fork uses real deployed contracts:

| Contract | Katana address |
| --- | --- |
| avKAT vault | `0x7231dbaCdFc968E07656D12389AB20De82FbfCeB` |
| KAT | `0x7F1f4b4b29f5058fA32CC7a97141b8D7e5ABDC2d` |
| USDC / vbUSDC | `0x203A662b0BD271A6ed5a60EdFbd04bFce608FD36` |
| Sushi V3 router | `0x4e1d81A3E627b9294532e990109e4c21d217376C` |
| Sushi V3 QuoterV2 | `0x92dea23ED1C683940fF1a2f8fE23FE98C5d3041c` |

Addresses: [Katana contract directory](https://docs.katana.network/katana/technical-reference/contract-addresses/).
Vault API: [AvKATVault.sol](https://github.com/aragon/katana-governance/blob/develop/src/AvKATVault.sol).

Only the DAO's initial 10 USDC funding is supplied with a test cheatcode. The
positive tests acquire all KAT through the real Sushi V3 0.05% pool and call the
real vault/strategy/escrow. They verify increased assets and backing per share,
unchanged share supply, no avKAT minted to the DAO, retained KAT, cleared
allowances, and a committed budget. The negative test injects a vault revert and
checks that the real swap and budget changes roll back.

At the pinned block, 10 USDC buys 2,995.360862202 KAT. An 80/20 allocation donates
2,396.288689761 KAT and retains 599.072172440 KAT. The 100% case donates all of it.
These are historical test results, not a current executable quote.

## Installation and configuration

`Recipes.buybackAndDonate(manager, stream, swap, vault, donateWeight)` builds the
installation recipe. `Install.s.sol` accepts `"recipe": "buybackAndDonate"`;
`installs/buyback-and-donate.example.json` demonstrates the Katana configuration.
Replace the DAO/manager placeholders and choose fresh auction terms before use.
The example's 2,900 KAT demand for up to 10 USDC is illustrative only.

`Deploy.s.sol` registers `VaultDonateAction@1` with the other components. Populate
its metadata URI alongside the other entries in `metadata/uris.json` before
publishing a registry. Existing registries need the new implementation registered
by their authorized manager before installing this recipe.

Weights are out of 1,000,000: 800,000 means 80% donation. Both 0% and 100% produce
a single-child flow. The DAO can change the split using `plugin.setFlow()` with
resolved component addresses from the installed flow/helpers; recipe placeholders
must not be passed directly to `setFlow()`. This retains the existing budget.
For an interior ratio, change the two root weights. For an endpoint, replace the
tree with OpenFill followed by either Donate or Keep. Manager permission alone
does not grant the ability to replace a flow.

The router allocates rounding dust to the largest branch. With an interior ratio,
choose a demand large enough that both children receive at least one raw token
unit; zero-sized child inputs revert.

## Execution details

- Revenue goes to the DAO, not the plugin. Call `budget.sync()` after incoming
  USDC so the funded stream resumes; the fork test exercises this path.
- OpenFill is a Dutch auction with a fixed KAT demand and an increasing USDC
  offer. Fillers compete to execute when profitable. It does not enforce an
  oracle market price or guarantee immediate execution.
- The fork sets its demand from Sushi's exact quote and fills at the budget cap
  to demonstrate market execution. Production terms and filler operation remain
  operational choices. Prices use `KAT_raw * 1e18 / USDC_raw` (18 vs. 6 decimals).
- Only OpenFill's declared `demandPerFill` is split. Any additional KAT a solver
  returns stays in the DAO. Unspent USDC also stays in the DAO.
- The donation action checks the vault asset and nonzero share supply before
  execution, grants an exact temporary allowance, calls `donate`, clears the
  allowance, and requires assets to increase by at least the donation while
  share supply stays unchanged. The vault is a trusted configured dependency;
  its asset accounting must update synchronously.
- A paused or otherwise unavailable vault blocks a donation flow atomically.
  The 0% hold-only configuration does not call the vault.
