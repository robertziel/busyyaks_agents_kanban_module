// The board editor's pure geometry and draft edits (no React). The graph is LAID OUT, not hand-placed: dagre (a layered
// Sugiyama layout, MIT, 17 KB) ranks the columns TOP TO BOTTOM along the BOARD ORDER — an arrow against that order is
// laid out reversed and drawn back up, dashed — sizes every node card to its full label (wrapped onto as many lines as it
// needs, never cut), and gives every edge label a box of its own in the layering, so a label never sits on a node or on another
// label. Every route is ORTHOGONAL (vertical runs, horizontal runs on tracks of their own in the gaps between ranks),
// like a flowchart. Hubs stay readable by three drawing rules (planTransitions): a transition with one or two sources
// is one labelled arrow per source; BUNDLE_FROM sources or more, up to half the columns, join a small junction that
// carries the one label and sends one arrow into the target; more than half the columns ("Cancel from every state")
// is a NOTE on the target node, no lines. Transitions with a "*" side are not drawn (every column to every column is a
// hairball); the editor lists them. The graph is as wide as its widest rank and scrolls down; the layout is automatic
// and nothing about it is stored (a board column has no position, SPEC § 2): every open lays the graph out again; a
// drag is a nudge for reading, kept for the session (withMoved).
import dagre, { type EdgeLabel, type GraphLabel, type NodeLabel } from "@dagrejs/dagre";
import type { BoardColumnDef, ColumnType, WorkflowActor, WorkflowTransition } from "../types";
import { ANY } from "./workflow";

export const PAD = 24; // the margin around the drawing
export const MAX_LINE = 26; // characters per node label line before it wraps
export const LINE_H = 18; // a node label line (15px, 600)
export const CHAR_W = 8.6; // the width of a node label character (15px, 600) — a constant, so the layout needs no DOM
export const LABEL_CHAR_W = 7.2; // an edge label character (12px mono)
export const LABEL_H = 22; // an edge label pill
export const NODE_MIN_W = 220;
export const NOTE_H = 18; // a note row inside a node
export const NOTE_CHAR_W = 6.5; // a note character (11.5px)
export const BUNDLE_FROM = 3; // a transition with this many sources (or more) is drawn as one bundle
const NODESEP = 36; // between nodes of one rank
const RANKSEP = 26; // between ranks (a label rank sits between two node ranks, so a hop is 2 × this + the label)
const EDGESEP = 18;
const JUNCTION_H = 24;
const RUN_GAP = 3; // two runs closer than this read as one line (a line is drawn 1.5–3px wide)

export type Pt = { x: number; y: number };
export type Box = { key: string; x: number; y: number; w: number; h: number };
type Side = { ti: number; name: string; to: string; by: WorkflowActor };
export type Arrow = Side & { kind: "arrow"; from: string };
export type Bundle = Side & { kind: "bundle"; froms: string[] };
export type Note = Side & { kind: "note"; froms: string[] };
export type Drawn = Arrow | Bundle | Note;
// one drawn line: a labelled arrow (label at `label`), a bundle's stub (source → junction, no head) or its link
// (junction → target, with the head)
export type Route = {
  id: string;
  ti: number;
  kind: "arrow" | "stub" | "link";
  from: string;
  to: string;
  points: Pt[];
  label: Pt | null;
  back: boolean; // against the board order: drawn back up (dashed)
};
export type Layout = {
  nodes: Record<string, Box>;
  lines: Record<string, string[]>; // each node's wrapped label
  notes: Record<string, Note[]>; // per target node
  junctions: Record<number, Box>; // per bundle (by transition index)
  routes: Route[];
  ranks: number; // how many ranks (rows of columns side by side) the drawing has
  // what the drawing could not keep (a gap still too crowded for its tracks after MAX_TRIES layouts, a run order with
  // a cycle): the editor shows each one — never a silently degraded drawing
  warnings: string[];
  tries: number; // how many dagre layouts this one took (1, plus one per retry of a crowded gap; ≤ MAX_TRIES + 1)
  w: number;
  h: number;
};

