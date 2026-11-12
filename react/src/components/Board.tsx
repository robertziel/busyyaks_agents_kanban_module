// Per-project kanban (Trello-like): the lists with drag-and-drop between and within, Trello's keyboard shortcuts
// ("?" lists them), a filter (text · labels · member · due) and the view order — by default the last change on top, cut
// into day groups, with each list folding the cards nobody touched within its column's `hide_after_hours` behind
// "Load older" —, list menus (counts, collapse),
// card faces with cover, label strips and badges (due, description, comments, checklist, priority, assignee), quick-add
// per list, and the card modal (CardDialog). Data: api.board / api.card (the host's KanbanApi); the board's shape
// (columns, gates, theme) is the config the server sends with it. The viewer (`me`) is the operator.
//
// The host owns the URL: `view` says which card / panel is open and whether archived cards show, `onView` asks for a
// change (busyyaks binds both to ?card=&panel=&archived=). The root element carries .ak-root (the CSS tokens) and
// the config's theme as inline custom properties.
import {
  Fragment,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type CSSProperties,
  type DragEvent,
  type FormEvent,
} from "react";
import { errMsg, type KanbanApi } from "../api";
import { KanbanHostProvider, colLabel as labelOf, type KanbanHostValue } from "../host";
import {
  dayGroups,
  dropPosition,
  dueLabel,
  dueState,
  EMPTY_FILTER,
  isFiltering,
  matches,
  ordered,
  ORDERS,
  SHORTCUTS,
  splitStale,
  type DueFilter,
  type Filter,
  type Order,
} from "../lib/board";
import { edgeBands, edgeScroller, glideTo, nearestStart, type EdgeBands } from "../lib/autoscroll";
import { splitCard } from "../lib/card";
import { useFetch } from "../lib/fetch";
import { isoAgo, isoAt } from "../lib/format";
import { noListener } from "../lib/listen";
import { useLiveRev } from "../lib/live";
import type { BacklogTask, BoardShapeData, HostConfig, BoardData, Card, ColumnKey, SessionLinks } from "../types";
import { Avatar, ErrorState, Loading } from "./Bits";
import { BoardEditor } from "./BoardEditor";
import { CardDialog, PANELS, type Panel } from "./CardDialog";
import { KbIcon } from "./KbIcon";
import { Select } from "./Select";

export type BoardView = { card: number | null; panel: Panel; archived: boolean };
export type BoardProps = {
  api: KanbanApi;
  me: string; // the operator, as the engine records them (busyyaks: the signed-in email)
  slug: string;
  view: BoardView;
  onView: (change: Partial<BoardView>) => void;
  onChanged?: () => void; // after any write (a host refreshes its own summaries)
  navigate?: (path: string) => void; // client-side navigation for same-origin links in rendered markdown
  projectHref?: string; // where the card dialog's project link goes
  cardHref?: (slug: string, id: number) => string;
  className?: string;
};

// per-viewer conveniences only (collapsed lists, label names on strips): storage may be missing or throw
function readStore<T>(k: string, empty: T): T {
  try {
    const v = window.localStorage.getItem(k);
    return v ? (JSON.parse(v) as T) : empty;
  } catch {
    return empty;
  }
}
function writeStore(k: string, v: unknown) {
  try {
    window.localStorage.setItem(k, JSON.stringify(v));
  } catch {
    /* not persisted in this browser: the view still works */
  }
}

// the drop slot in a list for a pointer at height y: before the first card whose middle is below it
function slotIndex(list: HTMLElement, y: number): number {
  const cards = Array.from(list.querySelectorAll<HTMLElement>("li.kb-card:not(.ro):not(.dragging)"));
  const i = cards.findIndex((c) => {
    const r = c.getBoundingClientRect();
    return y < r.top + r.height / 2;
  });
  return i < 0 ? cards.length : i;
}

const GLIDE_MS = 280; // after a drag the lists glide to the nearest list start, then snapping is back on

type Drag = { id: number; from: ColumnKey };
type Over = { col: ColumnKey; index: number };

