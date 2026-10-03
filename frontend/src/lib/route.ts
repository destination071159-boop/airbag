import type { Hex } from "viem";
import type { Market } from "./useAirbag";

/** Mirror of RiskCurve.sol: rate(u) = start + (end − start) · u^k, u = sold / capacity. */
function rate(m: Market, sold: number) {
  const cap = Number(m.capacity) / 1e18;
  const u = cap > 0 ? Math.min(1, sold / cap) : 1;
  const s = Number(m.startRateWad) / 1e18;
  const e = Number(m.endRateWad) / 1e18;
  const k = Number(m.convexityWad) / 1e18;
  return u <= 0 ? s : u >= 1 ? e : s + (e - s) * Math.pow(u, k);
}

/** premium of a single leg of `x` cover on `m` (priced at post-trade utilization, like the contract) */
export function legCost(m: Market, x: number) {
  if (x <= 0) return 0;
  const covered = Number(m.covered) / 1e18;
  return x * rate(m, covered + x);
}

export type Leg = { market: Market; notional: number };

/**
 * Deterministic route solver: slice the order and give each slice to the underwriter whose
 * leg gets the least more expensive by taking it — the ArcBook-style "walk the curves" solver.
 * The on-chain CoverRouter then fills all legs atomically with a premium cap.
 */
export function solveRoute(book: Market[], notional: number, slices = 40): Leg[] | null {
  const room = (m: Market) => Math.max(0, (Number(m.capacity) - Number(m.covered)) / 1e18);
  const alloc = new Map<Hex, number>(book.map((m) => [m.hash, 0]));
  const step = notional / slices;
  for (let i = 0; i < slices; i++) {
    let best: Market | null = null;
    let bestDelta = Infinity;
    for (const m of book) {
      const a = alloc.get(m.hash)!;
      if (a + step > room(m) + 1e-9) continue;
      const delta = legCost(m, a + step) - legCost(m, a);
      if (delta < bestDelta) {
        bestDelta = delta;
        best = m;
      }
    }
    if (!best) return null; // not enough capacity across the whole book
    alloc.set(best.hash, alloc.get(best.hash)! + step);
  }
  return book.map((m) => ({ market: m, notional: alloc.get(m.hash)! })).filter((l) => l.notional > 0);
}
