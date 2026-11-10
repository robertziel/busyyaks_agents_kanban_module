// Board logic with no React: due-date state, the board filter, ordering, the markdown toolbar's text edits, and the
// datetime-local <-> ISO conversion. Markdown is never rendered here — the server renders it (/api/markdown).
import type { Card } from "../types";

export const SOON_MS = 24 * 3600 * 1000; // "due soon" = within 24 h (Trello's orange)

export type DueState = "done" | "overdue" | "soon" | "later";

export function dueState(due: string | null, done: boolean, nowMs: number): DueState | null {
  if (!due) return null;
  if (done) return "done";
  const t = new Date(due).getTime();
  if (t < nowMs) return "overdue";
  if (t - nowMs <= SOON_MS) return "soon";
  return "later";
}

const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
const pad = (n: number) => String(n).padStart(2, "0");

// "Nov 5" (this year) / "Nov 5, 2027"; with the time when it is not midnight.
export function dueLabel(due: string, nowMs: number): string {
  const d = new Date(due);
  const y = d.getFullYear() !== new Date(nowMs).getFullYear() ? `, ${d.getFullYear()}` : "";
  const t = d.getHours() || d.getMinutes() ? ` ${pad(d.getHours())}:${pad(d.getMinutes())}` : "";
  return `${MONTHS[d.getMonth()]} ${d.getDate()}${y}${t}`;
}

// ISO → the value of <input type="datetime-local"> in the browser's zone.
export function toLocalInput(iso: string | null): string {
  if (!iso) return "";
  const d = new Date(iso);
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

// datetime-local value → ISO 8601 with the browser's offset (the server never guesses a zone for it).
export function fromLocalInput(v: string): string {
  const m = v.match(/^(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d)$/);
  if (!m) throw new Error(`not a datetime-local value: ${v}`);
  const d = new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3]), Number(m[4]), Number(m[5]));
  const off = -d.getTimezoneOffset();
  const sign = off >= 0 ? "+" : "-";
  return `${v}:00${sign}${pad(Math.floor(Math.abs(off) / 60))}:${pad(Math.abs(off) % 60)}`;
}

export type DueFilter = "" | "overdue" | "soon" | "none" | "done";
export type Filter = { text: string; labels: string[]; member: string; due: DueFilter };
export const EMPTY_FILTER: Filter = { text: "", labels: [], member: "", due: "" };
export const isFiltering = (f: Filter) => !!(f.text.trim() || f.labels.length || f.member || f.due);

// Trello semantics: every given facet must match; within labels, any of the chosen labels matches.
export function matches(c: Card, f: Filter, nowMs: number): boolean {
  const q = f.text.trim().toLowerCase();
  if (q && !`${c.title} #${c.id} ${c.labels.join(" ")} ${c.assignee ?? ""}`.toLowerCase().includes(q)) return false;
  if (f.labels.length && !f.labels.some((l) => c.labels.includes(l))) return false;
  if (f.member === "-" ? c.assignee != null : f.member && c.assignee !== f.member) return false;
  if (f.due) {
    const s = dueState(c.due, c.due_done, nowMs);
    if (f.due === "none" ? s !== null : f.due === "soon" ? s !== "soon" : s !== f.due) return false;
  }
  return true;
}

export type Order = "updated" | "position" | "due";
export const ORDERS: Order[] = ["updated", "position", "due"];

const updatedMs = (c: Card) => new Date(c.updated).getTime();

// "updated" (the default view): the latest change on top, then the higher id. "due": soonest first, cards
// without a due date last, then by position. A view order — the stored order is untouched.
export function ordered(cards: Card[], order: Order): Card[] {
  if (order === "position") return cards;
  if (order === "updated") return [...cards].sort((a, b) => updatedMs(b) - updatedMs(a) || b.id - a.id);
  const key = (c: Card) => (c.due ? new Date(c.due).getTime() : Number.POSITIVE_INFINITY);
  return [...cards].sort((a, b) => key(a) - key(b) || a.position - b.position);
}

// A list's fold: the cards updated within `hours` of now stay in view, the rest wait behind "Load older".
// hours 0 = never fold. Order is kept.
export function splitStale(cards: Card[], hours: number, nowMs: number): { recent: Card[]; older: Card[] } {
  if (!hours) return { recent: cards, older: [] };
  const cut = nowMs - hours * 3600 * 1000;
  const recent: Card[] = [];
  const older: Card[] = [];
  for (const c of cards) (updatedMs(c) >= cut ? recent : older).push(c);
  return { recent, older };
}

