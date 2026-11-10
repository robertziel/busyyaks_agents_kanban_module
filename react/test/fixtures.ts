// The fixtures as the SERVER sends them: the host config (fixtures/boards/<name>.json), the board shape
// (<name>.board.json) and the rules the engine derives from the columns' types (Board#rules — this helper mirrors the
// ruby derivation for the two fixtures so the components can be tested without a server; the engine's suite proves it).
import { readFileSync } from "node:fs";
import { join } from "node:path";
import type {
  ApprovalStep,
  BoardData,
  BoardRules,
  BoardShape,
  BoardShapeData,
  Card,
  ColumnType,
  ColumnTypeKey,
  HostConfig,
} from "../src/types";

const fixtures = join(__dirname, "..", "..", "fixtures", "boards");
// JSON.parse is untyped: each caller names the fixture file's shape
const read = <T>(f: string): T => JSON.parse(readFileSync(join(fixtures, f), "utf8")) as T;

export const TYPES: ColumnType[] = [
  {
    key: "parked",
    label: "Parked",
    summary: "nobody listens",
    hide_after_hours: 168,
    waiting: false,
    listened: false,
    operator_only: false,
    agent_no_create: false,
    finishes: false,
    terminal: false,
    singleton: false,
  },
  {
    key: "queued",
    label: "Queued",
    summary: "work waiting for a session",
    hide_after_hours: 72,
    waiting: false,
    listened: true,
    operator_only: false,
    agent_no_create: false,
    finishes: false,
    terminal: false,
    singleton: true,
  },
  {
    key: "working",
    label: "Working",
    summary: "a work column",
    hide_after_hours: 72,
    waiting: false,
    listened: true,
    operator_only: false,
    agent_no_create: false,
    finishes: false,
    terminal: false,
    singleton: false,
  },
  {
    key: "review",
    label: "Review",
    summary: "a further work column",
    hide_after_hours: 72,
    waiting: false,
    listened: true,
    operator_only: false,
    agent_no_create: false,
    finishes: false,
    terminal: false,
    singleton: false,
  },
  {
    key: "gate",
    label: "Gate",
    summary: "waits for the operator",
    hide_after_hours: 72,
    waiting: true,
    listened: true,
    operator_only: true,
    agent_no_create: false,
    finishes: false,
    terminal: false,
    singleton: false,
  },
  {
    key: "done",
    label: "Done",
    summary: "finished",
    hide_after_hours: 24,
    waiting: false,
    listened: false,
    operator_only: true,
    agent_no_create: true,
    finishes: true,
    terminal: true,
    singleton: true,
  },
  {
    key: "cancelled",
    label: "Cancelled",
    summary: "stopped",
    hide_after_hours: 24,
    waiting: false,
    listened: false,
    operator_only: true,
    agent_no_create: true,
    finishes: false,
    terminal: true,
    singleton: true,
  },
];

export function rulesOf(shape: BoardShape, host: HostConfig): BoardRules {
  const of = (...ts: ColumnTypeKey[]) => shape.columns.filter((c) => ts.includes(c.type)).map((c) => c.key);
  const one = (t: ColumnTypeKey) => of(t)[0] ?? null;
  const flag = (f: keyof ColumnType) =>
    shape.columns.filter((c) => TYPES.find((t) => t.key === c.type)![f]).map((c) => c.key);
  const gates = of("gate");
  const working = one("working");
  const done = one("done");
  const queued = one("queued");
  return {
    default_column: shape.columns[0]!.key,
    waiting: flag("waiting"),
    listened: flag("listened"),
    operator_only: flag("operator_only"),
    agent_no_create: flag("agent_no_create"),
    terminal: flag("terminal"),
    gates: {
      handoff: gates.length && host.handoff ? { columns: gates, ...host.handoff } : null,
      approvals: approvalsOf(shape, gates),
      watchdog: working && queued ? { from: working, to: queued } : null,
    },
    dependencies:
      host.dependencies && done
        ? {
            done: [done],
            blocked: of("queued", "working", "review"),
            promote: queued && of("parked").length ? { from: of("parked"), to: queued } : null,
          }
        : null,
    idle_column: working,
    review_columns: of("review"),
    spawn_columns: [],
    hide_after_hours: Object.fromEntries(shape.columns.map((c) => [c.key, c.hide_after_hours])),
  };
}

