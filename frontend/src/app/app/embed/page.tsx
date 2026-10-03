"use client";

import { Suspense, useEffect, useMemo, useState } from "react";
import { useSearchParams } from "next/navigation";
import { useAccount, useConnect, usePublicClient, useWriteContract } from "wagmi";
import { formatUnits, parseEventLogs, parseUnits } from "viem";
import Logo from "@/components/Logo";
import { coverAppAbi, erc20Abi, routerAbi } from "@/lib/abis";
import { DEPLOYMENT as D, IS_LOCAL } from "@/lib/wagmi";
import { useAirbag } from "@/lib/useAirbag";
import { useWallet } from "@/components/WalletButton";
import { solveRoute } from "@/lib/route";

/**
 * "Protect this balance" — the Airbag checkout widget. Any wallet, DEX or RWA app embeds it:
 *   <iframe src="https://<airbag>/app/embed?amount=25000&partner=YourApp" width="380" height="460" />
 * The user buys depeg cover for exactly the balance they hold, routed to the cheapest underwriters,
 * and the payout is pushed to their wallet automatically if the peg breaks.
 */
const ZERO = "0x0000000000000000000000000000000000000000";
const TERMS = [
  { label: "7 days", s: 7 * 86400 },
  { label: "30 days", s: 30 * 86400 },
];
const usd = (x: bigint, dp = 2) =>
  Number(formatUnits(x, 18)).toLocaleString("en-US", { minimumFractionDigits: dp, maximumFractionDigits: dp });

