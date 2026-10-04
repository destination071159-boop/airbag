#!/usr/bin/env node
// Airbag keeper — makes the airbag deploy itself.
//
// Every few seconds it walks every open policy on the CoverApp and:
//   • fires CoverApp.payout(id) when the policy's trigger has hit (depeg, LP loss, stock gap) —
//     the USDG lands in the note holder's wallet without them doing anything;
//   • settles lapsed policies with CoverApp.expire(id) so underwriter capacity is recycled.
// Both calls are permissionless: anyone can run this bot.
//
//   node scripts/keeper.mjs                      # local anvil (uses anvil dev account #2)
//   NETWORK=sepolia RPC_URL=… KEEPER_KEY=0x… DEMO_FEED=1 node scripts/keeper.mjs
//   DEMO_FEED=1 …                                # also re-post the demo oracles' last price when stale
import { readFileSync } from "node:fs";
import { createPublicClient, createWalletClient, http, parseAbi, formatUnits } from "viem";
import { privateKeyToAccount } from "viem/accounts";

// NETWORK=local (default) | sepolia
const NETWORK = process.env.NETWORK ?? process.argv[2] ?? "local"; // or: node scripts/keeper.mjs sepolia
const dep = JSON.parse(readFileSync(new URL(`../src/lib/deployment.${NETWORK === "sepolia" ? 421614 : 31337}.json`, import.meta.url)));
const local = dep.chainId === 31337;
const rpc = process.env.RPC_URL ?? (local ? "http://127.0.0.1:8545" : "https://sepolia-rollup.arbitrum.io/rpc");
// anvil dev account #2 — a public test key, only ever used against the local chain
const key = process.env.KEEPER_KEY ?? (local ? "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a" : null);
if (!key) throw new Error("set KEEPER_KEY for non-local chains");
const demoFeed = local || process.env.DEMO_FEED === "1";
const INTERVAL = Number(process.env.INTERVAL_MS ?? 3000);

const chain = { id: dep.chainId, name: local ? "anvil" : "arbitrum-sepolia", nativeCurrency: { name: "ETH", symbol: "ETH", decimals: 18 }, rpcUrls: { default: { http: [rpc] } } };
const account = privateKeyToAccount(key);
const pub = createPublicClient({ chain, transport: http(rpc, { batch: true }) });
const wallet = createWalletClient({ chain, transport: http(rpc), account });

const app = parseAbi([
  "function nextPolicyId() view returns (uint256)",
  "function policies(uint256) view returns (bytes32 marketHash, uint256 coverNotional, uint64 expiry, bool claimed, address buyer, uint64 boughtAt, uint256 premium, uint256 paidOut)",
  "function payout(uint256 policyId) returns (uint256)",
  "function expire(uint256 policyId)",
]);
const noteAbi = parseAbi(["function holderOf(uint256) view returns (address)"]);
const oracleAbi = parseAbi(["function latestPrice() view returns (uint256, uint256)", "function set(uint256)"]);

const t = () => new Date().toLocaleTimeString("en-GB");
const log = (...a) => console.log(`[${t()}]`, ...a);
const usd = (x) => Number(formatUnits(x, 18)).toLocaleString("en-US", { maximumFractionDigits: 2 });

const open = new Set(); // policy ids not yet settled
let seen = 0n; // policies discovered so far (ids are sequential — no log scans needed)

async function send(fn, args) {
  const { request, result } = await pub.simulateContract({ address: dep.coverApp, abi: app, functionName: fn, args, account });
  const hash = await wallet.writeContract(request);
  await pub.waitForTransactionReceipt({ hash });
  return { hash, result };
}

async function tick() {
  const next = await pub.readContract({ address: dep.coverApp, abi: app, functionName: "nextPolicyId" });
  for (; seen < next; seen++) open.add(seen);
  const now = (await pub.getBlock()).timestamp;

  if (demoFeed) {
    // demo oracles only move when someone posts; keep the last price fresh like a live feed would
    for (const o of [dep.oracle, dep.stockOracle].filter(Boolean)) {
      const [price, updatedAt] = await pub.readContract({ address: o, abi: oracleAbi, functionName: "latestPrice" });
      if (now - updatedAt > 3600n) {
        const hash = await wallet.writeContract({ address: o, abi: oracleAbi, functionName: "set", args: [price], chain });
        await pub.waitForTransactionReceipt({ hash });
        log(`feed heartbeat ${o.slice(0, 8)}… @ ${Number(price) / 1e8}`);
      }
    }
  }

  for (const id of [...open]) {
    const [, notional, expiry, claimed] = await pub.readContract({ address: dep.coverApp, abi: app, functionName: "policies", args: [id] });
    if (claimed) { open.delete(id); continue; }
    try {
      if (now > expiry) {
        const { hash } = await send("expire", [id]);
        log(`⌛ policy #${id} lapsed → capacity released (${usd(notional)} USDG)  ${hash.slice(0, 10)}`);
        open.delete(id);
        continue;
      }
      const holder = await pub.readContract({ address: dep.coverNote, abi: noteAbi, functionName: "holderOf", args: [id] });
      const { hash, result } = await send("payout", [id]);
      log(`🎈 AIRBAG DEPLOYED — policy #${id} paid ${usd(result)} USDG → ${holder}  ${hash.slice(0, 10)}`);
      open.delete(id);
    } catch {
      // not triggered yet (or oracle stale) — check again next round
    }
  }
}

log(`keeper ${account.address} watching CoverApp ${dep.coverApp} on ${chain.name} (every ${INTERVAL / 1000}s)`);
for (;;) {
  try { await tick(); } catch (e) { log("round failed:", e.shortMessage ?? e.message); }
  await new Promise((r) => setTimeout(r, INTERVAL));
}