export const center = (b: Box): Pt => ({ x: b.x + b.w / 2, y: b.y + b.h / 2 });

// The point on the box's border where a ray from its centre towards `towards` leaves it.
export function borderPoint(b: Box, towards: Pt): Pt {
  const c = center(b);
  const dx = towards.x - c.x;
  const dy = towards.y - c.y;
  if (dx === 0 && dy === 0) return c;
  const t = Math.min(dx === 0 ? Infinity : b.w / 2 / Math.abs(dx), dy === 0 ? Infinity : b.h / 2 / Math.abs(dy));
  return { x: c.x + dx * t, y: c.y + dy * t };
}

const r1 = (n: number) => Math.round(n * 10) / 10;

// An SVG path along the points: straight runs, each corner rounded by a quadratic curve of at most `radius` (and at
// most half of either run), so the drawn line never strays more than a few px from the polyline dagre routed around the
// nodes and labels (a spline through the points would bow out between them, through a node); ends exactly on the last.
export function pathOf(pts: Pt[], radius = 8): string {
  if (pts.length === 0) return "";
  const p0 = pts[0]!;
  let d = `M ${r1(p0.x)} ${r1(p0.y)}`;
  for (let i = 1; i < pts.length - 1; i++) {
    const a = pts[i - 1]!;
    const b = pts[i]!;
    const c = pts[i + 1]!;
    const lin = Math.hypot(b.x - a.x, b.y - a.y);
    const lout = Math.hypot(c.x - b.x, c.y - b.y);
    if (lin === 0 || lout === 0) continue;
    const rIn = Math.min(radius, lin / 2);
    const rOut = Math.min(radius, lout / 2);
    const s0 = { x: b.x - ((b.x - a.x) / lin) * rIn, y: b.y - ((b.y - a.y) / lin) * rIn };
    const s1 = { x: b.x + ((c.x - b.x) / lout) * rOut, y: b.y + ((c.y - b.y) / lout) * rOut };
    d += ` L ${r1(s0.x)} ${r1(s0.y)} Q ${r1(b.x)} ${r1(b.y)} ${r1(s1.x)} ${r1(s1.y)}`;
  }
  if (pts.length > 1) d += ` L ${r1(pts[pts.length - 1]!.x)} ${r1(pts[pts.length - 1]!.y)}`;
  return d;
}

// A node label on as many lines as it needs, broken at a space once a line passes MAX_LINE characters; a single word
// is never cut.
export function wrapLabel(label: string): string[] {
  if (label.length <= MAX_LINE) return [label];
  const words = label.split(" ");
  const lines: string[] = [];
  let cur = "";
  for (const w of words) {
    if (cur && `${cur} ${w}`.length > MAX_LINE) {
      lines.push(cur);
      cur = w;
    } else cur = cur ? `${cur} ${w}` : w;
  }
  lines.push(cur);
  return lines;
}

const sourcesOf = (t: WorkflowTransition, keys: string[]): string[] =>
  (Array.isArray(t.from) ? t.from : [t.from]).filter((k) => keys.includes(k) && k !== t.to);

// How each declared transition is drawn (see the top): arrows, bundles and notes, in transition order.
export function planTransitions(transitions: WorkflowTransition[], keys: string[]): Drawn[] {
  const out: Drawn[] = [];
  transitions.forEach((t, ti) => {
    if (t.to === ANY || t.from === ANY || !keys.includes(t.to)) return;
    const froms = sourcesOf(t, keys);
    if (froms.length === 0) return;
    const side = { ti, name: t.name, to: t.to, by: t.by };
    if (froms.length >= BUNDLE_FROM && froms.length > keys.length / 2) out.push({ ...side, kind: "note", froms });
    else if (froms.length >= BUNDLE_FROM) out.push({ ...side, kind: "bundle", froms });
    else for (const from of froms) out.push({ ...side, kind: "arrow", from });
  });
  return out;
}

// A node's second line ("3 · Asks the operator": its board position and type) and a bundle's pill ("Ask the operator · 6").
export const typeLine = (i: number, type: string): string => `${i + 1} · ${type}`;
export const junctionText = (name: string, n: number): string => `${name || "(unnamed)"} · ${n}`;

