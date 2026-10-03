"use client";

import { useEffect, useRef, useState } from "react";

/**
 * Hero loop, drawn as pixel art: the USDG price drifts around $1.00, then gaps below the
 * $0.97 trigger band — and the airbag deploys on its own (no claim form, no committee).
 */
const W = 48;
const H = 40;
const BAND = 0.97;
const INK = "#1b1712";
const RED = "#e4412a";
const RED_D = "#b8321f";
const CREAM = "#fbf6ea";
const SINK = "#e3d6b8";

type Phase = "calm" | "depeg" | "deployed";

export default function AirbagDemo() {
  const ref = useRef<HTMLCanvasElement>(null);
  const [price, setPrice] = useState(1);
  const [phase, setPhase] = useState<Phase>("calm");

  useEffect(() => {
    const cv = ref.current!;
    const ctx = cv.getContext("2d")!;
    cv.width = W;
    cv.height = H;
    const reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    const LOOP = 9000;
    let raf = 0;
    let lastUi = 0;

    const priceAt = (t: number) => {
      // t in [0,1): calm wobble, then a gap down, then a slow partial recovery
      const wob = Math.sin(t * 38) * 0.004 + Math.sin(t * 91) * 0.002;
      if (t < 0.45) return 1 + wob;
      if (t < 0.55) return 1 + wob - ((t - 0.45) / 0.1) * 0.09;
      return 0.91 + wob + (t - 0.55) * 0.08;
    };
    const yOf = (p: number) => Math.round((1.02 - p) / 0.13 * (H - 6)) + 2;

    function frame(now: number) {
      const t = reduced ? 0.8 : (now % LOOP) / LOOP;
      ctx.fillStyle = CREAM;
      ctx.fillRect(0, 0, W, H);

      // grid dots
      ctx.fillStyle = SINK;
      for (let x = 0; x < W; x += 4) for (let y = 0; y < H; y += 4) ctx.fillRect(x, y, 1, 1);

      // trigger band (dashed red)
      const by = yOf(BAND);
      ctx.fillStyle = RED;
      for (let x = 0; x < W; x += 3) ctx.fillRect(x, by, 2, 1);

      // price trace up to "now"
      const head = Math.floor(t * W * 1.0);
      ctx.fillStyle = INK;
      let firstHit = -1;
      for (let x = 0; x <= Math.min(head, W - 1); x++) {
        const p = priceAt(x / W);
        const y = yOf(p);
        ctx.fillRect(x, y, 1, 1);
        ctx.fillRect(x, y + 1, 1, 1);
        if (firstHit < 0 && p <= BAND) firstHit = x;
      }
      const cur = priceAt(Math.min(head, W - 1) / W);

      // airbag: pixel disc inflating from the moment the band is crossed
      let ph: Phase = "calm";
      if (firstHit >= 0) {
        const age = head - firstHit;
        ph = age > 7 ? "deployed" : "depeg";
        const r = Math.min(15, age * 2.2);
        const cx = 30;
        const cy = 20;
        for (let y = -16; y <= 16; y++) {
          for (let x = -16; x <= 16; x++) {
            const d = Math.hypot(x, y * 1.08);
            if (d > r) continue;
            const edge = d > r - 1.5;
            const shade = (x + y + 32) % 4 === 0 && d > r * 0.55;
            ctx.fillStyle = edge ? INK : shade ? RED_D : RED;
            ctx.fillRect(cx + x, cy + y, 1, 1);
          }
        }
        if (r > 8) {
          // highlight
          ctx.fillStyle = CREAM;
          ctx.fillRect(cx - 5, cy - 6, 2, 1);
          ctx.fillRect(cx - 6, cy - 5, 1, 2);
        }
      }

      if (now - lastUi > 120) {
        lastUi = now;
        setPrice(cur);
        setPhase(ph);
      }
      if (!reduced) raf = requestAnimationFrame(frame);
    }
    raf = requestAnimationFrame(frame);
    return () => cancelAnimationFrame(raf);
  }, []);

  const hot = phase !== "calm";
  return (
    <div className="bag-stage">
      <i className="corner c1" />
      <i className="corner c2" />
      <div className="bag-head">
        <span>USDG / USD · oracle</span>
        <span>trigger ≤ $0.97</span>
      </div>
      <div className="bag-canvas">
        <canvas ref={ref} />
      </div>
      <div className="bag-readout">
        <span>
          price <b className={hot ? "hot" : ""}>${price.toFixed(3)}</b>
        </span>
        <span>
          status{" "}
          <b className={hot ? "hot" : ""}>
            {phase === "calm" ? "armed" : phase === "depeg" ? "triggered" : "paid out · 100%"}
          </b>
        </span>
      </div>
    </div>
  );
}
