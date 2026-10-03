import Navbar from "@/components/Navbar";
import TileBackground from "@/components/TileBackground";

export const metadata = {
  title: "Integrate — Airbag",
  description: "Embed depeg cover in any wallet, DEX or RWA app: one iframe, or one contract call.",
};

const IFRAME = `<iframe
  src="https://YOUR-AIRBAG-HOST/app/embed?amount=25000&partner=YourApp"
  width="380" height="470" style="border:0"></iframe>`;

const SOLIDITY = `// sell cover inside your own flow (e.g. a USDG deposit or an RWA purchase)
IERC20(USDG).approve(address(coverApp), maxPremium);
uint256 premium  = coverApp.quotePremium(market, amount);
uint256 policyId = coverApp.buyPolicyFor(market, amount, 7 days, user);
// the note (ERC-6909) goes to \`user\`; if the peg breaks, the keeper pushes the payout to them`;

const ROUTER = `// best price across every underwriter, atomically, with a premium cap
router.buyRoute(legs, USDG, maxTotalPremium, 30 days, user, deadline);`;

export default function Integrate() {
  return (
    <>
      <TileBackground opacity={0.5} still />
      <Navbar />
      <main className="console">
        <div className="container">
          <span className="kicker">// distribution</span>
          <h1 className="console-title">Put an airbag in any app.</h1>
          <p className="sec-intro" style={{ maxWidth: 760 }}>
            People don&apos;t go looking for insurance — they buy it at checkout. Airbag is built to be sold <b>inside</b> the apps
            where stablecoins and tokenized assets already live: wallets, DEXs, RWA platforms, payroll and treasury tools. Partners
            embed one widget or make one contract call; underwriters compete on price behind it.
          </p>
          <div className="grid2">
            <div className="stackv">
              <div className="pnl">
                <div className="pnl-head"><span className="pnl-title"><span className="n">01</span>Drop-in widget</span><span className="pill ok">no code</span></div>
                <div className="pnl-body">
                  <p className="pnl-note" style={{ border: "none", padding: 0, margin: "0 0 12px" }}>
                    Pass the user&apos;s balance as <code>amount</code>. The widget quotes the cheapest route across underwriters, buys
                    the cover, and the payout is pushed automatically if the peg breaks.
                  </p>
                  <pre className="snippet">{IFRAME}</pre>
                </div>
              </div>
              <div className="pnl">
                <div className="pnl-head"><span className="pnl-title"><span className="n">02</span>Contract call</span><span className="pill">solidity</span></div>
                <div className="pnl-body">
                  <pre className="snippet">{SOLIDITY}</pre>
                  <pre className="snippet" style={{ marginTop: 10 }}>{ROUTER}</pre>
                </div>
              </div>
              <div className="pnl">
                <div className="pnl-head"><span className="pnl-title"><span className="n">03</span>Who embeds it</span></div>
                <div className="pnl-body">
                  <div className="cards" style={{ gridTemplateColumns: "1fr 1fr" }}>
                    <div className="card"><div className="card-k">wallets</div><h3>&ldquo;Protect this balance&rdquo;</h3><p>One tap next to a USDG balance.</p></div>
                    <div className="card"><div className="card-k">dexs &amp; lps</div><h3>LP-loss cover</h3><p>Sold at deposit on a v4 pool with the CoverHook.</p></div>
                    <div className="card"><div className="card-k">rwa platforms</div><h3>Gap-down cover</h3><p>Bundled with a tokenized-stock purchase.</p></div>
                    <div className="card"><div className="card-k">treasuries</div><h3>Payroll float</h3><p>Cover the float between funding and payout.</p></div>
                  </div>
                </div>
              </div>
            </div>
            <div className="stackv">
              <div className="pnl">
                <div className="pnl-head"><span className="pnl-title"><span className="n">//</span>Live preview</span><span className="pill warn">real widget</span></div>
                <div className="pnl-body" style={{ display: "flex", justifyContent: "center", background: "var(--bg-sink)" }}>
                  <iframe src="/app/embed?amount=25000&partner=Demo%20Wallet" width={380} height={470} style={{ border: 0 }} title="Airbag widget" />
                </div>
              </div>
            </div>
          </div>
        </div>
      </main>
    </>
  );
}
