import { describe, expect, it } from "vitest";
import type { Card } from "../types";
import {
  applyTool,
  dayGroups,
  dropPosition,
  dueLabel,
  dueState,
  EMPTY_FILTER,
  fromLocalInput,
  isFiltering,
  matches,
  ordered,
  ownerSessionAllowed,
  SOON_MS,
  splitStale,
  toLocalInput,
} from "./board";

const NOW = new Date(2026, 10, 2, 12, 0).getTime();
const card = (o: Partial<Card>): Card => ({
  transitions: [],
  id: 1,
  project: "g/r",
  owner_session: null,
  owner_socket: null,
  approved: null,
  approved_by: null,
  column: "todo",
  position: 0,
  title: "Fix login",
  labels: [],
  assignee: null,
  priority: null,
  comments: 0,
  due: null,
  due_done: false,
  cover: null,
  has_description: false,
  checklist_done: 0,
  checklist_total: 0,
  attachments: 0,
  parent: null,
  children: 0,
  blocked_by: [],
  needs_operator: false,
  blocked: null,
  review_round: null,
  metadata: null,
  created_by: "op",
  created: "2026-11-01T10:00:00Z",
  updated: "2026-11-01T10:00:00Z",
  archived: null,
  ...o,
});
const iso = (ms: number) => new Date(ms).toISOString();

describe("dueState", () => {
  it("is null without a due date", () => expect(dueState(null, false, NOW)).toBeNull());
  it("done wins over overdue", () => expect(dueState(iso(NOW - 1000), true, NOW)).toBe("done"));
  it("overdue in the past", () => expect(dueState(iso(NOW - 1000), false, NOW)).toBe("overdue"));
  it("soon within 24h", () => expect(dueState(iso(NOW + SOON_MS - 1), false, NOW)).toBe("soon"));
  it("later beyond 24h", () => expect(dueState(iso(NOW + SOON_MS + 60_000), false, NOW)).toBe("later"));
});

describe("dueLabel", () => {
  it("omits year and midnight time", () => expect(dueLabel(iso(new Date(2026, 10, 5).getTime()), NOW)).toBe("Nov 5"));
  it("shows time and other years", () =>
    expect(dueLabel(iso(new Date(2027, 0, 3, 9, 5).getTime()), NOW)).toBe("Jan 3, 2027 09:05"));
});

describe("datetime-local", () => {
  it("round-trips through ISO with the browser offset", () => {
    const v = "2026-11-05T18:30";
    const out = fromLocalInput(v);
    expect(out).toMatch(/^2026-11-05T18:30:00[+-]\d\d:\d\d$/);
    expect(toLocalInput(out)).toBe(v);
  });
  it("refuses anything else", () => expect(() => fromLocalInput("tomorrow")).toThrow());
  it("empty for no due", () => expect(toLocalInput(null)).toBe(""));
});

describe("filter", () => {
  const a = card({ id: 1, title: "Radar tiles", labels: ["bug"], assignee: "tl_x", due: iso(NOW - 1000) });
  const b = card({ id: 2, title: "Docs", labels: ["ui"], due: iso(NOW + 3600_000) });
  const c = card({ id: 3, title: "Ship", due: iso(NOW - 1000), due_done: true });
  const all = [a, b, c];
  const pick = (f: Partial<typeof EMPTY_FILTER>) =>
    all.filter((x) => matches(x, { ...EMPTY_FILTER, ...f }, NOW)).map((x) => x.id);
  it("empty filter matches all", () => {
    expect(pick({})).toEqual([1, 2, 3]);
    expect(isFiltering(EMPTY_FILTER)).toBe(false);
  });
  it("text over title, #id, labels, assignee", () => {
    expect(pick({ text: "radar" })).toEqual([1]);
    expect(pick({ text: "#2" })).toEqual([2]);
    expect(pick({ text: "tl_x" })).toEqual([1]);
  });
  it("any chosen label", () => expect(pick({ labels: ["bug", "ui"] })).toEqual([1, 2]));
  it("member and unassigned", () => {
    expect(pick({ member: "tl_x" })).toEqual([1]);
    expect(pick({ member: "-" })).toEqual([2, 3]);
  });
  it("due facets", () => {
    expect(pick({ due: "overdue" })).toEqual([1]);
    expect(pick({ due: "soon" })).toEqual([2]);
    expect(pick({ due: "done" })).toEqual([3]);
    expect(pick({ due: "none" })).toEqual([]);
  });
  it("facets combine", () => expect(pick({ labels: ["bug", "ui"], due: "soon" })).toEqual([2]));
});

describe("ordered", () => {
  it("by due, undated last, ties by position", () => {
    const xs = [
      card({ id: 1, position: 0 }),
      card({ id: 2, position: 1, due: iso(NOW + 5) }),
      card({ id: 3, position: 2, due: iso(NOW + 1) }),
    ];
    expect(ordered(xs, "due").map((x) => x.id)).toEqual([3, 2, 1]);
    expect(ordered(xs, "position")).toBe(xs);
  });
});