export function Board({
  api,
  me,
  slug,
  view,
  onView,
  onChanged,
  navigate,
  projectHref,
  cardHref,
  className,
}: BoardProps) {
  const showArchived = view.archived;
  const openId = view.card;
  const panel = PANELS.includes(view.panel) ? view.panel : null;
  const { data, error, loading, reload } = useFetch<BoardData>(
    () => api.board(slug, { archived: showArchived }),
    [api, slug, showArchived],
  );
  const [err, setErr] = useState<string | null>(null);
  const [drag, setDrag] = useState<Drag | null>(null);
  const [over, setOver] = useState<Over | null>(null);
  const [busy, setBusy] = useState<number | null>(null);
  const [filter, setFilter] = useState<Filter>(EMPTY_FILTER);
  const [order, setOrderState] = useState<Order>(() => {
    const o = readStore<string>("kb-order", "updated");
    return (ORDERS as string[]).includes(o) ? (o as Order) : "updated";
  });
  const setOrder = (o: Order) => {
    setOrderState(o);
    writeStore("kb-order", o);
  };
  const [unfolded, setUnfolded] = useState<ColumnKey[]>([]); // lists whose older cards are loaded (this visit only)
  const [addCol, setAddCol] = useState<ColumnKey | null>(null);
  const [menuCol, setMenuCol] = useState<ColumnKey | null>(null);
  const [help, setHelp] = useState(false);
  const [workflowOpen, setWorkflowOpen] = useState(false);
  const [collapsed, setCollapsed] = useState<ColumnKey[]>(() => readStore(`kb-collapsed:${slug}`, []));
  const [names, setNames] = useState<boolean>(() => readStore("kb-label-names", false));
  const focusId = useRef<number | null>(null);
  const hoverId = useRef<number | null>(null);
  const root = useRef<HTMLDivElement>(null);
  const filterRef = useRef<HTMLInputElement>(null);
  const keyHandler = useRef<(e: KeyboardEvent) => void>(() => {});
  // full height: the lists run from where the board starts to the bottom of the window (each list scrolls inside)
  const kbRef = useRef<HTMLDivElement>(null);
  useLayoutEffect(() => {
    const el = kbRef.current;
    if (!el) return;
    const fit = () =>
      el.style.setProperty("--kb-top", `${Math.max(0, el.getBoundingClientRect().top + window.scrollY)}px`);
    fit();
    const ro = new ResizeObserver(fit);
    ro.observe(document.body);
    window.addEventListener("resize", fit);
    return () => {
      ro.disconnect();
      window.removeEventListener("resize", fit);
    };
  });

  // a dragged card near the board's left / right edge scrolls the lists sideways (lib/autoscroll.ts); while they move
  // under a still pointer the drop slot follows them (no dragover comes until the pointer moves)
  // Scroll snapping is off while dragging (it would fight every frame) and while the lists then glide to the nearest
  // list start (snapping back on at once would jump there).
  const dragging = drag !== null;
  const [settling, setSettling] = useState(false);
  const cancelGlide = useRef<() => void>(() => {});
  // the edge bands: where a dragged card scrolls the lists, shown on each side they can still scroll toward
  const [edge, setEdge] = useState<EdgeBands | null>(null);
  useEffect(() => {
    if (!dragging) return;
    const el = kbRef.current;
    if (!el) throw new Error("kanban: a card is dragged but the board's lists are not mounted");
    cancelGlide.current();
    setSettling(true); // set before the drop's render takes `drag` away, so snapping stays off through it
    const s = edgeScroller(el, (x, y) => {
      const list = document.elementFromPoint(x, y)?.closest<HTMLElement>("ol.kb-list");
      const col = list?.closest<HTMLElement>("[data-col]")?.dataset.col;
      if (!list || !col) return;
      const index = slotIndex(list, y);
      setOver((o) => (o && o.col === col && o.index === index ? o : { col, index }));
    });
    const bands = () => {
      const room = { left: el.scrollLeft, right: el.scrollWidth - el.clientWidth - el.scrollLeft };
      const b = edgeBands(s.pointer(), el.getBoundingClientRect(), room);
      setEdge((e) => (e && e.zone === b.zone && e.left === b.left && e.right === b.right ? e : b));
    };
    const onOver = (e: globalThis.DragEvent) => {
      s.move(e.clientX, e.clientY);
      bands();
    };
    const onLeave = (e: globalThis.DragEvent) => {
      if (e.relatedTarget) return;
      s.leave(); // the pointer left the window
      bands();
    };
    bands();
    document.addEventListener("dragover", onOver, true);
    document.addEventListener("dragleave", onLeave, true);
    el.addEventListener("scroll", bands, { passive: true });
    return () => {
      document.removeEventListener("dragover", onOver, true);
      document.removeEventListener("dragleave", onLeave, true);
      el.removeEventListener("scroll", bands);
      setEdge((e) => e && { zone: e.zone, left: "off", right: "off" }); // fade out at the width they had
      s.stop();
      const left = nearestStart(el);
      if (Math.abs(left - el.scrollLeft) < 1) {
        setSettling(false);
        return;
      }
      cancelGlide.current = glideTo(el, left, GLIDE_MS, () => setSettling(false));
    };
  }, [dragging]);

  // live: poll the board's revision; refetch when an agent, the MCP or another tab changed it. Paused only while
  // a card is being dragged or a move is in flight, so a refresh never pulls the board from under the pointer.
  // NOT while a column's "Add a card" composer is open: it stays open after each add (Trello), its draft is local
  // state a refetch never touches, and pausing on it froze the board until a page reload.
  const pause = useRef(false);
  pause.current = drag !== null || busy !== null;
  const live = useLiveRev(
    () => api.boardRev(slug, { archived: showArchived }),
    () => void reload(),
    { paused: () => pause.current },
  );
  // cards that changed since the last render glow for a moment
  const seen = useRef<Map<number, string> | null>(null);
  useEffect(() => {
    if (!data) return;
    const now = new Map<number, string>();
    for (const col of data.columns) for (const c of col.cards) now.set(c.id, `${c.updated}|${c.column}|${c.position}`);
    const prev = seen.current;
    seen.current = now;
    if (!prev) return;
    const changed = [...now].filter(([id, v]) => prev.get(id) !== v).map(([id]) => id);
    for (const id of changed) {
      const el = root.current?.querySelector<HTMLElement>(`[data-id="${id}"]`);
      if (!el) continue;
      el.classList.remove("kb-changed");
      void el.offsetWidth; // restart the animation
      el.classList.add("kb-changed");
      window.setTimeout(() => el.classList.remove("kb-changed"), 2200);
    }
  }, [data]);

  useEffect(() => {
    if (focusId.current == null || !data) return;
    root.current?.querySelector<HTMLElement>(`.kb-card[data-id="${focusId.current}"]`)?.focus();
    focusId.current = null;
  }, [data]);

  useEffect(() => {
    const h = (e: KeyboardEvent) => keyHandler.current(e);
    document.addEventListener("keydown", h);
    return () => document.removeEventListener("keydown", h);
  }, []);

  const openCard = (id: number, p: Panel = null) => onView({ card: id, panel: p });
  const config: HostConfig | undefined = data?.config;
  const board: BoardShapeData | undefined = data?.board;
  const host = useMemo<KanbanHostValue | null>(
    () => (config && board ? { api, me, config, board, navigate: navigate ?? null, cardHref: cardHref ?? null } : null),
    [api, me, config, board, navigate, cardHref],
  );
  const columns = board?.columns ?? [];
  const colLabel = (k: ColumnKey) => (board ? labelOf(board, k) : k);

  // never rejects: a failure lands in the board's error flash (setErr), so handlers call it as `void act(...)`
  const act = async (id: number | null, fn: () => Promise<unknown>): Promise<void> => {
    setErr(null);
    setBusy(id);
    try {
      await fn();
      await reload();
      onChanged?.();
    } catch (e) {
      setErr(errMsg(e));
    } finally {
      setBusy(null);
    }
  };
  const move = (id: number, column: ColumnKey, position?: number) => {
    focusId.current = id;
    return act(id, () => api.move(id, position == null ? { column } : { column, position }));
  };
  const toggleCollapse = (k: ColumnKey) => {
    const next = collapsed.includes(k) ? collapsed.filter((x) => x !== k) : [...collapsed, k];
    setCollapsed(next);
    writeStore(`kb-collapsed:${slug}`, next);
  };

  // ── keyboard (document-level; never while typing or with the card dialog open) ─────────────────
  keyHandler.current = (e: KeyboardEvent) => {
    if (!data || openId) return;
    const t = e.target as HTMLElement | null;
    if (
      t &&
      (t.closest("input, textarea, select, [contenteditable=true], dialog, [role=listbox]") || t.isContentEditable)
    )
      return;
    if (e.ctrlKey || e.metaKey) return;
    const focused = (document.activeElement as HTMLElement | null)?.closest<HTMLElement>(".kb-card[data-id]");
    const cardId = Number(focused?.dataset.id) || hoverId.current;
    const all = data.columns.flatMap((c) => c.cards);
    const card = all.find((c) => c.id === cardId) ?? null;
    const k = e.key;
    const handled = () => e.preventDefault();

    if (k === "?") return (handled(), setHelp((h) => !h));
    if (k === "Escape") {
      if (help) return setHelp(false);
      if (menuCol) return setMenuCol(null);
      if (isFiltering(filter)) return setFilter(EMPTY_FILTER);
      return;
    }
    if (k === "f" || k === "/") return (handled(), filterRef.current?.focus());
    if (k === "q") return (handled(), setFilter((f) => ({ ...f, member: f.member === me ? "" : me })));
    if (k === "n") {
      const col = focused?.dataset.col ?? card?.column ?? t?.closest<HTMLElement>(".kb-col[data-col]")?.dataset.col;
      if (!col) return;
      handled();
      if (collapsed.includes(col)) toggleCollapse(col);
      return setAddCol(col);
    }
    if (k.startsWith("Arrow") && !e.altKey) {
      const cards = Array.from(root.current?.querySelectorAll<HTMLElement>(".kb-card[data-id]") ?? []);
      if (!cards.length) return;
      handled();
      if (!focused) return cards[0]!.focus();
      const cols = columns.map((c) => cards.filter((x) => x.dataset.col === c.key)).filter((xs) => xs.length);
      const ci = cols.findIndex((xs) => xs.includes(focused));
      const ri = cols[ci]!.indexOf(focused);
      if (k === "ArrowDown") cols[ci]![Math.min(ri + 1, cols[ci]!.length - 1)]!.focus();
      if (k === "ArrowUp") cols[ci]![Math.max(ri - 1, 0)]!.focus();
      if (k === "ArrowLeft" && ci > 0) cols[ci - 1]![Math.min(ri, cols[ci - 1]!.length - 1)]!.focus();
      if (k === "ArrowRight" && ci < cols.length - 1) cols[ci + 1]![Math.min(ri, cols[ci + 1]!.length - 1)]!.focus();
      return;
    }
    if (!card) return;
    if (e.altKey) {
      const ci = columns.findIndex((x) => x.key === card.column);
      if (k === "ArrowLeft" && ci > 0) return (handled(), void move(card.id, columns[ci - 1]!.key));
      if (k === "ArrowRight" && ci < columns.length - 1) return (handled(), void move(card.id, columns[ci + 1]!.key));
      if (k === "ArrowUp" && card.position > 0) return (handled(), void move(card.id, card.column, card.position - 1));
      if (k === "ArrowDown") return (handled(), void move(card.id, card.column, card.position + 1));
      return;
    }
    if (k === "Enter" || k === "e") return (handled(), openCard(card.id));
    if (k === "l") return (handled(), openCard(card.id, "labels"));
    if (k === "d") return (handled(), openCard(card.id, "due"));
    if (k === "m") return (handled(), openCard(card.id, "members"));
    if (k === "c") return (handled(), void act(card.id, () => api.archive(card.id, true)));
    if (k === " ") {
      handled();
      focusId.current = card.id;
      return void act(card.id, () => api.assign(card.id, card.assignee === me ? "" : me));
    }
  };

  if (loading) return <Loading what="board" />;
  if (error && !data) {
    // a stored board the host no longer fits is refused loudly (422 with the reason): the way out is the template
    return (
      <div className="ak-root kb-board">
        <ErrorState error={error} what="board" retry={() => void reload()} />
        <p className="kb-be-recover">
          <button
            type="button"
            className="btn small"
            onClick={() =>
              void api.boardShapeReset(slug).then(
                () => reload(),
                (e) => setErr(errMsg(e)),
              )
            }
          >
            Reset this board to the template
          </button>
          {err && <span className="err"> {err}</span>}
        </p>
      </div>
    );
  }
  if (!data || !host || !config || !board) return null;
  const theme = config.theme as CSSProperties;

  const nowMs = Date.now();
  const cols = data.columns;
  const bm = data.backlog_md;
  const bmByCol = new Map<ColumnKey | null, BacklogTask[]>();
  bm?.tasks.forEach((t) => bmByCol.set(t.column, [...(bmByCol.get(t.column) ?? []), t]));
  const total = cols.reduce((n, c) => n + c.cards.length, 0);
  const waiting = data.waiting; // the server counts: the waiting columns' cards + the flagged cards elsewhere
  const filtering = isFiltering(filter);
  const viewOf = (cards: Card[]) => ordered(filtering ? cards.filter((c) => matches(c, filter, nowMs)) : cards, order);
  // What a list shows: its view, minus the cards folded behind "Load older" — never while filtering (a search finds
  // old cards too) and never once the list was unfolded.
  const foldOf = (col: { column: ColumnKey; hide_after_hours: number; cards: Card[] }) => {
    const view = viewOf(col.cards);
    if (filtering || unfolded.includes(col.column)) return { shown: view, older: [] as Card[] };
    const { recent, older } = splitStale(view, col.hide_after_hours, nowMs);
    return { shown: recent, older };
  };
  const shownTotal = cols.reduce((n, c) => n + viewOf(c.cards).length, 0);
  const colorOf = new Map(data.labels.map((l) => [l.name, l.color]));
  const members = Array.from(
    new Set([
      me,
      ...(data.assignees ?? []),
      ...cols.flatMap((c) => c.cards.map((x) => x.assignee).filter((a): a is string => !!a)),
    ]),
  );
  const reviewCols = board.rules.review_columns;
  const maxRounds = data.config.review_loop?.max_rounds ?? null;

  // ── drag and drop ─────────────────────────────────────────────────────────────────────────────
  const onDragStart = (c: Card) => (e: DragEvent<HTMLLIElement>) => {
    e.dataTransfer.effectAllowed = "move";
    e.dataTransfer.setData("text/plain", String(c.id));
    setDrag({ id: c.id, from: c.column });
  };
  const onDragOverList = (col: ColumnKey) => (e: DragEvent<HTMLOListElement>) => {
    if (!drag) return;
    e.preventDefault();
    e.dataTransfer.dropEffect = "move";
    const index = slotIndex(e.currentTarget, e.clientY);
    if (!over || over.col !== col || over.index !== index) setOver({ col, index });
  };
  const onDrop = (col: ColumnKey) => (e: DragEvent<HTMLOListElement>) => {
    e.preventDefault();
    if (!drag || !over) return;
    const d = drag;
    const column = cols.find((c) => c.column === col)!;
    const position = dropPosition(
      column.cards.map((c) => c.id),
      foldOf(column).shown.map((c) => c.id),
      d.id,
      over.index,
    );
    setDrag(null);
    setOver(null);
    const cur = column.cards.find((c) => c.id === d.id);
    if (cur && cur.position === position) return;
    void move(d.id, col, position);
  };
  // a collapsed list shows no cards to drop between: the whole strip is the target, the card lands at its bottom
  const onDragOverCollapsed = (col: ColumnKey) => (e: DragEvent<HTMLElement>) => {
    if (!drag) return;
    e.preventDefault();
    e.dataTransfer.dropEffect = "move";
    if (!over || over.col !== col) setOver({ col, index: 0 });
  };
  const onDropCollapsed = (col: ColumnKey) => (e: DragEvent<HTMLElement>) => {
    e.preventDefault();
    if (!drag) return;
    const d = drag;
    setDrag(null);
    setOver(null);
    if (d.from !== col) void move(d.id, col);
  };
  const endDrag = () => {
    setDrag(null);
    setOver(null);
  };

  const dueOpts: { value: DueFilter; label: string }[] = [
    { value: "", label: "Any due" },
    { value: "overdue", label: "Overdue" },
    { value: "soon", label: "Due in 24h" },
    { value: "none", label: "No due date" },
    { value: "done", label: "Complete" },
  ];

  return (
    <KanbanHostProvider value={host}>
      <div ref={root} className={`ak-root kb-board${className ? ` ${className}` : ""}`} style={theme}>
        <div className="kb-head">
          <div className="kb-sum">
            {cols.map((c) => (
              <span
                key={c.column}
                className={`kb-pill kb-c-${c.column}${c.cards.length === 0 ? " zero" : ""}`}
                title={c.label}
              >
                <i />
                {c.label} <b>{c.cards.length}</b>
              </span>
            ))}
            <span className="kb-pill">
              total <b>{total}</b>
            </span>
            <span
              className={`kb-waiting${waiting === 0 ? " zero" : ""}`}
              title={`cards waiting for you: ${data.waiting_columns.map(colLabel).join(" + ")} that can be approved now + cards with a question for you (needs_operator)`}
            >
              <b>{waiting}</b> waiting for you
            </span>
            {data.held > 0 && (
              <span
                className="kb-held"
                title="gate cards whose Approve would not pass now (CI pending, red or unread; new commits): not counted"
              >
                <b>{data.held}</b> waiting for CI
              </span>
            )}
            {data.external > 0 && (
              <span
                className="kb-held kb-external"
                title="cards blocked on something outside the board (another card, CI, a third party): not counted"
              >
                <b>{data.external}</b> blocked externally
              </span>
            )}
          </div>
          <span className="spacer" />
          <span
            className={`kb-live${live.error ? " bad" : ""}`}
            title={live.error ? `live updates failing: ${live.error}` : "live: polls every 3 s, refreshes on change"}
          >
            <i /> {live.error ? "live · error" : "live"}
          </span>
          <button
            type="button"
            className="btn small"
            aria-pressed={showArchived}
            onClick={() => onView({ archived: !showArchived })}
          >
            Archived{data.archived ? ` · ${data.archived.length}` : ""}
          </button>
          <button
            type="button"
            className="btn small"
            onClick={() => setWorkflowOpen(true)}
            title="This project's board: its columns (with their types) and the named transitions a card may take"
          >
            Workflow
          </button>
          <button
            type="button"
            className="btn small"
            aria-label="Keyboard shortcuts"
            title="Keyboard shortcuts (?)"
            onClick={() => setHelp(true)}
          >
            ?
          </button>
        </div>

        <div className="kb-filter" role="search">
          <input
            ref={filterRef}
            type="search"
            className="kb-q"
            placeholder="Filter cards  (f)"
            aria-label="Filter cards"
            value={filter.text}
            onChange={(e) => setFilter({ ...filter, text: e.target.value })}
            onKeyDown={(e) => e.key === "Escape" && (e.currentTarget.blur(), setFilter({ ...filter, text: "" }))}
          />
          <Select
            ariaLabel="Member"
            options={[
              { value: "", label: "Any member" },
              { value: me, label: "Me (q)" },
              { value: "-", label: "Unassigned" },
              ...members.filter((m) => m !== me).map((m) => ({ value: m, label: m })),
            ]}
            value={filter.member}
            onChange={(v) => setFilter({ ...filter, member: v })}
          />
          <Select
            ariaLabel="Due"
            options={dueOpts}
            value={filter.due}
            onChange={(v) => setFilter({ ...filter, due: v as DueFilter })}
          />
          <Select
            ariaLabel="Order"
            options={[
              { value: "updated", label: "Last modified" },
              { value: "position", label: "List order" },
              { value: "due", label: "By due date" },
            ]}
            value={order}
            onChange={(v) => setOrder(v as Order)}
          />
          {data.labels.length > 0 && (
            <div className="kb-flabels" role="group" aria-label="Filter by label">
              {data.labels.map((l) => (
                <button
                  type="button"
                  key={l.id}
                  className={`kb-lchip lc-${l.color}`}
                  aria-pressed={filter.labels.includes(l.name)}
                  onClick={() =>
                    setFilter({
                      ...filter,
                      labels: filter.labels.includes(l.name)
                        ? filter.labels.filter((x) => x !== l.name)
                        : [...filter.labels, l.name],
                    })
                  }
                >
                  {l.name}
                </button>
              ))}
            </div>
          )}
          {filtering && (
            <span className="kb-fcount">
              <b>{shownTotal}</b>/{total}
              <button type="button" className="linklike" onClick={() => setFilter(EMPTY_FILTER)}>
                clear
              </button>
            </span>
          )}
        </div>

        {err && (
          <div className="flash bad" role="alert">
            <i className="dot bad" />
            <span>{err}</span>
          </div>
        )}
        {data.launcher_error && (
          <div className="flash bad">
            <i className="dot bad" />
            <span>Launcher down: {data.launcher_error} · tmux sessions missing from assignee suggestions</span>
          </div>
        )}
        {bm && bm.errors.length > 0 && (
          <div className="flash bad">
            <i className="dot bad" />
            <span>
              Backlog.md: {bm.errors.slice(0, 5).join(" · ")}
              {bm.errors.length > 5 && ` · +${bm.errors.length - 5}`}
            </span>
          </div>
        )}

        {showArchived && data.archived && (
          <section className="card kb-archived">
            <h2>Archived · {data.archived.length}</h2>
            {data.archived.length === 0 && <p className="muted">0 archived</p>}
            {data.archived.map((c) => (
              <div className="kb-arow" key={c.id}>
                <button type="button" className="linklike" onClick={() => openCard(c.id)}>
                  {c.title}
                </button>
                <span className="tag">{colLabel(c.column)}</span>
                <span className="muted">{isoAgo(c.archived)}</span>
                <button
                  type="button"
                  className="btn small kb-push"
                  disabled={busy === c.id}
                  onClick={() => void act(c.id, () => api.archive(c.id, false))}
                >
                  Restore
                </button>
              </div>
            ))}
          </section>
        )}

        <div className="kb-scroll" style={edge ? ({ "--kb-edge-zone": `${edge.zone}px` } as CSSProperties) : undefined}>
          <div className={`kb${drag || settling ? " kb-snap-off" : ""}`} ref={kbRef}>
            {cols.map((col) => {
              const { shown: view, older } = foldOf(col);
              const groups = order === "updated" ? dayGroups(view, nowMs) : [{ key: "", label: "", cards: view }];
              const ghostAt = drag && over && over.col === col.column ? over.index : -1;
              const overdue = col.cards.filter((c) => dueState(c.due, c.due_done, nowMs) === "overdue").length;
              const soon = col.cards.filter((c) => dueState(c.due, c.due_done, nowMs) === "soon").length;
              const isCollapsed = collapsed.includes(col.column);
              if (isCollapsed)
                return (
                  <section
                    key={col.column}
                    className={`kb-col collapsed kb-c-${col.column}${over && over.col === col.column ? " over" : ""}`}
                    data-col={col.column}
                    aria-label={`${col.label} (collapsed)`}
                    onDragOver={onDragOverCollapsed(col.column)}
                    onDragLeave={(e) => {
                      if (!e.currentTarget.contains(e.relatedTarget as Node | null))
                        setOver((o) => (o && o.col === col.column ? null : o));
                    }}
                    onDrop={onDropCollapsed(col.column)}
                  >
                    <button
                      type="button"
                      className="kb-expand"
                      onClick={() => toggleCollapse(col.column)}
                      title={`Expand ${col.label}`}
                    >
                      <i />
                      <span>{col.label}</span>
                      <b>{col.cards.length}</b>
                    </button>
                  </section>
                );
              return (
                <section
                  key={col.column}
                  className={`kb-col kb-c-${col.column}`}
                  data-col={col.column}
                  aria-labelledby={`kb-h-${col.column}`}
                >
                  <header>
                    <h2 id={`kb-h-${col.column}`}>
                      <i />
                      {col.label}
                    </h2>
                    <span className="n">
                      {filtering || older.length ? `${view.length}/${col.cards.length}` : col.cards.length}
                    </span>
                    <button
                      type="button"
                      className="kb-menu-btn"
                      aria-label={`${col.label} list menu`}
                      aria-expanded={menuCol === col.column}
                      onClick={() => setMenuCol(menuCol === col.column ? null : col.column)}
                    >
                      <KbIcon name="dots" />
                    </button>
                    {menuCol === col.column && (
                      <ListMenu
                        onClose={() => setMenuCol(null)}
                        stats={[
                          [col.cards.length, "cards"],
                          [overdue, "overdue"],
                          [soon, "due 24h"],
                          [col.cards.filter((c) => !c.assignee).length, "unassigned"],
                        ]}
                        onAdd={() => {
                          setMenuCol(null);
                          setAddCol(col.column);
                        }}
                        onCollapse={() => {
                          setMenuCol(null);
                          toggleCollapse(col.column);
                        }}
                      />
                    )}
                  </header>
                  <ol
                    className={`kb-list${over && over.col === col.column ? " over" : ""}`}
                    aria-label={col.label}
                    onDragOver={onDragOverList(col.column)}
                    onDragLeave={(e) => {
                      if (!e.currentTarget.contains(e.relatedTarget as Node | null))
                        setOver((o) => (o && o.col === col.column ? null : o));
                    }}
                    onDrop={onDrop(col.column)}
                  >
                    {groups.map((g) => (
                      <Fragment key={`g:${g.key}`}>
                        {g.label && (
                          <li className="kb-day" aria-hidden="true">
                            <span>{g.label}</span>
                            <b>{g.cards.length}</b>
                          </li>
                        )}
                        {g.cards.map((c) => {
                          const i = view.indexOf(c);
                          return (
                            <CardItem
                              reviewCols={reviewCols}
                              maxRounds={maxRounds}
                              live={data.live_sessions ?? null}
                              listened={data.listened_columns}
                              links={data.session_links}
                              key={c.id}
                              card={c}
                              colorOf={colorOf}
                              names={names}
                              nowMs={nowMs}
                              ghostBefore={ghostAt === i}
                              dragging={drag?.id === c.id}
                              busy={busy === c.id}
                              onOpen={() => openCard(c.id)}
                              onToggleNames={() => {
                                setNames(!names);
                                writeStore("kb-label-names", !names);
                              }}
                              onHover={(on) =>
                                (hoverId.current = on ? c.id : hoverId.current === c.id ? null : hoverId.current)
                              }
                              onDragStart={onDragStart(c)}
                              onDragEnd={endDrag}
                            />
                          );
                        })}
                      </Fragment>
                    ))}
                    {ghostAt >= view.length && ghostAt >= 0 && <li className="kb-ghost" aria-hidden="true" />}
                    {older.length > 0 && (
                      <li className="kb-older">
                        <button
                          type="button"
                          className="btn small"
                          onClick={() => setUnfolded((u) => [...u, col.column])}
                          title={`Cards not updated for ${col.hide_after_hours} h`}
                        >
                          Load older · {older.length}
                        </button>
                      </li>
                    )}
                    {(bmByCol.get(col.column) ?? []).map((t) => (
                      <li key={`bm:${t.id}`} className="kb-card ro" title={`${t.file} — edit with the backlog CLI`}>
                        <span className="kb-title">{t.title}</span>
                        <div className="kb-badges">
                          <span className="tag bmd">{t.id}</span>
                          {t.draft && <span className="tag">draft</span>}
                          {t.priority && <span className={`kb-prio p-${t.priority}`}>{t.priority}</span>}
                          {(t.labels ?? []).map((l) => (
                            <span className="tag" key={l}>
                              {l}
                            </span>
                          ))}
                          <span>{t.status}</span>
                          <span className="spacer" />
                          {(Array.isArray(t.assignee) ? t.assignee : t.assignee ? [t.assignee] : [])
                            .slice(0, 2)
                            .map((a) => (
                              <Avatar key={a} name={a} email={a} />
                            ))}
                        </div>
                      </li>
                    ))}
                  </ol>
                  <QuickAdd
                    api={api}
                    slug={slug}
                    column={col.column}
                    colLabel={col.label}
                    open={addCol === col.column}
                    setOpen={(o) => setAddCol(o ? col.column : null)}
                    onAdded={() => void act(null, async () => {})}
                    onError={setErr}
                  />
                </section>
              );
            })}
          </div>
          <i className={`kb-edge kb-edge-l ${edge?.left ?? "off"}`} aria-hidden="true" />
          <i className={`kb-edge kb-edge-r ${edge?.right ?? "off"}`} aria-hidden="true" />
        </div>

        {bm && (bmByCol.get(null) ?? []).length > 0 && (
          <section className="card">
            <h2>Backlog.md · no column · {bmByCol.get(null)!.length}</h2>
            {bmByCol.get(null)!.map((t) => (
              <div className="kb-arow" key={t.id}>
                <span className="tag bmd">{t.id}</span> {t.title} <span className="muted">{t.status}</span>
              </div>
            ))}
          </section>
        )}

        {help && <ShortcutsOverlay onClose={() => setHelp(false)} />}

        {workflowOpen && (
          <BoardEditor slug={slug} onClose={() => setWorkflowOpen(false)} onSaved={() => void reload()} />
        )}

        {openId && (
          <CardDialog
            id={openId}
            slug={slug}
            board={data}
            panel={panel}
            setPanel={(p) => onView({ panel: p })}
            projectHref={projectHref ?? null}
            onClose={() => {
              focusId.current = openId;
              onView({ card: null, panel: null });
            }}
            onChanged={() => {
              void reload();
              onChanged?.();
            }}
          />
        )}
      </div>
    </KanbanHostProvider>
  );
}

