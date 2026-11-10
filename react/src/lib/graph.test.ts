import { describe, expect, it } from "vitest";
import {
  borderPoint,
  BUNDLE_FROM,
  junctionText,
  keyFrom,
  foldGraph,
  layoutGraph,
  rankGraph,
  LINE_H,
  MAX_LINE,
  NOTE_CHAR_W,
  pathOf,
  planTransitions,
  removeColumn,
  renameKey,
  reorder,
  splits,
  typeLine,
  withMoved,
  wrapLabel,
  type Box,
} from "./graph";
import type { BoardColumnDef, WorkflowTransition } from "../types";

const col = (key: string, label = key, type: BoardColumnDef["type"] = "review"): BoardColumnDef => ({
  key,
  label,
  type,
  hide_after_hours: 72,
});
const right = (b: Box) => b.x + b.w;
const bottom = (b: Box) => b.y + b.h;
const inside = (p: { x: number; y: number }, b: Box, slack = 0.5) =>
  p.x > b.x + slack && p.x < right(b) - slack && p.y > b.y + slack && p.y < bottom(b) - slack;
const onBorder = (p: { x: number; y: number }, b: Box, eps = 1) =>
  (Math.abs(p.x - b.x) < eps || Math.abs(p.x - right(b)) < eps) && p.y >= b.y - eps && p.y <= bottom(b) + eps
    ? true
    : (Math.abs(p.y - b.y) < eps || Math.abs(p.y - bottom(b)) < eps) && p.x >= b.x - eps && p.x <= right(b) + eps;

describe("planTransitions — how each transition is drawn", () => {
  const keys = ["a", "b", "c", "d", "e", "f"];
  it("one or two sources: one labelled arrow per (from, to); wildcards and unknown or self sides are skipped", () => {
    const ts: WorkflowTransition[] = [
      { name: "Hand over", from: ["a", "b"], to: "c", by: "agent" },
      { name: "Fixes", from: "c", to: "a", by: "any" },
      { name: "Again", from: "c", to: "a", by: "operator" },
      { name: "Move", from: "*", to: "*", by: "any" },
      { name: "Gone", from: "nope", to: "a", by: "any" },
      { name: "Self", from: "a", to: "a", by: "any" },
    ];
    expect(planTransitions(ts, keys)).toEqual([
      { kind: "arrow", ti: 0, name: "Hand over", from: "a", to: "c", by: "agent" },
      { kind: "arrow", ti: 0, name: "Hand over", from: "b", to: "c", by: "agent" },
      { kind: "arrow", ti: 1, name: "Fixes", from: "c", to: "a", by: "any" },
      { kind: "arrow", ti: 2, name: "Again", from: "c", to: "a", by: "operator" },
    ]);
  });
  it(`${BUNDLE_FROM} sources up to half the columns: one bundle; more than half: a note on the target`, () => {
    const ts: WorkflowTransition[] = [
      { name: "Ask", from: ["a", "b", "c"], to: "f", by: "agent" },
      { name: "Cancel", from: ["a", "b", "c", "d"], to: "f", by: "operator" },
    ];
    expect(planTransitions(ts, keys)).toEqual([
      { kind: "bundle", ti: 0, name: "Ask", froms: ["a", "b", "c"], to: "f", by: "agent" },
      { kind: "note", ti: 1, name: "Cancel", froms: ["a", "b", "c", "d"], to: "f", by: "operator" },
    ]);
    // the target itself does not count as a source
    expect(planTransitions([{ name: "Ask", from: ["a", "b", "f"], to: "f", by: "agent" }], keys)).toHaveLength(2);
  });
});

describe("wrapLabel", () => {
  it("keeps a short label on one line and wraps a long one at a word boundary onto at most two", () => {
    expect(wrapLabel("In progress")).toEqual(["In progress"]);
    expect(wrapLabel("Pre-review PR (mirror)")).toEqual(["Pre-review PR", "(mirror)"]);
    expect(wrapLabel("Local: Author response")).toEqual(["Local: Author", "response"]);
    expect(wrapLabel("Allow merge (public)")).toEqual(["Allow merge", "(public)"]);
    expect(wrapLabel("a".repeat(MAX_LINE + 5))).toEqual(["a".repeat(MAX_LINE + 5)]); // one word: never cut
    expect(wrapLabel("one two three four five six seven").length).toBe(2);
  });
});

