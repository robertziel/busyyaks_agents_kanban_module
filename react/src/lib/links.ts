// Card links (the dialog's Links rail): what a row shows and where its detail popover goes. Pure.
import type { CardLink, LinkTone } from "../types";

export const LINK_TONES: readonly LinkTone[] = ["ok", "warn", "bad", "done", "muted", "info"];

// The popover's class for a tag's tone; a tone the engine does not know is shown muted, never dropped.
export const toneClass = (tone: string): string =>
  `t-${(LINK_TONES as readonly string[]).includes(tone) ? tone : "muted"}`;

// Only a link with detail rows gets the popover; a row without is the plain link it always was (native title = the url).
export const hasDetail = (l: CardLink): boolean => Array.isArray(l.detail) && l.detail.length > 0;
export const hasTags = (l: CardLink): boolean => Array.isArray(l.tags) && l.tags.length > 0;

// The rail's sections, in this order: one per kind family, each listed only when it has links. A kind no section names
// (a host sending a kind this engine does not know) gets its own section at the end under its own name, never dropped.
export const LINK_GROUPS: readonly { key: string; label: string; kinds: readonly string[] }[] = [
  { key: "pr", label: "Pull requests", kinds: ["pr"] },
  { key: "ci", label: "CI", kinds: ["ci"] },
  { key: "branch", label: "Branches", kinds: ["branch"] },
  { key: "commit", label: "Commits", kinds: ["commit"] },
  { key: "file", label: "Files", kinds: ["file"] },
  { key: "web", label: "Repo & web", kinds: ["repo", "site", "url"] },
];
// Rows a section shows before "+N more".
export const GROUP_FOLD = 3;

export type LinkGroup = { key: string; label: string; links: CardLink[] };

export function groupLinks(links: readonly CardLink[]): LinkGroup[] {
  const out: LinkGroup[] = LINK_GROUPS.map((g) => ({
    key: g.key,
    label: g.label,
    links: links.filter((l) => g.kinds.includes(l.kind)),
  }));
  const known = new Set(LINK_GROUPS.flatMap((g) => g.kinds));
  for (const l of links) {
    if (known.has(l.kind)) continue;
    const g =
      out.find((x) => x.key === `other:${l.kind}`) ??
      out[out.push({ key: `other:${l.kind}`, label: l.kind, links: [] }) - 1]!;
    g.links.push(l);
  }
  return out.filter((g) => g.links.length > 0);
}

// The native tooltip: the url for a plain link; none when the popover carries the detail (both at once overlap).
export const linkTitle = (l: CardLink): string | undefined => (hasDetail(l) ? undefined : l.url);

export type AnchorBox = { left: number; top: number; right: number; bottom: number; width: number; height: number };
export type Size = { width: number; height: number };
export type Placement = { left: number; top: number; side: "left" | "below" | "above" };

const clamp = (v: number, lo: number, hi: number) => Math.min(Math.max(v, lo), Math.max(lo, hi));

// The popover is position: fixed (the rail and the dialog both scroll and would clip it). Preferred: to the LEFT of the
// row, top-aligned (the rail is the dialog's right column, the card body is beside it); no room on the left (a phone)
// → below the row, left-aligned and kept inside the viewport; no room below → above. `gap` from the row and the edges.
export function placePopover(anchor: AnchorBox, pop: Size, view: Size, gap = 8): Placement {
  if (anchor.left - gap - pop.width >= gap) {
    return {
      side: "left",
      left: anchor.left - gap - pop.width,
      top: clamp(anchor.top, gap, view.height - pop.height - gap),
    };
  }
  const left = clamp(anchor.left, gap, view.width - pop.width - gap);
  const below = anchor.bottom + gap / 2;
  if (below + pop.height <= view.height - gap) return { side: "below", left, top: below };
  return { side: "above", left, top: Math.max(gap, anchor.top - gap / 2 - pop.height) };
}