// What a note says on its target node ("← Cancel · 12 of 14 columns").
export const noteText = (n: Note, total: number): string =>
  `← ${n.name || "(unnamed)"} · ${n.froms.length} of ${total} columns`;

export const isWildcard = (t: WorkflowTransition): boolean => t.to === ANY || t.from === ANY;

// an edge label pill's width (dagre keeps a box this wide for it; the editor draws the pill this wide)
export const labelW = (name: string): number => (name || "(unnamed)").length * LABEL_CHAR_W + 18;
const junctionKey = (ti: number) => `j:${ti}`;

// A node is a card: the type's icon tile on the left, the label (TITLE lines) and the type line (mono) beside it, an
// optional status pill (`badge`, e.g. "waits for you" on a column the operator approves) at its right end, one row per
// note under the type line. Every offset the editor draws at is here, so the layout and the drawing agree.
export const TILE = 34; // the icon tile's side
export const TILE_X = 12;
export const TEXT_X = TILE_X + TILE + 12; // the label and type line start here
export const TITLE_Y = 27; // the first label line's baseline
export const SUB_DY = 19; // the type line's baseline below the last label line
export const NODE_PAD_B = 15; // below the type line
export const BADGE_H = 22;
export const BADGE_CHAR_W = 7; // a badge character (11.5px, 600)
export const badgeW = (text: string): number => text.length * BADGE_CHAR_W + 18;
const SUB_CHAR_W = 7.2; // a type line character (11.5px mono)

// the type line's baseline and the box's height for a node of `lines` label lines and `notes` note rows
export const subY = (lines: number): number => TITLE_Y + (lines - 1) * LINE_H + SUB_DY;
export const nodeH = (lines: number, notes: number): number => subY(lines) + NODE_PAD_B + NOTE_H * notes;

// the status pill a column's card carries, from its type's rules: it waits for the operator, or it ends the flow
export const typeBadge = (t: ColumnType | undefined): string | null =>
  !t ? null : t.waiting ? "waits for you" : t.finishes ? "✓ done" : t.terminal ? "✕ closed" : null;

export type LayoutOpts = {
  typeLabel: (c: BoardColumnDef) => string; // a column's type line (the host's name for its type)
  badge?: (c: BoardColumnDef) => string | null; // the status pill a node carries (null = none)
  retries?: number; // how many times a crowded gap lays the graph out again (MAX_TRIES when omitted)
};
export const MIN_TEXT_PX = 11; // no text of the default view is drawn smaller than this
export const SMALLEST_FONT_PX = 11.5; // the smallest font the graph's CSS sets (.kb-be-ntype / .kb-be-note; tested)
// the editor never zooms below this by itself (a graph wider than its box at this zoom scrolls)
export const MIN_TEXT_ZOOM = MIN_TEXT_PX / SMALLEST_FONT_PX;
const TRACK = 8; // at least this between two horizontal runs sharing a gap between ranks (a line is drawn 1.5–3px wide)
const PORT_GAP = 12; // between two route ends on one side of a box
const END_INSET = 16; // a route end stays this far inside its box's corners (clear of the rounded corner)
// a gap too crowded for its runs lays the graph out again, the ranks apart by what the worst gap lacked (dagre gives a
// gap between a node rank and a label rank half the rank separation, so twice that), at most this many times
export const MAX_TRIES = 4;