describe("dropPosition", () => {
  it("is the index itself on an unfiltered list", () => {
    expect(dropPosition([1, 2, 3, 4], [1, 2, 3, 4], 9, 2)).toBe(2);
    expect(dropPosition([1, 2, 3], [1, 2, 3], 1, 1)).toBe(1); // dragging 1 below 2 (index among the rest)
  });
  it("maps a filtered index onto the stored order", () => {
    // all 1..5, only 2 and 4 visible: drop before 4 → position of 4 among the rest
    expect(dropPosition([1, 2, 3, 4, 5], [2, 4], 9, 1)).toBe(3);
    expect(dropPosition([1, 2, 3, 4, 5], [2, 4], 9, 2)).toBe(4); // after the last visible
    expect(dropPosition([1, 2, 3], [], 9, 0)).toBe(3);
  });
  it("respects a due-date view order", () => expect(dropPosition([1, 2, 3], [3, 1, 2], 9, 1)).toBe(0));
});

describe("applyTool", () => {
  it("wraps the selection in bold", () =>
    expect(applyTool("a word b", 2, 6, "bold")).toEqual({ text: "a **word** b", start: 4, end: 8 }));
  it("inserts a placeholder when nothing is selected", () =>
    expect(applyTool("", 0, 0, "italic")).toEqual({ text: "_italic_", start: 1, end: 7 }));
  it("inline code vs fenced block", () => {
    expect(applyTool("x", 0, 1, "code").text).toBe("`x`");
    expect(applyTool("a\nb", 0, 3, "code").text).toBe("```\na\nb\n```");
  });
  it("link selects the url", () => {
    const r = applyTool("see docs", 4, 8, "link");
    expect(r.text).toBe("see [docs](https://)");
    expect(r.text.slice(r.start, r.end)).toBe("https://");
  });
  it("prefixes every selected line", () => {
    expect(applyTool("one\ntwo", 0, 7, "list").text).toBe("- one\n- two");
    expect(applyTool("x\none\ntwo", 3, 9, "checklist").text).toBe("x\n- [ ] one\n- [ ] two");
  });
});

describe("ownerSessionAllowed", () => {
  it("allows every session when the board names none", () =>
    expect(ownerSessionAllowed(null, "coding_lead")).toBe(true));
  it("matches the board's globs only — another project's session is never offered", () => {
    const pats = ["news_articles", "news-articles-*"];
    expect(ownerSessionAllowed(pats, "news_articles")).toBe(true);
    expect(ownerSessionAllowed(pats, "news-articles-12")).toBe(true);
    expect(ownerSessionAllowed(pats, "news-articles-")).toBe(true);
    expect(ownerSessionAllowed(pats, "coding_lead")).toBe(false);
    expect(ownerSessionAllowed(pats, "acme_content_app")).toBe(false);
    expect(ownerSessionAllowed(pats, "xnews_articles")).toBe(false);
    expect(ownerSessionAllowed(["lead_?"], "lead_1")).toBe(true);
    expect(ownerSessionAllowed(["lead_?"], "lead_12")).toBe(false);
    expect(ownerSessionAllowed(["a.b"], "axb")).toBe(false);
  });
});

describe("last-modified view", () => {
  const H = 3600 * 1000;
  const a = card({ id: 1, updated: iso(NOW - 2 * H) });
  const b = card({ id: 2, updated: iso(NOW - 30 * H) });
  const c = card({ id: 3, updated: iso(NOW - 80 * H) });
  const d = card({ id: 4, updated: iso(NOW - 2 * H) });
  it("orders the latest change first, then the higher id", () =>
    expect(ordered([c, a, b, d], "updated").map((x) => x.id)).toEqual([4, 1, 2, 3]));
  it("folds what was not updated within the column's hours, keeping order", () => {
    expect(splitStale([d, a, b, c], 72, NOW)).toEqual({ recent: [d, a, b], older: [c] });
    expect(splitStale([d, a, b, c], 24, NOW)).toEqual({ recent: [d, a], older: [b, c] });
  });
  it("0 hours never folds", () => expect(splitStale([a, c], 0, NOW).older).toEqual([]));
  it("groups by local day, newest first, with Today / Yesterday / a date", () => {
    const old = card({ id: 5, updated: iso(new Date(2025, 11, 31, 9).getTime()) });
    const g = dayGroups(ordered([c, a, b, d, old], "updated"), NOW);
    expect(g.map((x) => [x.label, x.cards.map((y) => y.id)])).toEqual([
      ["Today", [4, 1]],
      ["Yesterday", [2]],
      ["Oct 30", [3]],
      ["Dec 31, 2025", [5]],
    ]);
  });
});
