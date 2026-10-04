# Airbag — deployments

## Arbitrum Sepolia (421614) — v2 (2026-09-28)

Deployed with `script/DeployDemo.s.sol` + `script/AddMarketplace.s.sol`. Deployer / genesis underwriter `0x204a73e8303F3d09B12062dEdAA74B1CDA6E167d`.

**Verification:** all 13 contracts are verified on **Sourcify (exact match)** (`VERIFIER=sourcify ./verify-sepolia.sh`); Arbiscan submissions are queued (`./verify-sepolia.sh` re-checks).

| Contract | Address | Notes |
|---|---|---|
| CoverApp | [`0xFc0684F87919be2aFfD4c8864D33e51e8E66D78A`](https://sepolia.arbiscan.io/address/0xFc0684F87919be2aFfD4c8864D33e51e8E66D78A) | markets, annual-rate premiums, payout / claim / expire |
| CoverRouter | [`0xA6304E024710b06d05AA33F9c4740E6dB854047F`](https://sepolia.arbiscan.io/address/0xA6304E024710b06d05AA33F9c4740E6dB854047F) | marketplace: atomic multi-underwriter routes |
| CoverNote | [`0x486f724f8320219918F5089F7FB4a27af24AE5cb`](https://sepolia.arbiscan.io/address/0x486f724f8320219918F5089F7FB4a27af24AE5cb) | ERC-6909 policy notes (holderOf → auto-payout) |
| ILTrigger | [`0x75390487FF8218A0Bf120B503D352CdF211d5a2A`](https://sepolia.arbiscan.io/address/0x75390487FF8218A0Bf120B503D352CdF211d5a2A) | Uniswap v4 LP-loss payouts |
| PriceGapTrigger | [`0x00cF0DD325070E60380917ECc98Be856ac93fc64`](https://sepolia.arbiscan.io/address/0x00cF0DD325070E60380917ECc98Be856ac93fc64) | stock gap-down payouts |
| CoverHook (Uniswap v4) | [`0xc72F5F6d244Fb43B070C2BF8dA15e2DF86f04ac0`](https://sepolia.arbiscan.io/address/0xc72F5F6d244Fb43B070C2BF8dA15e2DF86f04ac0) | LP entry/exit, IL math, block-open tick guard |
| v4 PoolManager (Uniswap, official) | [`0xFB3e0C6F74eB1a21CC1Da29aeC80D2Dfe6C9a317`](https://sepolia.arbiscan.io/address/0xFB3e0C6F74eB1a21CC1Da29aeC80D2Dfe6C9a317) | Arbitrum Sepolia deployment |
| Aqua (1inch, unmodified copy) | [`0xe94b3Af2Bf8f43B76033C439e5b5b4F4144bB993`](https://sepolia.arbiscan.io/address/0xe94b3Af2Bf8f43B76033C439e5b5b4F4144bB993) | 1inch hasn't deployed Aqua on Arb Sepolia — canonical 0x4999…6d31 is on Arbitrum One |
| YieldReserve | [`0x8f27ab5c57dcBd4faD7031cC94767e3C8dd3F708`](https://sepolia.arbiscan.io/address/0x8f27ab5c57dcBd4faD7031cC94767e3C8dd3F708) | genesis depeg maker: reserve earns vault yield, JIT withdraw on payout |
| Savings vault (demo, 4.5% APR) | [`0x5C6d9d18ec0D64D5915a53f814F680B319CCB249`](https://sepolia.arbiscan.io/address/0x5C6d9d18ec0D64D5915a53f814F680B319CCB249) | DripVault |
| USDG (demo, mintable) | [`0xBF45D57C483b66B00500977C58A909aaC6B703f9`](https://sepolia.arbiscan.io/address/0xBF45D57C483b66B00500977C58A909aaC6B703f9) | test USDG |
| USDG/USD feed (demo) | [`0xEc4891565e3a046D6d12080A902885003fd2304D`](https://sepolia.arbiscan.io/address/0xEc4891565e3a046D6d12080A902885003fd2304D) | settable |
| TSLAx/USD feed (demo) | [`0x1927D42D90e2FA653E82cDe95842bBbCbBF0Bc0C`](https://sepolia.arbiscan.io/address/0x1927D42D90e2FA653E82cDe95842bBbCbBF0Bc0C) | settable |
| wstETH/WETH LP router | [`0x0534fcA33D3bf12538dC3C2c6950De00528bD57A`](https://sepolia.arbiscan.io/address/0x0534fcA33D3bf12538dC3C2c6950De00528bD57A) | IMsgSender router (like PositionManager) |
| v4 swap router (test) | [`0x148f42b26016032736e2b465c02765abd14783cE`](https://sepolia.arbiscan.io/address/0x148f42b26016032736e2b465c02765abd14783cE) | used by the depeg-shock button |

| Market | strategyHash |
|---|---|
| USDG depeg — genesis (reserve in savings vault, 1%→10%/yr) | `0x60e5e1db04b822ca3400a83c2006c039db9a1398ec1518070b9fc03d5c317604` |
| USDG depeg — underwriter B (0.6%→14%/yr, k 2.5, 400k) | see `CoverApp.marketList(3)` |
| USDG depeg — underwriter C (1.5%→6%/yr, k 1, 600k) | see `CoverApp.marketList(4)` |
| Uniswap v4 LP loss (wstETH/WETH) | `0xe72813234647df783c49ffa145809abf02fb53d6a3e60dfb658574e14b7a70ed` |
| TSLAx gap-down | `0x895e3716cd58fd87c2bd28a2eaf59227a2e6def27bc93c47790aa8d73599b02c` |

v4 pool id `0x9afa1fd16c1e2f23aba6dafd968e004d0e16fd6001cb310af989b617d67071be`.

Seeded book: 4 policies from 3 throwaway wallets; underwriters B and C are throwaway wallets too (all derived from the deployer key and funded with a little gas).

**v1** (same day, superseded): premiums were per-policy regardless of term; v2 prices them as annual rates × term. v1 addresses are in `/tmp/airbag-demo/deployment.421614.v1.json` locally.

**Honest notes:** USDG, the two price feeds and the savings vault are demo stand-ins on testnet. Aqua is 1inch's unmodified contract, deployed by us because it isn't on Arbitrum Sepolia.

## Keeper

```bash
nohup ./keeper-sepolia.sh > /tmp/airbag-demo/keeper-sepolia.log 2>&1 &
```
Reads `PRIVATE_KEY` from `.env`, restarts on crashes; `DEMO_FEED=1` keeps the demo price feeds fresh like a live oracle.
