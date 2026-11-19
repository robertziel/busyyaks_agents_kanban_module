// Card links (the dialog's Links rail): what a row shows and where its detail popover goes. Pure.
import type { CardLink, LinkTag, LinkTone } from "../types";

export const LINK_TONES: readonly LinkTone[] = ["ok", "warn", "bad", "done", "muted", "info"];

// The popover's class for a tag's tone; a tone the engine does not know is shown muted, never dropped.
export const toneClass = (tone: string): string =>
  `t-${(LINK_TONES as readonly string[]).includes(tone) ? tone : "muted"}`;

// Only a link with detail rows gets the popover; a row without is the plain link it always was (native title = the url).
export const hasDetail = (l: CardLink): boolean => Array.isArray(l.detail) && l.detail.length > 0;
export const hasTags = (l: CardLink): boolean => Array.isArray(l.tags) && l.tags.length > 0;

// The rail's sections, in this order: one per kind family, each listed only when it has links. A kind no section names
// (a host sending a kind this engine does not know) gets its own section at the end under its own name, never dropped.
// A link with a `group` (e.g. a PR's role) goes into its own sub-section of its family's, in the order the groups first
// appear, named by the family's `short` name — "PRs · local", "PRs · public" (the full name three times over wraps on
// a phone).
export const LINK_GROUPS: readonly { key: string; label: string; short?: string; kinds: readonly string[] }[] = [
  { key: "pr", label: "Pull requests", short: "PRs", kinds: ["pr"] },
  { key: "ci", label: "CI", kinds: ["ci"] },
  { key: "branch", label: "Branches", kinds: ["branch"] },
  { key: "commit", label: "Commits", kinds: ["commit"] },
  { key: "file", label: "Files", kinds: ["file"] },
  { key: "web", label: "Repo & web", kinds: ["repo", "site", "url"] },
];
// Rows a section shows before "+N more". The PR sections never fold: every PR of the card is on the rail.
export const GROUP_FOLD = 3;
export const NEVER_FOLD: readonly string[] = ["pr"];

export type LinkGroup = { key: string; label: string; links: CardLink[]; fold: boolean };

export function groupLinks(links: readonly CardLink[]): LinkGroup[] {
  const out: LinkGroup[] = [];
  const section = (key: string, label: string, family: string): LinkGroup =>
    out.find((x) => x.key === key) ?? out[out.push({ key, label, links: [], fold: !NEVER_FOLD.includes(family) }) - 1]!;
  const known = new Set(LINK_GROUPS.flatMap((g) => g.kinds));
  for (const g of LINK_GROUPS) {
    for (const l of links) {
      if (!g.kinds.includes(l.kind)) continue;
      const sub = l.group?.trim();
      section(sub ? `${g.key}:${sub}` : g.key, sub ? `${g.short ?? g.label} · ${sub}` : g.label, g.key).links.push(l);
    }
  }
  for (const l of links) {
    if (known.has(l.kind)) continue;
    section(`other:${l.kind}`, l.kind, l.kind).links.push(l);
  }
  return out;
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

// A grouped row's chips: a tag that only repeats its section's name ("local" under "PRs · local") is left out — the
// header says it once. Never the row's only tag: on touch the chips are what opens the detail popover.
export function rowTags(l: CardLink, grouped: boolean): LinkTag[] {
  const tags = l.tags ?? [];
  const group = l.group?.trim().toLowerCase();
  if (!grouped || !group) return tags;
  const rest = tags.filter((t) => t.text.trim().toLowerCase() !== group);
  return rest.length > 0 ? rest : tags;
}

// A PR's label "#12 repo_name" → its number and its repo, drawn apart: the number strong, the repo wrapping whole (two
// repos that differ only at the end must not both end in an ellipsis) — in pieces that each end at a `_ - . /`, where
// a line may break ("busyyaks_agents_" / "kanban_module"). Any other label → null: drawn as it is.
export function prLabelParts(l: CardLink): { ref: string; name: string[] } | null {
  if (l.kind !== "pr") return null;
  const m = /^(#\d+)\s+(\S.*)$/.exec(l.label);
  return m ? { ref: m[1]!, name: m[2]!.match(/[^_\-./]*[_\-./]+|[^_\-./]+/g) ?? [m[2]!] } : null;
}

// The operator's unassign of an assigned PR (KanbanApi.prUnassign): the reason as typed → the one sent (trimmed);
// "" = none given, nothing is sent.
export const unassignReason = (typed: string): string => typed.trim();
