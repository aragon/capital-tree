// Playground logic, without any DOM: reads the fork, builds and installs recipes, runs flows.
// The page imports "viem" through an import map; Node tests resolve it from node_modules.
import {
  createPublicClient,
  createTestClient,
  createWalletClient,
  defineChain,
  encodeAbiParameters,
  encodeFunctionData,
  formatUnits,
  getAddress,
  http,
  isAddress,
  keccak256,
  stringToHex,
  toHex,
  zeroAddress,
  zeroHash,
  BaseError,
  ContractFunctionRevertedError,
} from "viem";

export const RPC = "http://127.0.0.1:8545";
export const ANY_ADDR = "0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF";
export const PERMISSIONS = ["TRIGGER", "PAUSE", "SET_SETTINGS", "CHECKPOINT", "RECORD_CLAIM"];
export const permissionId = (name) => keccak256(toHex(`${name}_PERMISSION`));

// Anvil's second and third accounts, used as default payroll recipients
const ALICE = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8";
const BOB = "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC";

// Recipe references, as in CapitalTreePluginSetup: RefKind, and NONE for a node without an action or splitter
const REF = { account: 0, dao: 1, plugin: 2, component: 3 };
const NONE = (1n << 256n) - 1n;

// Parsing what people type

/** "DAO", "PLUGIN", "ANY", "component(2)" or an address → the reference the recipe carries */
export function target(text) {
  const t = String(text ?? "").trim();
  const ref = (kind, account = zeroAddress, index = 0n) => ({ kind, account, index });
  if (t === "DAO") return ref(REF.dao);
  if (t === "PLUGIN") return ref(REF.plugin);
  if (t === "ANY") return ref(REF.account, ANY_ADDR);
  const m = t.match(/^component\((\d+)\)$/);
  if (m) return ref(REF.component, zeroAddress, BigInt(m[1]));
  if (isAddress(t)) return ref(REF.account, getAddress(t));
  throw new Error(`"${t}" is not an address, DAO, PLUGIN, ANY or component(i)`);
}

/** An address someone typed */
export function parseAddress(text) {
  const t = String(text ?? "").trim();
  if (!isAddress(t)) throw new Error(`"${t}" is not an address`);
  return getAddress(t);
}

/** "1000", "10e18" or "1.5e18" → bigint */
export function amount(text) {
  const t = String(text ?? "").trim();
  const m = t.match(/^(\d+)(?:\.(\d+))?e(\d+)$/);
  if (m) {
    const [, whole, decimals = "", exponent] = m;
    if (decimals.length > Number(exponent)) throw new Error(`"${t}" has more decimals than its exponent`);
    return BigInt(whole + decimals.padEnd(Number(exponent), "0"));
  }
  if (!/^\d+$/.test(t)) throw new Error(`"${t}" is not a whole number (e.g. 1000 or 10e18)`);
  return BigInt(t);
}

/** "1, 2" → [1, 2] */
export const numbers = (text) =>
  String(text ?? "")
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean)
    .map((s) => {
      if (!/^\d+$/.test(s)) throw new Error(`"${s}" is not a whole number`);
      return Number(s);
    });

function arg(type, value, where) {
  try {
    if (type === "address") return parseAddress(value);
    if (type === "uint32[]") return numbers(value);
    if (type.startsWith("uint")) return amount(value);
    if (type === "bytes32") {
      if (!/^0x[0-9a-fA-F]{64}$/.test(String(value).trim())) throw new Error(`"${value}" is not 32 bytes of hex`);
      return String(value).trim();
    }
  } catch (e) {
    throw new Error(`${where}: ${e.message}`);
  }
  throw new Error(`${where}: unsupported type ${type}`);
}

// Connecting