describe("layoutGraph — dagre left to right along the board order", () => {
  const chain = ["backlog", "todo", "doing", "review", "done"].map((k) => col(k, k[0]!.toUpperCase() + k.slice(1)));
  const ts: WorkflowTransition[] = [
    { name: "Prioritise", from: "backlog", to: "todo", by: "any" },
    { name: "Start work", from: "todo", to: "doing", by: "any" },
    { name: "Request review", from: "doing", to: "review", by: "agent" },
    { name: "Fixes needed", from: "review", to: "doing", by: "any" },
    { name: "Ship", from: "review", to: "done", by: "operator" },
  ];
  it("ranks follow the board order: each column sits right of the one before; nodes are sized to their wrapped label", () => {
    const l = layoutGraph(chain, ts);
    const xs = chain.map((c) => l.nodes[c.key]!.x);
    for (let i = 1; i < xs.length; i++) expect(xs[i]!).toBeGreaterThan(right(l.nodes[chain[i - 1]!.key]!));
    expect(l.nodes.backlog!.h).toBe(12 + LINE_H + 16);
    const wide = layoutGraph([col("a", "Pre-review PR (mirror)"), col("b", "x")], []);
    expect(wide.lines.a).toEqual(["Pre-review PR", "(mirror)"]);
    expect(wide.nodes.a!.h).toBe(12 + 2 * LINE_H + 16);
    expect(wide.nodes.a!.w).toBeGreaterThan(wide.nodes.b!.w);
  });
  it("an arrow against the board order is laid out reversed and drawn back: it starts at its source and ends on its target's border", () => {
    const l = layoutGraph(chain, ts);
    const back = l.routes.find((r) => r.ti === 3)!;
    expect(back.kind).toBe("arrow");
    const first = back.points[0]!;
    const last = back.points[back.points.length - 1]!;
    expect(onBorder(first, l.nodes.review!)).toBe(true);
    expect(onBorder(last, l.nodes.doing!)).toBe(true);
    expect(back.label).not.toBeNull();
    // every arrow carries a label point outside every node
    for (const r of l.routes.filter((r) => r.kind === "arrow")) {
      expect(r.label).not.toBeNull();
      for (const b of Object.values(l.nodes)) expect(inside(r.label!, b)).toBe(false);
    }
  });
  it("a node is wide enough for its type line, a junction for its text", () => {
    const narrow = layoutGraph([col("a", "x", "gate"), col("b", "y")], []);
    const wide = layoutGraph([col("a", "x", "gate"), col("b", "y")], [], {
      typeLabel: (c) => (c.type === "gate" ? "Waits for the operator" : c.type),
    });
    expect(wide.nodes.a!.w).toBeGreaterThan(narrow.nodes.a!.w);
    expect(wide.nodes.a!.w).toBeGreaterThanOrEqual(typeLine(0, "Waits for the operator").length * NOTE_CHAR_W + 22);
    const six = ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m"].map((k) => col(k));
    const l = layoutGraph(six, [
      { name: "Ask the operator", from: ["b", "c", "d", "e", "f", "g"], to: "a", by: "agent" },
    ]);
    expect(l.junctions[0]!.w).toBeGreaterThanOrEqual(junctionText("Ask the operator", 6).length * 7 + 18);
    expect(junctionText("", 3)).toBe("(unnamed) · 3");
  });
  it("folds the ranks into rows no wider than maxWidth, in board order; a route between rows is orthogonal, outside every node", () => {
    const one = layoutGraph(chain, ts);
    const l = layoutGraph(chain, ts, { maxWidth: 420 });
    expect(one.rows).toBe(1);
    expect(l.rows).toBeGreaterThan(1);
    expect(l.w).toBeLessThanOrEqual(420);
    // reading order: a later column is right of the one before on its row, or on a lower row
    for (let i = 1; i < chain.length; i++) {
      const a = l.nodes[chain[i - 1]!.key]!;
      const b = l.nodes[chain[i]!.key]!;
      expect(b.x > a.x || b.y > bottom(a)).toBe(true);
    }
    const cross = l.routes.filter((r) => r.ortho);
    expect(cross.length).toBeGreaterThan(0);
    for (const r of cross) {
      expect(onBorder(r.points[0]!, l.nodes[r.from]!)).toBe(true);
      expect(onBorder(r.points[r.points.length - 1]!, l.nodes[r.to]!)).toBe(true);
      for (let i = 1; i < r.points.length; i++) {
        const p = r.points[i - 1]!;
        const q = r.points[i]!;
        expect(p.x === q.x || p.y === q.y).toBe(true); // orthogonal
      }
    }
  });
  it("is deterministic", () => {
    expect(layoutGraph(chain, ts, { maxWidth: 400 })).toEqual(layoutGraph(chain, ts, { maxWidth: 400 }));
  });
  it("one rankGraph folds for any width, in any order, exactly as layoutGraph lays out that width; folding never changes it", () => {
    const ranked = rankGraph(chain, ts);
    const before = structuredClone(ranked);
    for (const w of [420, Infinity, 300, 700, 420])
      expect(foldGraph(ranked, w)).toEqual(layoutGraph(chain, ts, { maxWidth: w }));
    expect(ranked).toEqual(before);
    expect(foldGraph(ranked)).toEqual(layoutGraph(chain, ts));
  });
  it("a note: the target node grows a row per note; no route is drawn for it", () => {
    const ts2: WorkflowTransition[] = [
      ...ts,
      { name: "Cancel", from: ["backlog", "todo", "doing", "review"], to: "done", by: "operator" },
    ];
    const l = layoutGraph(chain, ts2);
    expect(l.notes.done).toEqual([
      {
        kind: "note",
        ti: 5,
        name: "Cancel",
        froms: ["backlog", "todo", "doing", "review"],
        to: "done",
        by: "operator",
      },
    ]);
    expect(l.nodes.done!.h).toBe(l.nodes.backlog!.h + 18);
    expect(l.nodes.done!.w).toBeGreaterThan(l.nodes.backlog!.w); // wide enough for the note text
    expect(l.routes.some((r) => r.ti === 5)).toBe(false);
  });
  it("a moved node keeps its place; the routes touching it end on its new border, the others stay", () => {
    const base = layoutGraph(chain, ts);
    const moved = withMoved(base, { doing: { x: 400, y: 300 } });
    expect(moved.nodes.doing).toMatchObject({ x: 400, y: 300 });
    expect(moved.nodes.backlog).toEqual(base.nodes.backlog);
    const start = moved.routes.find((r) => r.ti === 1)!; // todo → doing
    expect(onBorder(start.points[start.points.length - 1]!, moved.nodes.doing!)).toBe(true);
    expect(moved.routes.find((r) => r.ti === 0)).toEqual(base.routes.find((r) => r.ti === 0));
    expect(moved.h).toBeGreaterThanOrEqual(300 + moved.nodes.doing!.h);
  });
  it("an empty board has a size", () => {
    expect(layoutGraph([], [])).toMatchObject({ nodes: {}, routes: [] });
    expect(layoutGraph([], []).w).toBeGreaterThan(0);
  });
});

