import { describe, expect, it } from "vitest";
import {
  borderPoint,
  BUNDLE_FROM,
  junctionText,
  keyFrom,
  layoutGraph,
  LINE_H,
  MAX_LINE,
  NOTE_CHAR_W,
  NOTE_H,
  subY,
  TEXT_X,
  pathOf,
  planTransitions,
  removeColumn,
  renameKey,
  reorder,
  nodeH,
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
// the type line shows the raw type key: these tests pick no host names for the types
const OPTS = { typeLabel: (c: BoardColumnDef) => c.type };
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
  it("keeps a short label on one line and wraps a long one at word boundaries, every line up to MAX_LINE", () => {
    expect(wrapLabel("In progress")).toEqual(["In progress"]);
    expect(wrapLabel("Public: Author response")).toEqual(["Public: Author response"]);
    expect(wrapLabel("Waiting for the operator's final approval")).toEqual([
      "Waiting for the operator's",
      "final approval",
    ]);
    expect(wrapLabel("a".repeat(MAX_LINE + 5))).toEqual(["a".repeat(MAX_LINE + 5)]); // one word: never cut
    const long = "Waiting for the operator's final approval before the public release goes out";
    const lines = wrapLabel(long);
    expect(lines.length).toBeGreaterThan(2);
    expect(lines.join(" ")).toBe(long);
    for (const l of lines) expect(l.length).toBeLessThanOrEqual(MAX_LINE);
  });
});