/** @param load (path) => Promise<json>, relative to the repo root */
export async function connect(load, rpc = RPC) {
  const [deployment, abis, build] = await Promise.all([
    load("playground/deployment.json"),
    load("playground/abis.json"),
    load("metadata/build.json"),
  ]);
  const meta = {};
  await Promise.all(
    Object.keys(deployment.components).map(async (id) => {
      meta[id] = await load(`metadata/components/${id.split("@")[0]}.json`);
    }),
  );

  const chain = defineChain({
    id: deployment.chainId,
    name: "Sepolia fork",
    nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
    rpcUrls: { default: { http: [rpc] } },
  });
  const transport = http(rpc);
  const errors = uniqueErrors(Object.values(abis).flat());
  const implToId = Object.fromEntries(Object.entries(deployment.components).map(([id, a]) => [a.toLowerCase(), id]));

  return {
    deployment,
    abis,
    meta,
    errors,
    implToId,
    installParams: abiParam(build.pluginSetup.prepareInstallation.inputs[0]),
    pub: createPublicClient({ chain, transport }),
    wallet: createWalletClient({ chain, transport, account: deployment.account }),
    test: createTestClient({ chain, transport, mode: "anvil" }),
  };
}

const abiParam = ({ name, type, components }) =>
  components ? { name, type, components: components.map(abiParam) } : { name, type };

function uniqueErrors(abi) {
  const seen = new Map();
  for (const item of abi.filter((x) => x.type === "error")) {
    seen.set(`${item.name}(${item.inputs.map((i) => i.type).join(",")})`, item);
  }
  return [...seen.values()];
}

// Recipes

const component = (id, args, deps = []) => ({ id, deps, args });
const stream = (token, maxBudget = "0") =>
  component("StreamBudget@1", { token, amountPerEpoch: "10e18", maxBudget, epochInterval: "86400" });
// 1,000 B for at most 20 A (the stream's cap): 50 B per A or better
const openFill = (tokenB) => component("OpenFillAction@1", { demandedToken: tokenB, demandPerFill: "1000e18" }, [0]);
const weightSplitter = (weights) => component("WeightSplitter@1", { weights });
const leaf = (action) => ({ action, children: "", splitter: null });
const swapGrants = (manager) => [
  { where: "PLUGIN", who: "ANY", permission: "TRIGGER" },
  { where: "PLUGIN", who: manager, permission: "PAUSE" },
  { where: "component(0)", who: manager, permission: "SET_SETTINGS" },
  { where: "component(1)", who: manager, permission: "SET_SETTINGS" },
  { where: "component(0)", who: "DAO", permission: "CHECKPOINT" },
  { where: "component(0)", who: "component(1)", permission: "CHECKPOINT" },
];

/** The recipes in script/Recipes.sol, as editable state */
export function templates({ tokenA, tokenB, account }) {
  return {
    "Buy and burn": {
      components: [stream(tokenA, "20e18"), openFill(tokenB), component("BurnAction@1", {})],
      nodes: [{ action: 1, children: "1", splitter: null }, leaf(2)],
      grants: swapGrants(account),
    },
    "Buyback with a fee": {
      components: [
        stream(tokenA, "20e18"),
        openFill(tokenB),
        component("BurnAction@1", {}),
        component("TransferAction@1", { to: BOB }),
        weightSplitter("950000, 50000"),
      ],
      nodes: [{ action: 1, children: "1, 2", splitter: 4 }, leaf(2), leaf(3)],
      grants: [...swapGrants(account), { where: "component(4)", who: account, permission: "SET_SETTINGS" }],
    },
    Payroll: {
      components: [
        stream(tokenA),
        component("TransferAction@1", { to: ALICE }),
        component("TransferAction@1", { to: BOB }),
        weightSplitter("700000, 300000"),
      ],
      nodes: [{ action: null, children: "1, 2", splitter: 3 }, leaf(1), leaf(2)],
      grants: [
        { where: "PLUGIN", who: "ANY", permission: "TRIGGER" },
        { where: "PLUGIN", who: account, permission: "PAUSE" },
        { where: "component(0)", who: account, permission: "SET_SETTINGS" },
        { where: "component(0)", who: "DAO", permission: "CHECKPOINT" },
        { where: "component(3)", who: account, permission: "SET_SETTINGS" },
      ],
    },
    "Merkle claim": {
      components: [
        component("MerkleClaimBudget@1", { token: tokenA, root: merkleLeaf(account, 100n * 10n ** 18n) }),
        component("TransferToBeneficiaryAction@1", {}),
      ],
      nodes: [leaf(1)],
      grants: [
        { where: "PLUGIN", who: "ANY", permission: "TRIGGER" },
        { where: "PLUGIN", who: account, permission: "PAUSE" },
        { where: "component(0)", who: account, permission: "SET_SETTINGS" },
        { where: "component(0)", who: "DAO", permission: "RECORD_CLAIM" },
      ],
    },
  };
}