// Board#derive_approvals: per gate its ONE named operator-only exit (not "*") FORWARD — into a non-terminal column later
// in board order; `then` = the one agent-usable (agent | any) non-"*" exit from `to` not into a working column; final =
// `then` is the done column.
function approvalsOf(shape: BoardShape, gates: string[]): ApprovalStep[] {
  const keys = shape.columns.map((c) => c.key);
  const typeOf = (k: string) => shape.columns.find((c) => c.key === k)!.type;
  const terminal = (k: string) => TYPES.find((t) => t.key === typeOf(k))!.terminal;
  const fromList = (f: string | string[]) => (f === "*" ? keys : Array.isArray(f) ? f : [f]);
  const steps: ApprovalStep[] = [];
  for (const g of gates) {
    const exits = shape.transitions.filter(
      (t) =>
        t.by === "operator" &&
        t.to !== "*" &&
        fromList(t.from).includes(g) &&
        !terminal(t.to) &&
        keys.indexOf(t.to) > keys.indexOf(g),
    );
    if (exits.length !== 1) continue;
    const e = exits[0]!;
    const next = [
      ...new Set(
        shape.transitions
          .filter(
            (t) => t.by !== "operator" && t.to !== "*" && fromList(t.from).includes(e.to) && typeOf(t.to) !== "working",
          )
          .map((t) => t.to),
      ),
    ];
    const then = next.length === 1 ? next[0]! : null;
    if (then && typeOf(then) === "done") steps.push({ from: g, to: e.to, then, name: e.name, final: true });
    else steps.push({ from: g, to: e.to, then, name: e.name, final: false });
  }
  return steps;
}

export type Fixture = { host: HostConfig; shape: BoardShape; board: BoardShapeData };
// local_v4 = busyyaks's private local-repo board (two agent review loops, three approval steps, Public: Create PR) on the coding host;
// legacy_v2_prereview = the 13-column workflow v2 private board the unreadable editor screenshot showed, its types mapped
// to the v3 set (asks_operator → working, handoff / approved → gate): the graph editor's layout fixture.
export function fixture(name: "coding" | "content" | "local_v4" | "legacy_v2_prereview"): Fixture {
  const host = read<HostConfig>(`${name === "content" ? "content" : "coding"}.json`);
  const shape = read<BoardShape>(`${name}.board.json`);
  return {
    host,
    shape,
    board: {
      ...shape,
      rules: rulesOf(shape, host),
      types: TYPES,
      updated_by: "coding_lead",
      updated: "2026-11-04T20:00:00Z",
    },
  };
}

export function boardData(f: Fixture, cards: Card[], theme: Record<string, string> = {}): BoardData {
  const cfg = { ...f.host, theme };
  return {
    project: "g/r",
    labels: [{ id: 1, name: "bug", color: "red" }],
    label_colors: cfg.label_colors,
    config: cfg,
    board: f.board,
    backlog_md: null,
    columns: f.shape.columns.map((c) => ({
      column: c.key,
      label: c.label,
      type: c.type,
      operator_only: f.board.rules.operator_only.includes(c.key),
      hide_after_hours: c.hide_after_hours,
      cards: cards.filter((x) => x.column === c.key),
    })),
    columns_order: f.shape.columns.map((c) => c.key),
    waiting_columns: f.board.rules.waiting,
    listened_columns: f.board.rules.listened,
    waiting: cards.filter(
      (c) => (f.board.rules.waiting.includes(c.column) && !c.gate_hold) || c.needs_operator || !!c.blocked,
    ).length,
    held: cards.filter(
      (c) => f.board.rules.waiting.includes(c.column) && !!c.gate_hold && !c.needs_operator && !c.blocked,
    ).length,
    flagged: cards.filter((c) => !f.board.rules.waiting.includes(c.column) && (c.needs_operator || !!c.blocked)).length,
    priorities: cfg.priorities,
    assignees: ["me"],
    live_sessions: [],
    project_sessions: [],
    session_links: {},
    sessions_error: null,
  };
}
