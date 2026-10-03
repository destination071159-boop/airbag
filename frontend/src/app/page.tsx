import TileBackground from "@/components/TileBackground";
import SectionNav from "@/components/SectionNav";
import Navbar from "@/components/Navbar";
import AirbagDemo from "@/components/AirbagDemo";

/* ---------- content ---------- */

const STEPS = [
  {
    no: "01",
    title: "Underwriter ships a reserve. It never leaves their wallet.",
    body: (
      <>
        An underwriter commits USDG to a cover market through 1inch Aqua. Aqua records a{" "}
        <b>virtual balance</b> — the tokens stay in the underwriter&apos;s own wallet, free to sit in
        a vault and earn yield. No pool, no custody, no TVL honeypot.
      </>
    ),
    mech: (
      <>
        <em>aqua.ship()</em> → <em>CoverApp.registerMarket()</em> · reserve authenticated on-chain
      </>
    ),
  },
  {
    no: "02",
    title: "Buyers pay a risk-curve premium. They get a note.",
    body: (
      <>
        Premium is priced on a <b>utilization curve</b> — the fuller the book, the pricier the cover.
        It&apos;s pushed straight into the underwriter&apos;s reserve, and the buyer receives an
        ERC-6909 <b>CoverNote</b>: transferable, so cover can be sold or assigned.
      </>
    ),
    mech: (
      <>
        <em>quotePremium()</em> → <em>buyPolicy()</em> → aqua.push(premium) · note minted
      </>
    ),
  },
  {
    no: "03",
    title: "The peg breaks. The airbag deploys — by itself.",
    body: (
      <>
        The moment the trigger fires, a permissionless <b>keeper</b> calls <b>payout</b> and the USDG lands in
        whoever holds the note — pulled straight from the underwriter&apos;s reserve in one transaction. The
        insured doesn&apos;t even need to be online. No claim form, no committee, no waiting period.
      </>
    ),
    mech: (
      <>
        trigger fires → keeper <em>payout()</em> → <em>aqua.pull()</em> → note holder · note burned
      </>
    ),
  },
  {
    no: "04",
    title: "Nothing happens. The underwriter keeps the premium.",
    body: (
      <>
        Policies that lapse are settled by anyone — a keeper, the underwriter — which{" "}
        <b>frees the capacity</b> for the next buyer. The underwriter&apos;s P&amp;L is simply premiums
        earned minus payouts made, and it&apos;s verifiable on-chain at every block.
      </>
    ),
    mech: (
      <>
        <em>expire()</em> → capacity recycled · <em>aqua.dock()</em> to close the market
      </>
    ),
  },
];

const PRODUCTS = [
  { k: "live · 01", t: "USDG depeg cover", p: "Oracle band trigger (Chainlink / Pyth adapters with staleness checks). Pays 100% of notional — pushed automatically." },
  { k: "live · 03", t: "Tokenized-stock gap cover", p: "Proportional payout when a tokenized stock gaps down — pays by how far it fell below the strike, not all-or-nothing." },
  { k: "reserve", t: "Tranched reserve", p: "Junior first-loss / senior-protected waterfall. Two risk appetites, one reserve." },
  { k: "reserve", t: "Yield reserve", p: "The reserve earns savings-vault yield while it backs cover, withdrawn just-in-time only when a payout fires. Underwriters stack premium + vault APY." },
  { k: "live · marketplace", t: "Underwriters compete", p: "Every underwriter publishes their own risk curve; the CoverRouter splits each order across the cheapest ones in one atomic transaction." },
  { k: "live · 02", t: "Uniswap v4 LP-loss cover", p: "CoverHook measures an LP's real IL on a v4 pool; ILTrigger pays it out through the same claim — with a deductible, a cap, and a same-block manipulation guard." },
];

const STACK = [
  { k: "reserve rail", v: "1inch Aqua", p: "Shared-liquidity virtual balances: capital stays in the maker's wallet." },
  { k: "asset", v: "USDG", p: "Paxos-issued, regulated stablecoin — cover denominated and settled in USDG." },
  { k: "trigger / LP", v: "Uniswap v4", p: "Optional hook for LP impermanent-loss cover on v4 pools." },
  { k: "chain", v: "Arbitrum", p: "Cheap enough to make per-policy notes and permissionless expiry practical." },
];