/** A one-leaf Merkle tree: its root is the leaf, and the proof is empty */
export const merkleLeaf = (account, cumulative) =>
  keccak256(keccak256(encodeAbiParameters([{ type: "address" }, { type: "uint256" }], [account, cumulative])));

/** The recipe as `abi.encode(InstallParams)`; throws a readable error for anything mistyped */
export function encodeRecipe(ctx, recipe) {
  const components = recipe.components.map((c, i) => {
    const { dependencies, settings } = ctx.meta[c.id];
    const deps = c.deps ?? [];
    if (deps.length !== dependencies.length) {
      throw new Error(`component ${i} ${c.id}: expects ${dependencies.length} dependencies, got ${deps.length}`);
    }
    const values = settings.map((s) => arg(s.type, c.args[s.name], `component ${i} ${s.name}`));
    return {
      id: stringToHex(c.id, { size: 32 }),
      deps: deps.map(BigInt),
      settings: encodeAbiParameters(settings.map(({ type }) => ({ type })), values),
    };
  });
  const params = {
    components,
    nodes: recipe.nodes.map((n, i) => ({
      action: n.action === null ? NONE : BigInt(n.action),
      children: wrap(`node ${i} children`, () => numbers(n.children)),
      splitter: n.splitter === null ? NONE : BigInt(n.splitter),
      skipWhenEmpty: false,
      forwardSurplus: false,
    })),
    grants: recipe.grants.map((g, i) => ({
      where: wrap(`grant ${i} where`, () => target(g.where)),
      who: wrap(`grant ${i} who`, () => target(g.who)),
      permissionId: permissionId(g.permission),
    })),
  };
  return encodeAbiParameters([ctx.installParams], [params]);
}

function wrap(where, fn) {
  try {
    return fn();
  } catch (e) {
    throw new Error(`${where}: ${e.message}`);
  }
}

/** The tree as text, e.g. for a preview */
export function describeTree(nodes, label) {
  if (nodes.length === 0) return "(no nodes)";
  const lines = [];
  const seen = new Set();
  const walk = (index, prefix, last, share) => {
    const node = nodes[index];
    const connector = index === 0 ? "" : last ? "└─ " : "├─ ";
    if (!node || seen.has(index)) return lines.push(`${prefix}${connector}${share}invalid child ${index}`);
    seen.add(index);
    lines.push(`${prefix}${connector}${share}${label(node, index)}`);
    const children = node.children;
    const weights = node.weights;
    children.forEach((child, k) => {
      const pct = weights.length ? `${Number(weights[k]) / 10000}% → ` : "";
      walk(child, index === 0 ? "" : prefix + (last ? "   " : "│  "), k === children.length - 1, pct);
    });
  };
  walk(0, "", true, "");
  return lines.join("\n");
}

// Transactions

/** Simulates, sends and waits; throws with the decoded revert */
export async function write(ctx, call) {
  try {
    const { request, result } = await ctx.pub.simulateContract({
      ...call,
      abi: [...call.abi, ...ctx.errors],
      account: ctx.deployment.account,
    });
    const hash = await ctx.wallet.writeContract(request);
    const receipt = await ctx.pub.waitForTransactionReceipt({ hash });
    if (receipt.status !== "success") throw new Error(`transaction ${hash} reverted`);
    return { receipt, result };
  } catch (e) {
    throw new Error(describeError(e));
  }
}

