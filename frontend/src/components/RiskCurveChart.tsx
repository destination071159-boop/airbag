"use client";

import { useRef, useState } from "react";

/**
 * Premium-rate curve, mirroring RiskCurve.sol exactly:
 *   rate(u) = start + (end − start) · u^k      u = cover sold / capacity ∈ [0, 1]
 * Editable mode: drag the two endpoints to set start/end rate; convexity comes from the parent.
 * Read-only mode: shows where the book is now and where a purchase would land.
 */
export type Curve = { start: number; end: number; k: number }; // rates as fractions (0.01 = 1%)

export const rateAt = (c: Curve, u: number) =>
  u <= 0 ? c.start : u >= 1 ? c.end : c.start + (c.end - c.start) * Math.pow(u, c.k);

const W = 560;
const H = 264;
const PAD = { l: 46, r: 18, t: 40, b: 34 };
const IW = W - PAD.l - PAD.r;
const IH = H - PAD.t - PAD.b;

export default function RiskCurveChart({
  curve,
  onChange,
  nowU,
  afterU,
  yMax: yMaxProp,
  ghosts = [],
}: {
  curve: Curve;
  onChange?: (c: Curve) => void;
  nowU?: number;
  afterU?: number;
  yMax?: number;
  ghosts?: Curve[];
}) {
  const svg = useRef<SVGSVGElement>(null);
  const [drag, setDrag] = useState<"start" | "end" | null>(null);
  const [hover, setHover] = useState<number | null>(null);

  const yMax = yMaxProp ?? Math.max(0.05, Math.ceil(curve.end * 1.25 * 100) / 100);
  const x = (u: number) => PAD.l + u * IW;
  const y = (r: number) => PAD.t + IH - (Math.min(r, yMax) / yMax) * IH;

  const path = (c: Curve) => {
    let d = "";
    for (let i = 0; i <= 100; i++) {
      const u = i / 100;
      d += `${i ? "L" : "M"}${x(u).toFixed(1)},${y(rateAt(c, u)).toFixed(1)}`;
    }
    return d;
  };
  const line = path(curve);
  const area = `${line}L${x(1)},${y(0)}L${x(0)},${y(0)}Z`;

  // shaded slice: the capacity this purchase consumes
  let slice = "";
  if (nowU !== undefined && afterU !== undefined && afterU > nowU) {
    const a = Math.max(0, nowU), b = Math.min(1, afterU);
    slice = `M${x(a)},${y(0)}`;
    for (let i = 0; i <= 40; i++) {
      const u = a + ((b - a) * i) / 40;
      slice += `L${x(u).toFixed(1)},${y(rateAt(curve, u)).toFixed(1)}`;
    }
    slice += `L${x(b)},${y(0)}Z`;
  }

  function toLocal(e: React.PointerEvent) {
    const r = svg.current!.getBoundingClientRect();
    return { px: ((e.clientX - r.left) / r.width) * W, py: ((e.clientY - r.top) / r.height) * H };
  }
  function onMove(e: React.PointerEvent) {
    const { px, py } = toLocal(e);
    const u = Math.min(1, Math.max(0, (px - PAD.l) / IW));
    setHover(px >= PAD.l && px <= W - PAD.r ? u : null);
    if (!drag || !onChange) return;
    const r = Math.round(Math.min(yMax, Math.max(0, ((PAD.t + IH - py) / IH) * yMax)) * 1000) / 1000;
    if (drag === "start") onChange({ ...curve, start: Math.min(r, curve.end) });
    else onChange({ ...curve, end: Math.max(r, curve.start) });
  }

  const ticksY = [0, 0.25, 0.5, 0.75, 1].map((f) => f * yMax);
  const hr = hover !== null ? rateAt(curve, hover) : null;

  return (
    <svg
      ref={svg}
      className={`curve-svg ${onChange ? "editable" : ""} ${drag ? "dragging" : ""}`}
      viewBox={`0 0 ${W} ${H}`}
      onPointerMove={onMove}
      onPointerUp={() => setDrag(null)}
      onPointerLeave={() => { setDrag(null); setHover(null); }}
    >
      <defs>
        <pattern id="cv-dots" width="8" height="8" patternUnits="userSpaceOnUse">
          <rect width="1.2" height="1.2" fill="var(--border-bright)" />
        </pattern>
        <pattern id="cv-hatch" width="6" height="6" patternUnits="userSpaceOnUse" patternTransform="rotate(45)">
          <rect width="2" height="6" fill="var(--accent)" opacity=".45" />
        </pattern>
      </defs>

      {/* grid */}
      <rect x={PAD.l} y={PAD.t} width={IW} height={IH} fill="url(#cv-dots)" opacity=".5" />
      {ticksY.map((t) => (
        <g key={t}>
          <line x1={PAD.l} x2={W - PAD.r} y1={y(t)} y2={y(t)} stroke="var(--border)" strokeDasharray="3 4" />
          <text x={PAD.l - 8} y={y(t) + 3} textAnchor="end" className="cv-tick">{(t * 100).toFixed(t * 100 < 10 ? 1 : 0)}%</text>
        </g>
      ))}
      {[0, 0.25, 0.5, 0.75, 1].map((u) => (
        <text key={u} x={x(u)} y={H - 12} textAnchor="middle" className="cv-tick">{u * 100}%</text>
      ))}
      <text x={W - PAD.r} y={H - 1} textAnchor="end" className="cv-axis">capacity sold →</text>

      {/* preset ghosts */}
      {ghosts.map((g, i) => (
        <path key={i} d={path(g)} fill="none" stroke="var(--text-dim)" strokeWidth="1" strokeDasharray="2 4" opacity=".6" />
      ))}

      {/* curve */}
      <path d={area} fill="var(--ink)" opacity=".07" />
      {slice && <path d={slice} fill="url(#cv-hatch)" stroke="var(--accent)" strokeWidth="1" />}
      <path d={line} fill="none" stroke="var(--red)" strokeWidth="3" opacity=".35" transform="translate(1.5,0)" />
      <path d={line} fill="none" stroke="var(--blue)" strokeWidth="3" opacity=".35" transform="translate(-1.5,0)" />
      <path d={line} fill="none" stroke="var(--ink)" strokeWidth="2.5" />

      {/* markers */}
      {nowU !== undefined && (
        <g>
          <line x1={x(nowU)} x2={x(nowU)} y1={PAD.t - 30} y2={y(0)} stroke="var(--ink)" strokeDasharray="4 3" />
          <rect x={x(nowU) - 5} y={y(rateAt(curve, nowU)) - 5} width="10" height="10" fill="var(--bg-raise)" stroke="var(--ink)" strokeWidth="2" />
          <text x={x(nowU) + 8} y={PAD.t - 22} className="cv-label">now {(rateAt(curve, nowU) * 100).toFixed(2)}%</text>
        </g>
      )}
      {afterU !== undefined && nowU !== undefined && afterU > nowU && (
        <g>
          <line x1={x(Math.min(afterU, 1))} x2={x(Math.min(afterU, 1))} y1={PAD.t - 16} y2={y(0)} stroke="var(--accent)" strokeDasharray="4 3" />
          <rect x={x(Math.min(afterU, 1)) - 6} y={y(rateAt(curve, afterU)) - 6} width="12" height="12" fill="var(--accent)" />
          <text x={x(Math.min(afterU, 1)) + (afterU > 0.75 ? -8 : 8)} y={PAD.t - 8} textAnchor={afterU > 0.75 ? "end" : "start"} className="cv-label red">
            {afterU > 1 ? "over capacity" : `your rate ${(rateAt(curve, afterU) * 100).toFixed(2)}%`}
          </text>
        </g>
      )}

      {/* hover readout: a dark tooltip chip well above the point (flips below near the top) */}
      {hover !== null && hr !== null && !drag && (() => {
        const text = `${(hover * 100).toFixed(0)}% sold  →  ${(hr * 100).toFixed(2)}% / yr`;
        const w = text.length * 7.4 + 20;
        const h = 24;
        const px = x(hover);
        const py = y(hr);
        const above = py - 60 >= 4;
        const bx = Math.min(Math.max(px - w / 2, PAD.l), W - PAD.r - w);
        const by = above ? py - 60 : py + 22;
        return (
          <g pointerEvents="none">
            <line x1={px} x2={px} y1={above ? by + h : py} y2={above ? py : by} stroke="var(--ink)" strokeWidth="1" />
            <circle cx={px} cy={py} r="4" fill="var(--ink)" stroke="var(--bg)" strokeWidth="2" />
            <rect x={bx} y={by} width={w} height={h} fill="var(--ink)" />
            <text x={bx + w / 2} y={by + 16} textAnchor="middle" className="cv-tip">{text}</text>
          </g>
        );
      })()}

      {/* draggable endpoints */}
      {onChange && (
        <>
          <g className="cv-handle" onPointerDown={(e) => { (e.target as Element).setPointerCapture?.(e.pointerId); setDrag("start"); }}>
            <rect x={x(0) - 9} y={y(curve.start) - 9} width="18" height="18" fill="var(--ink)" />
            <rect x={x(0) - 4} y={y(curve.start) - 4} width="8" height="8" fill="var(--bg-raise)" />
          </g>
          <text x={x(0) + 14} y={y(curve.start) + 4} className="cv-label">{(curve.start * 100).toFixed(1)}%</text>
          <g className="cv-handle" onPointerDown={(e) => { (e.target as Element).setPointerCapture?.(e.pointerId); setDrag("end"); }}>
            <rect x={x(1) - 9} y={y(curve.end) - 9} width="18" height="18" fill="var(--accent)" />
            <rect x={x(1) - 4} y={y(curve.end) - 4} width="8" height="8" fill="var(--bg-raise)" />
          </g>
          <text x={x(1) - 14} y={y(curve.end) + 4} textAnchor="end" className="cv-label red">{(curve.end * 100).toFixed(1)}%</text>
        </>
      )}
    </svg>
  );
}
