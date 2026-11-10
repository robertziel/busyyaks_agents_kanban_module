// The workflow graph's READABILITY, proven on the real board shapes (fixtures/boards/*.board.json) at the widths the
// editor folds for: the drawn path of every route (sampled along the SVG path the editor draws, pathOf's rounded
// polyline) never enters a node or junction it does not connect; no two transitions' runs lie along one line; no label sits on a node or another label
// (a line may pass under a label: .kb-be-elabel draws a halo in the panel colour behind its text); no two boxes overlap; a folded drawing is never wider than it was asked to be.
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import {
  foldGraph,
  layoutGraph,
  LABEL_CHAR_W,
  MIN_TEXT_PX,
  MIN_TEXT_ZOOM,
  pathOf,
  planTransitions,
  rankGraph,
  SMALLEST_FONT_PX,
  type Box,
  type Layout,
  type Pt,
  type Route,
} from "../src/lib/graph";
import type { BoardShape } from "../src/types";
import { TYPES } from "./fixtures";

const boards = join(__dirname, "..", "..", "fixtures", "boards");
const shape = (name: string) => JSON.parse(readFileSync(join(boards, `${name}.board.json`), "utf8")) as BoardShape;
const typeLabel = (c: { type: string }) => TYPES.find((t) => t.key === c.type)?.label ?? c.type;

// ── geometry ──
const right = (b: Box) => b.x + b.w;
const bottom = (b: Box) => b.y + b.h;
const overlap = (a: Box, b: Box) => a.x < right(b) && b.x < right(a) && a.y < bottom(b) && b.y < bottom(a);
const inside = (p: Pt, b: Box, slack: number) =>
  p.x > b.x + slack && p.x < right(b) - slack && p.y > b.y + slack && p.y < bottom(b) - slack;

// the points along an SVG path made of M / L / C / Q commands (pathOf writes M / L / Q)
function sample(d: string, step = 0.05): Pt[] {
  const tok = d.trim().split(/\s+/);
  const out: Pt[] = [];
  let cur: Pt = { x: 0, y: 0 };
  const num = (i: number) => Number(tok[i]);
  for (let i = 0; i < tok.length;) {
    const c = tok[i]!;
    if (c === "M") {
      cur = { x: num(i + 1), y: num(i + 2) };
      out.push(cur);
      i += 3;
    } else if (c === "L") {
      const p = { x: num(i + 1), y: num(i + 2) };
      for (let t = step; t <= 1; t += step) out.push({ x: cur.x + (p.x - cur.x) * t, y: cur.y + (p.y - cur.y) * t });
      cur = p;
      i += 3;
    } else if (c === "Q") {
      const q = { x: num(i + 1), y: num(i + 2) };
      const p = { x: num(i + 3), y: num(i + 4) };
      for (let t = step; t <= 1; t += step) {
        const u = 1 - t;
        out.push({
          x: u * u * cur.x + 2 * u * t * q.x + t * t * p.x,
          y: u * u * cur.y + 2 * u * t * q.y + t * t * p.y,
        });
      }
      cur = p;
      i += 5;
    } else if (c === "C") {
      const a = { x: num(i + 1), y: num(i + 2) };
      const b = { x: num(i + 3), y: num(i + 4) };
      const p = { x: num(i + 5), y: num(i + 6) };
      for (let t = step; t <= 1; t += step) {
        const u = 1 - t;
        const f = (k: "x" | "y") => u * u * u * cur[k] + 3 * u * u * t * a[k] + 3 * u * t * t * b[k] + t * t * t * p[k];
        out.push({ x: f("x"), y: f("y") });
      }
      cur = p;
      i += 7;
    } else throw new Error(`unknown path command ${c} in ${d}`);
  }
  return out;
}
const drawn = (r: Route) => pathOf(r.points);

function labelBoxes(l: Layout, s: BoardShape): Box[] {
  return l.routes
    .filter((r) => r.label)
    .map((r) => {
      const w = (s.transitions[r.ti]!.name || "(unnamed)").length * LABEL_CHAR_W + 10;
      return { key: `label ${r.id}`, x: r.label!.x - w / 2, y: r.label!.y - 9, w, h: 18 };
    });
}

