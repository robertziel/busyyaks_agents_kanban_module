// The BOARD EDITOR (the board's "Workflow" button): a project's columns as typed nodes in an SVG graph — each with
// its label and TYPE (the type decides the column's rules) — and its transitions as labelled arrows between them, like
// a flowchart. The graph is laid out for reading (lib/graph.ts: dagre, top to bottom along the board order, orthogonal
// connectors, labels as pills on their lines, hubs as bundles or notes) and opens at its width, never below a readable
// size; each column is a card — its type's icon, its label, its position and type, a status pill for a column that
// waits for the operator or ends the flow; a node can still be dragged aside for the session, Auto-layout puts it
// back, − / + / Fit zoom the canvas. Add a column, rename it, retype it (Select), delete it (the server refuses
// with the card ids when cards sit in it); add a transition by dragging from a node's port onto another node (or the
// "+ Transition" button), click an arrow, a bundle or a note to edit its name / from / to / by or delete it; reorder the
// board's columns (↑ ↓ in the list, = the board's column order, = the graph's top-to-bottom order); Save sends the
// whole draft to the engine (validated there as a whole; the refusal shown verbatim) / Discard / Reset to template.
// Everything drawn here is read from the server's `board` (shape + rules + the type set): no column, type or rule is
// a constant of this file.
import { useEffect, useLayoutEffect, useMemo, useRef, useState, type PointerEvent as RPointerEvent } from "react";
import { errMsg } from "../api";
import { useKanbanHost } from "../host";
import {
  badgeW,
  BADGE_H,
  center,
  isWildcard,
  keyFrom,
  layoutGraph,
  labelW,
  LABEL_H,
  LINE_H,
  MIN_TEXT_ZOOM,
  NODE_PAD_B,
  NOTE_H,
  subY,
  TEXT_X,
  TILE,
  TILE_X,
  TITLE_Y,
  junctionText,
  noteText,
  pathOf,
  type Note,
  removeColumn,
  renameKey,
  reorder,
  typeBadge,
  typeLine,
  withMoved,
  type Pt,
} from "../lib/graph";
import { declareFrom, fromKeys } from "../lib/workflow";
import { isoAt } from "../lib/format";
import type {
  BoardColumnDef,
  BoardShape,
  BoardShapeData,
  ColumnType,
  ColumnTypeKey,
  WorkflowActor,
  WorkflowTransition,
} from "../types";
import { Select } from "./Select";

const RESIZE_SETTLE_MS = 120; // the graph box's size is read again this long after its last resize

const ACTORS: { value: WorkflowActor; label: string }[] = [
  { value: "any", label: "anyone" },
  { value: "operator", label: "operator" },
  { value: "agent", label: "agents" },
];
type Sel = { kind: "column"; key: string } | { kind: "transition"; i: number } | null;
type Drag = { key: string; dx: number; dy: number };
type Link = { from: string; x: number; y: number };

// each column type's icon (a 16 × 16 stroke drawing): the engine's type set is fixed (types.ts ColumnTypeKey)
const TYPE_ICON: Record<ColumnTypeKey, string> = {
  parked: "M5.5 3.5v9 M10.5 3.5v9",
  queued: "M3 4.5h10 M3 8h10 M3 11.5h6",
  working: "M5 3.2v9.6l7.5-4.8z",
  review:
    "M1.5 8s2.4-4.5 6.5-4.5 6.5 4.5 6.5 4.5-2.4 4.5-6.5 4.5-6.5-4.5-6.5-4.5z M8 6.2a1.8 1.8 0 1 0 0 3.6a1.8 1.8 0 1 0 0-3.6z",
  gate: "M8 1.8l5.2 2v3.9c0 3.2-2.2 5.5-5.2 6.5-3-1-5.2-3.3-5.2-6.5v-3.9z M5.6 8l1.7 1.7 3.1-3.4",
  done: "M8 1.8a6.2 6.2 0 1 0 0.01 0z M5.2 8.2l1.9 1.9 3.7-4",
  cancelled: "M8 1.8a6.2 6.2 0 1 0 0.01 0z M5.8 5.8l4.4 4.4 M10.2 5.8l-4.4 4.4",
};
// a question mark: the glyph of a type the editor has no icon for
export const UNKNOWN_ICON = "M5.8 6a2.2 2.2 0 1 1 3.2 2c-.7.4-1 .9-1 1.6 M8 12.2v.1";
// the icon a column's type draws; none = a type the engine's fixed set does not have — the card says so (never a blank card)
export const iconOf = (type: string): string | undefined => (TYPE_ICON as Record<string, string | undefined>)[type];
// the pill a card carries: its type's status, or the error for a type the editor cannot draw
export const cardBadge = (c: BoardColumnDef, t: ColumnType | undefined): string | null =>
  iconOf(c.type) && t ? typeBadge(t) : `unknown type: ${c.type}`;

