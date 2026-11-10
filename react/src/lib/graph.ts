// The board editor's pure geometry and draft edits (no React). The graph is LAID OUT, not hand-placed: dagre (a layered
// Sugiyama layout, MIT, 17 KB) ranks the columns left to right along the BOARD ORDER — an arrow against that order is
// laid out reversed and drawn back over the flow — sizes every node to its full label (wrapped onto two lines, never
// cut), and gives every edge label a box of its own in the layering, so a label never sits on a node or on another
// label. Hubs stay readable by three drawing rules (planTransitions): a transition with one or two sources is one
// labelled arrow per source; BUNDLE_FROM sources or more, up to half the columns, join a small junction that carries the
// one label and sends one arrow into the target; more than half the columns ("Cancel from every state") is a NOTE on
// the target node, no lines. Transitions with a "*" side are not drawn (every column to every column is a hairball);
// the editor lists them. The ranks are FOLDED into rows that fit the editor's box (layoutGraph `maxWidth`), so the whole
// board is on screen at a readable size; an arrow between rows runs through the gutter between them. The layout is
// automatic and nothing about it is stored (a board column has no position, SPEC § 2): every open lays the graph out
// again; a drag is a nudge for reading, kept for the session (withMoved).
import dagre, { type EdgeLabel, type GraphLabel, type NodeLabel } from "@dagrejs/dagre";
import type { BoardColumnDef, WorkflowActor, WorkflowTransition } from "../types";
import { ANY } from "./workflow";

