import type { Metadata } from "next";
import type { ReactNode } from "react";
import { Providers } from "./providers";

export const metadata: Metadata = {
  title: "Console — Airbag",
  description: "Buy depeg cover, underwrite a market, settle expired policies.",
};

export default function ConsoleLayout({ children }: { children: ReactNode }) {
  return <Providers>{children}</Providers>;
}