export function describeError(e) {
  if (e instanceof BaseError) {
    const revert = e.walk((err) => err instanceof ContractFunctionRevertedError);
    if (revert?.data?.errorName) {
      const args = (revert.data.args ?? []).map((a) => (typeof a === "bigint" ? a.toString() : String(a)));
      return `${revert.data.errorName}(${args.join(", ")})`;
    }
    return e.shortMessage ?? e.message;
  }
  return e.message ?? String(e);
}

/** Prepares the installation through Aragon's PluginSetupProcessor, then executes the proposal's
 *  actions as the DAO (the playground account holds EXECUTE on it). */
export async function install(ctx, recipe) {
  const { dao, pluginRepo, pluginSetupProcessor: psp } = ctx.deployment;
  const data = encodeRecipe(ctx, recipe);
  const setupRef = { versionTag: { release: 1, build: 1 }, pluginSetupRepo: pluginRepo };

  const { result } = await write(ctx, {
    address: psp,
    abi: ctx.abis.psp,
    functionName: "prepareInstallation",
    args: [dao, { pluginSetupRef: setupRef, data }],
  });
  const [plugin, prepared] = result;

  const helpersHash = keccak256(encodeAbiParameters([{ type: "address[]" }], [prepared.helpers]));
  const apply = { pluginSetupRef: setupRef, plugin, permissions: prepared.permissions, helpersHash };
  const root = keccak256(toHex("ROOT_PERMISSION"));
  const actions = [
    { to: dao, value: 0n, data: encodeFunctionData({ abi: ctx.abis.dao, functionName: "grant", args: [dao, psp, root] }) },
    { to: psp, value: 0n, data: encodeFunctionData({ abi: ctx.abis.psp, functionName: "applyInstallation", args: [dao, apply] }) },
    { to: dao, value: 0n, data: encodeFunctionData({ abi: ctx.abis.dao, functionName: "revoke", args: [dao, psp, root] }) },
  ];
  // A stream starts at its first checkpoint, so it didn't grow between preparing and applying
  if (recipe.components[0].id.startsWith("StreamBudget@")) {
    const start = encodeFunctionData({ abi: ctx.abis.StreamBudget, functionName: "writeCheckpoint" });
    actions.push({ to: prepared.helpers[0], value: 0n, data: start });
  }
  await write(ctx, { address: dao, abi: ctx.abis.dao, functionName: "execute", args: [zeroHash, actions, 0n] });
  return plugin;
}

// Reading

const read = (ctx, address, abi, functionName, args = []) => ctx.pub.readContract({ address, abi, functionName, args });

const SYMBOLS = new Map();
async function symbol(ctx, token) {
  if (!SYMBOLS.has(token)) SYMBOLS.set(token, await read(ctx, token, ctx.abis.token, "symbol").catch(() => token.slice(0, 8)));
  return SYMBOLS.get(token);
}

export const units = (value) => {
  const [whole, decimals = ""] = formatUnits(value, 18).split(".");
  return decimals ? `${whole}.${decimals.slice(0, 4)}` : whole;
};

async function balance(ctx, token, account) {
  return read(ctx, token, ctx.abis.token, "balanceOf", [account]);
}

export async function status(ctx) {
  const { dao, filler, tokenA, tokenB } = ctx.deployment;
  const [block, daoA, daoB, fillerB, daoEth] = await Promise.all([
    ctx.pub.getBlock(),
    balance(ctx, tokenA, dao),
    balance(ctx, tokenB, dao),
    balance(ctx, tokenB, filler),
    ctx.pub.getBalance({ address: dao }),
  ]);
  return { block: block.number, time: new Date(Number(block.timestamp) * 1000), daoA, daoB, fillerB, daoEth };
}

/** Which registered implementation a clone runs, from its EIP-1167 code */
async function identify(ctx, address) {
  const code = (await ctx.pub.getCode({ address })) ?? "0x";
  const m = code.match(/^0x363d3d373d3d3d363d73([0-9a-f]{40})5af43d82803e903d91602b57fd5bf3$/i);
  return m ? (ctx.implToId[`0x${m[1]}`.toLowerCase()] ?? "unknown") : "not a clone";
}