export const PAD = 20; // the margin around the drawing
export const MAX_LINE = 14; // characters per node label line before it wraps
export const LINE_H = 17; // a node label line (14px, 600)
export const CHAR_W = 8; // the width of a node label character (14px, 600) — a constant, so the layout needs no DOM
export const LABEL_CHAR_W = 7; // an edge label character (13px, 500)
export const NODE_MIN_W = 110;
export const NOTE_H = 18; // a note row inside a node
export const NOTE_CHAR_W = 6.5; // a note character (11.5px)
export const BUNDLE_FROM = 3; // a transition with this many sources (or more) is drawn as one bundle
const NODESEP = 22; // between nodes of one rank
const RANKSEP = 28; // between ranks (a label rank sits between two node ranks, so a hop is 2 × this + the label)
const EDGESEP = 14;
const JUNCTION_H = 22;

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
  ortho: boolean; // a route between two rows (orthogonal, through the gutter); else dagre's own route within a row
};
export type Layout = {
  nodes: Record<string, Box>;
  lines: Record<string, string[]>; // each node's wrapped label
  notes: Record<string, Note[]>; // per target node
  junctions: Record<number, Box>; // per bundle (by transition index)
  routes: Route[];
  rows: number; // how many rows the ranks were folded into
  ranks: number; // how many ranks (columns side by side) the board has: rows = ranks is the narrowest fold
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

// A node label on at most two lines, broken at a space once it passes MAX_LINE characters; a single word is never cut.
export function wrapLabel(label: string): string[] {
  if (label.length <= MAX_LINE) return [label];
  const words = label.split(" ");
  const lines: string[] = [];
  let cur = "";
  for (const w of words) {
    if (cur && lines.length === 0 && `${cur} ${w}`.length > MAX_LINE) {
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

const labelW = (name: string) => (name || "(unnamed)").length * LABEL_CHAR_W + 10;
const junctionKey = (ti: number) => `j:${ti}`;

// The flat drawing dagre makes: node boxes, the bundles' junctions, every route with its points (dagre's, through the
// border intersections it computes) and label point. `typeLabel` = the type's label as the node's second line shows
// it (the host's type set), so the box is wide enough for it. Then FOLDED into rows (`maxWidth`): a 13-column board
// laid out left to right is ~3000px wide, which no screen shows at a readable size, so the rank sequence wraps like
// text — a row holds as many ranks as fit, the next row continues under it — and an arrow between two rows runs
// through the gutter between them (orthogonal, one lane per arrow, its label on the gutter run), never through a node.
export type LayoutOpts = {
  typeLabel?: (c: BoardColumnDef) => string;
  maxWidth?: number; // fold the ranks into rows no wider than this (Infinity = one row)
};
export const MIN_TEXT_PX = 11; // no text of the default view is drawn smaller than this
export const SMALLEST_FONT_PX = 11.5; // the smallest font the graph's CSS sets (.kb-be-ntype / .kb-be-note; tested)
// the editor never zooms below this by itself, and folds for maxWidth = box width / this: the whole graph fits the box
export const MIN_TEXT_ZOOM = MIN_TEXT_PX / SMALLEST_FONT_PX;
const CHANNEL = 8; // a cross-row route leaves its rank this far right of the rank, and enters this far left of the target's
const CHANNEL_STEP = 4; // between two cross-row routes leaving (or entering) one rank: their vertical runs stay apart
const RUN_GAP = 3; // two vertical runs closer than this read as one line (a line is drawn 1.5–3px wide)
// between two cross-row routes sharing a gutter: two labels' height (18) + 4 when both lanes carry one, one label's
// half + its line's gap when one does, a line gap when neither does (a stub or link has no label)
const LANE = 22;
const LANE_HALF = 13;
const LANE_BARE = 8;
const GUTTER = 22; // a gutter's own margin

// The drawing in two stages: rankGraph runs dagre (the costly part, independent of the box width) and fixes the routes
// into the ranks; foldGraph folds that one flat drawing into rows for a width. The editor re-folds on a resize without
// laying out again; layoutGraph is both at once.
type Rank = { keys: string[]; left: number; right: number };
export type Ranked = {
  lines: Record<string, string[]>;
  notes: Record<string, Note[]>;
  transitions: WorkflowTransition[];
  spine: string[];
  flat: Record<string, Box>;
  flatRoutes: Route[];
  ranks: Rank[];
};

export function layoutGraph(
  columns: BoardColumnDef[],
  transitions: WorkflowTransition[],
  opts: LayoutOpts = {},
): Layout {
  return foldGraph(rankGraph(columns, transitions, opts), opts.maxWidth ?? Infinity);
}

export function rankGraph(
  columns: BoardColumnDef[],
  transitions: WorkflowTransition[],
  opts: Pick<LayoutOpts, "typeLabel"> = {},
): Ranked {
  const typeLabel = opts.typeLabel ?? ((c: BoardColumnDef) => c.type);
  const keys = columns.map((c) => c.key);
  const plan = planTransitions(transitions, keys);
  const notes: Record<string, Note[]> = {};
  for (const p of plan) if (p.kind === "note") (notes[p.to] ??= []).push(p);
  const lines: Record<string, string[]> = {};

  const g = new dagre.graphlib.Graph<GraphLabel, NodeLabel, EdgeLabel>({ multigraph: true });
  g.setGraph({ rankdir: "LR", nodesep: NODESEP, ranksep: RANKSEP, edgesep: EDGESEP, marginx: PAD, marginy: PAD });
  g.setDefaultEdgeLabel(() => ({}));
  for (const c of columns) {
    const ls = wrapLabel(c.label);
    lines[c.key] = ls;
    // wide enough for the longest of: a label line, the type line ("3 · Asks the operator"), a note
    const smallW = [
      typeLine(keys.indexOf(c.key), typeLabel(c)),
      ...(notes[c.key] ?? []).map((n) => noteText(n, keys.length)),
    ].map((t) => t.length * NOTE_CHAR_W + 22);
    const w = Math.max(NODE_MIN_W, Math.max(...ls.map((l) => l.length)) * CHAR_W + 22, ...smallW);
    const h = 12 + ls.length * LINE_H + 16 + NOTE_H * (notes[c.key]?.length ?? 0);
    g.setNode(c.key, { width: w, height: h });
  }

  // The rank order IS the board order: an invisible edge from each column to the next keeps every column right of the
  // one before, whatever the transitions say (a column no arrow reaches, or only arrows from later columns, would else
  // land at the far left). A bundle's junction sits at the median position of its sources (short stubs, one long link).
  // An edge against that order goes into dagre reversed (the board order is the spine) and is drawn back.
  for (let i = 1; i < keys.length; i++) g.setEdge(keys[i - 1]!, keys[i]!, { weight: 1, minlen: 1 }, `order${i}`);
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
  const rank = (k: string) => spine.indexOf(k);
  type Rec = {
    id: string;
    ti: number;
    kind: Route["kind"];
    from: string;
    to: string;
    v: string;
    w: string;
    reversed: boolean;
  };
  const recs: Rec[] = [];
  const addEdge = (id: string, ti: number, kind: Route["kind"], from: string, to: string, label: EdgeLabel) => {
    const reversed = rank(from) > rank(to);
    const [v, w] = reversed ? [to, from] : [from, to];
    g.setEdge(v, w, label, id);
    recs.push({ id, ti, kind, from, to, v, w, reversed });
  };
  plan.forEach((p, i) => {
    if (p.kind === "arrow")
      addEdge(`a${i}`, p.ti, "arrow", p.from, p.to, { width: labelW(p.name), height: 18, labelpos: "c" });
    else if (p.kind === "bundle") {
      p.froms.forEach((f, j) => addEdge(`s${i}.${j}`, p.ti, "stub", f, junctionKey(p.ti), {}));
      addEdge(`l${i}`, p.ti, "link", junctionKey(p.ti), p.to, {});
    }
  });
  dagre.layout(g);

  // ── the flat drawing ──
  const flat: Record<string, Box> = {};
  for (const k of spine) {
    const n = g.node(k);
    flat[k] = {
      key: k,
      x: Math.round((n.x ?? 0) - n.width / 2),
      y: Math.round((n.y ?? 0) - n.height / 2),
      w: n.width,
      h: n.height,
    };
  }
  const flatRoutes: Route[] = recs.map((r) => {
    const e = g.edge(r.v, r.w, r.id);
    let pts = (e.points ?? []).map((p) => ({ x: r1(p.x), y: r1(p.y) }));
    if (r.reversed) pts = [...pts].reverse();
    if (pts.length < 2) pts = [center(flat[r.from]!), center(flat[r.to]!)];
    const label = r.kind === "arrow" && e.x !== undefined && e.y !== undefined ? { x: r1(e.x), y: r1(e.y) } : null;
    return { id: r.id, ti: r.ti, kind: r.kind, from: r.from, to: r.to, points: pts, label, ortho: false };
  });

  // ── fold the ranks into rows ──
  // a rank = the boxes sharing one x centre (dagre's LR ranks); its left / right = the widest box's
  // grouped by dagre's own x (unrounded: every box of one LR rank has exactly its rank's x; a centre from the rounded
  // box would put an odd-width box half a pixel off its rank-mates, in a phantom rank of its own)
  const byX = new Map<number, string[]>();
  for (const k of spine) {
    const cx = g.node(k).x ?? 0;
    byX.set(cx, [...(byX.get(cx) ?? []), k]);
  }
  const ranks: Rank[] = [...byX.entries()]
    .sort((a, b) => a[0] - b[0])
    .map(([, ks]) => ({
      keys: ks,
      left: Math.min(...ks.map((k) => flat[k]!.x)),
      right: Math.max(...ks.map((k) => flat[k]!.x + flat[k]!.w)),
    }));
  // A box narrower than its rank (a junction pill, a short label) is entered and left SIDEWAYS: dagre ends a route on
  // the border point towards its neighbour, and from a neighbour outside the rank that last run crosses the rank's
  // wider boxes stacked above or below. The end moves to the box's side facing the neighbour, at the height dagre
  // chose (kept inside the side), with a point at the rank's edge before it: the run inside the rank is horizontal,
  // at a height no other box of the rank has.
  const rankOfKey = new Map<string, Rank>();
  for (const rk of ranks) for (const k of rk.keys) rankOfKey.set(k, rk);
  for (const r of flatRoutes) {
    const fix = (k: string, end: Pt, next: Pt): Pt[] => {
      const b = flat[k]!;
      const rk = rankOfKey.get(k)!;
      const y = Math.min(Math.max(end.y, b.y + 6), b.y + b.h - 6);
      if (next.x < rk.left)
        return rk.left < b.x
          ? [
              { x: rk.left, y },
              { x: b.x, y },
            ]
          : [{ x: b.x, y }];
      if (next.x > rk.right)
        return rk.right > b.x + b.w
          ? [
              { x: rk.right, y },
              { x: b.x + b.w, y },
            ]
          : [{ x: b.x + b.w, y }];
      return [end];
    };
    const p = r.points;
    if (p.length < 2) continue;
    const head = fix(r.from, p[0]!, p[1]!).reverse();
    const tail = fix(r.to, p[p.length - 1]!, p[p.length - 2]!);
    r.points = [...head, ...p.slice(1, -1), ...tail];
  }
  return { lines, notes, transitions, spine, flat, flatRoutes, ranks };
}

// The flat drawing folded into rows for `maxWidth` (Infinity = one row). Pure: one Ranked folds for any number of widths.
export function foldGraph(base: Ranked, maxWidth = Infinity): Layout {
  const { lines, notes, transitions, spine, flat, flatRoutes, ranks } = base;
  // rows no wider than `limit`; the drawing can still come out wider (the right-margin lanes of routes between rows
  // that are not adjacent), so the limit is lowered by the overflow until it fits or every rank has a row of its own
  const fold = (limit: number) => {
    const rows: Rank[][] = [];
    for (const r of ranks) {
      const cur = rows[rows.length - 1];
      if (cur && r.right - cur[0]!.left + 2 * PAD <= limit) cur.push(r);
      else rows.push([r]);
    }
    const rowOf: Record<string, number> = {};
    const rankOf: Record<string, Rank> = {};
    rows.forEach((row, ri) => row.forEach((r) => r.keys.forEach((k) => ((rowOf[k] = ri), (rankOf[k] = r)))));
    const sameRow = (r: Route) => rowOf[r.from] === rowOf[r.to];

    // each row's own vertical extent in the flat drawing (its boxes and its in-row routes), then rows stacked with a
    // gutter sized for the cross-row routes that run through it
    const ext = rows.map(() => ({ top: Infinity, bottom: -Infinity }));
    const grow = (ri: number, y: number) => {
      ext[ri]!.top = Math.min(ext[ri]!.top, y);
      ext[ri]!.bottom = Math.max(ext[ri]!.bottom, y);
    };
    for (const k of spine) {
      grow(rowOf[k]!, flat[k]!.y);
      grow(rowOf[k]!, flat[k]!.y + flat[k]!.h);
    }
    for (const r of flatRoutes)
      if (sameRow(r))
        for (const p of [
          ...r.points,
          ...(r.label
            ? [
                { x: r.label.x, y: r.label.y - 9 },
                { x: r.label.x, y: r.label.y + 9 },
              ]
            : []),
        ])
          grow(rowOf[r.from]!, p.y);
    const cross = flatRoutes.filter((r) => !sameRow(r));
    // the gutter under row i carries the routes between rows i and i+1 (adjacent) and, via the right margin, the farther ones
    const gutterOf = (r: Route) => Math.min(rowOf[r.from]!, rowOf[r.to]!);
    const lanes: Record<number, Route[]> = {};
    for (const r of cross) (lanes[gutterOf(r)] ??= []).push(r);
    for (const r of cross)
      if (Math.abs(rowOf[r.from]! - rowOf[r.to]!) > 1)
        for (let gi = gutterOf(r) + 1; gi < Math.max(rowOf[r.from]!, rowOf[r.to]!); gi++) (lanes[gi] ??= []).push(r);
    // a route's label sits on the gutter it ENTERS its target from (below the target's row going up: that row's own)
    const labelGutter = (r: Route) => (rowOf[r.from]! < rowOf[r.to]! ? rowOf[r.to]! - 1 : rowOf[r.to]!);
    const labelled = (gi: number, r: Route) => r.kind === "arrow" && labelGutter(r) === gi;
    // each lane's offset in its gutter: the sum of the gaps between it and the lanes above it
    const laneOff = new Map<string, number>();
    for (const [gi, rs] of Object.entries(lanes)) {
      let off = 0;
      rs.forEach((r, i) => {
        if (i > 0) {
          const a = labelled(Number(gi), rs[i - 1]!);
          const b = labelled(Number(gi), r);
          off += a && b ? LANE : a || b ? LANE_HALF : LANE_BARE;
        }
        laneOff.set(`${gi}:${r.id}`, off);
      });
    }
    const gutterH = (gi: number) => {
      const rs = lanes[gi];
      return rs?.length ? GUTTER + laneOff.get(`${gi}:${rs[rs.length - 1]!.id}`)! + GUTTER : GUTTER;
    };
    // The cross-row routes leaving / entering each rank: each runs vertically in a channel of its own, in a STRIPE
    // inserted right of the rank (leaving) or left of it (entering), so a vertical run never meets a box or a label
    // (dagre's gap between two ranks is too narrow for them, and holds the labels). A channel is a SLOT of its stripe:
    // first in route order (the stripes left of the rows' first ranks, which all sit at one x, share one numbering);
    // then any run that lies along another transition's run (two stripes of different rows that land on one x) is
    // moved to a new slot of its stripe and the drawing redone, until no two runs share a line.
    const outs = new Map<Rank, Route[]>();
    const ins = new Map<Rank, Route[]>();
    for (const r of cross) {
      outs.set(rankOf[r.from]!, [...(outs.get(rankOf[r.from]!) ?? []), r]);
      ins.set(rankOf[r.to]!, [...(ins.get(rankOf[r.to]!) ?? []), r]);
    }
    const firsts = new Set(rows.map((row) => row[0]!));
    const firstIns = cross.filter((r) => firsts.has(rankOf[r.to]!));
    const outSlot = new Map<Route, number>();
    const inSlot = new Map<Route, number>();
    for (const [, rs] of outs) rs.forEach((r, i) => outSlot.set(r, i));
    for (const [rk, rs] of ins) rs.forEach((r, i) => inSlot.set(r, firsts.has(rk) ? firstIns.indexOf(r) : i));
    const room = (n: number) => (n ? CHANNEL + CHANNEL_STEP * (n - 1) + CHANNEL : 0);
    const slots = (rs: Route[] | undefined, at: Map<Route, number>) =>
      rs?.length ? Math.max(...rs.map((r) => at.get(r)!)) + 1 : 0;
    // the routes into or out of one node: they leave / enter its border at their own heights, never on one stub
    const ends = new Map<string, Route[]>();
    for (const r of cross) {
      ends.set(`o:${r.from}`, [...(ends.get(`o:${r.from}`) ?? []), r]);
      ends.set(`i:${r.to}`, [...(ends.get(`i:${r.to}`) ?? []), r]);
    }
    const rowTop: number[] = [];
    const rowDx: number[] = [];
    let y = PAD;
    rows.forEach((row, ri) => {
      rowTop.push(y);
      rowDx.push(PAD - row[0]!.left);
      y += ext[ri]!.bottom - ext[ri]!.top + (ri < rows.length - 1 ? gutterH(ri) : 0);
    });
    const Y = (ri: number, yy: number) => r1(yy - ext[ri]!.top + rowTop[ri]!);
    const gutterY = (gi: number, r: Route) => rowTop[gi + 1]! - gutterH(gi) + GUTTER + laneOff.get(`${gi}:${r.id}`)!;
    // the routes between rows that are not adjacent run down the right margin: one lane each, over all gutters
    const far = cross.filter((r) => Math.abs(rowOf[r.from]! - rowOf[r.to]!) > 1);

    const draw = () => {
      const inRoom = (rk: Rank) =>
        room(
          firsts.has(rk)
            ? Math.max(slots(firstIns, inSlot), ...rows.map((row) => slots(ins.get(row[0]!), inSlot)))
            : slots(ins.get(rk), inSlot),
        );
      const outRoom = (rk: Rank) => room(slots(outs.get(rk), outSlot));
      // flat x → drawn x on row ri: the row's offset plus every stripe inserted before x (a rank's entering stripe moves
      // the rank itself and what follows; its leaving stripe moves what lies right of the rank's right edge)
      const X = (ri: number, x: number) => {
        let dx = rowDx[ri]!;
        for (const rk of rows[ri]!) {
          if (x >= rk.left - 0.5) dx += inRoom(rk);
          if (x > rk.right + 0.5) dx += outRoom(rk);
        }
        return r1(x + dx);
      };
      const nodes: Record<string, Box> = {};
      const junctions: Record<number, Box> = {};
      for (const k of spine) {
        const b = flat[k]!;
        const ri = rowOf[k]!;
        const box = { key: k, x: X(ri, b.x), y: Y(ri, b.y), w: b.w, h: b.h };
        if (k.startsWith("j:")) junctions[Number(k.slice(2))] = box;
        else nodes[k] = box;
      }
      const boxOf = (k: string): Box => nodes[k] ?? junctions[Number(k.slice(2))]!;
      const rowRight = rows.map((row, ri) => X(ri, row[row.length - 1]!.right) + outRoom(row[row.length - 1]!));
      const width = Math.max(...rowRight, NODE_MIN_W + PAD) + PAD;
      const endY = (key: string, b: Box, r: Route) => {
        const list = ends.get(key)!;
        const step = Math.min(6, (b.h - 8) / Math.max(1, list.length));
        return r1(b.y + b.h / 2 + (list.indexOf(r) - (list.length - 1) / 2) * step);
      };
      // a cross-row route: out of the source rank's right channel, to the gutter lane, (via the right margin when the
      // rows are not adjacent), to the target rank's left channel, into the target's left border
      const route = (r: Route): Route => {
        const s = boxOf(r.from);
        const t = boxOf(r.to);
        const rs = rowOf[r.from]!;
        const rt = rowOf[r.to]!;
        const sx = X(rs, rankOf[r.from]!.right) + CHANNEL + CHANNEL_STEP * outSlot.get(r)!;
        const tx = X(rt, rankOf[r.to]!.left) - CHANNEL - CHANNEL_STEP * inSlot.get(r)!;
        const sy = endY(`o:${r.from}`, s, r);
        const ty = endY(`i:${r.to}`, t, r);
        const gS = rs < rt ? rs : rs - 1; // the gutter the source leaves into (below it going down, above it going up)
        const gT = rs < rt ? rt - 1 : rt; // the gutter the target is entered from
        const pts: Pt[] = [
          { x: r1(s.x + s.w), y: sy },
          { x: sx, y: sy },
          { x: sx, y: gutterY(gS, r) },
        ];
        if (gS !== gT) {
          const mx = width + CHANNEL + CHANNEL_STEP * 2 * far.indexOf(r);
          pts.push({ x: mx, y: gutterY(gS, r) }, { x: mx, y: gutterY(gT, r) });
        }
        pts.push({ x: tx, y: gutterY(gT, r) }, { x: tx, y: ty }, { x: t.x, y: ty });
        const label = r.kind === "arrow" ? { x: r1((pts[gS === gT ? 2 : 4]!.x + tx) / 2), y: gutterY(gT, r) } : null;
        return { ...r, points: pts, label, ortho: true };
      };
      const routes = flatRoutes.map((r) => {
        if (!sameRow(r)) return route(r);
        const ri = rowOf[r.from]!;
        const mv = (p: Pt) => ({ x: X(ri, p.x), y: Y(ri, p.y) });
        return { ...r, points: r.points.map(mv), label: r.label ? mv(r.label) : null };
      });
      return { nodes, junctions, routes };
    };

    // the first pair of runs (different transitions) along one line: [the route to move, which of its ends]
    const clash = (routes: Route[]): [Route, "out" | "in"] | null => {
      type Run = { r: Route; end: "out" | "in" | "mid"; x: number; y0: number; y1: number };
      const runs: Run[] = [];
      for (const r of routes) {
        if (!r.ortho) continue;
        const v = r.points
          .slice(1)
          .map((q, i) => [r.points[i]!, q] as const)
          .filter(([p, q]) => Math.abs(p.x - q.x) < 0.5);
        v.forEach(([p, q], i) =>
          runs.push({
            r,
            end: i === 0 ? "out" : i === v.length - 1 ? "in" : "mid",
            x: p.x,
            y0: Math.min(p.y, q.y),
            y1: Math.max(p.y, q.y),
          }),
        );
      }
      for (let i = 0; i < runs.length; i++)
        for (let j = i + 1; j < runs.length; j++) {
          const a = runs[i]!;
          const b = runs[j]!;
          if (a.r.ti === b.r.ti || Math.abs(a.x - b.x) >= RUN_GAP || Math.min(a.y1, b.y1) - Math.max(a.y0, b.y0) <= 0)
            continue;
          const mv = b.end !== "mid" ? b : a.end !== "mid" ? a : null;
          // the drawn route is a copy: its slots are kept on the route of `cross` with its id
          if (mv) return [cross.find((x) => x.id === mv.r.id)!, mv.end as "out" | "in"];
        }
      return null;
    };
    let drawn = draw();
    for (let n = 0, c = clash(drawn.routes); c && n < 4 * cross.length + 4; n++, c = clash(drawn.routes)) {
      const [r, end] = c;
      if (end === "out") outSlot.set(r, slots(outs.get(rankOf[r.from]!), outSlot));
      else
        inSlot.set(
          r,
          firsts.has(rankOf[r.to]!) ? Math.max(...[...inSlot.values()]) + 1 : slots(ins.get(rankOf[r.to]!), inSlot),
        );
      drawn = draw();
    }
    const { nodes, junctions, routes } = drawn;

    let w = NODE_MIN_W + 2 * PAD;
    let h = 12 + LINE_H + 16 + 2 * PAD;
    for (const b of [...Object.values(nodes), ...Object.values(junctions)]) {
      w = Math.max(w, b.x + b.w + PAD);
      h = Math.max(h, b.y + b.h + PAD);
    }
    for (const r of routes)
      for (const p of r.points) {
        w = Math.max(w, p.x + PAD);
        h = Math.max(h, p.y + PAD);
      }
    for (const r of routes)
      if (r.label) {
        w = Math.max(w, r.label.x + labelW(transitions[r.ti]?.name ?? "") / 2 + PAD);
        h = Math.max(h, r.label.y + 9 + PAD);
      }
    return { nodes, junctions, routes, rows: rows.length, w: Math.ceil(w), h: Math.ceil(h) };
  };
  let out = fold(maxWidth);
  for (let limit = maxWidth; Number.isFinite(maxWidth) && out.w > maxWidth && out.rows < ranks.length;) {
    limit -= out.w - maxWidth;
    out = fold(limit);
  }
  return { lines, notes, ...out, ranks: ranks.length };
}

// The layout with this session's nudges: a moved node keeps its position and the routes touching it end on its new
// border (the rest of the route stays). Cheap: the editor applies it on every pointer move without laying out again.
export function withMoved(base: Layout, moved: Record<string, Pt>): Layout {
  if (Object.keys(moved).length === 0) return base;
  const nodes: Record<string, Box> = {};
  for (const [k, b] of Object.entries(base.nodes)) {
    const m = moved[k];
    nodes[k] = m ? { ...b, x: m.x, y: m.y } : b;
  }
  const anyBox = (k: string): Box => nodes[k] ?? base.junctions[Number(k.slice(2))]!;
  const routes = base.routes.map((r) => {
    if (!moved[r.from] && !moved[r.to]) return r;
    const pts = [...r.points];
    if (moved[r.from]) pts[0] = borderPoint(anyBox(r.from), pts[1] ?? center(anyBox(r.to)));
    if (moved[r.to]) pts[pts.length - 1] = borderPoint(anyBox(r.to), pts[pts.length - 2] ?? center(anyBox(r.from)));
    return { ...r, points: pts };
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
