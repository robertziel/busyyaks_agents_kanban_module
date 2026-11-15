// The workflow graph's READABILITY, proven on the real board shapes (fixtures/boards/*.board.json) and 150 random ones:
// the drawn path of every route (sampled along the SVG path the editor draws, pathOf's rounded polyline) never enters
// a node or junction it does not connect; every route is orthogonal; no two transitions' runs lie along one line; no
// label pill sits on a node or another label (a line passes under its own pill: the pill is filled); no two boxes
// overlap; the graph runs top to bottom along the board order and is never wider than the desktop box at a readable zoom.
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import {
  typeBadge,
  layoutGraph,
  MAX_TRIES,
  LABEL_H,
  labelW,
  MIN_TEXT_PX,
  MIN_TEXT_ZOOM,
  pathOf,
  planTransitions,
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
// as the editor does: a type the engine does not know (a stored legacy board's) shows its key, next to the editor's
// "unknown type: <key>" pill
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
      const w = labelW(s.transitions[r.ti]!.name);
      return { key: `label ${r.id}`, x: r.label!.x - w / 2, y: r.label!.y - LABEL_H / 2, w, h: LABEL_H };
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
  // every run is vertical or horizontal (orthogonal connectors)
  for (const r of l.routes)
    r.points.slice(1).forEach((q, i) => {
      const p = r.points[i]!;
      if (Math.abs(p.x - q.x) > 0.01 && Math.abs(p.y - q.y) > 0.01) out.push(`${r.id} diagonal at ${p.x},${p.y}`);
    });
  // two routes of different transitions never run along each other: no two overlapping vertical runs less than 3px
  // apart (a line is drawn up to 3px wide), nor two such horizontal runs
  const runs = l.routes.flatMap((r) => r.points.slice(1).map((q, i) => ({ r, p: r.points[i]!, q })));
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
const DESKTOP_BOX_W = 1434;
const BOARDS = ["legacy_v2_prereview", "local_v4", "legacy_v2", "coding", "content", "local_v3", "mirror_v3"];

describe("the workflow graph is readable on every board shape", () => {
  for (const name of BOARDS)
    it(name, () => {
      const s = shape(name);
      const l = layoutGraph(s.columns, s.transitions, { typeLabel, badge: () => "waits for you" });
      expect(problems(l, s)).toEqual([]);
      expect(l.warnings).toEqual([]);
      // no horizontal scroll on a desktop at a readable zoom
      expect(l.w * MIN_TEXT_ZOOM).toBeLessThanOrEqual(DESKTOP_BOX_W - 2);
    });
});

describe("top to bottom along the board order", () => {
  for (const name of BOARDS)
    it(`${name}: an arrow along the board order runs down (its target below its source), one against it runs back up`, () => {
      const s = shape(name);
      const l = layoutGraph(s.columns, s.transitions, { typeLabel });
      const order = s.columns.map((c) => c.key);
      for (const r of l.routes.filter((x) => x.kind === "arrow")) {
        const down = order.indexOf(r.from) < order.indexOf(r.to);
        expect(r.back, r.id).toBe(!down);
        const a = l.nodes[r.from]!;
        const b = l.nodes[r.to]!;
        if (down) expect(b.y, `${r.from} → ${r.to}`).toBeGreaterThan(a.y + a.h);
        else expect(a.y, `${r.from} → ${r.to}`).toBeGreaterThan(b.y + b.h);
      }
    });
  it("a branch: two columns reached from one, not from each other, sit side by side in one rank; their merge below", () => {
    const col = (key: string) => ({ key, label: key, type: "working" as const, hide_after_hours: 72 });
    const columns = ["check", "manager", "finance", "onboarded"].map(col);
    const transitions = [
      { name: "No", from: "check", to: "manager", by: "any" as const },
      { name: "Yes", from: "check", to: "finance", by: "any" as const },
      { name: "Approve", from: "manager", to: "onboarded", by: "any" as const },
      { name: "Approve", from: "finance", to: "onboarded", by: "any" as const },
    ];
    const l = layoutGraph(columns, transitions, { typeLabel });
    expect(l.nodes.manager!.y).toBe(l.nodes.finance!.y);
    expect(l.nodes.manager!.y).toBeGreaterThan(l.nodes.check!.y);
    expect(l.nodes.onboarded!.y).toBeGreaterThan(l.nodes.finance!.y);
    expect(l.ranks).toBe(3);
    expect(problems(l, { columns, transitions })).toEqual([]);
  });
  it("a badge widens its card", () => {
    const s = shape("coding");
    const plain = layoutGraph(s.columns, s.transitions, { typeLabel });
    const badged = layoutGraph(s.columns, s.transitions, { typeLabel, badge: () => "waits for you" });
    const k = s.columns[0]!.key;
    expect(badged.nodes[k]!.w).toBeGreaterThanOrEqual(plain.nodes[k]!.w);
  });
});

// dagre runs once, and again per crowded gap (up to MAX_TRIES more): the work bound is counted, not timed — a
// wall-clock bound measured the CI host (one agent ran a layout 10× slower than a laptop), not the code
it("layoutGraph runs dagre at most MAX_TRIES + 1 times, and the 15-column local board needs 2", () => {
  const s = shape("local_v4");
  expect(layoutGraph(s.columns, s.transitions, { typeLabel }).tries).toBe(2);
  expect(layoutGraph(s.columns, s.transitions, { typeLabel, retries: 0 }).tries).toBe(1);
  for (const f of ["coding", "content", "legacy_v2", "legacy_v2_prereview", "local_v3", "local_v4", "mirror_v3"]) {
    const b = shape(f);
    expect(layoutGraph(b.columns, b.transitions, { typeLabel }).tries).toBeLessThanOrEqual(MAX_TRIES + 1);
  }
});

describe("a drawing it cannot keep is said, never silently degraded", () => {
  it("a gap still too crowded after its retries: a warning names it; with the retries the same board lays out clean", () => {
    const col = (key: string) => ({ key, label: key, type: "working" as const, hide_after_hours: 72 });
    const columns = ["a", "b", "c"].map(col);
    // 40 transitions a → b and b → c: their label boxes sit side by side, and every one turns in the gaps
    const transitions = Array.from({ length: 40 }, (_, i) => ({
      name: `t${i}`,
      from: i % 2 ? "a" : "b",
      to: i % 2 ? "c" : "a",
      by: "any" as const,
    }));
    expect(layoutGraph(columns, transitions, { typeLabel }).warnings).toEqual([]);
    const l = layoutGraph(columns, transitions, { typeLabel, retries: 0 });
    expect(l.warnings.length).toBeGreaterThan(0);
    expect(l.warnings[0]).toMatch(/^gap \d+: \d+ connectors turn in \d+px/);
  });
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
describe("readable on 150 seeded random boards", () => {
  const rnd = mulberry32(234);
  const all = Array.from({ length: 150 }, () => randomBoard(rnd));
  for (let from = 0; from < all.length; from += 10)
    it(`boards ${from}..${from + 9}: no route through a node, no label on a label or node, no two transitions along one line`, () => {
      const bad: string[] = [];
      all.slice(from, from + 10).forEach((s, i) => {
        // the editor's own pills: a column the operator approves "waits for you", a done one "✓ done", others none
        const badge = (c: { type: string }) => typeBadge(TYPES.find((t) => t.key === c.type));
        const l = layoutGraph(s.columns, s.transitions, { typeLabel, badge });
        const pr = [...problems(l, s), ...l.warnings];
        if (pr.length) bad.push(`board ${from + i}: ${pr.slice(0, 2).join("; ")}`);
      });
      expect(bad).toEqual([]);
    });
});

describe("the smallest text the graph draws", () => {
  it(`every .kb-be-* font in the graph is at least SMALLEST_FONT_PX (${SMALLEST_FONT_PX}px), so MIN_TEXT_ZOOM keeps it ≥ ${MIN_TEXT_PX}px`, () => {
    const css = readFileSync(join(__dirname, "..", "src", "styles", "kanban.css"), "utf8");
    const graphClasses = ["kb-be-nlabel", "kb-be-ntype", "kb-be-note", "kb-be-jlabel", "kb-be-elabel", "kb-be-btext"];
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
  it("local v4 (15 columns): Cancel (13 of 15 sources) and Rework (8) are notes — more than half; both review loops are arrows both ways", () => {
    const s = shape("local_v4");
    const l = layoutGraph(s.columns, s.transitions, { typeLabel });
    expect(l.notes.cancelled!.map((n) => n.name)).toEqual(["Cancel"]);
    expect(l.notes.doing!.map((n) => n.name)).toEqual(["Rework"]);
    expect(Object.keys(l.junctions)).toEqual([]);
    const names = (from: string, to: string) =>
      l.routes.filter((r) => r.from === from && r.to === to).map((r) => s.transitions[r.ti]!.name);
    expect(names("local_agent_review", "local_author")).toEqual(["Comments posted"]);
    expect(names("local_author", "local_agent_review")).toEqual(["All threads answered"]);
    expect(names("public_agent_review", "public_author")).toEqual(["Comments posted"]);
    expect(names("public_author", "public_agent_review")).toEqual(["All threads answered"]);
  });
});