/** A component's kind and the settings worth showing */
export async function describeComponent(ctx, address) {
  if (address === zeroAddress) return { address, id: "branch", name: "branch (no action)", details: [] };
  const id = await identify(ctx, address);
  const name = id.split("@")[0];
  const abi = ctx.abis[name];
  const get = (fn) => read(ctx, address, abi, fn);
  const details = [];
  if (name === "StreamBudget" || name === "BalanceBudget") {
    const token = await get("token");
    const sym = await symbol(ctx, token);
    const [amount] = await read(ctx, address, abi, "available", [zeroAddress, "0x"]);
    details.push(`available ${units(amount)} ${sym}`);
    if (name === "StreamBudget") {
      details.push(`${units(await get("amountPerEpoch"))} ${sym} per ${await get("epochInterval")}s`);
      const cap = await get("maxBudget");
      if (cap > 0n) details.push(`capped at ${units(cap)} ${sym}`);
    }
  } else if (name === "OpenFillAction") {
    const demanded = await symbol(ctx, await get("demandedToken"));
    details.push(`demands ${units(await get("demandPerFill"))} ${demanded} per fill`);
    details.push("offers its whole input");
  } else if (name === "MerkleClaimBudget") {
    details.push(`root ${(await get("root")).slice(0, 10)}…`);
  } else if (name === "TransferAction") {
    details.push(`to ${await get("recipient")}`);
  }
  return { address, id, name, details };
}

/** Every flow installed in the playground DAO, newest first */
export async function flows(ctx) {
  const { dao, pluginSetupProcessor: psp, startBlock } = ctx.deployment;
  const logs = await ctx.pub.getContractEvents({
    address: psp,
    abi: ctx.abis.psp,
    eventName: "InstallationApplied",
    args: { dao },
    fromBlock: BigInt(startBlock) + 1n,
  });
  return Promise.all(logs.reverse().map((log) => readFlow(ctx, log.args.plugin)));
}

export async function readFlow(ctx, plugin) {
  const [budget, nodes, paused] = await Promise.all([
    read(ctx, plugin, ctx.abis.plugin, "budget"),
    read(ctx, plugin, ctx.abis.plugin, "nodes"),
    read(ctx, plugin, ctx.abis.plugin, "paused"),
  ]);
  const [budgetInfo, ...actions] = await Promise.all([
    describeComponent(ctx, budget),
    ...nodes.map((n) => describeComponent(ctx, n.action)),
  ]);
  const weights = await Promise.all(nodes.map((n) => splitterWeights(ctx, n.splitter)));
  return {
    plugin,
    paused,
    budget: budgetInfo,
    nodes: nodes.map((n, i) => ({ ...actions[i], children: n.children.map(Number), weights: weights[i] })),
  };
}

/** A branch's weights, read from its WeightSplitter (the only splitter registered here) */
async function splitterWeights(ctx, splitter) {
  if (splitter === zeroAddress) return [];
  return (await read(ctx, splitter, ctx.abis.WeightSplitter, "weights")).map(Number);
}

// Running flows

/** The playground filler takes the flow's OpenFill offer, paying from its own balance */
export const fill = (ctx, plugin) =>
  write(ctx, { address: ctx.deployment.filler, abi: ctx.abis.filler, functionName: "fill", args: [plugin] });

export const trigger = (ctx, plugin) =>
  write(ctx, { address: plugin, abi: ctx.abis.plugin, functionName: "trigger", args: ["0x", []] });

/** Claims `cumulative` for the playground account from a one-leaf Merkle tree (empty proof) */
export async function claim(ctx, plugin, cumulative) {
  const data = encodeAbiParameters(
    [{ type: "address" }, { type: "uint256" }, { type: "bytes32[]" }, { type: "address" }],
    [ctx.deployment.account, cumulative, [], zeroAddress],
  );
  return write(ctx, { address: plugin, abi: ctx.abis.plugin, functionName: "trigger", args: [data, []] });
}

export async function advance(ctx, seconds) {
  await ctx.test.increaseTime({ seconds });
  await ctx.test.mine({ blocks: 1 });
}