function Widget() {
  const q = useSearchParams();
  const amount = q.get("amount") ?? "10000";
  const partner = q.get("partner") ?? "your wallet";
  const { address, isConnected } = useAccount();
  const { connectAsync, connectors } = useConnect();
  const client = usePublicClient();
  const { writeContractAsync } = useWriteContract();
  const s = useAirbag(address);
  const wallet = useWallet();

  const [term, setTerm] = useState(TERMS[0].s);
  const [quote, setQuote] = useState<bigint | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [done, setDone] = useState<bigint[] | null>(null);
  const [err, setErr] = useState<string | null>(null);

  const notional = useMemo(() => {
    try {
      return parseUnits(amount.replace(/[^0-9.]/g, "") || "0", 18);
    } catch {
      return 0n;
    }
  }, [amount]);
  const book = s.markets.filter((m) => !m.docked && m.product === "depeg");
  const routed = book.length > 1 && !!D.coverRouter && D.coverRouter !== ZERO;
  const route = useMemo(
    () => (notional > 0n && book.length ? solveRoute(book, Number(formatUnits(notional, 18))) : null),
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [notional, book.map((m) => `${m.hash}:${m.covered}`).join("|")]
  );
  const legs = useMemo(
    () => (route ?? []).map((l) => ({ strategyHash: l.market.hash, coverNotional: parseUnits(l.notional.toFixed(6), 18) })),
    [route]
  );

  useEffect(() => {
    if (!client || legs.length === 0) return;
    const p = routed
      ? client.readContract({ address: D.coverRouter!, abi: routerAbi, functionName: "quoteRouteFor", args: [legs, BigInt(term)] }).then((r) => r[1])
      : client.readContract({ address: D.coverApp, abi: coverAppAbi, functionName: "quotePremiumFor", args: [legs[0].strategyHash, legs[0].coverNotional, BigInt(term)] });
    p.then(setQuote).catch(() => setQuote(null));
  }, [client, legs, routed, term]);

  const trigger = book[0] ? (Number(book[0].pegPrice) * (10_000 - book[0].depegBps)) / 1e12 : 0.97;
  const days = term / 86400;
  const annual = quote && notional > 0n ? (Number(quote) / Number(notional)) * (365 / days) * 100 : 0;

  async function tx(label: string, fn: () => Promise<`0x${string}`>) {
    setBusy(label);
    const hash = await fn();
    const r = await client!.waitForTransactionReceipt({ hash });
    return r;
  }

  async function protect() {
    if (!address || quote === null) return;
    setErr(null);
    try {
      if (s.usdgBalance < quote) {
        await tx("Getting test USDG", () => writeContractAsync({ address: D.usdg, abi: erc20Abi, functionName: "mint", args: [address, notional] }));
      }
      const spender = routed ? D.coverRouter! : D.coverApp;
      const cap = (quote * 101n) / 100n;
      const allowance = await client!.readContract({ address: D.usdg, abi: erc20Abi, functionName: "allowance", args: [address, spender] });
      if (allowance < cap) {
        await tx("Approving USDG", () => writeContractAsync({ address: D.usdg, abi: erc20Abi, functionName: "approve", args: [spender, 2n ** 255n] }));
      }
      const r = routed
        ? await tx("Buying cover", () =>
            writeContractAsync({
              address: D.coverRouter!, abi: routerAbi, functionName: "buyRoute",
              args: [legs, D.usdg, cap, BigInt(term), address, BigInt(Math.floor(Date.now() / 1000) + 900)],
            }))
        : await tx("Buying cover", () =>
            writeContractAsync({ address: D.coverApp, abi: coverAppAbi, functionName: "buyPolicy", args: [legs[0].strategyHash, notional, BigInt(term)] }));
      setDone(parseEventLogs({ abi: coverAppAbi, eventName: "PolicyBought", logs: r.logs }).map((e) => e.args.policyId));
    } catch (e) {
      const x = e as { shortMessage?: string; message?: string };
      setErr(x.shortMessage ?? x.message?.split("\n")[0] ?? "failed");
    } finally {
      setBusy(null);
    }
  }

  return (
    <div className="embed">
      <div className="embed-head">
        <Logo className="embed-mark" />
        <div>
          <div className="embed-brand">Airbag</div>
          <div className="embed-sub">depeg cover · in {partner}</div>
        </div>
      </div>

      {done ? (
        <div className="embed-done">
          <div className="embed-big">Protected ✓</div>
          <p>
            <b>{usd(notional, 0)} USDG</b> is covered for {days} days (policy{done.length > 1 ? "s" : ""} #{done.join(", #")}). If USDG
            trades at or below ${trigger.toFixed(2)}, the payout lands in your wallet automatically — no claim.
          </p>
        </div>
      ) : (
        <>
          <div className="embed-title">
            Protect your <b>{usd(notional, 0)} USDG</b> against a depeg
          </div>
          <div className="chips" style={{ margin: "12px 0" }}>
            {TERMS.map((t) => (
              <button key={t.s} className={`chip ${term === t.s ? "on" : ""}`} onClick={() => setTerm(t.s)}>{t.label}</button>
            ))}
          </div>
          <div className="quote" style={{ margin: "0 0 14px" }}>
            <div className="quote-row"><span>You pay</span><b className="big">{quote !== null ? `${usd(quote)} USDG` : "—"}</b></div>
            <div className="quote-row"><span>Pays out</span><b>{usd(notional, 0)} USDG if ≤ ${trigger.toFixed(2)}</b></div>
            <div className="quote-row"><span>≈ annualized</span><b>{annual ? `${annual.toFixed(2)}%` : "—"}</b></div>
            <div className="quote-row"><span>Underwriters</span><b>{legs.length || "—"} of {book.length} (best price)</b></div>
          </div>
          {IS_LOCAL && !isConnected ? (
            <button className="btn btn-primary embed-cta" onClick={() => connectAsync({ connector: connectors[0] }).catch(() => undefined)}>
              Use demo wallet →
            </button>
          ) : !IS_LOCAL && wallet.state !== "ready" ? (
            <button className="btn btn-primary embed-cta" onClick={wallet.act}>
              {wallet.label} →
            </button>
          ) : (
            <button className="btn btn-primary embed-cta" disabled={!!busy || quote === null || !route} onClick={protect}>
              {busy ? `${busy}…` : `Protect for ${quote !== null ? usd(quote) : "…"} USDG →`}
            </button>
          )}
          {wallet.error && <div className="embed-err">{wallet.error}</div>}
          {err && <div className="embed-err">{err}</div>}
        </>
      )}
      <div className="embed-foot">non-custodial · auto-payout · provably solvent</div>
    </div>
  );
}

export default function EmbedPage() {
  return (
    <Suspense fallback={null}>
      <Widget />
    </Suspense>
  );
}