// The day a card was last changed, in the browser's zone: "Today", "Yesterday", "Nov 5" (this year) / "Nov 5, 2025".
export function dayKey(iso: string): string {
  const d = new Date(iso);
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
}
export function dayLabel(key: string, nowMs: number): string {
  const today = dayKey(new Date(nowMs).toISOString());
  const y = new Date(nowMs);
  y.setDate(y.getDate() - 1);
  if (key === today) return "Today";
  if (key === dayKey(y.toISOString())) return "Yesterday";
  const [yy, mm, dd] = key.split("-").map(Number) as [number, number, number];
  return `${MONTHS[mm - 1]} ${dd}${yy !== new Date(nowMs).getFullYear() ? `, ${yy}` : ""}`;
}

// The cards (already ordered by "updated") cut into runs of one day each, newest day first: [{key, label, cards}].
export function dayGroups(cards: Card[], nowMs: number): { key: string; label: string; cards: Card[] }[] {
  const out: { key: string; label: string; cards: Card[] }[] = [];
  for (const c of cards) {
    const k = dayKey(c.updated);
    const last = out[out.length - 1];
    if (last && last.key === k) last.cards.push(c);
    else out.push({ key: k, label: dayLabel(k, nowMs), cards: [c] });
  }
  return out;
}

export type Edit = { text: string; start: number; end: number };
export type Tool = "bold" | "italic" | "code" | "link" | "list" | "checklist";

// The toolbar: wrap the selection (bold/italic/code/link) or prefix each selected line (list/checklist).
// Returns the new text and the selection to restore.
export function applyTool(text: string, start: number, end: number, tool: Tool): Edit {
  const sel = text.slice(start, end);
  const wrap = (l: string, r: string, placeholder: string): Edit => {
    const inner = sel || placeholder;
    const out = text.slice(0, start) + l + inner + r + text.slice(end);
    return { text: out, start: start + l.length, end: start + l.length + inner.length };
  };
  switch (tool) {
    case "bold":
      return wrap("**", "**", "bold");
    case "italic":
      return wrap("_", "_", "italic");
    case "code":
      return sel.includes("\n") ? wrap("```\n", "\n```", "") : wrap("`", "`", "code");
    case "link": {
      const label = sel || "text";
      const out = `${text.slice(0, start)}[${label}](https://)${text.slice(end)}`;
      const urlAt = start + label.length + 3;
      return { text: out, start: urlAt, end: urlAt + 8 };
    }
    case "list":
    case "checklist": {
      const prefix = tool === "list" ? "- " : "- [ ] ";
      const ls = text.lastIndexOf("\n", start - 1) + 1; // start of the first selected line
      const block = text.slice(ls, end);
      const lines = block.split("\n").map((l) => prefix + l);
      const joined = lines.join("\n");
      const out = text.slice(0, ls) + joined + text.slice(end);
      return { text: out, start: ls + prefix.length, end: ls + joined.length };
    }
  }
}

// Drag-and-drop onto a filtered or re-ordered list: the drop index counts only the visible cards (without the dragged
// one); the server wants a position among all the column's cards (without the dragged one). `all` = the column's ids in
// stored order, `visible` = the ids shown, in shown order.
export function dropPosition(all: number[], visible: number[], dragId: number, index: number): number {
  const rest = all.filter((x) => x !== dragId);
  const shown = visible.filter((x) => x !== dragId);
  if (index < shown.length) return rest.indexOf(shown[index]!);
  if (shown.length === 0) return rest.length;
  return rest.indexOf(shown[shown.length - 1]!) + 1;
}

// Shortcuts ("?" overlay and the board's key handler share this list).
export const SHORTCUTS: [string, string][] = [
  ["← ↑ → ↓", "focus the next card"],
  ["Enter · e", "open card"],
  ["n", "new card in the focused list"],
  ["c", "archive card"],
  ["l", "labels"],
  ["d", "due date"],
  ["m", "members (assignee)"],
  ["Space", "assign to me / unassign"],
  ["Alt + ← →", "move card to the previous / next list"],
  ["Alt + ↑ ↓", "move card up / down"],
  ["q", "only my cards"],
  ["f · /", "filter"],
  ["Esc", "close · clear filter"],
  ["?", "this overlay"],
];

// The board's owner-session rule (config.owner_sessions, SPEC § 2): null = every session the host lists; else only a
// session matching one of the globs (* any run, ? one char — File.fnmatch on the ruby side). The picker shows only
// these, so a session of another project's host is never offered (the engine refuses it anyway).
export function ownerSessionAllowed(patterns: string[] | null | undefined, name: string): boolean {
  if (!patterns) return true;
  return patterns.some((p) =>
    new RegExp(
      "^" +
        p
          .split(/(\*|\?)/)
          .map((x) => (x === "*" ? ".*" : x === "?" ? "." : x.replace(/[.+^${}()|[\]\\]/g, "\\$&")))
          .join("") +
        "$",
    ).test(name),
  );
}