describe("layoutGraph — dagre top to bottom along the board order", () => {
  const chain = ["backlog", "todo", "doing", "review", "done"].map((k) => col(k, k[0]!.toUpperCase() + k.slice(1)));
  const ts: WorkflowTransition[] = [
    { name: "Prioritise", from: "backlog", to: "todo", by: "any" },
    { name: "Start work", from: "todo", to: "doing", by: "any" },
    { name: "Request review", from: "doing", to: "review", by: "agent" },
    { name: "Fixes needed", from: "review", to: "doing", by: "any" },
    { name: "Ship", from: "review", to: "done", by: "operator" },
  ];
  it("ranks follow the board order: each column sits below the one before; nodes are sized to their wrapped label", () => {
    const l = layoutGraph(chain, ts, OPTS);
    const ys = chain.map((c) => l.nodes[c.key]!.y);
    for (let i = 1; i < ys.length; i++) expect(ys[i]!).toBeGreaterThan(bottom(l.nodes[chain[i - 1]!.key]!));
    expect(l.nodes.backlog!.h).toBe(nodeH(1, 0));
    expect(nodeH(2, 1)).toBe(subY(2) + 15 + NOTE_H);
    expect(subY(2) - subY(1)).toBe(LINE_H);
    const label = "Waiting for the operator's final approval";
    const wide = layoutGraph([col("a", label), col("b", "x")], [], OPTS);
    expect(wide.lines.a).toEqual(["Waiting for the operator's", "final approval"]);
    expect(wide.nodes.a!.h).toBe(nodeH(2, 0));
    expect(wide.nodes.a!.w).toBeGreaterThan(wide.nodes.b!.w);
    expect(wide.nodes.a!.w).toBeGreaterThanOrEqual(TEXT_X + "Waiting for the operator's".length * 8.6);
  });
  it("an arrow against the board order is laid out reversed and drawn back: it starts at its source and ends on its target's border", () => {
    const l = layoutGraph(chain, ts, OPTS);
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
    const narrow = layoutGraph([col("a", "x", "gate"), col("b", "y")], [], OPTS);
    const wide = layoutGraph([col("a", "x", "gate"), col("b", "y")], [], {
      typeLabel: (c) => (c.type === "gate" ? "Waits for the operator" : c.type),
    });
    expect(wide.nodes.a!.w).toBeGreaterThan(narrow.nodes.a!.w);
    expect(wide.nodes.a!.w).toBeGreaterThanOrEqual(TEXT_X + typeLine(0, "Waits for the operator").length * NOTE_CHAR_W);
    const six = ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m"].map((k) => col(k));
    const l = layoutGraph(
      six,
      [{ name: "Ask the operator", from: ["b", "c", "d", "e", "f", "g"], to: "a", by: "agent" }],
      OPTS,
    );
    expect(l.junctions[0]!.w).toBeGreaterThanOrEqual(junctionText("Ask the operator", 6).length * 7 + 18);
    expect(junctionText("", 3)).toBe("(unnamed) · 3");
  });
  it("every route is orthogonal: it leaves its source on the top or bottom border, ends on its target's, and runs only up, down or across", () => {
    const l = layoutGraph(chain, ts, OPTS);
    for (const r of l.routes) {
      const first = r.points[0]!;
      const last = r.points[r.points.length - 1]!;
      expect(onBorder(first, l.nodes[r.from]!)).toBe(true);
      expect([l.nodes[r.from]!.y, bottom(l.nodes[r.from]!)]).toContain(first.y);
      expect([l.nodes[r.to]!.y, bottom(l.nodes[r.to]!)]).toContain(last.y);
      for (let i = 1; i < r.points.length; i++) {
        const p = r.points[i - 1]!;
        const q = r.points[i]!;
        expect(p.x === q.x || p.y === q.y).toBe(true);
      }
    }
    expect(l.routes.filter((r) => r.back).map((r) => r.ti)).toEqual([3]); // Fixes needed: review → doing, back up
  });
  it("is deterministic", () => {
    expect(layoutGraph(chain, ts, OPTS)).toEqual(layoutGraph(chain, ts, OPTS));
  });
  it("a note: the target node grows a row per note; no route is drawn for it", () => {
    const ts2: WorkflowTransition[] = [
      ...ts,
      { name: "Cancel", from: ["backlog", "todo", "doing", "review"], to: "done", by: "operator" },
    ];
    const l = layoutGraph(chain, ts2, OPTS);
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
    expect(l.nodes.done!.h).toBe(l.nodes.backlog!.h + NOTE_H);
    expect(l.nodes.done!.w).toBeGreaterThan(l.nodes.backlog!.w); // wide enough for the note text
    expect(l.routes.some((r) => r.ti === 5)).toBe(false);
  });
  it("a moved node keeps its place; the routes touching it end on its new border, still orthogonal; the others stay", () => {
    const base = layoutGraph(chain, ts, OPTS);
    for (const to of [
      { x: 400, y: 300 },
      { x: 3, y: 900 },
      { x: base.nodes.doing!.x + 37, y: base.nodes.doing!.y - 5 },
    ]) {
      const moved = withMoved(base, { doing: to, done: { x: 50, y: 40 } });
      expect(moved.nodes.doing).toMatchObject(to);
      expect(moved.nodes.backlog).toEqual(base.nodes.backlog);
      for (const r of moved.routes) {
        const first = r.points[0]!;
        const last = r.points[r.points.length - 1]!;
        expect(onBorder(first, moved.nodes[r.from]!), r.id).toBe(true);
        expect(onBorder(last, moved.nodes[r.to]!), r.id).toBe(true);
        for (let i = 1; i < r.points.length; i++) {
          const p = r.points[i - 1]!;
          const q = r.points[i]!;
          expect(Math.abs(p.x - q.x) < 0.01 || Math.abs(p.y - q.y) < 0.01, `${r.id} segment ${i}`).toBe(true);
        }
      }
      expect(moved.routes.find((r) => r.ti === 0)).toEqual(base.routes.find((r) => r.ti === 0));
      expect(moved.h).toBeGreaterThanOrEqual(to.y + moved.nodes.doing!.h);
    }
  });
  it("an empty board has a size", () => {
    expect(layoutGraph([], [], OPTS)).toMatchObject({ nodes: {}, routes: [] });
    expect(layoutGraph([], [], OPTS).w).toBeGreaterThan(0);
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