export default function Home() {
  return (
    <>
      <TileBackground still />
      <Navbar />
      <SectionNav />

      <header className="hero" id="top">
        <div className="hero-scrim" aria-hidden />
        <div className="container hero-grid">
          <div className="hero-text">
            <span className="hero-tag">Parametric depeg cover · 1inch Aqua · Arbitrum</span>
            <h1>
              Depeg cover
              <br />
              that deploys
              <br />
              itself<span className="dot">.</span>
            </h1>
            <p className="lede">
              Airbag is <b>parametric, provably-solvent cover</b> for USDG. Underwriters back it from
              their own wallets through <b>1inch Aqua</b>; buyers hold a transferable note. When the
              price breaks the band, the payout fires <span className="u">automatically</span>, in one
              transaction — <b>no claims desk, no custody</b>.
            </p>
            <div className="cta-row">
              <a className="btn btn-primary" href="/app">Open console →</a>
              <a className="btn btn-ghost" href="#how">How it works ↓</a>
              <a className="btn btn-ghost" href="/integrate">Integrate ↗</a>
            </div>
            <div className="hero-foot">
              <span>non-custodial</span>
              <span className="sep">/</span>
              <span>auto-payout</span>
              <span className="sep">/</span>
              <span>solvency on-chain</span>
              <span className="sep">/</span>
              <span>transferable cover</span>
            </div>
          </div>
          <div className="hero-visual">
            <AirbagDemo />
          </div>
        </div>
      </header>

      <section className="section" id="why">
        <div className="container">
          <div className="panel">
            <span className="kicker">// why now</span>
            <h2 className="sec-title">0x00 Stablecoins are money now. Nobody insures them.</h2>
            <p className="sec-intro">
              Regulated stablecoins like <b>USDG</b> are moving into payments, payroll and treasuries — and a peg is only as strong as the
              bank the reserves sit in. When it wobbles, holders have nowhere to go: on-chain cover barely exists, and what does exist
              pays out after committee votes and waiting periods.
            </p>
            <div className="why">
              <div className="why-tile">
                <div className="why-v red">$0.87</div>
                <div className="why-k">USDC, 11 Mar 2023</div>
                <p>Circle disclosed $3.3B of reserves stuck at Silicon Valley Bank; the &ldquo;safest&rdquo; stablecoin lost 13% overnight and took ~3 days to recover.</p>
                <a href="https://www.cnbc.com/2023/03/11/stablecoin-usdc-breaks-dollar-peg-after-firm-reveals-it-has-3point3-billion-in-svb-exposure.html" target="_blank" rel="noreferrer">CNBC ↗</a>
              </div>
              <div className="why-tile">
                <div className="why-v">&lt; 2%</div>
                <div className="why-k">of DeFi TVL is insured</div>
                <p>On-chain insurance capital is in the hundreds of millions against ~$100B of TVL — over 98% of deposits are naked.</p>
                <a href="https://bex.co/blog/2026/05/03/defi-insurance-450m-q1-hacks-coverage-gap" target="_blank" rel="noreferrer">bex.co ↗</a>
              </div>
              <div className="why-tile">
                <div className="why-v">MAS · MiCA</div>
                <div className="why-k">USDG is regulated money</div>
                <p>Paxos&apos; Global Dollar is issued under Singapore&apos;s MAS framework and the EU&apos;s MiCA — the kind of dollar businesses actually hold.</p>
                <a href="https://www.coingecko.com/en/coins/global-dollar" target="_blank" rel="noreferrer">CoinGecko ↗</a>
              </div>
              <div className="why-tile">
                <div className="why-v green">1 block</div>
                <div className="why-k">Airbag payout time</div>
                <p>Parametric trigger + keeper: the payout lands in the holder&apos;s wallet in the same block the price breaks the band. No claim at all.</p>
                <a href="/app">try it ↗</a>
              </div>
            </div>
          </div>
        </div>
      </section>

      <section className="section" id="how">
        <div className="container">
          <div className="panel">
            <span className="kicker">// lifecycle</span>
            <h2 className="sec-title">0x01 From reserve to payout. Four calls.</h2>
            <p className="sec-intro">
              The whole protocol, start to finish — covered end-to-end by the <b>Lifecycle</b> test suite
              against the real Aqua contract.
            </p>
            <div className="steps">
              {STEPS.map((s) => (
                <div className="step" key={s.no}>
                  <div className="step-no">{s.no}</div>
                  <div>
                    <h3>{s.title}</h3>
                    <p>{s.body}</p>
                  </div>
                  <div className="mech">{s.mech}</div>
                </div>
              ))}
            </div>
          </div>
        </div>
      </section>

      <section className="section" id="solvency">
        <div className="container">
          <div className="panel">
            <span className="kicker">// solvency</span>
            <h2 className="sec-title">0x02 It can&apos;t sell cover it can&apos;t pay.</h2>
            <p className="sec-intro">
              Every market enforces a <b>solvency floor</b>: outstanding cover can never exceed a fixed
              share of the reserve. Try to oversell and the transaction reverts. Anyone can read{" "}
              <b>solvency()</b> and check the backing at any block.
            </p>
            <div className="meter-wrap">
              <div className="meter">
                <div className="pnl-title">example market</div>
                <div className="meter-bar">
                  <div className="meter-fill" style={{ width: "58%" }} />
                  <div className="meter-floor" style={{ left: "80%" }}>
                    <span>floor 80%</span>
                  </div>
                </div>
                <div className="meter-legend">
                  <span>covered 580k</span>
                  <span>backing 1.0M USDG</span>
                </div>
              </div>
              <div className="meter eq">
                <div>
                  backing <b>= reserve + premiums − payouts</b>
                </div>
                <div>
                  outstanding <b>≤ backing × maxUtil</b>
                </div>
                <div>
                  aqua balance <b>== underwriter wallet</b> <span className="ok">✓ asserted in tests</span>
                </div>
                <div>
                  invariant fuzz <b>8,192 random buys × 128 runs</b> <span className="ok">✓ never over capacity</span>
                </div>
              </div>
            </div>
          </div>
        </div>
      </section>

      <section className="section" id="products">
        <div className="container">
          <div className="panel">
            <span className="kicker">// products</span>
            <h2 className="sec-title">0x03 One engine. Pluggable cover.</h2>
            <p className="sec-intro">
              The core <b>CoverApp</b> handles reserves, pricing, notes and payouts. What counts as an
              &quot;event&quot; is a plug-in: the built-in depeg band, or any contract implementing{" "}
              <b>ITrigger</b>.
            </p>
            <div className="cards">
              {PRODUCTS.map((c) => (
                <div className="card" key={c.t}>
                  <div className="card-k">{c.k}</div>
                  <h3>{c.t}</h3>
                  <p>{c.p}</p>
                </div>
              ))}
            </div>
          </div>
        </div>
      </section>

      <section className="section" id="stack">
        <div className="container">
          <div className="panel">
            <span className="kicker">// stack</span>
            <h2 className="sec-title">0x04 Built on rails that already exist.</h2>
            <p className="sec-intro">No new token, no new pool. Airbag composes infrastructure that&apos;s already live.</p>
            <div className="stack">
              {STACK.map((s) => (
                <div key={s.v}>
                  <div className="k">{s.k}</div>
                  <div className="v">{s.v}</div>
                  <p>{s.p}</p>
                </div>
              ))}
            </div>
          </div>
        </div>
      </section>

      <section className="section final" id="final">
        <div className="container">
          <div className="panel">
            <h2>
              Buckle up.
              <br />
              <span className="red">Pegs break.</span>
            </h2>
            <p>Open a market as an underwriter, buy cover as a holder, and watch the airbag deploy when the oracle drops.</p>
            <div className="cta-row">
              <a className="btn btn-primary" href="/app">Open console →</a>
            </div>
          </div>
        </div>
      </section>

      <footer className="footer">
        <div className="container footer-inner">
          <span>Airbag — Arbitrum Open House 2026</span>
          <span>non-custodial · parametric · provably solvent</span>
        </div>
      </footer>
    </>
  );
}
