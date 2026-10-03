"use client";

import { useCallback, useEffect, useState } from "react";
import { usePublicClient } from "wagmi";
import type { Address, Hex } from "viem";
import {
  coverAppAbi,
  erc20Abi,
  gapTriggerAbi,
  hookAbi,
  ilTriggerAbi,
  noteAbi,
  noteHolderAbi,
  oracleAbi,
  payoutAbi,
  vaultAbi,
  yieldReserveAbi,
} from "./abis";
import { DEPLOYMENT } from "./wagmi";

const ZERO = "0x0000000000000000000000000000000000000000";

export type Product = "depeg" | "il" | "gap" | "custom";

export type Market = {
  hash: Hex;
  product: Product;
  underwriter: Address;
  owner: Address; // who controls the maker (the wallet, or the YieldReserve's owner)
  inVault: boolean;
  asset: Address;
  oracle: Address;
  pegPrice: bigint;
  depegBps: number;
  maxUtilBps: number;
  oracleTimeout: number;
  startRateWad: bigint;
  endRateWad: bigint;
  convexityWad: bigint;
  trigger: Address;
  backing: bigint;
  covered: bigint;
  utilBps: bigint;
  capacity: bigint;
  premiums: bigint;
  payouts: bigint;
  premiumApyBps: number; // annualized premium income on backing, from live policies
  docked: boolean;
  // product params
  strike?: bigint; // gap: strike price (8 dp)
  deductibleBps?: number; // il
  capBps?: number; // il
};

export type Policy = {
  id: bigint;
  market: Hex;
  buyer: Address;
  notional: bigint;
  premium: bigint;
  boughtAt: bigint;
  expiry: bigint;
  settled: boolean;
  paidOut: bigint | null;
  paidTo: Address | null;
  expiredReleased: boolean;
  held: boolean;
  holder: Address;
  due: bigint | null; // what payout() would pay right now (null = not triggered)
  bound?: boolean; // il: bound to an LP position
  ilBps?: number; // il: IL since the policy baseline
};

export type Pool = {
  settledTick: number;
  myEntry: { entryTick: number; active: boolean; enteredAt: bigint } | null;
  myIlBps: number;
  t0Bal: bigint;
  t1Bal: bigint;
};

export type AirbagState = {
  markets: Market[];
  policies: Policy[];
  price: bigint;
  priceUpdatedAt: bigint;
  stockPrice: bigint;
  stockUpdatedAt: bigint;
  pool: Pool | null;
  vault: { aprBps: number; yieldEarned: bigint } | null;
  now: bigint;
  usdgBalance: bigint;
  allowanceCover: bigint;
  allowanceAqua: bigint;
};

const EMPTY: AirbagState = {
  markets: [],
  policies: [],
  price: 0n,
  priceUpdatedAt: 0n,
  stockPrice: 0n,
  stockUpdatedAt: 0n,
  pool: null,
  vault: null,
  now: 0n,
  usdgBalance: 0n,
  allowanceCover: 0n,
  allowanceAqua: 0n,
};

const YEAR = 365n * 86400n;

