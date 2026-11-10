// The BOARD EDITOR (the board's "Workflow" button): a project's columns as typed nodes in an SVG graph — each with
// its label and TYPE (the type decides the column's rules) — and its transitions as labelled arrows between them, like
// Jira's workflow diagram. The graph is laid out for reading (lib/graph.ts: dagre, left to right along the board order,
// folded into rows that fit the box, labels placed off the nodes, hubs as bundles or notes) and opens showing the whole
// of it at a readable size; a node can still be dragged aside for the session, Auto-layout puts it back, − / + / Fit
// zoom the canvas. Add a column, rename it, retype it (Select), delete it (the server refuses
// with the card ids when cards sit in it); add a transition by dragging from a node's port onto another node (or the
// "+ Transition" button), click an arrow, a bundle or a note to edit its name / from / to / by or delete it; reorder the
// board's columns (↑ ↓ in the list, = the board's column order, = the graph's left-to-right order); Save sends the
// whole draft to the engine (validated there as a whole; the refusal shown verbatim) / Discard / Reset to template.
// Everything drawn here is read from the server's `board` (shape + rules + the type set): no column, type or rule is
// a constant of this file.
import { useEffect, useLayoutEffect, useMemo, useRef, useState, type PointerEvent as RPointerEvent } from "react";
import { errMsg } from "../api";
import { useKanbanHost } from "../host";
import {
  center,
  isWildcard,
  keyFrom,
  foldGraph,
  rankGraph,
  LINE_H,
  MIN_TEXT_ZOOM,
  junctionText,
  noteText,
  pathOf,
  type Note,
  removeColumn,
  renameKey,
  reorder,
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
  const [box, setBox] = useState<{ w: number; maxH: number }>({ w: 0, maxH: 0 }); // the graph box, measured (0 = unknown: jsdom)
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
  // the box decides the fold (rows no wider than the box at MIN_TEXT_ZOOM, the split that fits its height best) and the
  // default zoom (the whole graph)
  useLayoutEffect(() => {
    const el = graphRef.current;
    if (!el) return;
    const measure = () => {
      const maxH = parseFloat(getComputedStyle(el).maxHeight);
      setBox({ w: el.clientWidth, maxH: Number.isFinite(maxH) ? maxH : 0 });
    };
    measure();
    // a resize re-folds once it settles (RESIZE_SETTLE_MS), not on every frame of a drag: the fold for a height draws
    // up to a few hundred row splits
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
  // dagre once per draft; a resize only re-folds the same ranks
  const ranked = useMemo(
    () =>
      rankGraph(draft.columns, draft.transitions, {
        typeLabel: (c) => data.types.find((t) => t.key === c.type)?.label ?? c.type,
      }),
    [draft, data.types],
  );
  const base = useMemo(
    () =>
      foldGraph(
        ranked,
        box.w > 0 ? (box.w - 2) / MIN_TEXT_ZOOM : Infinity,
        box.maxH > 0 ? (box.maxH - 2) / MIN_TEXT_ZOOM : Infinity,
      ),
    [ranked, box.w, box.maxH],
  );
  const layout = useMemo(() => withMoved(base, moved), [base, moved]);
  // the zoom that shows the whole graph, never below readable text (the box scrolls instead); 1 when the box is unknown
  const fitted = useMemo(() => {
    if (box.w <= 0) return 1;
    const z = Math.min(1, (box.w - 2) / base.w, box.maxH > 0 ? (box.maxH - 2) / base.h : 1);
    return clampZoom(Math.max(Math.floor(z * 100) / 100, MIN_TEXT_ZOOM)); // floored: a rounded-up zoom would overflow the box by a pixel
  }, [box, base]);
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
                  <path d={d} className="kb-be-line" markerEnd={on ? "url(#kb-be-arrow-sel)" : "url(#kb-be-arrow)"} />
                  {r.label && (
                    <text x={r.label.x} y={r.label.y + 4} textAnchor="middle" className="kb-be-elabel">
                      {name || "(unnamed)"}
                    </text>
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
                          className={`kb-be-line${r.kind === "stub" ? " kb-be-stub" : ""}`}
                          markerEnd={
                            r.kind === "link" ? (on ? "url(#kb-be-arrow-sel)" : "url(#kb-be-arrow)") : undefined
                          }
                        />
                      </g>
                    );
                  })}
                  <rect x={j.x} y={j.y} width={j.w} height={j.h} rx={j.h / 2} className="kb-be-junction" />
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
              const typeY = 19 + (lines.length - 1) * LINE_H + 17;
              return (
                <g
                  key={c.key}
                  className={`kb-be-node type-${c.type}${on ? " sel" : ""}${moved[c.key] ? " moved" : ""}`}
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
                  <rect width={b.w} height={b.h} rx="8" className="kb-be-box" />
                  {lines.map((l, li) => (
                    <text key={li} x={10} y={19 + li * LINE_H} className="kb-be-nlabel">
                      {l}
                    </text>
                  ))}
                  <text x={10} y={typeY} className="kb-be-ntype">
                    {typeLine(i, t?.label ?? c.type)}
                  </text>
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
              const typeY = 19 + ((layout.lines[c.key] ?? [c.label]).length - 1) * LINE_H + 17;
              return (layout.notes[c.key] ?? []).map((n, ni) => (
                <text
                  key={`n${n.ti}`}
                  x={b.x + 10}
                  y={b.y + typeY + 18 + ni * 18}
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
              Columns <span className="muted">(board order = left to right)</span>
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