describe("geometry", () => {
  it("a ray from the centre leaves the box on its border", () => {
    const b: Box = { key: "a", x: 0, y: 0, w: 150, h: 46 };
    expect(borderPoint(b, { x: 1000, y: 23 })).toEqual({ x: 150, y: 23 });
    expect(borderPoint(b, { x: 75, y: -100 })).toEqual({ x: 75, y: 0 });
    expect(borderPoint(b, { x: 75, y: 23 })).toEqual({ x: 75, y: 23 });
  });
  it("a path: straight runs with each corner rounded (≤ 8px, ≤ half a run), ending exactly on the last point", () => {
    expect(
      pathOf([
        { x: 0, y: 0 },
        { x: 10, y: 5 },
      ]),
    ).toBe("M 0 0 L 10 5");
    expect(
      pathOf([
        { x: 0, y: 0 },
        { x: 40, y: 0 },
        { x: 40, y: 30 },
      ]),
    ).toBe("M 0 0 L 32 0 Q 40 0 40 8 L 40 30");
    // a short run: the corner is cut at half of it on that side
    expect(
      pathOf([
        { x: 0, y: 0 },
        { x: 6, y: 0 },
        { x: 6, y: 30 },
      ]),
    ).toBe("M 0 0 L 3 0 Q 6 0 6 8 L 6 30");
    const d = pathOf([
      { x: 0, y: 0 },
      { x: 30, y: 40 },
      { x: 60, y: 40 },
    ]);
    expect(d.startsWith("M 0 0 L ")).toBe(true);
    expect(d.endsWith(" L 60 40")).toBe(true);
    expect(d.match(/ Q /g)).toHaveLength(1);
  });
});