type CardItemProps = {
  card: Card;
  reviewCols: ColumnKey[]; // the review columns: a card there shows its review round
  maxRounds: number | null; // config.review_loop.max_rounds (null = no limit)
  live: string[] | null; // live agent session names; null = launcher down (no "gone" claims)
  listened: string[]; // columns where an assignee without an owner session is flagged "no listener"
  links: Record<string, SessionLinks> | undefined;
  colorOf: Map<string, string>;
  names: boolean;
  nowMs: number;
  ghostBefore: boolean;
  dragging: boolean;
  busy: boolean;
  onOpen: () => void;
  onToggleNames: () => void;
  onHover: (on: boolean) => void;
  onDragStart: (e: DragEvent<HTMLLIElement>) => void;
  onDragEnd: () => void;
};

function CardItem({
  card: c,
  reviewCols,
  maxRounds,
  live,
  listened,
  links,
  colorOf,
  names,
  nowMs,
  ghostBefore,
  dragging,
  busy,
  onOpen,
  onToggleNames,
  onHover,
  onDragStart,
  onDragEnd,
}: CardItemProps) {
  const ds = dueState(c.due, c.due_done, nowMs);
  const full = c.checklist_total > 0 && c.checklist_done === c.checklist_total;
  return (
    <>
      {ghostBefore && <li className="kb-ghost" aria-hidden="true" />}
      <li
        className={`kb-card${dragging ? " dragging" : ""}${busy ? " busy" : ""}${c.cover ? " has-cover" : ""}`}
        draggable
        tabIndex={0}
        data-id={c.id}
        data-col={c.column}
        aria-label={`${c.title} — #${c.id}`}
        onDragStart={onDragStart}
        onDragEnd={onDragEnd}
        onMouseEnter={() => onHover(true)}
        onMouseLeave={() => onHover(false)}
        onClick={(e) => {
          if ((e.target as HTMLElement).closest("a, .kb-strips")) return;
          onOpen();
        }}
      >
        {c.cover && <div className={`kb-cardcover lc-${c.cover}`} aria-hidden="true" />}
        {c.labels.length > 0 && (
          <button
            type="button"
            tabIndex={-1}
            className={`kb-strips${names ? " names" : ""}`}
            title={names ? "hide label names" : c.labels.join(", ")}
            onClick={onToggleNames}
          >
            {c.labels.map((l) => (
              <span key={l} className={`kb-strip lc-${colorOf.get(l) ?? "missing"}`}>
                {names ? l : ""}
              </span>
            ))}
          </button>
        )}
        <span className="kb-title">{c.title}</span>
        <div className="kb-badges">
          {c.needs_operator && (
            <span
              className="kb-asked"
              title={`needs the operator — question from ${c.asked_by ?? "?"}: ${(c.question ?? "").slice(0, 300)}`}
            >
              ?{" "}
              {c.dialog
                ? `dialog on ${c.dialog.session}`
                : c.question_options?.length
                  ? `${c.question_options.length} choices`
                  : "question"}
            </span>
          )}
          {c.blocked && (
            <span
              className="kb-extblocked"
              title={`blocked (external) by ${c.blocked.by ?? "?"}: ${c.blocked.reason ?? ""}${c.blocked.url ? ` — ${c.blocked.url}` : ""}`}
            >
              ⛔ blocked: {(c.blocked.reason ?? "").slice(0, 60)}
            </span>
          )}
          {c.gate_hold && (
            <span className="kb-held" title={`waiting for CI, not for you: ${c.gate_hold}`}>
              ⏳ {c.gate_hold.slice(0, 60)}
            </span>
          )}
          {c.review_round != null && reviewCols.includes(c.column) && (
            <span
              className="kb-round"
              title={`review round ${c.review_round}${maxRounds ? ` of ${maxRounds}` : ""} in this column`}
            >
              round {c.review_round}
              {maxRounds ? `/${maxRounds}` : ""}
            </span>
          )}
          {noListener(c, listened) && (
            <span
              className="kb-nolisten"
              title={`${c.assignee} is assigned but no tmux session owns this card — comments reach nobody. Set the owner session in the card.`}
            >
              no listener
            </span>
          )}
          {c.blocked_by.length > 0 && (
            <span className="kb-blocked" title={`waits for card #${c.blocked_by.join(", #")} — not done yet`}>
              ⧗ waits for #{c.blocked_by.join(", #")}
            </span>
          )}
          {c.approved && (
            <span className="kb-approved" title={`approved by ${c.approved_by ?? "?"} — its agent moves it on`}>
              ✓ approved
            </span>
          )}
          {c.owner_session && (
            <span
              className={`kb-owner${live && !live.includes(c.owner_session) ? " gone" : ""}`}
              title={
                live && !live.includes(c.owner_session)
                  ? `owner session ${c.owner_session} is gone — the watchdog releases the card`
                  : `owner session ${c.owner_session}: comments are typed into it`
              }
            >
              ⌁ {c.owner_session}
              {live && !live.includes(c.owner_session) ? " · gone" : ""}
              {links?.[c.owner_session]?.claude_url && (
                <a
                  className="kb-owner-claude"
                  href={links[c.owner_session]!.claude_url!}
                  target="_blank"
                  rel="noopener"
                  title={`Open ${c.owner_session} in Claude (Remote Control)`}
                  onClick={(e) => e.stopPropagation()}
                  onMouseDown={(e) => e.stopPropagation()}
                >
                  Claude ↗
                </a>
              )}
              {links?.[c.owner_session]?.model && (
                <span className="kb-owner-model" title={`model running ${c.owner_session}`}>
                  {links[c.owner_session]!.model}
                </span>
              )}
            </span>
          )}
          {c.owner_session && links?.[c.owner_session]?.model && (
            <span className="kb-owner-model" title={`model running ${c.owner_session}`}>
              {links[c.owner_session]!.model}
            </span>
          )}
          {c.due && (
            <span className={`kb-due d-${ds}`} title={`due ${isoAt(c.due)}${c.due_done ? " · complete" : ""}`}>
              <KbIcon name="clock" />
              {dueLabel(c.due, nowMs)}
            </span>
          )}
          {c.has_description && (
            <span title="has a description">
              <KbIcon name="desc" />
            </span>
          )}
          {c.comments > 0 && (
            <span title={`${c.comments} comments`}>
              <KbIcon name="comment" />
              {c.comments}
            </span>
          )}
          {c.attachments > 0 && (
            <span className="kb-att-badge" title={`${c.attachments} attachment${c.attachments === 1 ? "" : "s"}`}>
              <KbIcon name="clip" />
              {c.attachments}
            </span>
          )}
          {c.checklist_total > 0 && (
            <span className={full ? "kb-cl full" : "kb-cl"} title="checklist items done">
              <KbIcon name="check" />
              {c.checklist_done}/{c.checklist_total}
            </span>
          )}
          {c.priority && <span className={`kb-prio p-${c.priority}`}>{c.priority}</span>}
          <span className="mono kb-id" title={`updated ${isoAt(c.updated)}`}>
            #{c.id}
          </span>
          <span className="spacer" />
          {c.assignee && (
            <span className="kb-who" title={c.assignee}>
              <Avatar name={c.assignee} email={c.assignee} />
            </span>
          )}
        </div>
      </li>
    </>
  );
}

