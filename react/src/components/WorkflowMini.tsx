// The board header's Workflow button face: a square CHUNK of the board's real workflow tree, for
// illustration — the very drawing the editor opens (lib/graph.ts layoutGraph: each column its card with the type's
// icon tile, each transition its orthogonal arrow), seen through a square window on the start of the flow: the board's
// first two columns and what runs between them (miniCrop). The rest of the tree is drawn too and lies outside the
// window. Lines and outlines keep a visible width at that scale (vector-effect in kanban.css). Nothing in it is
// interactive or read by a screen reader: the button carries the name ("Workflow") and the counts in its title.
import { useMemo } from "react";
import {
  badgeW,
  BADGE_H,
  junctionText,
  labelW,
  LABEL_H,
  LINE_H,
  layoutGraph,
  NODE_PAD_B,
  NOTE_H,
  noteText,
  pathOf,
  subY,
  TEXT_X,
  TILE,
  TILE_X,
  TITLE_Y,
  typeLine,
  type Layout,
} from "../lib/graph";
import type { BoardShapeData } from "../types";
import { cardBadge, iconOf, UNKNOWN_ICON } from "./BoardEditor";

export const MINI_PX = 24; // the square's side: the 28 px button (one header control high) less a 2 px rim each side
// an arrowhead's side in graph units: about 3 px at the miniature's scale (the editor's 13 would be a dot); sized by
// the line's width, the marker would follow the non-scaling stroke instead
const ARROW = 30;
const CROP_PAD = 8; // graph units of air around the chunk
const CROP_COLUMNS = 2; // the chunk: this many columns from the start of the board (all of them on a shorter board)

type Shape = Pick<BoardShapeData, "columns" | "transitions" | "types">;

// The miniature draws only a SAVED board, whose transitions the engine validated (each one named, between known
// columns): a missing one is a broken board — thrown, never drawn with a stand-in name. A column type this client has
// no entry for is the editor's visible "unknown type" state (a server newer than its client), drawn as the editor does.
const typeOf = (shape: Shape, key: string) => shape.types.find((x) => x.key === key);
function transitionAt(transitions: Shape["transitions"], ti: number) {
  const t = transitions[ti];
  if (!t) throw new Error(`workflow miniature: no transition ${ti}`);
  if (!t.name) throw new Error(`workflow miniature: transition ${ti} has no name`);
  return t;
}

// the editor's layout of the shape (its type labels and pills), so the miniature is the same tree
export function miniLayout(shape: Shape): Layout {
  return layoutGraph(shape.columns, shape.transitions, {
    typeLabel: (c) => typeOf(shape, c.type)?.label ?? c.type, // unknown: its key, as the editor
    badge: (c) => cardBadge(c, typeOf(shape, c.type)),
  });
}

// the square window on the drawing: around the first CROP_COLUMNS columns' cards (board order), padded and centred on
// them — as wide as it is tall, whichever of their span is the larger
export function miniCrop(layout: Layout, columns: Shape["columns"]): { x: number; y: number; side: number } {
  if (columns.length === 0) throw new Error("workflow miniature: a board with no columns has nothing to show");
  const boxes = columns.slice(0, CROP_COLUMNS).map((c) => {
    const b = layout.nodes[c.key];
    if (!b) throw new Error(`workflow miniature: column ${c.key} was not laid out`);
    return b;
  });
  const x0 = Math.min(...boxes.map((b) => b.x));
  const y0 = Math.min(...boxes.map((b) => b.y));
  const x1 = Math.max(...boxes.map((b) => b.x + b.w));
  const y1 = Math.max(...boxes.map((b) => b.y + b.h));
  const side = Math.max(x1 - x0, y1 - y0) + 2 * CROP_PAD;
  return { x: (x0 + x1 - side) / 2, y: (y0 + y1 - side) / 2, side };
}

export function WorkflowMini({ shape }: { shape: Shape }) {
  // dagre once per shape (the board's data is polled; the shape rarely changes)
  const sig = JSON.stringify({ columns: shape.columns, transitions: shape.transitions, types: shape.types });
  const layout = useMemo(() => miniLayout(JSON.parse(sig) as Shape), [sig]);
  const { columns, transitions } = shape;
  const crop = miniCrop(layout, columns);
  return (
    <svg
      className="kb-wf-mini"
      width={MINI_PX}
      height={MINI_PX}
      viewBox={`${crop.x} ${crop.y} ${crop.side} ${crop.side}`}
      preserveAspectRatio="xMidYMid meet"
      aria-hidden="true"
      focusable="false"
    >
      <defs>
        <marker
          id="kb-wf-mini-arrow"
          viewBox="0 0 10 10"
          refX="9"
          refY="5"
          markerUnits="userSpaceOnUse"
          markerWidth={ARROW}
          markerHeight={ARROW}
          orient="auto-start-reverse"
        >
          <path d="M 0 0 L 10 5 L 0 10 z" className="kb-be-arrowhead" />
        </marker>
      </defs>
      {layout.routes.map((r) => {
        const t = transitionAt(transitions, r.ti);
        const name = t.name;
        const lw = labelW(name);
        return (
          <g key={r.id} className={`kb-be-edge by-${t.by}`}>
            <path
              d={pathOf(r.points)}
              className={`kb-be-line${r.kind === "stub" ? " kb-be-stub" : ""}${r.back ? " back" : ""}`}
              markerEnd={r.kind === "stub" ? undefined : "url(#kb-wf-mini-arrow)"}
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
                  {name}
                </text>
              </g>
            )}
          </g>
        );
      })}
      {Object.entries(layout.junctions).map(([ti, j]) => {
        const t = transitionAt(transitions, Number(ti));
        const n = layout.routes.filter((r) => r.ti === Number(ti) && r.kind === "stub").length;
        return (
          <g key={`j${ti}`} className={`kb-be-edge kb-be-bundle by-${t.by}`}>
            <rect x={j.x} y={j.y} width={j.w} height={j.h} rx={6} className="kb-be-junction" />
            <text x={j.x + j.w / 2} y={j.y + j.h / 2 + 4} textAnchor="middle" className="kb-be-jlabel">
              {junctionText(t.name, n)}
            </text>
          </g>
        );
      })}
      {columns.map((c, i) => {
        const b = layout.nodes[c.key];
        if (!b) throw new Error(`workflow miniature: column ${c.key} was not laid out`);
        const t = typeOf(shape, c.type);
        const lines = layout.lines[c.key];
        if (!lines) throw new Error(`workflow miniature: column ${c.key} has no wrapped label`);
        const typeY = subY(lines.length);
        const tileY = Math.round((typeY + NODE_PAD_B - TILE) / 2);
        const glyph = iconOf(c.type);
        const badge = cardBadge(c, t);
        const bw = badge ? badgeW(badge) : 0;
        return (
          <g
            key={c.key}
            className={`kb-be-node type-${c.type}${glyph && t ? "" : " unknown"}`}
            transform={`translate(${b.x} ${b.y})`}
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
            {(layout.notes[c.key] ?? []).map((n, ni) => (
              <text key={`n${n.ti}`} x={TEXT_X} y={typeY + NOTE_H + ni * NOTE_H} className={`kb-be-note by-${n.by}`}>
                {noteText(n, columns.length)}
              </text>
            ))}
          </g>
        );
      })}
    </svg>
  );
}
