// An agent's face: two eyes on a disc coloured by its agent TYPE — lib/face.ts picks the eyes' shape from the name. The
// mood is the eyes alone (styles/kanban.css "Agent faces"): a still pose per mood + a motion on top — they blink (a
// double blink now and then), wander when idle, glance around at work, look up while thinking, squint and scan at a
// tool, read along while writing, look from one subagent to the other, open wide and hop when waiting for you, close
// and breathe when asleep. One inline SVG, animated by CSS only (no timer per face); under prefers-reduced-motion the
// pose stays, still.
import type { CSSProperties } from "react";
import { agentFace, faceHash, faceLabel, typeBackdrop, type Mood } from "../lib/face";

export type AgentFaceProps = {
  name: string; // the identity the face is drawn from
  type?: string | null; // its agent type key: the disc's colour (absent / null = the neutral one)
  mood?: Mood | null; // absent / null = still eyes
  size?: number; // px; absent = the stylesheet's (24px, or the context's)
  title?: string; // the tooltip + label; absent = name · type · mood in words
  className?: string;
};

export function AgentFace({ name, type = null, mood = null, size, title, className }: AgentFaceProps) {
  const { eyes } = agentFace(name);
  const bg = typeBackdrop(type);
  const label = title ?? faceLabel(name, type, mood);
  const style = {
    ...(bg ? { "--yf-bg": bg } : {}),
    // every face blinks on its own beat
    "--yf-d": `${-(faceHash(name) % 47) / 10}s`,
    ...(size ? { width: size, height: size } : {}),
  } as CSSProperties;
  const eye = (x: number) =>
    eyes === "capsule" ? (
      <rect className="yf-eye" x={x - 4.5} y="22" width="9" height="20" rx="4.5" />
    ) : (
      <circle className="yf-eye" cx={x} cy="32" r="6.5" />
    );
  return (
    <svg
      className={`ak-face${mood ? ` m-${mood}` : ""}${className ? ` ${className}` : ""}`}
      viewBox="0 0 64 64"
      role="img"
      aria-label={label}
      data-type={type ?? undefined}
      data-mood={mood ?? undefined}
      data-eyes={eyes}
      style={style}
    >
      <title>{label}</title>
      <circle className="yf-bg" cx="32" cy="32" r="32" />
      <g className="yf-look">
        <g className="yf-open">
          {eye(22)}
          {eye(42)}
        </g>
        <path className="yf-shut" d="M15 33 Q22 39 29 33 M35 33 Q42 39 49 33" />
      </g>
    </svg>
  );
}
