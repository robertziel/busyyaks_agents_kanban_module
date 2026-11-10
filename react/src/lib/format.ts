// Time and avatar formatting the board uses (busyyaks's ERB helpers, ported; the same words in every host).
export const now = () => Math.floor(Date.now() / 1000);

export function ago(ts: number | null | undefined, at = now()): string {
  if (ts == null) return "—";
  const d = at - ts;
  if (d < 60) return `${d}s`;
  if (d < 3600) return `${Math.floor(d / 60)}m`;
  if (d < 86400) return `${Math.floor(d / 3600)}h`;
  return `${Math.floor(d / 86400)}d`;
}

const pad = (n: number) => String(n).padStart(2, "0");

export function at(ts: number | null | undefined): string {
  if (ts == null) return "—";
  const d = new Date(ts * 1000);
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

export const isoAgo = (iso: string | null | undefined) =>
  iso ? ago(Math.floor(new Date(iso).getTime() / 1000), now()) : "—";
export const isoAt = (iso: string | null | undefined) => (iso ? at(Math.floor(new Date(iso).getTime() / 1000)) : "—");

export function initials(name: string): string {
  const s = name
    .split(/[\s._-]+/)
    .filter(Boolean)
    .slice(0, 2)
    .map((w) => w[0])
    .join("")
    .toUpperCase();
  return s || "?";
}

// a stable hue per name, so the same agent has the same avatar colour everywhere
export function hue(email: string): number {
  let sum = 0;
  for (const b of new TextEncoder().encode(email)) sum += b;
  return (sum * 47) % 360;
}
