import Logo from "@/components/Logo";
import type { ReactNode } from "react";

export default function Navbar({ right, onConsole, calm }: { right?: ReactNode; onConsole?: boolean; calm?: boolean }) {
  return (
    <nav className={`nav ${calm ? "calm" : ""}`}>
      <div className="nav-inner">
        <a className="brand" href="/">
          <Logo />
          <span>
            Air<span className="brand-dim">bag</span>
          </span>
        </a>
        <div className="nav-right">
          <a className="plain" href="/">Home</a>
          {calm ? (
            <a className={`plain ${onConsole ? "on" : ""}`} href="/app">Console</a>
          ) : (
            <a className="plain" href="/#how">Lifecycle</a>
          )}
          <a className="plain" href="/integrate">Integrate</a>
          {!calm && (
            <a className={`nav-mono ${onConsole ? "on" : ""}`} href="/app">
              Console ↗
            </a>
          )}
          {right}
        </div>
      </div>
    </nav>
  );
}
