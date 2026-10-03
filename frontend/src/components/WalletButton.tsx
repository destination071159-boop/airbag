"use client";

import { useEffect, useState } from "react";
import { useAccount, useConnect, useDisconnect, useSwitchChain } from "wagmi";
import { CHAIN } from "@/lib/wagmi";

const short = (a: string) => `${a.slice(0, 6)}…${a.slice(-4)}`;

/**
 * Real-wallet state machine shared by the console and the checkout widget:
 * no wallet installed → "Get MetaMask" · not connected → "Connect wallet" ·
 * wrong network → "Switch to Arbitrum Sepolia" · ready → address.
 */
export function useWallet() {
  const { address, isConnected, chainId, connector } = useAccount();
  const { connectAsync, connectors } = useConnect();
  const { disconnectAsync } = useDisconnect();
  const { switchChainAsync } = useSwitchChain();
  const [hasProvider, setHasProvider] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    setHasProvider(typeof window !== "undefined" && !!(window as unknown as { ethereum?: unknown }).ethereum);
  }, []);

  const injected = connectors.find((c) => c.type === "injected");
  const viaWallet = isConnected && connector?.type === "injected";
  const wrongChain = viaWallet && chainId !== CHAIN.id;

  const state: "install" | "connect" | "switch" | "ready" = !hasProvider
    ? "install"
    : !viaWallet
      ? "connect"
      : wrongChain
        ? "switch"
        : "ready";

  async function act() {
    setError(null);
    try {
      if (state === "install") {
        window.open("https://metamask.io/download/", "_blank", "noopener,noreferrer");
      } else if (state === "connect") {
        if (isConnected) await disconnectAsync(); // leave a demo account first
        await connectAsync({ connector: injected!, chainId: CHAIN.id });
      } else if (state === "switch") {
        await switchChainAsync({ chainId: CHAIN.id });
      }
    } catch (e) {
      const x = e as { shortMessage?: string; message?: string };
      setError(x.shortMessage ?? x.message?.split("\n")[0] ?? "wallet error");
    }
  }

  const label =
    state === "install" ? "Get MetaMask ↗"
    : state === "connect" ? "Connect wallet"
    : state === "switch" ? `Switch to ${CHAIN.name}`
    : short(address!);

  return { state, label, act, error, address, disconnect: () => disconnectAsync() };
}

export default function WalletButton() {
  const w = useWallet();
  return (
    <span className="wallet">
      <button
        className={`nav-mono ${w.state === "ready" ? "on" : w.state === "switch" ? "warn" : ""}`}
        onClick={w.state === "ready" ? undefined : w.act}
        title={w.error ?? (w.state === "ready" ? "Connected wallet" : undefined)}
      >
        <span className={`nav-dot ${w.state === "ready" ? "on" : ""}`} />
        {w.label}
      </button>
      {w.state === "ready" && (
        <button className="nav-mono wallet-x" onClick={w.disconnect} title="Disconnect">
          ×
        </button>
      )}
      {w.error && <span className="wallet-err">{w.error}</span>}
    </span>
  );
}