describe("draft edits", () => {
  it("a key from a label, unique", () => {
    expect(keyFrom("In staging", [])).toBe("in_staging");
    expect(keyFrom("  Ready / Merged! ", [])).toBe("ready_merged");
    expect(keyFrom("Été", [])).toBe("ete");
    expect(keyFrom("2nd", [])).toBe("c_2nd");
    expect(keyFrom("", [])).toBe("c");
    expect(keyFrom("QA", ["qa", "qa_2"])).toBe("qa_3");
  });
  it("reorders one step and ignores the edges", () => {
    expect(reorder(["a", "b", "c"], 0, 1)).toEqual(["b", "a", "c"]);
    expect(reorder(["a", "b", "c"], 2, 1)).toEqual(["a", "b", "c"]);
    expect(reorder(["a", "b", "c"], 0, -1)).toEqual(["a", "b", "c"]);
  });
  it("removing a column drops its edges and prunes it from from-lists; renaming a key follows into the edges", () => {
    const cols = [col("doing", "Doing", "working"), col("qa", "QA", "review"), col("check", "Check", "gate")];
    const ts: WorkflowTransition[] = [
      { name: "Hand over", from: ["doing", "qa"], to: "check", by: "agent" },
      { name: "Fixes", from: "qa", to: "doing", by: "any" },
      { name: "Review", from: "doing", to: "qa", by: "any" },
      { name: "Move", from: "*", to: "*", by: "any" },
    ];
    const r = removeColumn(cols, ts, "qa");
    expect(r.columns.map((c) => c.key)).toEqual(["doing", "check"]);
    expect(r.transitions).toEqual([
      { name: "Hand over", from: "doing", to: "check", by: "agent" },
      { name: "Move", from: "*", to: "*", by: "any" },
    ]);
    expect(renameKey(ts, "qa", "review")[0]!.from).toEqual(["doing", "review"]);
    expect(renameKey(ts, "doing", "work")[1]!.to).toBe("work");
  });
});

describe("splits", () => {
  it("cuts a list into k non-empty runs in order, every way", () => {
    expect(splits([1, 2, 3, 4], 2)).toEqual([
      [[1], [2, 3, 4]],
      [
        [1, 2],
        [3, 4],
      ],
      [[1, 2, 3], [4]],
    ]);
    expect(splits([1, 2, 3], 3)).toEqual([[[1], [2], [3]]]);
    expect(splits([1, 2, 3], 1)).toEqual([[[1, 2, 3]]]);
    expect(splits([1, 2], 3)).toEqual([]);
    expect(splits([1, 2], 0)).toEqual([]);
  });
  it("no cap: C(14, 4) = 1001 ways for 15 ranks in 5 rows, every one", () => {
    const ranks = Array.from({ length: 15 }, (_, i) => i);
    expect(splits(ranks, 4)).toHaveLength(364);
    expect(splits(ranks, 5)).toHaveLength(1001);
  });
  it("only the runs that fit: a run that does not fit is never extended, and a split's last run must fit too", () => {
    const sum = (run: number[]) => run.reduce((a, b) => a + b, 0);
    const fits = (run: number[]) => sum(run) <= 5;
    expect(splits([1, 2, 3, 4], 2, fits)).toEqual([]); // 1 | 2+3+4 and 1+2 | 3+4 and 1+2+3 | 4: a run over 5 in each
    expect(splits([1, 2, 3, 4], 3, fits)).toEqual([
      [[1], [2, 3], [4]],
      [[1, 2], [3], [4]],
    ]);
    const all = splits([1, 2, 3, 4], 3);
    expect(all.filter((sp) => sp.every(fits))).toEqual(splits([1, 2, 3, 4], 3, fits));
  });
});