// The drawing: dagre lays the columns out TOP TO BOTTOM (rankdir TB) along the board order — every edge is oriented
// along it (an arrow against it goes into dagre reversed and is drawn back up), so the graph is acyclic and the ranks
// read in board order; columns no forward arrow reaches hang under the column before them. Columns of one rank sit
// side by side (a branch). Then every route is made ORTHOGONAL: each end on the top or bottom side of its box facing
// the route (ends on one side spread PORT_GAP apart), and between two consecutive points — which dagre puts in
// adjacent ranks — a vertical run, a horizontal run on a TRACK of its own in the gap between the two ranks (one track
// per run, so no two runs of different transitions lie along one line), and a vertical run again. A label sits on its
// route's vertical run through the label rank (dagre's own box for it: never on a node or another label).
export function layoutGraph(columns: BoardColumnDef[], transitions: WorkflowTransition[], opts: LayoutOpts): Layout {
  let ranksep = RANKSEP;
  let out = drawGraph(columns, transitions, opts, ranksep);
  let tries = 1;
  for (; out.short > 0 && tries <= (opts.retries ?? MAX_TRIES); tries++) {
    ranksep += Math.ceil(2 * out.short) + 2;
    out = drawGraph(columns, transitions, opts, ranksep);
  }
  return { ...out.layout, warnings: [...out.crowded, ...out.layout.warnings], tries };
}