function problems(l: Layout, s: BoardShape): string[] {
  const out: string[] = [];
  const boxes = [...Object.values(l.nodes), ...Object.values(l.junctions)];
  const labels = labelBoxes(l, s);
  for (let i = 0; i < boxes.length; i++)
    for (let j = i + 1; j < boxes.length; j++)
      if (overlap(boxes[i]!, boxes[j]!)) out.push(`${boxes[i]!.key} overlaps ${boxes[j]!.key}`);
  for (let i = 0; i < labels.length; i++) {
    for (let j = i + 1; j < labels.length; j++)
      if (overlap(labels[i]!, labels[j]!)) out.push(`${labels[i]!.key} on ${labels[j]!.key}`);
    for (const b of boxes) if (overlap(labels[i]!, b)) out.push(`${labels[i]!.key} on ${b.key}`);
  }
  for (const r of l.routes) {
    const pts = sample(drawn(r));
    const touches = (k: string) => k === r.from || k === r.to || k === `j:${r.ti}`;
    for (const b of boxes)
      if (!touches(b.key) && pts.some((p) => inside(p, b, 2))) out.push(`${r.id} (${r.from}→${r.to}) through ${b.key}`);
  }
  // two routes of different transitions never run along each other: no two overlapping vertical runs less than 3px
  // apart (a line is drawn up to 3px wide), nor two such horizontal runs (the orthogonal routes between rows, and their stubs at a node's border)
  const runs = l.routes
    .filter((r) => r.ortho)
    .flatMap((r) => r.points.slice(1).map((q, i) => ({ r, p: r.points[i]!, q })));
  const span = (u: number, v: number) => [Math.min(u, v), Math.max(u, v)] as const;
  const shared = (a: readonly [number, number], b: readonly [number, number]) =>
    Math.min(a[1], b[1]) - Math.max(a[0], b[0]);
  for (let i = 0; i < runs.length; i++)
    for (let j = i + 1; j < runs.length; j++) {
      const a = runs[i]!;
      const b = runs[j]!;
      if (a.r.ti === b.r.ti) continue;
      const va = Math.abs(a.p.x - a.q.x) < 0.5;
      const vb = Math.abs(b.p.x - b.q.x) < 0.5;
      if (va && vb && Math.abs(a.p.x - b.p.x) < 3 && shared(span(a.p.y, a.q.y), span(b.p.y, b.q.y)) > 0)
        out.push(`${a.r.id} runs along ${b.r.id} at x ${a.p.x}`);
      if (!va && !vb && Math.abs(a.p.y - b.p.y) < 3 && shared(span(a.p.x, a.q.x), span(b.p.x, b.q.x)) > 0)
        out.push(`${a.r.id} runs along ${b.r.id} at y ${a.p.y}`);
    }
  for (const b of boxes)
    if (b.x < 0 || b.y < 0 || right(b) > l.w || bottom(b) > l.h) out.push(`${b.key} out of bounds`);
  for (const r of l.routes)
    for (const p of sample(drawn(r)))
      if (p.x < 0 || p.y < 0 || p.x > l.w || p.y > l.h) {
        out.push(`${r.id} out of bounds at ${p.x},${p.y}`);
        break;
      }
  return out;
}

// the box the editor gets at 1920 × 1080 (the dialog's graph column, measured in Chromium: 1434 on the local preview)
// and on a 390px phone (322 there)
const DESKTOP_BOX_W = 1434;
const PHONE_BOX_W = 322;
const fold = (boxW: number) => (boxW - 2) / MIN_TEXT_ZOOM;

describe("the workflow graph is readable on every board shape, at every fold", () => {
  for (const name of ["legacy_v2_prereview", "local_v3", "legacy_v2", "coding", "content"]) {
    for (const [what, maxWidth] of [
      ["one row", Infinity],
      ["1920px desktop", fold(DESKTOP_BOX_W)],
      ["1280px laptop", fold(900)],
      ["phone", fold(PHONE_BOX_W)],
    ] as const) {
      it(`${name} · ${what}`, () => {
        const s = shape(name);
        const l = layoutGraph(s.columns, s.transitions, { typeLabel, maxWidth });
        expect(problems(l, s)).toEqual([]);
        // as wide as asked, or folded as far as it goes (one rank per row: a phone scrolls)
        if (Number.isFinite(maxWidth) && l.w > maxWidth) expect(l.rows).toBe(l.ranks);
        if (!Number.isFinite(maxWidth)) expect(l.rows).toBe(1);
      });
    }
  }
});