function ListMenu({
  stats,
  onAdd,
  onCollapse,
  onClose,
}: {
  stats: [number, string][];
  onAdd: () => void;
  onCollapse: () => void;
  onClose: () => void;
}) {
  const ref = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const away = (e: PointerEvent) => {
      if (!ref.current?.contains(e.target as Node) && !(e.target as HTMLElement).closest(".kb-menu-btn")) onClose();
    };
    document.addEventListener("pointerdown", away);
    ref.current?.querySelector<HTMLElement>("button")?.focus();
    return () => document.removeEventListener("pointerdown", away);
  }, [onClose]);
  return (
    <div className="kb-menu" ref={ref} role="menu" onKeyDown={(e) => e.key === "Escape" && onClose()}>
      <dl className="kb-menu-stats">
        {stats.map(([n, l]) => (
          <div key={l} className={n === 0 ? "zero" : ""}>
            <dt>{l}</dt>
            <dd>{n}</dd>
          </div>
        ))}
      </dl>
      <button type="button" role="menuitem" onClick={onAdd}>
        Add card <kbd>n</kbd>
      </button>
      <button type="button" role="menuitem" onClick={onCollapse}>
        Collapse list
      </button>
    </div>
  );
}

function ShortcutsOverlay({ onClose }: { onClose: () => void }) {
  const ref = useRef<HTMLDialogElement>(null);
  useEffect(() => {
    const d = ref.current;
    if (!d) return;
    if (!d.open) d.showModal();
    const onCancel = (e: Event) => {
      e.preventDefault();
      onClose();
    };
    d.addEventListener("cancel", onCancel);
    return () => {
      d.removeEventListener("cancel", onCancel);
      if (d.open) d.close();
    };
  }, [onClose]);
  return (
    <dialog
      ref={ref}
      className="kb-dialog kb-help"
      aria-label="Keyboard shortcuts"
      onClick={(e) => e.target === ref.current && onClose()}
      onKeyDown={(e) => {
        e.stopPropagation();
        if (e.key === "?") onClose();
      }}
    >
      <header className="kb-dhead">
        <h3>Keyboard shortcuts</h3>
        <span className="spacer" />
        <button type="button" className="btn small" onClick={onClose} aria-label="Close">
          ✕
        </button>
      </header>
      <dl className="kb-keys-list">
        {SHORTCUTS.map(([k, d]) => (
          <div key={k}>
            <dt>
              {k.split(" · ").map((x) => (
                <kbd key={x}>{x}</kbd>
              ))}
            </dt>
            <dd>{d}</dd>
          </div>
        ))}
      </dl>
      <p className="muted kb-help-foot">
        Editors: <kbd>Ctrl</kbd>+<kbd>B</kbd> <kbd>I</kbd> <kbd>E</kbd> <kbd>K</kbd> format · <kbd>Ctrl</kbd>+
        <kbd>Enter</kbd> save · <kbd>Esc</kbd> cancel
      </p>
    </dialog>
  );
}

