import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "Airbag — depeg cover that deploys itself",
  description:
    "Parametric, provably-solvent USDG depeg cover on 1inch Aqua. The reserve never leaves the underwriter's wallet; payouts fire atomically when the peg breaks.",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <head>
        <link rel="preconnect" href="https://fonts.googleapis.com" />
        <link rel="preconnect" href="https://fonts.gstatic.com" crossOrigin="anonymous" />
        <link
          href="https://fonts.googleapis.com/css2?family=Archivo+Black&family=Archivo:wght@500;700;800&family=JetBrains+Mono:wght@400;600;700;800&display=swap"
          rel="stylesheet"
        />
      </head>
      <body>
        <div className="grain" aria-hidden />
        {children}
      </body>
    </html>
  );
}
