"use client";

import { useEffect, useMemo, useRef, useState } from "react";
import { useAccount, useConnect, useDisconnect, usePublicClient, useWriteContract } from "wagmi";
import {
  encodeAbiParameters,
  formatUnits,
  keccak256,
  parseEventLogs,
  parseUnits,
  toHex,
  type Hex,
  type TransactionReceipt,
} from "viem";
import Navbar from "@/components/Navbar";
import Logo from "@/components/Logo";
import WalletButton from "@/components/WalletButton";
import TileBackground from "@/components/TileBackground";
import RiskCurveChart, { type Curve } from "@/components/RiskCurveChart";
import {
  aquaAbi,
  coverAppAbi,
  erc20Abi,
  ilTriggerAbi,
  lpRouterAbi,
  marketComponents,
  oracleAbi,
  payoutAbi,
  routerAbi,
  swapperAbi,
} from "@/lib/abis";
import { solveRoute } from "@/lib/route";
import { DEPLOYMENT as D, DEV_ACCOUNTS, IS_LOCAL, CHAIN, POOL_KEY, explorerTx } from "@/lib/wagmi";
import { useAirbag, type Market, type Policy, type Product } from "@/lib/useAirbag";

/* ---------- formatting ---------- */
const wad = (x: bigint) => Number(formatUnits(x, 18));
const usd = (x: bigint, dp = 2) =>
  Number(formatUnits(x, 18)).toLocaleString("en-US", { minimumFractionDigits: dp, maximumFractionDigits: dp });
const compact = (x: bigint) =>
  Number(formatUnits(x, 18)).toLocaleString("en-US", { notation: "compact", maximumFractionDigits: 1 });
const px = (p: bigint, dp = 3) => (Number(p) / 1e8).toFixed(dp);
const pct = (bps: bigint | number, dp = 1) => `${(Number(bps) / 100).toFixed(dp)}%`;
const short = (a: string) => `${a.slice(0, 6)}…${a.slice(-4)}`;
function left(sec: bigint) {
  const s = Number(sec);
  if (s <= 0) return "expired";
  if (s < 3600) return `${Math.ceil(s / 60)}m left`;
  if (s < 86400) return `${(s / 3600).toFixed(1)}h left`;
  return `${(s / 86400).toFixed(1)}d left`;
}
const sqrtAtTick = (tick: number) => BigInt(Math.floor(Math.sqrt(1.0001 ** tick) * 2 ** 96));
const eq = (a?: string | null, b?: string | null) => !!a && !!b && a.toLowerCase() === b.toLowerCase();

/* ---------- products ---------- */
const LST_IS_1 = D.token1Symbol === "wstETH";
const SHOCK_TICK = LST_IS_1 ? 4020 : -4020; // ≈ wstETH −33% vs WETH
/** wstETH priced in WETH, from the pool tick */
const lstPrice = (tick: number) => (LST_IS_1 ? 1 / 1.0001 ** tick : 1.0001 ** tick);

const META: Record<Product, { n: string; name: string; tag: string }> = {
  depeg: { n: "01", name: "Stablecoin depeg", tag: "USDG" },
  il: { n: "02", name: "LP loss · Uniswap v4", tag: "wstETH/WETH" },
  gap: { n: "03", name: "Stock gap-down", tag: "TSLAx" },
  custom: { n: "··", name: "Custom trigger", tag: "ITrigger" },
};
const ORDER: Product[] = ["depeg", "il", "gap", "custom"];

function payoutRule(m: Market) {
  if (m.product === "depeg") {
    const tp = (m.pegPrice * BigInt(10_000 - m.depegBps)) / 10_000n;
    return `Pays 100% if USDG ≤ $${px(tp, 2)}`;
  }
  if (m.product === "gap") return `Pays the % TSLAx falls below $${px(m.strike ?? 0n, 0)}`;
  if (m.product === "il") return `Pays LP loss past ${pct(m.deductibleBps ?? 0)}, 100% at ${pct(m.capBps ?? 0, 0)}`;
  return "Pays when its trigger fires";
}

/** what a policy of `notional` would pay in a representative event */
function exampleFor(m: Market, notional: bigint) {
  if (m.product === "gap") return `a −20% gap → ${usd((notional * 2000n) / 10_000n, 0)} USDG`;
  if (m.product === "il") {
    const d = m.deductibleBps ?? 50;
    const c = m.capBps ?? 500;
    const bps = Math.min(10_000, Math.max(0, ((200 - d) * 10_000) / (c - d)));
    return `2% LP loss → ${usd((notional * BigInt(Math.round(bps))) / 10_000n, 0)} USDG`;
  }
  return `a depeg → ${usd(notional, 0)} USDG`;
}

const DURATIONS = [
  { label: "5 min", s: 300 },
  { label: "1 day", s: 86400 },
  { label: "7 days", s: 7 * 86400 },
  { label: "30 days", s: 30 * 86400 },
];

const PRESETS: { label: string; hint: string; c: Curve }[] = [
  { label: "Linear", hint: "rate rises evenly", c: { start: 0.01, end: 0.1, k: 1 } },
  { label: "Spike near full", hint: "cheap until the book fills", c: { start: 0.01, end: 0.15, k: 3 } },
  { label: "Front-loaded", hint: "pricey early, flattens out", c: { start: 0.02, end: 0.08, k: 0.5 } },
  { label: "Flat", hint: "one fixed rate", c: { start: 0.03, end: 0.03, k: 1 } },
];

type Log = { t: string; msg: string; kind: "ok" | "err" | "info" | "bag"; hash?: string };
type Toast = { id: number; kind: "pending" | "ok" | "err"; title: string; sub?: string; hash?: string };

/** turn wallet / contract errors into sentences people understand */
function humanError(raw: string) {
  const r = raw.toLowerCase();
  if (r.includes("user rejected") || r.includes("user denied") || r.includes("rejected the request")) return "You rejected the transaction in your wallet.";
  if (r.includes("insufficient funds")) return "Not enough ETH for gas — get a little Arbitrum Sepolia ETH.";
  if (r.includes("transfer amount exceeds balance") || r.includes("insufficient balance") || r.includes("erc20")) return "Not enough USDG — use Get test USDG first.";
  if (r.includes("solvencyfloorbreached")) return "Not enough capacity for this size — try a smaller amount.";
  if (r.includes("notdepegged") || r.includes("nottriggered")) return "The trigger hasn't fired yet, so there's nothing to pay.";
  if (r.includes("staleoracle")) return "The price feed is stale — wait a moment and retry.";
  if (r.includes("policyexpired")) return "This policy has already expired.";
  if (r.includes("chain") && r.includes("mismatch")) return "Wrong network — switch your wallet to the right chain.";
  return raw.length > 140 ? raw.slice(0, 140) + "…" : raw;
}
type Tab = "buy" | "underwrite" | "keeper";
type St = ReturnType<typeof useAirbag>;
type Send = (label: string, fn: () => Promise<Hex>) => Promise<TransactionReceipt | null>;
type Write = ReturnType<typeof useWriteContract>["writeContractAsync"];

function status(p: Policy, now: bigint) {
  if (p.paidOut !== null) return { k: "paid", label: `paid ${compact(p.paidOut)}`, cls: "ok" };
  if (p.expiredReleased) return { k: "lapsed", label: "lapsed", cls: "" };
  if (now > p.expiry) return { k: "expired", label: "expired · settle", cls: "warn" };
  if (p.due !== null) return { k: "due", label: `due ${compact(p.due)}`, cls: "bad" };
  if (p.bound === false) return { k: "unbound", label: "not linked", cls: "warn" };
  return { k: "active", label: "active", cls: "ok" };
}