type QuickAddProps = {
  api: KanbanApi;
  slug: string;
  column: ColumnKey;
  colLabel: string;
  open: boolean;
  setOpen: (o: boolean) => void;
  onAdded: () => void;
  onError: (m: string) => void;
};

function QuickAdd({ api, slug, column, colLabel, open, setOpen, onAdded, onError }: QuickAddProps) {
  const [title, setTitle] = useState("");
  const [busy, setBusy] = useState(false);
  // never rejects: a failed create goes to onError (the board's error flash)
  const submit = async (e: FormEvent): Promise<void> => {
    e.preventDefault();
    const card = splitCard(title);
    if (!card.title) return;
    setBusy(true);
    try {
      await api.createCard(slug, { title: card.title, description: card.description, column });
      setTitle("");
      onAdded();
    } catch (err) {
      onError(errMsg(err));
    } finally {
      setBusy(false);
    }
  };
  if (!open)
    return (
      <div className="kb-add">
        <button type="button" className="kb-add-btn" onClick={() => setOpen(true)}>
          + Add a card
        </button>
      </div>
    );
  return (
    <form className="kb-add" onSubmit={(e) => void submit(e)}>
      <textarea
        autoFocus
        rows={3}
        required
        className="kb-add-text"
        placeholder="Card title — paste a whole task; the first line becomes the title"
        aria-label={`New card title in ${colLabel}`}
        value={title}
        onChange={(e) => setTitle(e.target.value)}
        onKeyDown={(e) => {
          if (e.key === "Escape") setOpen(false);
          if (e.key === "Enter" && !e.shiftKey) {
            e.preventDefault();
            void submit(e);
          }
        }}
      />
      {(() => {
        const c = splitCard(title);
        return c.description ? (
          <p className="kb-add-split" aria-live="polite">
            <b>{c.title}</b> <span>+ description · {c.description.length} chars</span>
          </p>
        ) : null;
      })()}
      <div className="kb-add-row">
        <button className="btn primary small" disabled={busy}>
          Add
        </button>
        <button type="button" className="btn small" onClick={() => setOpen(false)}>
          Cancel
        </button>
      </div>
    </form>
  );
}
