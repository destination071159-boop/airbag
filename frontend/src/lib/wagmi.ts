import { createConfig, http } from "wagmi";
import { anvil, arbitrumSepolia } from "wagmi/chains";
import { injected } from "wagmi/connectors/injected";
import { mock } from "wagmi/connectors/mock";
import local from "./deployment.31337.json";
import sepolia from "./deployment.421614.json";

// which deployment the app talks to: NEXT_PUBLIC_NETWORK=local|sepolia
// (default: local in `next dev`, Arbitrum Sepolia in production builds)
const NETWORK = process.env.NEXT_PUBLIC_NETWORK ?? (process.env.NODE_ENV === "development" ? "local" : "sepolia");
const deployment = NETWORK === "local" ? local : sepolia;

export const DEPLOYMENT = deployment as {
  chainId: number;
  startBlock: number;
  aqua: `0x${string}`;
  usdg: `0x${string}`;
  oracle: `0x${string}`;
  coverApp: `0x${string}`;
  coverNote: `0x${string}`;
  underwriter: `0x${string}`;
  market: `0x${string}`;
  gapMarket?: `0x${string}`;
  coverRouter?: `0x${string}`;
  ilMarket?: `0x${string}`;
  ilTrigger?: `0x${string}`;
  gapTrigger?: `0x${string}`;
  stockOracle?: `0x${string}`;
  vault?: `0x${string}`;
  yieldReserve?: `0x${string}`;
  hook?: `0x${string}`;
  lpRouter?: `0x${string}`;
  swapper?: `0x${string}`;
  token0?: `0x${string}`;
  token1?: `0x${string}`;
  token0Symbol?: string;
  token1Symbol?: string;
  poolId?: `0x${string}`;
};

export const POOL_KEY = DEPLOYMENT.token0
  ? {
      currency0: DEPLOYMENT.token0,
      currency1: DEPLOYMENT.token1!,
      fee: 3000,
      tickSpacing: 60,
      hooks: DEPLOYMENT.hook!,
    }
  : null;

export const IS_LOCAL = DEPLOYMENT.chainId === anvil.id;
export const CHAIN = IS_LOCAL ? anvil : arbitrumSepolia;

// Anvil's well-known dev accounts (unlocked on the node, so no keys live here):
// #0 deployed + underwrites the seeded market, #1 plays the cover buyer.
export const DEV_ACCOUNTS = [
  { label: "Buyer (anvil #1)", address: "0x70997970C51812dc3A010C7d01b50e0d17dc79C8" },
  { label: "Underwriter (anvil #0)", address: "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266" },
] as const;

export const config = IS_LOCAL
  ? createConfig({
      chains: [anvil],
      connectors: [
        ...DEV_ACCOUNTS.map((a) => mock({ accounts: [a.address], features: { reconnect: true } })),
        injected(),
      ],
      transports: { [anvil.id]: http("http://127.0.0.1:8545", { batch: true }) },
      ssr: true,
    })
  : createConfig({
      chains: [arbitrumSepolia],
      connectors: [injected()],
      transports: { [arbitrumSepolia.id]: http(process.env.NEXT_PUBLIC_RPC_URL || undefined, { batch: true }) },
      ssr: true,
    });

export function explorerTx(hash: string) {
  return IS_LOCAL ? null : `https://sepolia.arbiscan.io/tx/${hash}`;
}