// every graph box width from a phone to a wide screen, in 10px steps: the fold changes at many of them. dagre runs once
// per board (rankGraph: the width does not reach it) and every width folds that one drawing (foldGraph, what layoutGraph
// does); a fold equal to one already checked has the same problems (problems() is a pure function of the layout), so
// each distinct drawing is checked once — every width still gets its own fold and its own width check
describe("readable at every box width from 300 to 2400px", () => {
  const BANDS = [
    [300, 900],
    [910, 1600],
    [1610, 2400],
  ] as const;
  for (const name of ["legacy_v2_prereview", "local_v3", "legacy_v2", "coding", "content"]) {
    const s = shape(name);
    let ranked: ReturnType<typeof rankGraph> | undefined;
    const checked = new Map<string, string[]>();
    for (const [lo, hi] of BANDS)
      it(`${name} · ${lo}..${hi}px`, () => {
        ranked ??= rankGraph(s.columns, s.transitions, { typeLabel });
        const bad: string[] = [];
        for (let boxW = lo; boxW <= hi; boxW += 10) {
          const l = foldGraph(ranked, fold(boxW));
          const key = JSON.stringify(l);
          let pr = checked.get(key);
          if (!pr) checked.set(key, (pr = problems(l, s)));
          if (pr.length) bad.push(`${boxW}px: ${pr.slice(0, 3).join("; ")}`);
          if (l.w > fold(boxW) && l.rows !== l.ranks) bad.push(`${boxW}px: ${l.w} wide in ${l.rows} rows`);
        }
        expect(bad).toEqual([]);
      });
  }
});