function drawGraph(
  columns: BoardColumnDef[],
  transitions: WorkflowTransition[],
  opts: LayoutOpts,
  ranksep: number,
): { layout: Omit<Layout, "tries">; crowded: string[]; short: number } {
  const typeLabel = opts.typeLabel;
  const keys = columns.map((c) => c.key);
  const plan = planTransitions(transitions, keys);
  const notes: Record<string, Note[]> = {};
  for (const p of plan) if (p.kind === "note") (notes[p.to] ??= []).push(p);
  const lines: Record<string, string[]> = {};

  const g = new dagre.graphlib.Graph<GraphLabel, NodeLabel, EdgeLabel>({ multigraph: true });
  g.setGraph({ rankdir: "TB", nodesep: NODESEP, ranksep, edgesep: EDGESEP, marginx: PAD, marginy: PAD });
  g.setDefaultEdgeLabel(() => ({}));
  for (const c of columns) {
    const ls = wrapLabel(c.label);
    lines[c.key] = ls;
    const badge = opts.badge?.(c) ?? null;
    const textW = Math.max(
      ...ls.map((l) => l.length * CHAR_W),
      typeLine(keys.indexOf(c.key), typeLabel(c)).length * SUB_CHAR_W,
    );
    const noteW = (notes[c.key] ?? []).map((n) => TEXT_X + noteText(n, keys.length).length * NOTE_CHAR_W + 16);
    const w = Math.max(NODE_MIN_W, TEXT_X + textW + 16 + (badge ? badgeW(badge) + 12 : 0), ...noteW);
    g.setNode(c.key, { width: Math.ceil(w), height: nodeH(ls.length, notes[c.key]?.length ?? 0) });
  }

  // the spine = the board order, a bundle's junction right after the median of its sources
  const spine = [...keys];
  for (const p of plan) {
    if (p.kind !== "bundle") continue;
    const at = p.froms.map((k) => spine.indexOf(k)).sort((a, b) => a - b)[Math.floor((p.froms.length - 1) / 2)]!;
    spine.splice(at + 1, 0, junctionKey(p.ti));
    g.setNode(junctionKey(p.ti), {
      width: junctionText(p.name, p.froms.length).length * LABEL_CHAR_W + 18,
      height: JUNCTION_H,
    });
  }
  const pos = (k: string) => spine.indexOf(k);
  type Rec = { id: string; ti: number; kind: Route["kind"]; from: string; to: string; v: string; w: string };
  const recs: Rec[] = [];
  const reached = new Set<string>();
  const addEdge = (id: string, ti: number, kind: Route["kind"], from: string, to: string, label: EdgeLabel) => {
    const [v, w] = pos(from) > pos(to) ? [to, from] : [from, to];
    g.setEdge(v, w, label, id);
    reached.add(w);
    recs.push({ id, ti, kind, from, to, v, w });
  };
  plan.forEach((p, i) => {
    if (p.kind === "arrow")
      addEdge(`a${i}`, p.ti, "arrow", p.from, p.to, { width: labelW(p.name), height: LABEL_H, labelpos: "c" });
    else if (p.kind === "bundle") {
      p.froms.forEach((f, j) => addEdge(`s${i}.${j}`, p.ti, "stub", f, junctionKey(p.ti), {}));
      addEdge(`l${i}`, p.ti, "link", junctionKey(p.ti), p.to, {});
    }
  });
  // a column nothing comes down into hangs under the one before it (else it would float up to the top rank)
  for (let i = 1; i < spine.length; i++)
    if (!reached.has(spine[i]!)) g.setEdge(spine[i - 1]!, spine[i]!, { weight: 0, minlen: 1 }, `order${i}`);
  dagre.layout(g);

  // dagre places every node it was given; one it did not is a broken layout, never drawn at 0
  const placed = (k: string) => {
    const n = g.node(k);
    if (n.x === undefined || n.y === undefined) throw new Error(`layoutGraph: dagre gave column ${k} no position`);
    return { x: n.x, y: n.y, width: n.width, height: n.height };
  };
  const boxes: Record<string, Box> = {};
  for (const k of spine) {
    const n = placed(k);
    // whole pixels: a dragged node lands on whole pixels too, and every route end is computed from these boxes
    boxes[k] = {
      key: k,
      x: Math.round(n.x - n.width / 2),
      y: Math.round(n.y - n.height / 2),
      w: n.width,
      h: n.height,
    };
  }
  const cy = (k: string) => placed(k).y;

  // ── the ranks: every box's and every route point's y (dagre centres a rank's boxes on one y) ──
  const half = new Map<number, number>(); // rank y → half the height of its tallest box or label
  const note = (y: number, h: number) => half.set(y, Math.max(half.get(y) ?? 0, h / 2));
  for (const k of spine) note(cy(k), boxes[k]!.h);
  type Raw = { rec: Rec; pts: Pt[]; label: Pt | null };
  const raws: Raw[] = recs.map((rec) => {
    const e = g.edge(rec.v, rec.w, rec.id);
    if (!e.points) throw new Error(`layoutGraph: dagre routed no points for ${rec.v} → ${rec.w}`);
    let mid = e.points.slice(1, -1);
    if (rec.v !== rec.from) mid = [...mid].reverse();
    if (rec.kind === "arrow" && (e.x === undefined || e.y === undefined))
      throw new Error(`layoutGraph: dagre gave the label of ${rec.v} → ${rec.w} no position`);
    const label = rec.kind === "arrow" ? { x: e.x!, y: e.y! } : null;
    for (const p of mid) note(p.y, label && p.x === label.x && p.y === label.y ? LABEL_H : 0);
    return { rec, pts: mid, label };
  });
  const ys = [...half.keys()].sort((a, b) => a - b);
  // the gap below rank y (top = its band's bottom, bottom = the next band's top)
  const gapBelow = (y: number) => {
    const i = ys.indexOf(y);
    const n = ys[i + 1]!;
    return { i, top: y + half.get(y)!, bottom: n - half.get(n)! };
  };

  // ── the ends: on the side of the box facing the route, spread along it ──
  type End = { r: number; at: "start" | "end"; box: Box; side: "top" | "bottom"; want: number; x: number };
  const ends: End[] = [];
  raws.forEach((raw, r) => {
    const from = boxes[raw.rec.from]!;
    const to = boxes[raw.rec.to]!;
    const first = raw.pts[0] ?? center(to);
    const last = raw.pts[raw.pts.length - 1] ?? center(from);
    const clampX = (b: Box, x: number) => Math.min(Math.max(x, b.x + END_INSET), b.x + b.w - END_INSET);
    ends.push({
      r,
      at: "start",
      box: from,
      side: first.y < cy(from.key) ? "top" : "bottom",
      want: clampX(from, first.x),
      x: 0,
    });
    ends.push({ r, at: "end", box: to, side: last.y < cy(to.key) ? "top" : "bottom", want: clampX(to, last.x), x: 0 });
  });
  const sides = new Map<string, End[]>();
  for (const e of ends) sides.set(`${e.box.key} ${e.side}`, [...(sides.get(`${e.box.key} ${e.side}`) ?? []), e]);
  for (const list of sides.values()) {
    list.sort((a, b) => a.want - b.want || a.r - b.r);
    const b = list[0]!.box;
    const lo = b.x + END_INSET;
    const hi = b.x + b.w - END_INSET;
    if ((list.length - 1) * PORT_GAP > hi - lo) {
      list.forEach((e, i) => (e.x = list.length === 1 ? b.x + b.w / 2 : lo + ((hi - lo) * i) / (list.length - 1)));
      continue;
    }
    let prev = -Infinity;
    for (const e of list) prev = e.x = Math.max(e.want, prev + PORT_GAP);
    let next = Infinity;
    for (const e of [...list].reverse()) next = e.x = Math.min(e.x, next - PORT_GAP, hi);
  }
  const endBy = new Map(ends.map((e) => [`${e.r} ${e.at}`, e]));
  const endOf = (r: number, at: End["at"]) => {
    const e = endBy.get(`${r} ${at}`)!;
    return { x: e.x, y: e.side === "top" ? e.box.y : e.box.y + e.box.h, rank: cy(e.box.key) };
  };

  // ── the horizontal runs: one per pair of consecutive points at different x, each on a track of its own ──
  // ux / lx = the run's x at its upper / lower end: in the gap it drops from the gap's top at ux to its track, runs
  // across, and drops on from the track at lx to the gap's bottom
  type Run = { r: number; seg: number; gap: number; ux: number; lx: number; y: number };
  const runs: Run[] = [];
  const chains = raws.map((raw, r) => {
    const s = endOf(r, "start");
    const t = endOf(r, "end");
    const ch = [s, ...raw.pts.map((p) => ({ x: p.x, y: p.y, rank: p.y })), t];
    // an end a fraction of a pixel off the point next to it moves onto it (a run that short would only kink the line)
    if (ch.length > 1 && Math.abs(ch[0]!.x - ch[1]!.x) < 0.5) ch[0]!.x = ch[1]!.x;
    const n = ch.length - 1;
    if (n > 0 && Math.abs(ch[n]!.x - ch[n - 1]!.x) < 0.5) ch[n]!.x = ch[n - 1]!.x;
    return ch;
  });
  chains.forEach((ch, r) => {
    for (let i = 0; i + 1 < ch.length; i++) {
      const a = ch[i]!;
      const b = ch[i + 1]!;
      if (a.x === b.x) continue;
      const [u, l] = a.rank < b.rank ? [a, b] : [b, a];
      runs.push({ r, seg: i, gap: gapBelow(u.rank).i, ux: u.x, lx: l.x, y: 0 });
    }
  });
  const crowded: string[] = [];
  let short = 0; // the most a gap lacks for its tracks, px
  const warnings: string[] = [];
  const byGap = new Map<number, Run[]>();
  for (const run of runs) byGap.set(run.gap, [...(byGap.get(run.gap) ?? []), run]);
  for (const [gi, list] of byGap) {
    const { top, bottom } = gapBelow(ys[gi]!);
    // one track per run, top to bottom. A run dropping in at the x another drops out at must be above it (else their
    // drops overlap on one line): those pairs order the tracks (a topological order); the rest go left to right
    list.sort((a, b) => Math.min(a.ux, a.lx) - Math.min(b.ux, b.lx) || a.r - b.r);
    const above = (a: Run, b: Run) =>
      a !== b && raws[a.r]!.rec.ti !== raws[b.r]!.rec.ti && Math.abs(a.ux - b.lx) < RUN_GAP;
    const order: Run[] = [];
    const left = [...list];
    while (left.length) {
      const i = left.findIndex((b) => !left.some((a) => above(a, b)));
      if (i < 0) warnings.push(`gap ${gi}: the runs' order has a cycle; two connectors may overlap where they turn`);
      order.push(...left.splice(i < 0 ? 0 : i, 1));
    }
    const step = (bottom - top) / (order.length + 1);
    if (step < TRACK) short = Math.max(short, (order.length + 1) * TRACK - (bottom - top));
    if (step < TRACK)
      crowded.push(
        `gap ${gi}: ${order.length} connectors turn in ${Math.round(bottom - top)}px; they are drawn closer than ${TRACK}px`,
      );
    order.forEach((run, k) => (run.y = top + step * (k + 1)));
  }

  const runBy = new Map(runs.map((x) => [`${x.r} ${x.seg}`, x]));
  const routes: Route[] = chains.map((ch, r) => {
    const raw = raws[r]!;
    const pts: Pt[] = [{ x: ch[0]!.x, y: ch[0]!.y }];
    for (let i = 0; i + 1 < ch.length; i++) {
      const run = runBy.get(`${r} ${i}`);
      if (run) {
        const fromUpper = ch[i]!.rank < ch[i + 1]!.rank;
        pts.push({ x: fromUpper ? run.ux : run.lx, y: run.y }, { x: fromUpper ? run.lx : run.ux, y: run.y });
      }
      pts.push({ x: ch[i + 1]!.x, y: ch[i + 1]!.y });
    }
    // drop the points in the middle of a straight run (pathOf would round a corner that is not there)
    const clean = pts.filter((p, i) => {
      const a = pts[i - 1];
      const b = pts[i + 1];
      if (!a || !b) return true;
      return !(
        (Math.abs(a.x - p.x) < 0.01 && Math.abs(b.x - p.x) < 0.01) ||
        (Math.abs(a.y - p.y) < 0.01 && Math.abs(b.y - p.y) < 0.01)
      );
    });
    return {
      id: raw.rec.id,
      ti: raw.rec.ti,
      kind: raw.rec.kind,
      from: raw.rec.from,
      to: raw.rec.to,
      points: clean,
      label: raw.label ? { x: raw.label.x, y: raw.label.y } : null,
      back: pos(raw.rec.from) > pos(raw.rec.to),
    };
  });

  // the bounds: every box, route point and label pill inside PAD of the edge (dagre may route a dummy past its margin)
  let minX = Infinity;
  let minY = Infinity;
  let maxX = -Infinity;
  let maxY = -Infinity;
  const take = (x0: number, y0: number, x1: number, y1: number) => {
    minX = Math.min(minX, x0);
    minY = Math.min(minY, y0);
    maxX = Math.max(maxX, x1);
    maxY = Math.max(maxY, y1);
  };
  for (const k of spine) take(boxes[k]!.x, boxes[k]!.y, boxes[k]!.x + boxes[k]!.w, boxes[k]!.y + boxes[k]!.h);
  for (const r of routes) {
    for (const p of r.points) take(p.x, p.y, p.x, p.y);
    if (r.label) {
      const lw = labelW(transitions[r.ti]?.name ?? "");
      take(r.label.x - lw / 2, r.label.y - LABEL_H / 2, r.label.x + lw / 2, r.label.y + LABEL_H / 2);
    }
  }
  if (!Number.isFinite(minX)) [minX, minY, maxX, maxY] = [PAD, PAD, PAD, PAD];
  const dx = Math.round(PAD - minX);
  const dy = Math.round(PAD - minY);
  const at = (p: Pt): Pt => ({ x: r1(p.x + dx), y: r1(p.y + dy) });
  for (const r of routes) {
    r.points = r.points.map(at);
    if (r.label) r.label = at(r.label);
  }
  const nodes: Record<string, Box> = {};
  const junctions: Record<number, Box> = {};
  for (const k of spine) {
    const b = boxes[k]!;
    const rb = { ...b, x: b.x + dx, y: b.y + dy };
    if (k.startsWith("j:")) junctions[Number(k.slice(2))] = rb;
    else nodes[k] = rb;
  }
  const ranks = new Set(keys.map((k) => cy(k))).size;
  return {
    layout: {
      nodes,
      lines,
      notes,
      junctions,
      routes,
      ranks,
      warnings,
      w: Math.ceil(maxX + dx + PAD),
      h: Math.ceil(maxY + dy + PAD),
    },
    crowded,
    short,
  };
}
// The layout with this session's nudges: a moved node keeps its position, the others stay. A move only translates a
// box, so a route end on it moves by the same offset (it stays on the same side, at the same place along it) and the
// corner next to it slides along its track (a horizontal run stays horizontal, the drop to the end stays vertical): a
// nudged drawing is orthogonal too. A straight route (no corner) gets two, half-way between its ends. Cheap: the editor
// applies it on every pointer move without laying out again.
export function withMoved(base: Layout, moved: Record<string, Pt>): Layout {
  if (Object.keys(moved).length === 0) return base;
  const nodes: Record<string, Box> = {};
  const delta: Record<string, Pt> = {};
  for (const [k, b] of Object.entries(base.nodes)) {
    const m = moved[k];
    nodes[k] = m ? { ...b, x: m.x, y: m.y } : b;
    if (m) delta[k] = { x: m.x - b.x, y: m.y - b.y };
  }
  const routes = base.routes.map((r) => {
    const df = delta[r.from];
    const dt = delta[r.to];
    if (!df && !dt) return r;
    let pts = r.points.map((p) => ({ ...p }));
    if (pts.length === 2) {
      // a straight drop: two corners half-way, so either end can move sideways
      const [a, b] = [pts[0]!, pts[1]!];
      const my = (a.y + b.y) / 2;
      pts = [a, { x: a.x, y: my }, { x: b.x, y: my }, b];
    }
    const shift = (end: number, next: number, d: Pt) => {
      const e = pts[end]!;
      const n = pts[next]!;
      const vertical = Math.abs(e.x - n.x) < 0.01;
      e.x += d.x;
      e.y += d.y;
      if (vertical) n.x = e.x;
      else n.y = e.y; // (an end that leaves sideways: its corner slides up or down)
    };
    if (df) shift(0, 1, df);
    if (dt) shift(pts.length - 1, pts.length - 2, dt);
    return { ...r, points: pts.map((p) => ({ x: r1(p.x), y: r1(p.y) })) };
  });
  let w = base.w;
  let h = base.h;
  for (const b of Object.values(nodes)) {
    w = Math.max(w, b.x + b.w + PAD);
    h = Math.max(h, b.y + b.h + PAD);
  }
  return { ...base, nodes, routes, w: Math.ceil(w), h: Math.ceil(h) };
}