/** Reads the whole Airbag book (products, policies, oracles, pool, vault, balances) and polls it. */
export function useAirbag(account?: Address) {
  const client = usePublicClient();
  const [state, setState] = useState<AirbagState>(EMPTY);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    if (!client) return;
    try {
      const D = DEPLOYMENT;
      const app = D.coverApp;
      // pure state reads (no event-log scans), JSON-RPC batched by the transport
      const [block, nPolicies, nMarkets] = await Promise.all([
        client.getBlock(),
        client.readContract({ address: app, abi: coverAppAbi, functionName: "nextPolicyId" }),
        client.readContract({ address: app, abi: coverAppAbi, functionName: "marketCount" }),
      ]);
      const now = block.timestamp;
      const hashes = await Promise.all(
        Array.from({ length: Number(nMarkets) }, (_, i) =>
          client.readContract({ address: app, abi: coverAppAbi, functionName: "marketList", args: [BigInt(i)] })
        )
      );

      const policies: Policy[] = await Promise.all(
        Array.from({ length: Number(nPolicies) }, async (_, i) => {
          const id = BigInt(i);
          const [p, bal, holder] = await Promise.all([
            client.readContract({ address: app, abi: coverAppAbi, functionName: "policies", args: [id] }),
            account
              ? client.readContract({ address: D.coverNote, abi: noteAbi, functionName: "balanceOf", args: [account, id] })
              : Promise.resolve(0n),
            client.readContract({ address: D.coverNote, abi: noteHolderAbi, functionName: "holderOf", args: [id] }),
          ]);
          const [market, notional, expiry, settled, buyer, boughtAt, premium, paidOut] = p;
          // what would payout() pay right now? (simulated; reverts => not triggered)
          let due: bigint | null = null;
          if (!settled && now <= expiry) {
            try {
              const r = await client.simulateContract({ address: app, abi: payoutAbi, functionName: "payout", args: [id], account: holder });
              due = r.result;
            } catch {
              due = null;
            }
          }
          const pol: Policy = {
            id,
            market,
            buyer,
            notional,
            premium,
            boughtAt,
            expiry,
            settled,
            paidOut: settled && paidOut > 0n ? paidOut : null,
            paidTo: null,
            expiredReleased: settled && paidOut === 0n,
            held: bal > 0n,
            holder,
            due,
          };
          if (D.ilMarket && market === D.ilMarket && D.ilTrigger) {
            const [b, pv] = await Promise.all([
              client.readContract({ address: D.ilTrigger, abi: ilTriggerAbi, functionName: "bindings", args: [id] }),
              client.readContract({ address: D.ilTrigger, abi: ilTriggerAbi, functionName: "preview", args: [id] }),
            ]);
            pol.bound = b[3];
            pol.ilBps = Number(pv[0]);
          }
          return pol;
        })
      );

      const markets: Market[] = await Promise.all(
        hashes.map(async (hash) => {
          const m = await client.readContract({ address: app, abi: coverAppAbi, functionName: "markets", args: [hash] });
          let backing = 0n, covered = 0n, utilBps = 0n, capacity = 0n, docked = false;
          try {
            [backing, covered, utilBps] = await client.readContract({ address: app, abi: coverAppAbi, functionName: "solvency", args: [hash] });
            capacity = await client.readContract({ address: app, abi: coverAppAbi, functionName: "capacityOf", args: [hash] });
          } catch {
            docked = true; // Aqua reverts balance reads once the strategy is docked
          }
          const trigger = m[10];
          const product: Product =
            trigger === ZERO ? "depeg"
            : trigger.toLowerCase() === D.ilTrigger?.toLowerCase() ? "il"
            : trigger.toLowerCase() === D.gapTrigger?.toLowerCase() ? "gap"
            : "custom";
          const inVault = !!D.yieldReserve && m[0].toLowerCase() === D.yieldReserve.toLowerCase();
          const owner = inVault
            ? await client.readContract({ address: D.yieldReserve!, abi: yieldReserveAbi, functionName: "owner" })
            : m[0];
          const mine = policies.filter((p) => p.market === hash);
          // annualized premium income from live policies: Σ premium × (year / term) / backing
          const live = mine.filter((p) => !p.settled && p.expiry > now);
          const annual = live.reduce((s, p) => {
            const term = p.expiry > p.boughtAt ? p.expiry - p.boughtAt : 1n;
            return s + (p.premium * YEAR) / term;
          }, 0n);
          const mk: Market = {
            hash,
            product,
            underwriter: m[0],
            owner,
            inVault,
            asset: m[1],
            oracle: m[2],
            pegPrice: m[3],
            depegBps: Number(m[4]),
            maxUtilBps: Number(m[5]),
            oracleTimeout: Number(m[6]),
            startRateWad: m[7],
            endRateWad: m[8],
            convexityWad: m[9],
            trigger,
            backing,
            covered,
            utilBps,
            capacity,
            premiums: mine.reduce((s, p) => s + p.premium, 0n),
            payouts: mine.reduce((s, p) => s + (p.paidOut ?? 0n), 0n),
            premiumApyBps: backing > 0n ? Number((annual * 10_000n) / backing) : 0,
            docked,
          };
          if (product === "gap" && D.gapTrigger) {
            const c = await client.readContract({ address: D.gapTrigger, abi: gapTriggerAbi, functionName: "configs", args: [hash] });
            mk.strike = c[1];
          }
          if (product === "il" && D.ilTrigger) {
            const c = await client.readContract({ address: D.ilTrigger, abi: ilTriggerAbi, functionName: "configs", args: [hash] });
            mk.deductibleBps = Number(c[2]);
            mk.capBps = Number(c[3]);
          }
          return mk;
        })
      );

      const readPrice = (o?: Address) =>
        o ? client.readContract({ address: o, abi: oracleAbi, functionName: "latestPrice" }) : Promise.resolve([0n, 0n] as const);
      const [[price, priceUpdatedAt], [stockPrice, stockUpdatedAt], usdgBalance, allowanceCover, allowanceAqua] = await Promise.all([
        readPrice(D.oracle),
        readPrice(D.stockOracle),
        account ? client.readContract({ address: D.usdg, abi: erc20Abi, functionName: "balanceOf", args: [account] }) : 0n,
        account ? client.readContract({ address: D.usdg, abi: erc20Abi, functionName: "allowance", args: [account, D.coverApp] }) : 0n,
        account ? client.readContract({ address: D.usdg, abi: erc20Abi, functionName: "allowance", args: [account, D.aqua] }) : 0n,
      ]);

      let pool: Pool | null = null;
      if (D.hook && D.poolId && D.token0 && D.token1) {
        const settledTick = Number(await client.readContract({ address: D.hook, abi: hookAbi, functionName: "settledTick", args: [D.poolId] }));
        let myEntry: Pool["myEntry"] = null;
        let myIlBps = 0;
        let t0Bal = 0n, t1Bal = 0n;
        if (account) {
          const e = await client.readContract({ address: D.hook, abi: hookAbi, functionName: "entryOf", args: [D.poolId, account] });
          if (e[2] > 0n) {
            myEntry = { entryTick: Number(e[0]), active: e[4], enteredAt: e[2] };
            const end = e[4] ? settledTick : Number(e[1]);
            myIlBps = Number(await client.readContract({ address: D.hook, abi: hookAbi, functionName: "ilBps", args: [Number(e[0]), end] }));
          }
          [t0Bal, t1Bal] = await Promise.all([
            client.readContract({ address: D.token0, abi: erc20Abi, functionName: "balanceOf", args: [account] }),
            client.readContract({ address: D.token1, abi: erc20Abi, functionName: "balanceOf", args: [account] }),
          ]);
        }
        pool = { settledTick, myEntry, myIlBps, t0Bal, t1Bal };
      }

      let vault: AirbagState["vault"] = null;
      if (D.vault) {
        const [apr, y, pend] = await Promise.all([
          client.readContract({ address: D.vault, abi: vaultAbi, functionName: "aprBps" }),
          client.readContract({ address: D.vault, abi: vaultAbi, functionName: "totalYield" }),
          client.readContract({ address: D.vault, abi: vaultAbi, functionName: "pending" }),
        ]);
        vault = { aprBps: Number(apr), yieldEarned: y + pend };
      }

      setState({ markets, policies, price, priceUpdatedAt, stockPrice, stockUpdatedAt, pool, vault, now, usdgBalance, allowanceCover, allowanceAqua });
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message.split("\n")[0] : String(e));
    } finally {
      setLoading(false);
    }
  }, [client, account]);

  useEffect(() => {
    load();
    const t = setInterval(load, 3000);
    return () => clearInterval(t);
  }, [load]);

  return { ...state, loading, error, refresh: load };
}
