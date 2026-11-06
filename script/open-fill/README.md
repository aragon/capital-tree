# Open fill examples

See the [generic solver guide](../../docs/generic-solver.md) for payload encoding,
quote helpers, deployment and usage commands.

From `v2`, run the offline examples with:

```sh
forge test --match-path 'test/solvers/*' -vv
forge script script/open-fill/DeployLocal.s.sol:DeployLocal -vv
```

Fork and live quote tests are opt-in; the guide lists their environment variables.
