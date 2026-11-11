import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { test } from "node:test";
import { decodeAbiParameters, encodeAbiParameters, hexToString, zeroHash } from "viem";
import { ANY_ADDR, encodeRecipe, permissionId, templates } from "./lib.js";
import { graphToRecipe, recipeToGraph } from "./graph.js";

const read = async (path) => JSON.parse(await readFile(new URL(path, import.meta.url), "utf8"));
const deployment = {
  dao: "0x0000000000000000000000000000000000000001",
  account: "0x0000000000000000000000000000000000000002",
  tokenA: "0x0000000000000000000000000000000000000003",
  tokenB: "0x0000000000000000000000000000000000000004",
};
const names = ["StreamBudget", "BalanceBudget", "OpenFillAction", "MerkleClaimBudget", "TransferAction",
  "TransferToBeneficiaryAction", "BurnAction", "KeepAction", "WeightSplitter", "VaultDonateAction"];
const meta = Object.fromEntries(await Promise.all(names.map(async (n) => [n + "@1", await read(`../metadata/components/${n}.json`)])));
const build = await read("../metadata/build.json");
const ctx = { meta, installParams: build.pluginSetup.prepareInstallation.inputs[0] };
const recipes = templates(deployment);
const shape = (p) => [p.type, (p.components ?? []).map((c) => [c.name, shape(c)])];

// Compile first: this compares against the real compiler output, not another handwritten schema.
test("install and uninstall metadata match the compiled ABI", async () => {
  const { abi: installer } = await read("../out/Install.s.sol/Install.json");
  const { abi: setup } = await read("../out/CapitalTreePluginSetup.sol/CapitalTreePluginSetup.json");
  assert.deepEqual(shape(ctx.installParams), shape(installer.find((f) => f.name === "recipe").outputs[0]));
  assert.deepEqual(shape(build.pluginSetup.prepareUninstallation.inputs[0]),
    shape(setup.find((f) => f.name === "prepareUninstallation").outputs[0]));
});

for (const [name, recipe] of Object.entries(recipes)) {
  test(`${name}: graph conversion preserves the complete encoded recipe`, () => {
    const graph = recipeToGraph(recipe, meta);
    const restored = graphToRecipe(graph, deployment.account, meta, deployment.dao);
    assert.equal(encodeRecipe(ctx, restored), encodeRecipe(ctx, recipe));
  });
  test(`${name}: settings and actual permission recipients survive encoding`, () => {
    const [decoded] = decodeAbiParameters([ctx.installParams], encodeRecipe(ctx, recipe));
    assert.equal(decoded.budget.id, name === "Merkle claim" ? encodedId("MerkleClaimBudget@1") : encodedId("StreamBudget@1"));
    const componentEntries = [decoded.budget, ...decoded.nodes.flatMap((n) => [n.action, n.splitter])];
    for (const component of componentEntries) {
      if (component.id === zeroHash) {
        assert.equal(component.settings, "0x");
        assert.deepEqual(component.permissions, []);
        continue;
      }
      const id = hexToString(component.id, { size: 32 });
      const params = meta[id].settings;
      const values = decodeAbiParameters(params, component.settings);
      assert.equal(encodeAbiParameters(params, values), component.settings);
      for (const grant of component.permissions) {
        assert.ok([deployment.account, deployment.dao].includes(grant.who));
      }
    }
    assert.equal(decoded.pluginPermissions[0].who.toLowerCase(), ANY_ADDR.toLowerCase());
    assert.equal(decoded.pluginPermissions[0].permissionId, permissionId("TRIGGER"));
    const daoPermission = decoded.budget.permissions.find((g) => g.who === deployment.dao);
    assert.equal(daoPermission.permissionId, permissionId(name === "Merkle claim" ? "RECORD_CLAIM" : "CHECKPOINT"));
    const isSwap = name.startsWith("Buy");
    assert.deepEqual(decoded.nodes[0].action.budgetPermissions, isSwap ? [permissionId("CHECKPOINT")] : []);
    if (isSwap) {
      const [token, demand] = decodeAbiParameters(meta["OpenFillAction@1"].settings, decoded.nodes[0].action.settings);
      assert.equal(token, deployment.tokenB);
      assert.equal(demand, 1000n * 10n ** 18n);
    }
  });
}

function encodedId(id) {
  return "0x" + Buffer.from(id).toString("hex").padEnd(64, "0");
}

test("node flags and node child indexes are encoded unchanged", () => {
  const recipe = structuredClone(recipes["Buyback with a fee"]);
  recipe.nodes[0].forwardSurplus = true;
  recipe.nodes[2].skipWhenEmpty = true;
  const [decoded] = decodeAbiParameters([ctx.installParams], encodeRecipe(ctx, recipe));
  assert.equal(decoded.nodes[0].forwardSurplus, true);
  assert.equal(decoded.nodes[2].skipWhenEmpty, true);
  assert.deepEqual(decoded.nodes[0].children.map(Number), [1, 2]);
});

test("permission recipients must be actual addresses", () => {
  const recipe = structuredClone(recipes.Payroll);
  recipe.budget.permissions[0].who = "component(1)";
  assert.throws(() => encodeRecipe(ctx, recipe), /not an address/);
});

test("two identical leaf declarations remain separate graph nodes", () => {
  const recipe = structuredClone(recipes.Payroll);
  recipe.nodes[2].action = structuredClone(recipe.nodes[1].action);
  const graph = recipeToGraph(recipe, meta);
  const restored = graphToRecipe(graph, deployment.account, meta, deployment.dao);
  assert.equal(restored.nodes.length, 3);
  assert.notEqual(restored.nodes[1].action, restored.nodes[2].action);
  assert.deepEqual(restored.nodes[1].action, restored.nodes[2].action);
});