// A column key from a label ("In staging" → in_staging), unique among `taken` (in_staging_2, …); the engine's key rule.
export function keyFrom(label: string, taken: string[]): string {
  let base = label
    .toLowerCase()
    .normalize("NFD")
    .replace(/[̀-ͯ]/g, "")
    .replace(/[^a-z0-9]+/g, "_")
    .replace(/^_+|_+$/g, "")
    .slice(0, 36);
  if (!/^[a-z]/.test(base)) base = `c${base ? `_${base}` : ""}`;
  let key = base;
  for (let n = 2; taken.includes(key); n++) key = `${base}_${n}`;
  return key;
}

// Board order: the column at i moved one step (dir -1 = earlier, +1 = later); out of range = unchanged.
export function reorder<T>(list: T[], i: number, dir: -1 | 1): T[] {
  const j = i + dir;
  if (i < 0 || i >= list.length || j < 0 || j >= list.length) return list;
  const out = [...list];
  [out[i], out[j]] = [out[j]!, out[i]!];
  return out;
}

// A column removed from the draft, with every transition that named it: a from-list loses the key (a transition left
// with no from goes), a transition to it goes.
export function removeColumn(
  columns: BoardColumnDef[],
  transitions: WorkflowTransition[],
  key: string,
): { columns: BoardColumnDef[]; transitions: WorkflowTransition[] } {
  const ts = transitions.flatMap((t) => {
    if (t.to === key) return [];
    if (t.from === key) return [];
    if (Array.isArray(t.from)) {
      const left = t.from.filter((k) => k !== key);
      if (left.length === 0) return [];
      return [{ ...t, from: left.length === 1 ? left[0]! : left }];
    }
    return [t];
  });
  return { columns: columns.filter((c) => c.key !== key), transitions: ts };
}

// A column's key renamed in every transition (a new column's key follows its label until it is saved).
export function renameKey(transitions: WorkflowTransition[], from: string, to: string): WorkflowTransition[] {
  const map = (k: string) => (k === from ? to : k);
  return transitions.map((t) => ({ ...t, to: map(t.to), from: Array.isArray(t.from) ? t.from.map(map) : map(t.from) }));
}