export default function Console() {
  const { address, isConnected } = useAccount();
  const { connectAsync, connectors } = useConnect();
  const { disconnectAsync } = useDisconnect();
  const client = usePublicClient();
  const { writeContractAsync } = useWriteContract();
  const s = useAirbag(address);

  const [tab, setTab] = useState<Tab>("buy");
  const [prod, setProd] = useState<Product>("depeg");
  const [busy, setBusy] = useState<string | null>(null);
  const [logs, setLogs] = useState<Log[]>([]);
  const [toasts, setToasts] = useState<Toast[]>([]);
  const toastId = useRef(0);
  const pushToast = (t: Omit<Toast, "id">) => {
    const id = ++toastId.current;
    setToasts((ts) => [...ts.slice(-3), { ...t, id }]);
    return id;
  };
  const updateToast = (id: number, t: Partial<Toast>) => {
    setToasts((ts) => ts.map((x) => (x.id === id ? { ...x, ...t } : x)));
    if (t.kind && t.kind !== "pending") setTimeout(() => setToasts((ts) => ts.filter((x) => x.id !== id)), 7000);
  };
  const [deployed, setDeployed] = useState<{ amount: bigint; ids: bigint[] } | null>(null);

  // the order book for the selected product: every live market (underwriter) selling it
  const book = s.markets.filter((m) => !m.docked && m.product === prod);
  const market: Market | undefined = book.find((m) => m.hash === D.market) ?? book[0] ?? s.markets[0];
  const agg = book.reduce(
    (a, m) => ({ backing: a.backing + m.backing, covered: a.covered + m.covered, capacity: a.capacity + m.capacity }),
    { backing: 0n, covered: 0n, capacity: 0n }
  );
  const product = market?.product ?? "depeg";
  const triggerPrice = market ? (market.pegPrice * BigInt(10_000 - market.depegBps)) / 10_000n : 0n;

  const log = (msg: string, kind: Log["kind"] = "info", hash?: string) =>
    setLogs((l) => [{ t: new Date().toLocaleTimeString("en-GB"), msg, kind, hash }, ...l].slice(0, 8));

  /** send a tx, wait for it, log it, refresh state */
  const send: Send = async (label, fn) => {
    setBusy(label);
    const tid = pushToast({ kind: "pending", title: label, sub: "Confirm in your wallet…" });
    try {
      const hash = await fn();
      updateToast(tid, { sub: "Waiting for the network…", hash });
      const r = await client!.waitForTransactionReceipt({ hash });
      log(label, "ok", hash);
      updateToast(tid, { kind: "ok", sub: "Done", hash });
      await s.refresh();
      return r;
    } catch (e: unknown) {
      const err = e as { shortMessage?: string; message?: string };
      const raw = err.shortMessage ?? err.message?.split("\n")[0] ?? "failed";
      log(`${label} — ${raw}`, "err");
      updateToast(tid, { kind: "err", sub: humanError(raw) });
      return null;
    } finally {
      setBusy(null);
    }
  };

  /* ---------- auto-payout detection: my open cover got paid without me claiming ---------- */
  const claimedByMe = useRef(new Set<bigint>());
  const seenOpen = useRef(new Set<bigint>());
  useEffect(() => {
    if (!address) return;
    for (const p of s.policies) {
      if (!p.settled && p.held) seenOpen.current.add(p.id);
      else if (p.settled && p.paidOut !== null && seenOpen.current.has(p.id)) {
        seenOpen.current.delete(p.id);
        if (!claimedByMe.current.has(p.id) && p.paidOut > 0n) {
          // one order can be split across underwriters → several policies pay in the same keeper round: add them up
          const paid = p.paidOut, id = p.id;
          setDeployed((d) => (d ? { amount: d.amount + paid, ids: [...d.ids, id] } : { amount: paid, ids: [id] }));
          log(`Airbag deployed — policy #${p.id} paid ${usd(p.paidOut)} USDG to you automatically`, "bag");
        }
      }
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [s.policies, address]);

  /* ---------- wallet ---------- */
  /** switch dev account (local chain); remembered per browser so a reload keeps the role */
  async function connectAs(i: number) {
    if (isConnected) await disconnectAsync().catch(() => undefined);
    await connectAsync({ connector: connectors[i] }).catch((e) => console.warn("[airbag] connect failed", e));
    try {
      localStorage.setItem("airbag.devAccount", String(i));
    } catch {
      /* storage unavailable */
    }
  }
  useEffect(() => {
    if (!IS_LOCAL) return;
    let i = -1;
    try {
      i = Number(localStorage.getItem("airbag.devAccount") ?? -1);
    } catch {
      /* storage unavailable */
    }
    if (i >= 0 && i < DEV_ACCOUNTS.length) connectAsync({ connector: connectors[i] }).catch((e) => console.warn("[airbag] restore failed", e));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);
  const devIdx = IS_LOCAL ? DEV_ACCOUNTS.findIndex((a) => eq(a.address, address)) : -1;
  const walletRight = (
    <>
      {IS_LOCAL && (
        <details className="demo-menu">
          <summary className={`nav-mono ${devIdx >= 0 ? "on" : ""}`}>
            <span className={`nav-dot ${devIdx >= 0 ? "on" : ""}`} />
            {devIdx >= 0 ? `Demo: ${DEV_ACCOUNTS[devIdx].label.split(" ")[0]}` : "Demo accounts"} ▾
          </summary>
          <div className="demo-pop">
            <div className="hint">Pre-funded test accounts on the local chain — no wallet needed.</div>
            {DEV_ACCOUNTS.map((a, i) => (
              <button key={a.address} className={`nav-mono ${devIdx === i ? "on" : ""}`} onClick={() => connectAs(i)}>
                <span className={`nav-dot ${devIdx === i ? "on" : ""}`} />
                {a.label}
              </button>
            ))}
          </div>
        </details>
      )}
      <WalletButton />
    </>
  );

  /* ---------- actions ---------- */
  const mintUsdg = () =>
    send("Mint 100,000 test USDG", () =>
      writeContractAsync({ address: D.usdg, abi: erc20Abi, functionName: "mint", args: [address!, parseUnits("100000", 18)] })
    );

  async function mine() {
    if (IS_LOCAL) await client!.request({ method: "evm_mine" as never, params: [] as never });
  }

  async function warp(sec: number, label: string) {
    setBusy(label);
    try {
      await client!.request({ method: "evm_increaseTime" as never, params: [toHex(sec)] as never });
      await mine();
      log(`Time travel ${label} (local chain)`, "ok");
      await s.refresh();
    } finally {
      setBusy(null);
    }
  }

  async function claim(p: Policy) {
    claimedByMe.current.add(p.id);
    await send(`Claim policy #${p.id}`, () =>
      writeContractAsync({ address: D.coverApp, abi: coverAppAbi, functionName: "claim", args: [p.id] })
    );
  }
  async function expire(p: Policy) {
    await send(`Expire policy #${p.id}`, () =>
      writeContractAsync({ address: D.coverApp, abi: coverAppAbi, functionName: "expire", args: [p.id] })
    );
  }
  /** a keeper round from the browser: anyone may fire due payouts and settle lapsed policies */
  async function keeperRound() {
    const due = s.policies.filter((p) => !p.settled && p.due !== null && s.now <= p.expiry);
    const lapsed = s.policies.filter((p) => !p.settled && s.now > p.expiry);
    if (due.length + lapsed.length === 0) return log("Keeper round: nothing due", "info");
    for (const p of due)
      await send(`Keeper: payout #${p.id} → ${short(p.holder)}`, () =>
        writeContractAsync({ address: D.coverApp, abi: payoutAbi, functionName: "payout", args: [p.id] })
      );
    for (const p of lapsed) await expire(p);
  }

  const myPolicies = s.policies.filter((p) => p.held || (address && eq(p.buyer, address)));
  const capLeft = agg.capacity > agg.covered ? agg.capacity - agg.covered : 0n;
  const dueCount = s.policies.filter((p) => !p.settled && p.due !== null).length;

  // product-specific headline price for the KPI row
  const kpiPrice =
    product === "gap"
      ? { k: "TSLAx oracle", v: `$${px(s.stockPrice, 2)}`, s: `strike $${px(market?.strike ?? 0n, 0)}`, hot: market?.strike ? s.stockPrice < market.strike : false }
      : product === "il"
        ? { k: "wstETH / WETH", v: s.pool ? lstPrice(s.pool.settledTick).toFixed(3) : "—", s: "pool price (settled)", hot: s.pool ? lstPrice(s.pool.settledTick) < 0.99 : false }
        : { k: "USDG oracle", v: `$${px(s.price)}`, s: `trigger ≤ $${px(triggerPrice)}`, hot: s.price > 0n && s.price <= triggerPrice };

  return (
    <>
      <TileBackground opacity={0.8} still full soft />
      <Navbar onConsole calm right={walletRight} />
      <main className="console calm">
        <div className="container">
          <div className="console-head">
            <div>
              <div className="crumbs">Airbag / <b>Console</b></div>
              <h1 className="console-title">Cover console</h1>
              <div className="console-sub">
                <span className={`net ${IS_LOCAL ? "local" : ""}`}><i />{IS_LOCAL ? "Local demo chain" : `${CHAIN.name} · testnet`}</span>
                <span className="pill ok">Auto-payout on</span>
                {dueCount > 0 && <span className="pill bad">{dueCount} payout{dueCount > 1 ? "s" : ""} firing</span>}
              </div>
            </div>
            {isConnected && (
              <div className="acct">
                <div className="acct-bal"><span>Your balance</span><b>{s.loading ? <span className="skel w90" /> : `${usd(s.usdgBalance)} USDG`}</b></div>
                <button className="btn btn-sm btn-ghost" onClick={mintUsdg} disabled={!!busy}>Get test USDG</button>
              </div>
            )}
          </div>

          {deployed && (
            <div className="deployed" onClick={() => setDeployed(null)}>
              <Logo className="deployed-mark" />
              <div>
                <div className="deployed-title">Paid ✓ — your airbag deployed</div>
                <div className="deployed-sub">
                  {deployed.ids.length > 1 ? "Policies" : "Policy"} {deployed.ids.map((i) => `#${i}`).join(", ")} paid <b>{usd(deployed.amount)} USDG</b> into your wallet — automatically, you
                  didn&apos;t send a transaction.
                </div>
              </div>
              <span className="deployed-x">×</span>
            </div>
          )}
          {s.error && (
            <div className="banner">
              <b>Can&apos;t reach the chain.</b> {s.error}
              {IS_LOCAL && <> — is anvil running on :8545 and was <code>DeployDemo.s.sol</code> broadcast?</>}
            </div>
          )}
          {!isConnected && (
            <div className="banner">
              <b>Connect a wallet</b> to buy cover or underwrite.{" "}
              {IS_LOCAL
                ? "Use Connect wallet (top right), or one of the pre-funded demo accounts — Buyer / Underwriter."
                : "Use Connect wallet (top right) with MetaMask on Arbitrum Sepolia — test USDG is free to mint here."}
            </div>
          )}

          {/* product catalog */}
          <div className="catalog">
            {ORDER.filter((p) => s.markets.some((m) => !m.docked && m.product === p)).map((p) => {
              const ms = s.markets.filter((m) => !m.docked && m.product === p);
              const lead = ms.find((m) => m.hash === D.market) ?? ms[0];
              const meta = META[p];
              const room = ms.reduce((a, m) => a + (m.capacity > m.covered ? m.capacity - m.covered : 0n), 0n);
              const from = Math.min(...ms.map((m) => wad(m.startRateWad)));
              return (
                <button key={p} className={`product ${p === prod ? "on" : ""}`} onClick={() => { setProd(p); setTab("buy"); }}>
                  <div className="product-top">
                    <span className="product-n">{meta.n}</span>
                    <span className="pill">{meta.tag}</span>
                  </div>
                  <div className="product-name">{meta.name}</div>
                  <div className="product-rule">{payoutRule(lead)}</div>
                  <div className="product-stats">
                    <span>from <b>{(from * 100).toFixed(1)}%</b></span>
                    <span>capacity <b>{compact(room)}</b></span>
                    {ms.length > 1 && <span className="red">{ms.length} underwriters</span>}
                    {ms.some((m) => m.inVault) && <span className="green">+{pct(s.vault?.aprBps ?? 0)} vault</span>}
                  </div>
                </button>
              );
            })}
          </div>

          {/* KPIs */}
          <div className="kpis">
            <div className="kpi">
              <div className="k">Reserve backing</div>
              <div className="v">{s.loading ? <span className="skel w60" /> : compact(agg.backing)}</div>
              <div className="s">{book.length > 1 ? `across ${book.length} underwriters` : market?.inVault ? "USDG in savings vault" : "USDG in underwriter wallet"}</div>
            </div>
            <div className="kpi">
              <div className="k">Cover in force</div>
              <div className="v">{s.loading ? <span className="skel w40" /> : compact(agg.covered)}</div>
              <div className="s">active policies' notional</div>
            </div>
            <div className="kpi">
              <div className="k">Utilization</div>
              <div className="v">{s.loading ? <span className="skel w40" /> : agg.backing > 0n ? pct((agg.covered * 10_000n) / agg.backing) : "—"}</div>
              <div className="s">max {market ? pct(market.maxUtilBps, 0) : "—"} of backing</div>
            </div>
            <div className="kpi">
              <div className="k">Available to buy</div>
              <div className="v green">{s.loading ? <span className="skel w60" /> : compact(capLeft)}</div>
              <div className="s">USDG of cover left</div>
            </div>
            <div className="kpi">
              <div className="k"><span className={`kdot ${kpiPrice.hot ? "bad" : ""}`} />{kpiPrice.k}</div>
              <div className={`v ${kpiPrice.hot ? "red" : ""}`}>{s.loading ? <span className="skel w60" /> : kpiPrice.v}</div>
              <div className="s">{kpiPrice.s}</div>
            </div>
          </div>

          <div className="pnl modebar">
            <div className="tabs">
              <button className={`tab ${tab === "buy" ? "on" : ""}`} onClick={() => setTab("buy")}>Buy cover</button>
              <button className={`tab ${tab === "underwrite" ? "on" : ""}`} onClick={() => setTab("underwrite")}>Underwrite</button>
              <button className={`tab ${tab === "keeper" ? "on" : ""}`} onClick={() => setTab("keeper")}>Keeper</button>
            </div>
          </div>

          {tab === "buy" && market && (
            <BuyPanel market={market} book={book} state={s} busy={busy} account={address} send={send} write={writeContractAsync} capLeft={capLeft} mine={mine} />
          )}
          {tab === "buy" && !market && <div className="pnl"><div className="empty">no market registered yet</div></div>}
          {tab === "underwrite" && (
            <UnderwritePanel state={s} busy={busy} account={address} send={send} write={writeContractAsync} onOpened={() => setProd("depeg")} />
          )}
          {tab === "keeper" && (
            <div className="pnl row-full">
              <div className="pnl-body"><KeeperPanel state={s} busy={busy} onRound={keeperRound} onExpire={expire} /></div>
            </div>
          )}

          <div className="row2">
            <div className="stackv">
              {product === "il" ? (
                <PoolSimulator state={s} busy={busy} account={address} send={send} write={writeContractAsync} mine={mine} />
              ) : product === "gap" ? (
                <OraclePanel
                  key="gap"
                  title="TSLAx price oracle"
                  unit="TSLAx / USD"
                  oracle={D.stockOracle!}
                  price={s.stockPrice}
                  dp={2}
                  hot={kpiPrice.hot}
                  note={
                    kpiPrice.hot && market?.strike
                      ? `down ${pct(((market.strike - s.stockPrice) * 10_000n) / market.strike)} from strike — pays that share`
                      : `pays by the % below $${px(market?.strike ?? 0n, 0)}`
                  }
                  range={[150, 270, 0.5]}
                  presets={[{ l: "Reset $250", v: 250 }, { l: "Earnings miss −20%", v: 200, hot: true }]}
                  busy={busy}
                  send={send}
                  write={writeContractAsync}
                />
              ) : (
                <OraclePanel
                  key="usd"
                  title="USDG price oracle"
                  unit="USDG / USD"
                  oracle={D.oracle}
                  price={s.price}
                  dp={3}
                  hot={kpiPrice.hot}
                  note={kpiPrice.hot ? "below trigger — airbag deploying" : `trigger at ≤ $${px(triggerPrice)}`}
                  range={[0.85, 1.02, 0.001]}
                  presets={[{ l: "Reset $1.00", v: 1 }, { l: "Depeg → $0.92", v: 0.92, hot: true }]}
                  busy={busy}
                  send={send}
                  write={writeContractAsync}
                />
              )}
              {IS_LOCAL && (
                <div className="timebar">
                  <span className="pnl-title"><span className="n">⏩</span>Time machine</span>
                  <button className="chip" disabled={!!busy} onClick={() => warp(3600, "+1 hour")}>+1h</button>
                  <button className="chip" disabled={!!busy} onClick={() => warp(86400, "+1 day")}>+1d</button>
                  <button className="chip" disabled={!!busy} onClick={() => warp(31 * 86400, "+31 days")}>+31d</button>
                </div>
              )}

            </div>
            <div className="stackv">
              <div className="pnl">
                <div className="pnl-head">
                  <span className="pnl-title"><span className="n">//</span>My cover notes</span>
                  <span className="pill">{myPolicies.length} policies</span>
                </div>
                {myPolicies.length === 0 ? (
                  <div className="empty">You don&apos;t hold any cover yet. Pick a product above, choose an amount and a term, and buy — it shows up here.</div>
                ) : (
                  <table className="dtable">
                    <thead>
                      <tr><th>#</th><th>Product</th><th className="num">Cover</th><th>Term</th><th>Status</th><th /></tr>
                    </thead>
                    <tbody>
                      {myPolicies.map((p) => {
                        const st = status(p, s.now);
                        const m = s.markets.find((x) => x.hash === p.market);
                        return (
                          <tr key={String(p.id)}>
                            <td>{String(p.id)}</td>
                            <td>{m ? META[m.product].tag : "—"}{p.ilBps !== undefined && !p.settled ? <span className="dim"> · IL {pct(p.ilBps, 2)}</span> : null}</td>
                            <td className="num">{usd(p.notional, 0)}</td>
                            <td>{p.settled ? "—" : left(p.expiry - s.now)}</td>
                            <td><span className={`pill ${st.cls}`}>{st.label}</span></td>
                            <td className="num">
                              {st.k === "due" && p.held && (
                                <button className="btn btn-sm btn-red" disabled={!!busy} onClick={() => claim(p)} title="The keeper pays this automatically — or claim it yourself now">
                                  Claim now
                                </button>
                              )}
                              {st.k === "unbound" && p.held && (
                                <button className="btn btn-sm btn-ghost" disabled={!!busy} onClick={() =>
                                  send(`Link policy #${p.id} to my LP position`, () =>
                                    writeContractAsync({ address: D.ilTrigger!, abi: ilTriggerAbi, functionName: "bind", args: [p.id] }))
                                }>Link LP</button>
                              )}
                              {st.k === "expired" && (
                                <button className="btn btn-sm btn-ghost" disabled={!!busy} onClick={() => expire(p)}>Settle</button>
                              )}
                            </td>
                          </tr>
                        );
                      })}
                    </tbody>
                  </table>
                )}
              </div>
              <div className="pnl">
                <div className="pnl-head">
                  <span className="pnl-title"><span className="n">//</span>Activity</span>
                  {busy && <span className="pill warn">{busy}…</span>}
                </div>
                <div className="pnl-body log">
                  {logs.length === 0 && <div style={{ color: "var(--text-dim)" }}>transactions show up here</div>}
                  {logs.map((l, i) => {
                    const url = l.hash ? explorerTx(l.hash) : null;
                    return (
                      <div key={i}>
                        <span className="t">{l.t}</span>
                        <span className={l.kind}>
                          {l.kind === "ok" ? "✓ " : l.kind === "err" ? "✗ " : l.kind === "bag" ? "◉ " : ""}
                          {l.msg}
                          {l.hash && (url ? <> · <a href={url} target="_blank" rel="noreferrer">{short(l.hash)}</a></> : <> · {short(l.hash)}</>)}
                        </span>
                      </div>
                    );
                  })}
                </div>
              </div>
            </div>
          </div>
        </div>
      </main>
      <div className="toasts">
        {toasts.map((t) => {
          const url = t.hash ? explorerTx(t.hash) : null;
          return (
            <div key={t.id} className={`toast ${t.kind}`}>
              <div className="ti">{t.kind === "pending" ? <span className="spin" /> : t.kind === "ok" ? "✓" : "!"}</div>
              <div>
                <div className="tt">{t.title}</div>
                {t.sub && <div className="ts">{t.sub}{url && <> · <a href={url} target="_blank" rel="noreferrer">view on Arbiscan</a></>}</div>}
              </div>
              {t.kind !== "pending" && <span className="tx" onClick={() => setToasts((ts) => ts.filter((x) => x.id !== t.id))}>×</span>}
            </div>
          );
        })}
      </div>
    </>
  );
}

/* =====================================================================
   buy
   ===================================================================== */

function BuyPanel({ market, book, state, busy, account, send, write, capLeft, mine }: {
  market: Market; book: Market[]; state: St; busy: string | null; account?: `0x${string}`; send: Send; write: Write; capLeft: bigint; mine: () => Promise<void>;
}) {
  const client = usePublicClient();
  const [amt, setAmt] = useState("50000");
  const [dur, setDur] = useState(DURATIONS[2].s);
  const [premium, setPremium] = useState<bigint | null>(null);
  const [quoteErr, setQuoteErr] = useState<string | null>(null);

  const notional = useMemo(() => {
    try {
      return parseUnits(amt || "0", 18);
    } catch {
      return 0n;
    }
  }, [amt]);

  useEffect(() => {
    let dead = false;
    if (!client || notional === 0n) {
      setPremium(null);
      return;
    }
    const t = setTimeout(async () => {
      try {
        const p = await client.readContract({ address: D.coverApp, abi: coverAppAbi, functionName: "quotePremiumFor", args: [market.hash, notional, BigInt(dur)] });
        if (!dead) { setPremium(p); setQuoteErr(null); }
      } catch {
        if (!dead) { setPremium(null); setQuoteErr("quote unavailable"); }
      }
    }, 250);
    return () => { dead = true; clearTimeout(t); };
  }, [client, notional, market.hash, market.covered, dur]);

  const isIl = market.product === "il";
  const routed = book.length > 1 && !!D.coverRouter && D.coverRouter !== "0x0000000000000000000000000000000000000000";
  const route = useMemo(
    () => (routed && notional > 0n ? solveRoute(book, Number(formatUnits(notional, 18))) : null),
    // re-solve when the book moves
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [routed, notional, book.map((m) => `${m.hash}:${m.covered}:${m.capacity}`).join("|")]
  );
  const legs = useMemo(
    () => (route ?? []).map((l) => ({ strategyHash: l.market.hash, coverNotional: parseUnits(l.notional.toFixed(6), 18) })),
    [route]
  );
  const [routeQuote, setRouteQuote] = useState<bigint | null>(null);
  const [single, setSingle] = useState<{ m: Market; p: bigint } | null>(null);
  useEffect(() => {
    let dead = false;
    if (!routed || !client || legs.length === 0) { setRouteQuote(null); setSingle(null); return; }
    (async () => {
      try {
        const [, total] = await client.readContract({ address: D.coverRouter!, abi: routerAbi, functionName: "quoteRouteFor", args: [legs, BigInt(dur)] });
        // best a buyer could do with ONE underwriter (for the savings comparison)
        let best: { m: Market; p: bigint } | null = null;
        for (const m of book) {
          if (m.capacity - m.covered < notional) continue;
          const p = await client.readContract({ address: D.coverApp, abi: coverAppAbi, functionName: "quotePremiumFor", args: [m.hash, notional, BigInt(dur)] });
          if (!best || p < best.p) best = { m, p };
        }
        if (!dead) { setRouteQuote(total); setSingle(best); }
      } catch {
        if (!dead) setRouteQuote(null);
      }
    })();
    return () => { dead = true; };
  }, [routed, client, legs, book, notional, dur]);
  const lpLive = !!state.pool?.myEntry?.active;
  const over = notional > capLeft;
  const shownPremium = routed ? routeQuote : premium;
  // annualized rate actually paid (curve rates are annual; premium = rate × notional × term / year)
  const rate = shownPremium && notional > 0n ? (Number((shownPremium * 1_000_000n) / notional) / 10_000) * (365 * 86400 / dur) : 0;
  const capAfter = market.capacity > 0n ? Number(((market.covered + notional) * 10_000n) / market.capacity) : 0;
  const utilAfter = market.backing > 0n ? Number(((market.covered + notional) * 10_000n) / market.backing) : 0;
  const needApprove = shownPremium !== null && state.allowanceCover < shownPremium;
  const poor = shownPremium !== null && state.usdgBalance < shownPremium;
  const [routerAllowance, setRouterAllowance] = useState(0n);
  useEffect(() => {
    if (!routed || !client || !account) return;
    client.readContract({ address: D.usdg, abi: erc20Abi, functionName: "allowance", args: [account, D.coverRouter!] }).then(setRouterAllowance).catch(() => undefined);
  }, [routed, client, account, busy]);

  async function becomeLp() {
    if (!POOL_KEY || !account) return;
    const big = parseUnits("10000", 18);
    for (const [tok, sym] of [[D.token0!, D.token0Symbol], [D.token1!, D.token1Symbol]] as const) {
      if (!(await send(`Mint test ${sym}`, () => write({ address: tok, abi: erc20Abi, functionName: "mint", args: [account, big] })))) return;
      if (!(await send(`Approve ${sym} for the pool`, () => write({ address: tok, abi: erc20Abi, functionName: "approve", args: [D.lpRouter!, 2n ** 255n] })))) return;
    }
    await send(`Add liquidity to ${D.token0Symbol}/${D.token1Symbol} (Uniswap v4)`, () =>
      write({ address: D.lpRouter!, abi: lpRouterAbi, functionName: "modifyAs", args: [POOL_KEY!, -6000, 6000, parseUnits("1000", 18)] })
    );
    await mine();
  }
  async function exitLp() {
    if (!POOL_KEY) return;
    await send("Remove liquidity (locks in realized IL)", () =>
      write({ address: D.lpRouter!, abi: lpRouterAbi, functionName: "modifyAs", args: [POOL_KEY!, -6000, 6000, -parseUnits("1000", 18)] })
    );
  }

  async function buyRouted() {
    if (routeQuote === null || !account) return;
    const cap = (routeQuote * 101n) / 100n; // 1% premium slippage cap, refunded if unused
    if (routerAllowance < cap) {
      const ok = await send("Approve USDG for the cover router", () =>
        write({ address: D.usdg, abi: erc20Abi, functionName: "approve", args: [D.coverRouter!, 2n ** 255n] })
      );
      if (!ok) return;
    }
    const deadline = BigInt(Math.floor(Date.now() / 1000) + 900);
    await send(`Buy ${usd(notional, 0)} USDG cover across ${legs.length} underwriter${legs.length > 1 ? "s" : ""}`, () =>
      write({ address: D.coverRouter!, abi: routerAbi, functionName: "buyRoute", args: [legs, D.usdg, cap, BigInt(dur), account, deadline] })
    );
  }

  async function buy() {
    if (routed) return buyRouted();
    if (premium === null) return;
    if (needApprove) {
      const ok = await send("Approve USDG for premiums", () =>
        write({ address: D.usdg, abi: erc20Abi, functionName: "approve", args: [D.coverApp, 2n ** 255n] })
      );
      if (!ok) return;
    }
    const r = await send(`Buy ${usd(notional, 0)} USDG ${META[market.product].name} cover`, () =>
      write({ address: D.coverApp, abi: coverAppAbi, functionName: "buyPolicy", args: [market.hash, notional, BigInt(dur)] })
    );
    if (!r || !isIl) return;
    const ev = parseEventLogs({ abi: coverAppAbi, eventName: "PolicyBought", logs: r.logs })[0];
    if (ev) {
      await send(`Link policy #${ev.args.policyId} to my LP position`, () =>
        write({ address: D.ilTrigger!, abi: ilTriggerAbi, functionName: "bind", args: [ev.args.policyId] })
      );
    }
  }

  return (
    <div className="row2">
      <div className="pnl col">
        <div className="pnl-head">
          <span className="pnl-title"><span className="n">01</span>Your order</span>
          <span className="pill">{META[market.product].tag}</span>
        </div>
        <div className="pnl-body grow">
      {isIl && (
        <div className="lp-step">
          <div className="lp-step-head">
            <span className="pnl-title"><span className="n">step 1</span>Your LP position</span>
            {lpLive ? <span className="pill ok">live</span> : <span className="pill warn">none</span>}
          </div>
          {lpLive && state.pool?.myEntry ? (
            <div className="lp-row">
              <span>{D.token0Symbol}/{D.token1Symbol} · ±6000 ticks · entered at {lstPrice(state.pool.myEntry.entryTick).toFixed(3)}</span>
              <b className={state.pool.myIlBps > 0 ? "red" : ""}>IL {pct(state.pool.myIlBps, 2)}</b>
              <button className="btn btn-sm btn-ghost" disabled={!!busy} onClick={exitLp}>Exit</button>
            </div>
          ) : (
            <div className="lp-row">
              <span>LP cover links to a live position in the v4 pool — the hook proves it on-chain.</span>
              <button className="btn btn-sm btn-primary" disabled={!account || !!busy} onClick={becomeLp}>Become an LP →</button>
            </div>
          )}
        </div>
      )}

      <div className="field">
        <label><span>{isIl ? "Step 2 · Cover amount" : "Cover amount"}</span><span>capacity left {usd(capLeft, 0)}</span></label>
        <div className="amt">
          <input value={amt} onChange={(e) => setAmt(e.target.value.replace(/[^0-9.]/g, ""))} inputMode="decimal" />
          <span className="unit">USDG</span>
        </div>
        <div className="chips">
          {["10000", "50000", "100000", "250000"].map((v) => (
            <button key={v} className={`chip ${amt === v ? "on" : ""}`} onClick={() => setAmt(v)}>{Number(v) / 1000}k</button>
          ))}
        </div>
      </div>
      <div className="field">
        <label><span>Term</span></label>
        <div className="chips">
          {DURATIONS.map((d) => (
            <button key={d.s} className={`chip ${dur === d.s ? "on" : ""}`} onClick={() => setDur(d.s)}>{d.label}</button>
          ))}
        </div>
      </div>

      <div className="price-card">
        <div className="pc-k">You pay</div>
        <div className="pc-v">{shownPremium !== null ? usd(shownPremium) : quoteErr ? "—" : <span className="skel w40" />}<small>USDG</small></div>
        <div className="pc-s">for <b>{usd(notional, 0)} USDG</b> of cover · {DURATIONS.find((d) => d.s === dur)?.label}</div>
        <div className="pc-rule">✓ {payoutRule(market)} — paid automatically</div>
      </div>
      <details className="more">
        <summary>Details</summary>
      <div className="quote">
        <div className="quote-row"><span>Annual rate (risk curve)</span><b>{shownPremium !== null ? `${rate.toFixed(2)}% / yr · ${(rate * dur / (365 * 86400)).toFixed(3)}% for this term` : "—"}</b></div>
        <div className="quote-row"><span>Example</span><b>{exampleFor(market, notional)}</b></div>
        <div className="quote-row"><span>Capacity sold after</span><b style={{ color: over ? "var(--red)" : undefined }}>{over ? "over the floor" : pct(capAfter)} <span className="dim">· {pct(utilAfter)} of backing</span></b></div>
      </div>

      </details>
      <div className="actions">
        <button className="btn btn-primary" disabled={!account || !!busy || shownPremium === null || over || poor || (isIl && !lpLive) || (routed && !route)} onClick={buy}>
          {isIl ? "Buy + link LP cover" : "Buy cover"}{shownPremium !== null ? ` · ${usd(shownPremium)} USDG` : ""} →
        </button>
      </div>
      <div className="pnl-note">
        {routed && legs.length > 0 ? `Filled by ${legs.length} underwriter${legs.length > 1 ? "s" : ""} in one transaction. ` : ""}
        {poor && account ? "Not enough USDG for the premium — use Get test USDG above. " : ""}
        {isIl && !lpLive ? "Become an LP first — the cover is tied to your position. " : ""}
        The premium goes straight into the underwriter&apos;s reserve through Aqua. You get an ERC-6909 CoverNote. When the
        trigger fires, a keeper pushes the payout to whoever holds the note — no claim needed.
      </div>
        </div>
      </div>
      <div className="pnl col">
        <div className="pnl-head">
          <span className="pnl-title"><span className="n">02</span>The market</span>
          <span className="pill">{book.length} underwriter{book.length > 1 ? "s" : ""}</span>
        </div>
        <div className="pnl-body grow">
      <div className="market-sum">
        {book.length > 1 ? <><b>{book.length} underwriters compete</b> — the cheapest price is picked for you automatically.</> : <>One underwriter backs this product with <b>{compact(market.backing)} USDG</b>.</>}
      </div>
      <div className="curve-box">
        <div className="curve-box-head">
          <span>How the price rises as cover sells</span>
          <span><b>{(wad(market.startRateWad) * 100).toFixed(1)}% → {(wad(market.endRateWad) * 100).toFixed(1)}%</b> a year</span>
        </div>
        <RiskCurveChart
          curve={{ start: wad(market.startRateWad), end: wad(market.endRateWad), k: wad(market.convexityWad) }}
          nowU={market.capacity > 0n ? wad((market.covered * 10n ** 18n) / market.capacity) : 0}
          afterU={market.capacity > 0n ? wad(((market.covered + (routed ? legs.find((l) => l.strategyHash === market.hash)?.coverNotional ?? 0n : notional)) * 10n ** 18n) / market.capacity) : 0}
          ghosts={book.filter((m) => m.hash !== market.hash).map((m) => ({ start: wad(m.startRateWad), end: wad(m.endRateWad), k: wad(m.convexityWad) }))}
        />
      </div>

      {routed && (
        <div className="book">
          <div className="curve-box-head">
            <span>Order book · {book.length} underwriters</span>
            <span>cheapest curves fill first</span>
          </div>
          <table className="dtable">
            <thead>
              <tr><th>Underwriter</th><th>Price range / yr</th><th className="num">Room</th><th className="num">Your fill</th></tr>
            </thead>
            <tbody>
              {book.map((m) => {
                const leg = route?.find((l) => l.market.hash === m.hash);
                return (
                  <tr key={m.hash} className={leg ? "fill" : ""}>
                    <td>{m.inVault ? "Airbag Genesis · vault" : short(m.underwriter)}</td>
                    <td>{(wad(m.startRateWad) * 100).toFixed(1)}% → {(wad(m.endRateWad) * 100).toFixed(1)}%</td>
                    <td className="num">{compact(m.capacity > m.covered ? m.capacity - m.covered : 0n)}</td>
                    <td className="num">{leg ? <b>{Math.round(leg.notional).toLocaleString("en-US")}</b> : <span className="dim">—</span>}</td>
                  </tr>
                );
              })}
            </tbody>
          </table>
          {routeQuote !== null && single && (single.p - routeQuote) * 200n > single.p ? (
            <div className="book-save">
              Best single underwriter: {usd(single.p)} USDG → routed: <b>{usd(routeQuote)} USDG</b> · you save{" "}
              <b>{usd(single.p - routeQuote)} ({((wad(single.p - routeQuote) / wad(single.p)) * 100).toFixed(1)}%)</b>
            </div>
          ) : routeQuote !== null && route && route.length > 0 ? (
            <div className="book-save">
              Routed to the cheapest curve{route.length > 1 ? "s" : ""} right now — premium <b>{usd(routeQuote)} USDG</b>. Bigger orders spread across more underwriters.
            </div>
          ) : null}
          {route === null && notional > 0n && <div className="book-save red">Not enough capacity across the book for this size.</div>}
        </div>
      )}

      {!routed && (
        <div className="facts">
          <div><span>Underwriter</span><b>{market.inVault ? "Airbag Genesis · vault" : short(market.underwriter)}</b></div>
          <div><span>Reserve</span><b>{compact(market.backing)} USDG · {market.inVault ? "savings vault" : "wallet"}</b></div>
          <div><span>Cover sold</span><b>{compact(market.covered)} · {pct(market.utilBps)} of backing</b></div>
          {market.product === "il" && <div><span>Payout band</span><b>IL {pct(market.deductibleBps ?? 0)} → {pct(market.capBps ?? 0, 0)} pays 0 → 100%</b></div>}
          {market.product === "il" && <div><span>Measured by</span><b>CoverHook · block-open price</b></div>}
          {market.product === "gap" && <div><span>Strike</span><b>${px(market.strike ?? 0n, 0)} · pays the % below it</b></div>}
          {market.product === "gap" && <div><span>Oracle</span><b>TSLAx / USD feed</b></div>}
          <div><span>Solvency floor</span><b>sells at most {pct(market.maxUtilBps, 0)} of backing</b></div>
        </div>
      )}
        </div>
      </div>
    </div>
  );
}

/* =====================================================================
   event simulators
   ===================================================================== */

function OraclePanel({ title, unit, oracle, price, dp, hot, note, range, presets, busy, send, write }: {
  title: string; unit: string; oracle: `0x${string}`; price: bigint; dp: number; hot: boolean; note: string;
  range: [number, number, number]; presets: { l: string; v: number; hot?: boolean }[]; busy: string | null; send: Send; write: Write;
}) {
  const current = Number(price) / 1e8;
  const [v, setV] = useState(current || range[1]);
  useEffect(() => {
    if (current > 0) setV(current);
  }, [current]);
  const set = (p: number) =>
    send(`${unit} → $${p.toFixed(dp)}`, () => write({ address: oracle, abi: oracleAbi, functionName: "set", args: [BigInt(Math.round(p * 1e8))] }));
  return (
    <div className="pnl oracle">
      <div className="pnl-head">
        <span className="pnl-title"><span className="n">//</span>{title}</span>
        <span className="pill warn">event simulator</span>
      </div>
      <div className="pnl-body">
        <div className="band">{unit}</div>
        <div className={`price ${hot ? "down" : ""}`}>${current.toFixed(dp)}</div>
        <div className="band">{note}</div>
        <input className="slider" type="range" min={range[0]} max={range[1]} step={range[2]} value={v} onChange={(e) => setV(Number(e.target.value))} />
        <div className="actions">
          {presets.map((p) => (
            <button key={p.l} className={`btn btn-sm ${p.hot ? "btn-red" : "btn-ghost"}`} disabled={!!busy} onClick={() => set(p.v)}>{p.l}</button>
          ))}
          <button className="btn btn-sm btn-ghost" disabled={!!busy} onClick={() => set(v)}>Set ${v.toFixed(dp)}</button>
        </div>
        <div className="pnl-note">Demo feed you can move by hand. Production markets read Chainlink / Pyth through the oracle adapters, with staleness checks.</div>
      </div>
    </div>
  );
}

function PoolSimulator({ state, busy, account, send, write, mine }: {
  state: St; busy: string | null; account?: `0x${string}`; send: Send; write: Write; mine: () => Promise<void>;
}) {
  const tick = state.pool?.settledTick ?? 0;
  const price = lstPrice(tick);
  const shocked = Math.abs(tick) > 500;

  async function swapTo(target: number, label: string) {
    if (!POOL_KEY || !account) return;
    const zeroForOne = target < tick; // pushing the tick down sells token0
    const tokenIn = zeroForOne ? D.token0! : D.token1!;
    const big = parseUnits("100000", 18);
    if (!(await send("Mint swap inventory", () => write({ address: tokenIn, abi: erc20Abi, functionName: "mint", args: [account, big] })))) return;
    if (!(await send("Approve swap router", () => write({ address: tokenIn, abi: erc20Abi, functionName: "approve", args: [D.swapper!, 2n ** 255n] })))) return;
    await send(label, () =>
      write({
        address: D.swapper!,
        abi: swapperAbi,
        functionName: "swap",
        args: [POOL_KEY!, { zeroForOne, amountSpecified: -big, sqrtPriceLimitX96: sqrtAtTick(target) }, { takeClaims: false, settleUsingBurn: false }, "0x"],
      })
    );
    await mine(); // the hook reads the block-open price: settle the move into a new block
    await state.refresh();
  }

  return (
    <div className="pnl oracle">
      <div className="pnl-head">
        <span className="pnl-title"><span className="n">//</span>Uniswap v4 pool</span>
        <span className="pill warn">event simulator</span>
      </div>
      <div className="pnl-body">
        <div className="band">wstETH priced in WETH · settled</div>
        <div className={`price ${shocked ? "down" : ""}`}>{price.toFixed(3)}</div>
        <div className="band">
          {state.pool?.myEntry?.active ? <>your LP loss <b>{pct(state.pool.myIlBps, 2)}</b></> : `pool tick ${tick}`}
        </div>
        <div className="actions" style={{ marginTop: 18 }}>
          <button className="btn btn-sm btn-red" disabled={!account || !!busy || shocked} onClick={() => swapTo(SHOCK_TICK, "wstETH depeg shock — dump into the pool")}>
            wstETH depeg −33%
          </button>
          <button className="btn btn-sm btn-ghost" disabled={!account || !!busy || !shocked} onClick={() => swapTo(0, "Restore the peg")}>
            Restore peg
          </button>
        </div>
        <div className="pnl-note">
          A real swap through the v4 pool. CoverHook measures LP loss from the <b>block-open</b> price, so a flash-loan push inside one
          transaction can&apos;t fake a claim.
        </div>
      </div>
    </div>
  );
}

/* =====================================================================
   underwrite
   ===================================================================== */

function UnderwritePanel({ state, busy, account, send, write, onOpened }: {
  state: St; busy: string | null; account?: `0x${string}`; send: Send; write: Write; onOpened: (h: Hex) => void;
}) {
  const [reserve, setReserve] = useState("500000");
  const [band, setBand] = useState(300);
  const [util, setUtil] = useState(8000);
  const [curve, setCurve] = useState<Curve>(PRESETS[0].c);
  const mine = state.markets.filter((m) => eq(m.owner, account));

  const tot = mine.reduce(
    (a, m) => ({
      backing: a.backing + m.backing,
      premiums: a.premiums + m.premiums,
      payouts: a.payouts + m.payouts,
      annualPrem: a.annualPrem + (m.backing * BigInt(m.premiumApyBps)) / 10_000n,
      annualVault: a.annualVault + (m.inVault ? (m.backing * BigInt(state.vault?.aprBps ?? 0)) / 10_000n : 0n),
    }),
    { backing: 0n, premiums: 0n, payouts: 0n, annualPrem: 0n, annualVault: 0n }
  );
  const vaultYield = mine.some((m) => m.inVault) ? state.vault?.yieldEarned ?? 0n : 0n;
  const net = tot.premiums + vaultYield - tot.payouts;
  const apyPrem = tot.backing > 0n ? Number((tot.annualPrem * 10_000n) / tot.backing) : 0;
  const apyVault = tot.backing > 0n ? Number((tot.annualVault * 10_000n) / tot.backing) : 0;
  const apy = apyPrem + apyVault;
  const maxApy = Math.max(apy, 1);

  async function open() {
    if (!account) return;
    const amount = parseUnits(reserve || "0", 18);
    const market = {
      underwriter: account,
      asset: D.usdg,
      oracle: D.oracle,
      pegPrice: 100_000_000n,
      depegBps: band,
      maxUtilBps: util,
      oracleTimeout: 86400,
      startRateWad: parseUnits(curve.start.toFixed(6), 18),
      endRateWad: parseUnits(curve.end.toFixed(6), 18),
      convexityWad: parseUnits(curve.k.toFixed(4), 18),
      trigger: "0x0000000000000000000000000000000000000000" as const,
      salt: keccak256(toHex(`${account}-${Date.now()}`)),
    };
    const strategy = encodeAbiParameters([{ type: "tuple", components: marketComponents }], [market]);
    const hash = keccak256(strategy);
    if (state.allowanceAqua < amount) {
      const ok = await send("Approve USDG for Aqua", () =>
        write({ address: D.usdg, abi: erc20Abi, functionName: "approve", args: [D.aqua, 2n ** 255n] })
      );
      if (!ok) return;
    }
    const shipped = await send(`Ship ${usd(amount, 0)} USDG reserve to Aqua`, () =>
      write({ address: D.aqua, abi: aquaAbi, functionName: "ship", args: [D.coverApp, strategy, [D.usdg], [amount]] })
    );
    if (!shipped) return;
    const ok = await send("Register cover market", () =>
      write({ address: D.coverApp, abi: coverAppAbi, functionName: "registerMarket", args: [market] })
    );
    if (ok) onOpened(hash);
  }

  async function close(m: Market) {
    await send(`Close market ${short(m.hash)} (dock)`, () =>
      write({ address: D.aqua, abi: aquaAbi, functionName: "dock", args: [D.coverApp, m.hash, [D.usdg]] })
    );
  }

  return (
    <>
      <div className="pnl row-full">
        <div className="pnl-head">
          <span className="pnl-title"><span className="n">//</span>Your book</span>
          <span className="pill">{mine.length} market{mine.length === 1 ? "" : "s"}</span>
        </div>
        <div className="pnl-body">
          {mine.length > 0 ? (
            <div className="book-grid">
              <div>
          <div className="earn">
            <div className="earn-head">
              <div>
                <div className="k">Your book · expected yield</div>
                <div className="earn-apy">{pct(apy, 2)} <span>APY</span></div>
              </div>
              <div className="earn-split">
                <div><span className="sw ink" />premiums <b>{pct(apyPrem, 2)}</b></div>
                <div><span className="sw green" />savings vault <b>{pct(apyVault, 2)}</b></div>
              </div>
            </div>
            <div className="earn-bar">
              <div className="ink" style={{ width: `${(apyPrem / maxApy) * 100}%` }} />
              <div className="green" style={{ width: `${(apyVault / maxApy) * 100}%` }} />
            </div>
            <div className="earn-grid">
              <div><div className="k">Backing</div><div className="v">{compact(tot.backing)}</div></div>
              <div><div className="k">Premiums</div><div className="v green">+{usd(tot.premiums, 0)}</div></div>
              <div><div className="k">Vault yield</div><div className="v green">+{usd(vaultYield, 0)}</div></div>
              <div><div className="k">Payouts</div><div className="v red">{tot.payouts > 0n ? "−" : ""}{usd(tot.payouts, 0)}</div></div>
              <div><div className="k">Net P&amp;L</div><div className={`v ${net >= 0n ? "green" : "red"}`}>{net >= 0n ? "+" : "−"}{usd(net >= 0n ? net : -net, 0)}</div></div>
            </div>
            <div className="pnl-note" style={{ marginTop: 10 }}>
              Premium APY annualizes the premiums of live policies over your reserve. The vault leg is the savings rate the reserve
              earns while it backs cover — withdrawn just-in-time only when a payout fires. Loss ratio{" "}
              <b>{tot.premiums > 0n ? `${((wad(tot.payouts) / wad(tot.premiums)) * 100).toFixed(0)}%` : "—"}</b>.
            </div>
          </div>

              </div>
              <div>
          <table className="dtable">
            <thead>
              <tr><th>Market</th><th>Reserve</th><th className="num">Backing</th><th className="num">APY</th><th className="num">P&amp;L</th><th /></tr>
            </thead>
            <tbody>
              {mine.map((m) => {
                const pnl = m.premiums - m.payouts + (m.inVault ? vaultYield : 0n);
                const mApy = m.premiumApyBps + (m.inVault ? state.vault?.aprBps ?? 0 : 0);
                return (
                  <tr key={m.hash}>
                    <td>{META[m.product].name}{m.docked && <span className="pill" style={{ marginLeft: 6 }}>closed</span>}</td>
                    <td>{m.inVault ? "savings vault" : "wallet"}</td>
                    <td className="num">{m.docked ? "—" : compact(m.backing)}</td>
                    <td className="num">{pct(mApy, 2)}</td>
                    <td className="num"><b style={{ color: pnl >= 0n ? "var(--green)" : "var(--red)" }}>{pnl >= 0n ? "+" : "−"}{usd(pnl >= 0n ? pnl : -pnl, 0)}</b></td>
                    <td className="num">
                      {!m.docked && eq(m.underwriter, account) && (
                        <button className="btn btn-sm btn-ghost" disabled={!!busy} onClick={() => close(m)} title={m.covered > 0n ? "Cover still outstanding" : "Withdraw: clear the Aqua balance"}>
                          Close
                        </button>
                      )}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
              </div>
            </div>
          ) : (
            <div className="empty-state">
              <div className="empty-big">No markets yet</div>
              <p>
                Ship a USDG reserve through Aqua — it never leaves your wallet — and publish your own risk curve. You earn premiums
                on every policy sold against it, and (with a YieldReserve) the savings-vault rate on top. Switch to the Underwriter
                account to see the genesis book.
              </p>
            </div>
          )}
        </div>
      </div>

      <div className="row2">
        <div className="pnl col">
          <div className="pnl-head">
            <span className="pnl-title"><span className="n">01</span>Open a depeg market</span>
            <span className="pill">your reserve</span>
          </div>
          <div className="pnl-body grow">
      <div className="field">
        <label><span>Reserve</span><span>wallet {usd(state.usdgBalance, 0)} USDG</span></label>
        <div className="amt">
          <input value={reserve} onChange={(e) => setReserve(e.target.value.replace(/[^0-9.]/g, ""))} inputMode="decimal" />
          <span className="unit">USDG</span>
        </div>
      </div>
      <div className="field">
        <label><span>Trigger band</span><span>pays at ≤ ${(1 - band / 10_000).toFixed(3)}</span></label>
        <div className="chips">
          {[100, 300, 500].map((b) => (
            <button key={b} className={`chip ${band === b ? "on" : ""}`} onClick={() => setBand(b)}>−{b / 100}%</button>
          ))}
        </div>
      </div>
      <div className="field">
        <label><span>Solvency floor</span><span>sell up to {util / 100}% of backing</span></label>
        <div className="chips">
          {[5000, 8000, 9500].map((u) => (
            <button key={u} className={`chip ${util === u ? "on" : ""}`} onClick={() => setUtil(u)}>{u / 100}%</button>
          ))}
        </div>
      </div>
      <div className="actions">
        <button className="btn btn-primary" disabled={!account || !!busy} onClick={open}>Ship reserve + open market →</button>
      </div>
      <div className="pnl-note">
        Your USDG never leaves your wallet: Aqua records a virtual balance that CoverApp can only pull from on a valid payout.
        Premiums land in your wallet as policies are sold, priced on the curve you set (u = share of capacity already sold).
      </div>
          </div>
        </div>
        <div className="pnl col">
          <div className="pnl-head">
            <span className="pnl-title"><span className="n">02</span>Your risk curve</span>
            <span className="pill">drag the endpoints</span>
          </div>
          <div className="pnl-body grow">
        <div className="curve-box editor">
          <div className="curve-box-head">
            <span>rate = start + (end − start) · u<sup>k</sup></span>
            <span><b>{(curve.start * 100).toFixed(1)}% → {(curve.end * 100).toFixed(1)}%</b> · k {curve.k.toFixed(2)}</span>
          </div>
          <RiskCurveChart curve={curve} onChange={setCurve} yMax={0.2} ghosts={PRESETS.filter((p) => p.c !== curve).map((p) => p.c)} />
          <div className="curve-ctrl">
            <div>
              <label><span>Start rate</span><b>{(curve.start * 100).toFixed(1)}%</b></label>
              <input type="range" min={0} max={0.2} step={0.001} value={curve.start} onChange={(e) => setCurve({ ...curve, start: Math.min(Number(e.target.value), curve.end) })} />
            </div>
            <div>
              <label><span>End rate</span><b>{(curve.end * 100).toFixed(1)}%</b></label>
              <input type="range" min={0} max={0.2} step={0.001} value={curve.end} onChange={(e) => setCurve({ ...curve, end: Math.max(Number(e.target.value), curve.start) })} />
            </div>
            <div>
              <label><span>Curve shape</span><b>{curve.k.toFixed(2)}</b></label>
              <input type="range" min={0.25} max={5} step={0.05} value={curve.k} onChange={(e) => setCurve({ ...curve, k: Number(e.target.value) })} />
            </div>
          </div>
          <div className="curve-presets">
            {PRESETS.map((p) => (
              <button key={p.label} title={p.hint} className={`chip ${curve === p.c ? "on" : ""}`} onClick={() => setCurve(p.c)}>{p.label}</button>
            ))}
          </div>
        </div>
          </div>
        </div>
      </div>
    </>
  );
}

/* =====================================================================
   keeper
   ===================================================================== */

function KeeperPanel({ state, busy, onRound, onExpire }: {
  state: St; busy: string | null; onRound: () => void; onExpire: (p: Policy) => void;
}) {
  const open = state.policies.filter((p) => !p.settled);
  const due = open.filter((p) => p.due !== null && state.now <= p.expiry);
  const lapsed = open.filter((p) => state.now > p.expiry);
  return (
    <>
      <div className="keeper-hero">
        <Logo className="keeper-mark" />
        <div>
          <div className="pnl-title">Payouts happen automatically</div>
          <div className="pnl-note" style={{ border: "none", padding: 0, margin: "6px 0 0" }}>
            A permissionless bot watches every open policy. The moment a trigger fires it calls <code>payout()</code> and the USDG goes to
            the note holder — nobody has to claim. It also settles lapsed policies so capacity is recycled. Anyone can run it (
            <code>node scripts/keeper.mjs</code>), or fire a round from this browser:
          </div>
        </div>
      </div>
      <div className="actions" style={{ margin: "14px 0 18px" }}>
        <button className="btn btn-primary" disabled={!!busy} onClick={onRound}>
          Run a keeper round ({due.length} due · {lapsed.length} lapsed) →
        </button>
      </div>
      {open.length === 0 ? (
        <div className="empty">no open policies</div>
      ) : (
        <table className="dtable">
          <thead>
            <tr><th>#</th><th>Product</th><th>Holder</th><th className="num">Cover</th><th>Status</th><th /></tr>
          </thead>
          <tbody>
            {open.map((p) => {
              const st = status(p, state.now);
              const m = state.markets.find((x) => x.hash === p.market);
              return (
                <tr key={String(p.id)}>
                  <td>{String(p.id)}</td>
                  <td>{m ? META[m.product].tag : "—"}</td>
                  <td>{short(p.holder)}</td>
                  <td className="num">{usd(p.notional, 0)}</td>
                  <td><span className={`pill ${st.cls}`}>{st.label}</span></td>
                  <td className="num">
                    {st.k === "expired" && (
                      <button className="btn btn-sm btn-ghost" disabled={!!busy} onClick={() => onExpire(p)}>Settle</button>
                    )}
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      )}
    </>
  );
}