const clone = (s: BoardShape): BoardShape => ({
  columns: s.columns.map((c) => ({ ...c })),
  transitions: s.transitions.map((t) => ({ ...t, from: Array.isArray(t.from) ? [...t.from] : t.from })),
});
const same = (a: BoardShape, b: BoardShape) => JSON.stringify(a) === JSON.stringify(b);
const ZOOMS = { min: 0.2, max: 2 };
const clampZoom = (z: number) => Math.min(ZOOMS.max, Math.max(ZOOMS.min, Math.round(z * 100) / 100));

export function BoardEditor({ slug, onClose, onSaved }: { slug: string; onClose: () => void; onSaved: () => void }) {
  const { api, board: initial } = useKanbanHost();
  const ref = useRef<HTMLDialogElement>(null);
  const graphRef = useRef<HTMLDivElement>(null);
  const svgRef = useRef<SVGSVGElement>(null);
  const [data, setData] = useState<BoardShapeData>(initial);
  const [draft, setDraft] = useState<BoardShape>(() => clone(initial));
  const [moved, setMoved] = useState<Record<string, Pt>>({}); // nodes dragged aside this session
  const [sel, setSel] = useState<Sel>(null);
  const [drag, setDrag] = useState<Drag | null>(null);
  const [link, setLink] = useState<Link | null>(null);
  const [zoom, setZoom] = useState(1);
  const [autoZoom, setAutoZoom] = useState(true); // the zoom follows the box until − / + is pressed; Fit turns it back on
  const [boxW, setBoxW] = useState(0); // the graph box's width, measured (0 = unknown: jsdom)
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [newKeys, setNewKeys] = useState<string[]>([]); // columns added in this draft: their key follows the label

  useEffect(() => {
    const d = ref.current;
    if (d && !d.open) d.showModal();
    const onCancel = (e: Event) => (e.preventDefault(), onClose());
    d?.addEventListener("cancel", onCancel);
    return () => {
      d?.removeEventListener("cancel", onCancel);
      if (d?.open) d.close();
    };
  }, [onClose]);

  const take = (d: BoardShapeData) => {
    setData(d);
    setDraft(clone(d));
    setMoved({});
    setNewKeys([]);
    setSel(null);
    setError(null);
  };
  const run = async (fn: () => Promise<BoardShapeData>) => {
    setBusy(true);
    try {
      take(await fn());
      onSaved();
    } catch (e) {
      setError(errMsg(e));
    } finally {
      setBusy(false);
    }
  };

  const keys = draft.columns.map((c) => c.key);
  const labelOf = (k: string) => draft.columns.find((c) => c.key === k)?.label ?? k;
  const typeOf = (k: ColumnTypeKey) => data.types.find((t) => t.key === k);
  const typeOptions = data.types.map((t) => ({ value: t.key, label: t.label }));
  // the box's width decides the default zoom (the graph's width, never below readable text)
  useLayoutEffect(() => {
    const el = graphRef.current;
    if (!el) return;
    const measure = () => setBoxW(el.clientWidth);
    measure();
    // a resize re-fits once it settles (RESIZE_SETTLE_MS), not on every frame of a drag
    let timer: ReturnType<typeof setTimeout> | undefined;
    const ro = new ResizeObserver(() => {
      clearTimeout(timer);
      timer = setTimeout(measure, RESIZE_SETTLE_MS);
    });
    ro.observe(el);
    return () => {
      clearTimeout(timer);
      ro.disconnect();
    };
  }, []);
  // dagre once per draft
  const base = useMemo(
    () =>
      layoutGraph(draft.columns, draft.transitions, {
        typeLabel: (c) => data.types.find((t) => t.key === c.type)?.label ?? c.type,
        badge: (c) =>
          cardBadge(
            c,
            data.types.find((t) => t.key === c.type),
          ),
      }),
    [draft, data.types],
  );
  const layout = useMemo(() => withMoved(base, moved), [base, moved]);
  // the zoom that shows the graph's whole width, never below readable text (the box scrolls instead); 1 when the box is
  // unknown. The graph runs down: the box scrolls vertically
  const fitted = useMemo(() => {
    if (boxW <= 0) return 1;
    const z = Math.min(1, (boxW - 2) / base.w);
    return clampZoom(Math.max(Math.floor(z * 100) / 100, MIN_TEXT_ZOOM)); // floored: a rounded-up zoom would overflow the box by a pixel
  }, [boxW, base]);
  useEffect(() => {
    if (autoZoom) setZoom(fitted);
  }, [autoZoom, fitted]);
  const arrows = layout.routes.filter((r) => r.kind === "arrow");
  const bundles = Object.keys(layout.junctions).map(Number);
  const noteCount = Object.values(layout.notes).reduce((n, l) => n + l.length, 0);
  const wild = draft.transitions.map((t, i) => [t, i] as const).filter(([t]) => isWildcard(t));
  const noted: Note[] = Object.values(layout.notes).flat();
  const dirty = !same(draft, { columns: data.columns, transitions: data.transitions });

  // pointer → graph coordinates (the SVG is drawn at zoom × its natural size; a box of no size — jsdom — maps 1:1)
  const toGraph = (e: { clientX: number; clientY: number }) => {
    const r = svgRef.current?.getBoundingClientRect();
    const s = r && r.height > 0 ? layout.h / r.height : 1;
    return { x: (e.clientX - (r?.left ?? 0)) * s, y: (e.clientY - (r?.top ?? 0)) * s };
  };
  const fit = () => {
    setAutoZoom(true);
    setZoom(fitted);
  };
  const zoomBy = (d: number) => {
    setAutoZoom(false);
    setZoom((z) => clampZoom(z + d));
  };

  const setCol = (key: string, patch: Partial<BoardColumnDef>) =>
    setDraft((d) => ({ ...d, columns: d.columns.map((c) => (c.key === key ? { ...c, ...patch } : c)) }));
  const setTr = (i: number, patch: Partial<WorkflowTransition>) =>
    setDraft((d) => ({ ...d, transitions: d.transitions.map((t, j) => (j === i ? { ...t, ...patch } : t)) }));

  const addColumn = () => {
    const key = keyFrom("New column", keys);
    setDraft((d) => ({
      ...d,
      columns: [
        ...d.columns,
        {
          key,
          label: "New column",
          type: data.types[0]!.key,
          hide_after_hours: data.types[0]!.hide_after_hours,
        },
      ],
    }));
    setNewKeys((n) => [...n, key]);
    setSel({ kind: "column", key });
  };
  const relabel = (key: string, label: string) => {
    if (!newKeys.includes(key)) return setCol(key, { label });
    // a column not saved yet: its key follows its label (a key is for life once cards reference it)
    const next = keyFrom(
      label,
      keys.filter((k) => k !== key),
    );
    setDraft((d) => ({
      columns: d.columns.map((c) => (c.key === key ? { ...c, key: next, label } : c)),
      transitions: renameKey(d.transitions, key, next),
    }));
    setMoved((m) => {
      const p = m[key];
      if (!p) return m;
      const rest = Object.fromEntries(Object.entries(m).filter(([k]) => k !== key));
      return { ...rest, [next]: p };
    });
    setNewKeys((n) => n.map((k) => (k === key ? next : k)));
    setSel({ kind: "column", key: next });
  };
  const deleteColumn = (key: string) => {
    setDraft((d) => removeColumn(d.columns, d.transitions, key));
    setNewKeys((n) => n.filter((k) => k !== key));
    setMoved((m) => Object.fromEntries(Object.entries(m).filter(([k]) => k !== key)));
    setSel(null);
  };
  const addTransition = (from: string, to: string) => {
    const t: WorkflowTransition = { name: "", from, to, by: "any" };
    setDraft((d) => ({ ...d, transitions: [...d.transitions, t] }));
    setSel({ kind: "transition", i: draft.transitions.length });
  };
  const deleteTransition = (i: number) => {
    setDraft((d) => ({ ...d, transitions: d.transitions.filter((_, j) => j !== i) }));
    setSel(null);
  };
  const toggleFrom = (i: number, key: string) => {
    const ticked = fromKeys(draft.transitions[i]!.from, keys);
    const next = ticked.includes(key) ? ticked.filter((k) => k !== key) : [...ticked, key];
    setTr(i, { from: declareFrom(next, keys) });
  };
  const selectTr = (i: number) => setSel({ kind: "transition", i });
  // Enter / Space select; only when pressed on this element itself (a child control handles its own keys)
  const keySelects =
    (fn: () => void) =>
    (k: { key: string; target: EventTarget; currentTarget: EventTarget; preventDefault: () => void }) => {
      if (k.target !== k.currentTarget || (k.key !== "Enter" && k.key !== " ")) return;
      k.preventDefault();
      fn();
    };

  // ── pointer interaction: drag a node, or draw a link from a node's port onto another node ──
  const onNodeDown = (c: BoardColumnDef) => (e: RPointerEvent<SVGGElement>) => {
    if (e.button !== 0) return;
    e.preventDefault();
    const p = toGraph(e);
    const b = layout.nodes[c.key]!;
    setDrag({ key: c.key, dx: p.x - b.x, dy: p.y - b.y });
    setSel({ kind: "column", key: c.key });
    try {
      (e.currentTarget as unknown as Element).setPointerCapture?.(e.pointerId);
    } catch {
      // a browser without pointer capture (or a synthetic event): the svg's own move / up handlers still finish the drag
    }
  };
  const onPortDown = (c: BoardColumnDef) => (e: RPointerEvent<SVGCircleElement>) => {
    e.preventDefault();
    e.stopPropagation();
    const p = toGraph(e);
    setLink({ from: c.key, x: p.x, y: p.y });
  };
  const onMove = (e: RPointerEvent<SVGSVGElement>) => {
    if (drag) {
      const p = toGraph(e);
      setMoved((m) => ({
        ...m,
        [drag.key]: { x: Math.max(0, Math.round(p.x - drag.dx)), y: Math.max(0, Math.round(p.y - drag.dy)) },
      }));
    } else if (link) {
      const p = toGraph(e);
      setLink({ ...link, x: p.x, y: p.y });
    }
  };
  const onUp = () => {
    setDrag(null);
    if (link) {
      const hit = draft.columns.find((c) => {
        const b = layout.nodes[c.key]!;
        return link.x >= b.x && link.x <= b.x + b.w && link.y >= b.y && link.y <= b.y + b.h && c.key !== link.from;
      });
      setLink(null);
      if (hit) addTransition(link.from, hit.key);
    }
  };
  const onNodeUp = (c: BoardColumnDef) => () => {
    if (link && link.from !== c.key) {
      setLink(null);
      setDrag(null);
      addTransition(link.from, c.key);
    }
  };

  const selCol = sel?.kind === "column" ? (draft.columns.find((c) => c.key === sel.key) ?? null) : null;
  const selTr = sel?.kind === "transition" ? (draft.transitions[sel.i] ?? null) : null;
  const selIdx = sel?.kind === "transition" ? sel.i : -1;
  const nMoved = Object.keys(moved).length;
  const graphLabel =
    `Workflow graph: ${draft.columns.length} columns, ${arrows.length} arrows` +
    (bundles.length ? `, ${bundles.length} bundles` : "") +
    (noteCount ? `, ${noteCount} notes` : "");

  return (
    <dialog ref={ref} className="kb-dialog kb-be" aria-label="Board editor" onKeyDown={(e) => e.stopPropagation()}>
      <header className="kb-be-head">
        <h2>Workflow</h2>
        <span className="kb-be-src">
          {data.updated_by ? `saved by ${data.updated_by}${data.updated ? ` · ${isoAt(data.updated)}` : ""}` : ""}
          {dirty ? " · unsaved changes" : ""}
        </span>
        <span className="spacer" />
        <button
          type="button"
          className="btn small"
          disabled={nMoved === 0}
          onClick={() => setMoved({})}
          title="Lay the graph out again (undoes the nodes dragged aside)"
        >
          Auto-layout
        </button>
        <button type="button" className="btn small" onClick={() => zoomBy(-0.2)} aria-label="Zoom out">
          −
        </button>
        <button
          type="button"
          className="btn small"
          onClick={fit}
          aria-label="Fit the graph to its box"
          title="Fit to width"
        >
          Fit
        </button>
        <button type="button" className="btn small" onClick={() => zoomBy(0.2)} aria-label="Zoom in">
          +
        </button>
        <button type="button" className="btn small" aria-label="Close" onClick={onClose}>
          ✕
        </button>
      </header>
      {error && (
        <div className="flash bad" role="alert">
          <i className="dot bad" />
          <span>{error}</span>
        </div>
      )}
      {base.warnings.length > 0 && (
        <div className="flash warn" role="status" aria-label="Drawing warnings">
          <i className="dot warn" />
          <span>{base.warnings.join(" · ")}</span>
        </div>
      )}
      <div className="kb-be-body">
        <div className="kb-be-graph" data-testid="graph" ref={graphRef}>
          <svg
            ref={svgRef}
            viewBox={`0 0 ${layout.w} ${layout.h}`}
            width={Math.round(layout.w * zoom)}
            height={Math.round(layout.h * zoom)}
            preserveAspectRatio="xMinYMin meet"
            role="group"
            aria-label={graphLabel}
            onPointerDown={(e) => e.target === e.currentTarget && setSel(null)}
            onPointerMove={onMove}
            onPointerUp={onUp}
            onPointerCancel={() => (setDrag(null), setLink(null))}
            onPointerLeave={() => (setDrag(null), setLink(null))}
          >
            <defs>
              <marker
                id="kb-be-arrow"
                viewBox="0 0 10 10"
                refX="9"
                refY="5"
                markerWidth="8"
                markerHeight="8"
                orient="auto-start-reverse"
              >
                <path d="M 0 0 L 10 5 L 0 10 z" className="kb-be-arrowhead" />
              </marker>
              <marker
                id="kb-be-arrow-sel"
                viewBox="0 0 10 10"
                refX="9"
                refY="5"
                markerWidth="8"
                markerHeight="8"
                orient="auto-start-reverse"
              >
                <path d="M 0 0 L 10 5 L 0 10 z" className="kb-be-arrowhead sel" />
              </marker>
            </defs>
            {arrows.map((r) => {
              const on = selIdx === r.ti;
              const name = draft.transitions[r.ti]?.name ?? "";
              const d = pathOf(r.points);
              const lw = labelW(name);
              return (
                <g
                  key={r.id}
                  className={`kb-be-edge${on ? " sel" : ""} by-${draft.transitions[r.ti]?.by ?? "any"}`}
                  onClick={() => selectTr(r.ti)}
                  role="button"
                  tabIndex={0}
                  aria-label={`Transition ${name || "(unnamed)"}: ${labelOf(r.from)} → ${labelOf(r.to)}`}
                  onKeyDown={keySelects(() => selectTr(r.ti))}
                >
                  <path d={d} className="kb-be-hit" />
                  <path
                    d={d}
                    className={`kb-be-line${r.back ? " back" : ""}`}
                    markerEnd={on ? "url(#kb-be-arrow-sel)" : "url(#kb-be-arrow)"}
                  />
                  {r.label && (
                    <g className="kb-be-epill">
                      <rect
                        x={r.label.x - lw / 2}
                        y={r.label.y - LABEL_H / 2}
                        width={lw}
                        height={LABEL_H}
                        rx={6}
                        className="kb-be-ebox"
                      />
                      <text x={r.label.x} y={r.label.y + 4} textAnchor="middle" className="kb-be-elabel">
                        {name || "(unnamed)"}
                      </text>
                    </g>
                  )}
                </g>
              );
            })}
            {bundles.map((ti) => {
              const on = selIdx === ti;
              const t = draft.transitions[ti];
              const j = layout.junctions[ti]!;
              const routes = layout.routes.filter((r) => r.ti === ti);
              const n = routes.filter((r) => r.kind === "stub").length;
              const name = t?.name || "(unnamed)";
              return (
                <g
                  key={`b${ti}`}
                  className={`kb-be-edge kb-be-bundle${on ? " sel" : ""} by-${t?.by ?? "any"}`}
                  onClick={() => selectTr(ti)}
                  role="button"
                  tabIndex={0}
                  aria-label={`Transition ${name}: ${n} columns → ${labelOf(t?.to ?? "")}`}
                  onKeyDown={keySelects(() => selectTr(ti))}
                >
                  {routes.map((r) => {
                    const d = pathOf(r.points);
                    return (
                      <g key={r.id}>
                        <path d={d} className="kb-be-hit" />
                        <path
                          d={d}
                          className={`kb-be-line${r.kind === "stub" ? " kb-be-stub" : ""}${r.back ? " back" : ""}`}
                          markerEnd={
                            r.kind === "link" ? (on ? "url(#kb-be-arrow-sel)" : "url(#kb-be-arrow)") : undefined
                          }
                        />
                      </g>
                    );
                  })}
                  <rect x={j.x} y={j.y} width={j.w} height={j.h} rx={6} className="kb-be-junction" />
                  <text x={j.x + j.w / 2} y={j.y + j.h / 2 + 4} textAnchor="middle" className="kb-be-jlabel">
                    {junctionText(name, n)}
                  </text>
                </g>
              );
            })}
            {link &&
              (() => {
                const c0 = center(layout.nodes[link.from]!);
                return (
                  <line
                    x1={c0.x}
                    y1={c0.y}
                    x2={link.x}
                    y2={link.y}
                    className="kb-be-linking"
                    markerEnd="url(#kb-be-arrow)"
                  />
                );
              })()}
            {draft.columns.map((c, i) => {
              const on = sel?.kind === "column" && sel.key === c.key;
              const t = typeOf(c.type);
              const b = layout.nodes[c.key]!;
              const lines = layout.lines[c.key] ?? [c.label];
              const typeY = subY(lines.length);
              const tileY = Math.round((typeY + NODE_PAD_B - TILE) / 2);
              const glyph = iconOf(c.type);
              const badge = cardBadge(c, t);
              const bw = badge ? badgeW(badge) : 0;
              return (
                <g
                  key={c.key}
                  className={`kb-be-node type-${c.type}${glyph && t ? "" : " unknown"}${on ? " sel" : ""}${moved[c.key] ? " moved" : ""}`}
                  transform={`translate(${b.x} ${b.y})`}
                  onPointerDown={onNodeDown(c)}
                  onPointerUp={onNodeUp(c)}
                  onClick={() => setSel({ kind: "column", key: c.key })}
                  role="button"
                  tabIndex={0}
                  aria-label={`Column ${c.label} (${t?.label ?? c.type})`}
                  data-key={c.key}
                  onKeyDown={keySelects(() => setSel({ kind: "column", key: c.key }))}
                >
                  <rect width={b.w} height={b.h} rx="12" className="kb-be-box" />
                  <rect x={TILE_X} y={tileY} width={TILE} height={TILE} rx="9" className="kb-be-tile" />
                  <path
                    d={glyph ?? UNKNOWN_ICON}
                    transform={`translate(${TILE_X + (TILE - 16) / 2} ${tileY + (TILE - 16) / 2})`}
                    className="kb-be-glyph"
                  />
                  {lines.map((l, li) => (
                    <text key={li} x={TEXT_X} y={TITLE_Y + li * LINE_H} className="kb-be-nlabel">
                      {l}
                    </text>
                  ))}
                  <text x={TEXT_X} y={typeY} className="kb-be-ntype">
                    {typeLine(i, t?.label ?? c.type)}
                  </text>
                  {badge && (
                    <g className="kb-be-badge">
                      <rect
                        x={b.w - 12 - bw}
                        y={tileY + (TILE - BADGE_H) / 2}
                        width={bw}
                        height={BADGE_H}
                        rx="6"
                        className="kb-be-bbox"
                      />
                      <text x={b.w - 12 - bw / 2} y={tileY + TILE / 2 + 4} textAnchor="middle" className="kb-be-btext">
                        {badge}
                      </text>
                    </g>
                  )}
                  <circle
                    cx={b.w}
                    cy={b.h / 2}
                    r="7"
                    className="kb-be-port"
                    onPointerDown={onPortDown(c)}
                    aria-label={`Connect from ${c.label}`}
                  >
                    <title>Drag onto another column to add a transition</title>
                  </circle>
                </g>
              );
            })}
            {draft.columns.flatMap((c) => {
              const b = layout.nodes[c.key]!;
              const typeY = subY((layout.lines[c.key] ?? [c.label]).length);
              return (layout.notes[c.key] ?? []).map((n, ni) => (
                <text
                  key={`n${n.ti}`}
                  x={b.x + TEXT_X}
                  y={b.y + typeY + NOTE_H + ni * NOTE_H}
                  className={`kb-be-note by-${n.by}${selIdx === n.ti ? " sel" : ""}`}
                  role="button"
                  tabIndex={0}
                  aria-label={`Transition ${n.name || "(unnamed)"}: ${n.froms.length} of ${draft.columns.length} columns → ${c.label}`}
                  onClick={() => selectTr(n.ti)}
                  onKeyDown={keySelects(() => selectTr(n.ti))}
                >
                  {noteText(n, draft.columns.length)}
                </text>
              ));
            })}
          </svg>
        </div>

        <aside className="kb-be-side">
          {selCol && (
            <section className="kb-be-panel" aria-label="Column">
              <h3>
                Column <code>{selCol.key}</code>
              </h3>
              <label className="kb-side-field">
                <span>Label</span>
                <input
                  value={selCol.label}
                  aria-label="Column label"
                  onChange={(e) => relabel(selCol.key, e.target.value)}
                />
              </label>
              <label className="kb-side-field">
                <span>Type</span>
                <Select
                  options={typeOptions}
                  value={selCol.type}
                  onChange={(v) =>
                    setCol(selCol.key, {
                      type: v as ColumnTypeKey,
                      hide_after_hours: typeOf(v as ColumnTypeKey)?.hide_after_hours ?? selCol.hide_after_hours,
                    })
                  }
                  ariaLabel="Column type"
                />
              </label>
              <label className="kb-side-field">
                <span>Fold after (h)</span>
                <input
                  type="number"
                  min={0}
                  step={1}
                  value={selCol.hide_after_hours}
                  aria-label="Fold cards not updated for (hours)"
                  title="A card with no update for this many hours is folded behind “Load older” · 0 = never"
                  onChange={(e) =>
                    setCol(selCol.key, {
                      hide_after_hours: e.target.value === "" ? 0 : Math.max(0, Math.floor(Number(e.target.value))),
                    })
                  }
                />
              </label>
              <p className="muted kb-be-summary">{typeOf(selCol.type)?.summary}</p>
              <p className="muted">
                {moved[selCol.key]
                  ? "Dragged aside for this session; Auto-layout puts it back. Positions are not saved."
                  : "Placed by the automatic layout; drag the node to nudge it for this session."}
              </p>
              <div className="kb-be-row">
                <button
                  type="button"
                  className="btn small"
                  aria-label={`Move ${selCol.label} earlier`}
                  onClick={() =>
                    setDraft((d) => ({
                      ...d,
                      columns: reorder(
                        d.columns,
                        d.columns.findIndex((c) => c.key === selCol.key),
                        -1,
                      ),
                    }))
                  }
                >
                  ← earlier
                </button>
                <button
                  type="button"
                  className="btn small"
                  aria-label={`Move ${selCol.label} later`}
                  onClick={() =>
                    setDraft((d) => ({
                      ...d,
                      columns: reorder(
                        d.columns,
                        d.columns.findIndex((c) => c.key === selCol.key),
                        1,
                      ),
                    }))
                  }
                >
                  later →
                </button>
                <span className="spacer" />
                <button
                  type="button"
                  className="btn small danger"
                  aria-label={`Delete column ${selCol.label}`}
                  onClick={() => deleteColumn(selCol.key)}
                >
                  Delete
                </button>
              </div>
            </section>
          )}
          {selTr && (
            <section className="kb-be-panel" aria-label="Transition">
              <h3>Transition</h3>
              <label className="kb-side-field">
                <span>Name</span>
                <input
                  value={selTr.name}
                  placeholder="Start work"
                  aria-label="Transition name"
                  onChange={(e) => setTr(selIdx, { name: e.target.value })}
                />
              </label>
              <div className="kb-be-from" role="group" aria-label="Transition from">
                <span>from</span>
                {draft.columns.map((c) => {
                  const ticked = fromKeys(selTr.from, keys);
                  return (
                    <label key={c.key} className={`kb-wf-chip${ticked.includes(c.key) ? " on" : ""}`}>
                      <input
                        type="checkbox"
                        checked={ticked.includes(c.key)}
                        onChange={() => toggleFrom(selIdx, c.key)}
                      />
                      {c.label}
                    </label>
                  );
                })}
              </div>
              <label className="kb-side-field">
                <span>To</span>
                <Select
                  options={[
                    ...draft.columns.map((c) => ({ value: c.key, label: c.label })),
                    { value: "*", label: "any column" },
                  ]}
                  value={selTr.to}
                  onChange={(v) => setTr(selIdx, { to: v })}
                  ariaLabel="Transition to"
                />
              </label>
              <label className="kb-side-field">
                <span>Taken by</span>
                <Select
                  options={ACTORS}
                  value={selTr.by}
                  onChange={(v) => setTr(selIdx, { by: v as WorkflowActor })}
                  ariaLabel="Transition taken by"
                />
              </label>
              <div className="kb-be-row">
                <span className="spacer" />
                <button
                  type="button"
                  className="btn small danger"
                  aria-label="Delete transition"
                  onClick={() => deleteTransition(selIdx)}
                >
                  Delete
                </button>
              </div>
            </section>
          )}
          <section className="kb-be-panel" aria-label="Columns in board order">
            <h3>
              Columns <span className="muted">(board order = top to bottom)</span>
            </h3>
            <ol className="kb-be-cols">
              {draft.columns.map((c, i) => (
                <li key={c.key} className={sel?.kind === "column" && sel.key === c.key ? "sel" : ""}>
                  <button type="button" className="kb-be-colbtn" onClick={() => setSel({ kind: "column", key: c.key })}>
                    <b>{c.label}</b> <span className="muted">{typeOf(c.type)?.label ?? c.type}</span>
                  </button>
                  <button
                    type="button"
                    className="btn small"
                    aria-label={`Move ${c.label} up`}
                    disabled={i === 0}
                    onClick={() => setDraft((d) => ({ ...d, columns: reorder(d.columns, i, -1) }))}
                  >
                    ↑
                  </button>
                  <button
                    type="button"
                    className="btn small"
                    aria-label={`Move ${c.label} down`}
                    disabled={i === draft.columns.length - 1}
                    onClick={() => setDraft((d) => ({ ...d, columns: reorder(d.columns, i, 1) }))}
                  >
                    ↓
                  </button>
                </li>
              ))}
            </ol>
            <div className="kb-be-row">
              <button type="button" className="btn small" onClick={addColumn}>
                + Column
              </button>
              <button
                type="button"
                className="btn small"
                disabled={draft.columns.length < 2}
                onClick={() => addTransition(draft.columns[0]!.key, draft.columns[1]!.key)}
              >
                + Transition
              </button>
            </div>
          </section>
          {(wild.length > 0 || noted.length > 0) && (
            <section className="kb-be-panel" aria-label="Transitions not drawn as arrows">
              <h3>
                Not drawn as arrows <span className="muted">(any-column, and notes on their target)</span>
              </h3>
              <ul className="kb-be-wild">
                {wild.map(([t, i]) => (
                  <li key={i} className={selIdx === i ? "sel" : ""}>
                    <button type="button" className="kb-be-colbtn" onClick={() => selectTr(i)}>
                      <b>{t.name || "(unnamed)"}</b>{" "}
                      <span className="muted">
                        {t.from === "*" ? "any" : fromKeys(t.from, keys).map(labelOf).join(", ")} →{" "}
                        {t.to === "*" ? "any" : labelOf(t.to)} · {t.by}
                      </span>
                    </button>
                  </li>
                ))}
                {noted.map((n) => (
                  <li key={`n${n.ti}`} className={selIdx === n.ti ? "sel" : ""}>
                    <button type="button" className="kb-be-colbtn" onClick={() => selectTr(n.ti)}>
                      <b>{n.name || "(unnamed)"}</b>{" "}
                      <span className="muted">
                        note on {labelOf(n.to)}: {n.froms.length} of {draft.columns.length} columns → {labelOf(n.to)} ·{" "}
                        {n.by}
                      </span>
                    </button>
                  </li>
                ))}
              </ul>
            </section>
          )}
        </aside>
      </div>
      <footer className="kb-be-actions">
        <button
          type="button"
          className="btn small"
          disabled={busy}
          onClick={() => void run(() => api.boardShapeReset(slug))}
          title="The template board again (refused while cards sit in a column the template lacks)"
        >
          Reset to template
        </button>
        <span className="spacer" />
        <button type="button" className="btn small" disabled={busy || !dirty} onClick={() => take(data)}>
          Discard
        </button>
        <button
          type="button"
          className="btn primary small"
          disabled={busy || !dirty}
          onClick={() => void run(() => api.boardShapeSave(slug, draft))}
        >
          Save
        </button>
      </footer>
    </dialog>
  );
}