// seeded random boards (mulberry32: the same boards on every run): 2..19 columns of random labels (one word longer than
// a line) and types, forward arrows, up to 1.5 × n more transitions — back edges, many-to-one (bundles and notes),
// unnamed ones — at 8 box widths each
function mulberry32(seed: number) {
  return () => {
    seed = (seed + 0x6d2b79f5) | 0;
    let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}
function randomBoard(rnd: () => number): BoardShape {
  const words = [
    "Review",
    "PR",
    "(mirror)",
    "Public",
    "Agent",
    "Human",
    "Waiting",
    "for",
    "approval",
    "Deployed",
    "locally",
    "Supercalifragilisticexpialidocious",
    "QA",
    "x",
  ];
  const pick = <T>(xs: readonly T[]) => xs[Math.floor(rnd() * xs.length)]!;
  const text = (max: number) => Array.from({ length: 1 + Math.floor(rnd() * max) }, () => pick(words)).join(" ");
  const n = 2 + Math.floor(rnd() * 18);
  const columns = Array.from({ length: n }, (_, i) => ({
    key: `c${i}`,
    label: text(5),
    type: pick(TYPES).key,
    hide_after_hours: 72,
  }));
  const transitions: BoardShape["transitions"] = [];
  for (let i = 0; i + 1 < n; i++)
    if (rnd() < 0.85) transitions.push({ name: text(4), from: `c${i}`, to: `c${i + 1}`, by: "any" });
  for (let e = Math.floor(rnd() * n * 1.5); e > 0; e--) {
    const to = `c${Math.floor(rnd() * n)}`;
    const k = rnd() < 0.3 ? 1 + Math.floor(rnd() * n) : 1;
    const froms = [...new Set(Array.from({ length: k }, () => `c${Math.floor(rnd() * n)}`))].filter((f) => f !== to);
    if (!froms.length) continue;
    transitions.push({
      name: rnd() < 0.1 ? "" : text(5),
      from: froms.length === 1 ? froms[0]! : froms,
      to,
      by: pick(["agent", "operator", "any"] as const),
    });
  }
  return { columns, transitions };
}
describe("readable on 150 seeded random boards, at 8 box widths each", () => {
  const rnd = mulberry32(234);
  const all = Array.from({ length: 150 }, () => randomBoard(rnd));
  for (let from = 0; from < all.length; from += 10)
    it(`boards ${from}..${from + 9}: no route through a node, no label on a label or node, no two transitions along one line`, () => {
      const bad: string[] = [];
      all.slice(from, from + 10).forEach((s, i) => {
        const ranked = rankGraph(s.columns, s.transitions, { typeLabel }); // dagre once per board, folded per width
        for (const boxW of [322, 520, 700, 900, 1100, 1434, 1800, 2400]) {
          const l = foldGraph(ranked, fold(boxW));
          const pr = problems(l, s);
          if (pr.length) bad.push(`board ${from + i} at ${boxW}px: ${pr.slice(0, 2).join("; ")}`);
        }
      });
      expect(bad).toEqual([]);
    });
});

describe("the default view at 1920 × 1080 shows the whole graph at a readable size", () => {
  // the graph box's max-height as kanban.css sets it (calc(100vh - Npx)), at a 1080px viewport
  const css = readFileSync(join(__dirname, "..", "src", "styles", "kanban.css"), "utf8");
  const m = /\.ak-root \.kb-be-graph \{[^}]*max-height:\s*calc\(\s*100vh - (\d+)px\s*\)/.exec(css);
  if (!m) throw new Error(".kb-be-graph max-height is not calc(100vh - Npx): update this test with the new rule");
  const BOX_H = 1080 - Number(m[1]);
  for (const name of ["legacy_v2_prereview", "local_v3"]) {
    it(`${name}: folded into rows, no horizontal scroll, the whole height inside the box, text ≥ ${MIN_TEXT_PX}px`, () => {
      const s = shape(name);
      const l = layoutGraph(s.columns, s.transitions, { typeLabel, maxWidth: fold(DESKTOP_BOX_W) });
      expect(l.rows).toBeGreaterThan(1);
      const zoom = Math.min(1, (DESKTOP_BOX_W - 2) / l.w, (BOX_H - 2) / l.h);
      expect(zoom).toBeGreaterThanOrEqual(MIN_TEXT_ZOOM);
      expect(l.w * zoom).toBeLessThanOrEqual(DESKTOP_BOX_W - 2);
      expect(l.h * zoom).toBeLessThanOrEqual(BOX_H - 2);
      expect(SMALLEST_FONT_PX * zoom).toBeGreaterThanOrEqual(MIN_TEXT_PX);
    });
  }
});

describe("the smallest text the graph draws", () => {
  it(`every .kb-be-* font in the graph is at least SMALLEST_FONT_PX (${SMALLEST_FONT_PX}px), so MIN_TEXT_ZOOM keeps it ≥ ${MIN_TEXT_PX}px`, () => {
    const css = readFileSync(join(__dirname, "..", "src", "styles", "kanban.css"), "utf8");
    const graphClasses = ["kb-be-nlabel", "kb-be-ntype", "kb-be-note", "kb-be-jlabel", "kb-be-elabel"];
    for (const cls of graphClasses) {
      const rule = new RegExp(`\\.ak-root \\.${cls} \\{([^}]*)\\}`).exec(css);
      expect(rule, cls).not.toBeNull();
      const px = /font-size:\s*([\d.]+)px/.exec(rule![1]!);
      expect(px, `${cls} sets its font-size`).not.toBeNull();
      expect(Number(px![1])).toBeGreaterThanOrEqual(SMALLEST_FONT_PX);
    }
    expect(SMALLEST_FONT_PX * MIN_TEXT_ZOOM).toBeGreaterThanOrEqual(MIN_TEXT_PX);
  });
});

describe("hubs on the real boards", () => {
  it("legacy v2 (13 columns): Ask the operator and Fixes needed are two bundles of 6, every other transition an arrow", () => {
    const s = shape("legacy_v2_prereview");
    const plan = planTransitions(
      s.transitions,
      s.columns.map((c) => c.key),
    );
    expect(plan.filter((p) => p.kind === "bundle").map((p) => [p.name, p.froms.length])).toEqual([
      ["Ask the operator", 6],
      ["Fixes needed", 6],
    ]);
    expect(plan.filter((p) => p.kind === "arrow")).toHaveLength(12);
    expect(plan.filter((p) => p.kind === "note")).toHaveLength(0);
  });
  it("local v3 (14 columns): Cancel (12 of 14 sources) is a note, Rework (7) one bundle; both review loops are arrows both ways", () => {
    const s = shape("local_v3");
    const l = layoutGraph(s.columns, s.transitions, { typeLabel, maxWidth: fold(DESKTOP_BOX_W) });
    expect(l.notes.cancelled!.map((n) => n.name)).toEqual(["Cancel"]);
    expect(Object.keys(l.junctions).map((ti) => s.transitions[Number(ti)]!.name)).toEqual(["Rework"]);
    const names = (from: string, to: string) =>
      l.routes.filter((r) => r.from === from && r.to === to).map((r) => s.transitions[r.ti]!.name);
    expect(names("local_agent_review", "local_author")).toEqual(["Comments posted"]);
    expect(names("local_author", "local_agent_review")).toEqual(["All threads answered"]);
    expect(names("public_agent_review", "public_author")).toEqual(["Comments posted"]);
    expect(names("public_author", "public_agent_review")).toEqual(["All threads answered"]);
  });
});
