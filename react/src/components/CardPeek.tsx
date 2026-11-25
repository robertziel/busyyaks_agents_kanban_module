// A card's details on hover: anything in the page carrying data-card-id="<id>" — the server's card chips in rendered
// markdown (CardLinks: "card #N", a bare #N that is a card), the card mentions inside a question's option buttons, the
// dependency line of the card dialog, and whatever the host marks (an agents list, a waiting list) — opens a small panel
// with that card's title, column, flags, open question, people, PRs and the start of its description, an arrow pointing
// at the mention. Mounted ONCE by the host, anywhere:
// it listens on the document, so it reaches mentions outside the Board too. `load` is the host's card read (the
// KanbanApi's card); each card is read once per `ttlMs` and a failed read is shown as the server's reason, never a guess.
// Hover or keyboard focus opens it after `delayMs`; leaving both the mention and the panel closes it.
import { useCallback, useEffect, useId, useRef, useState, type CSSProperties } from "react";
import { createPortal } from "react-dom";
import { errMsg } from "../api";
import { useFaceType } from "../host";
import { dueLabel, dueState } from "../lib/board";
import { isoAgo } from "../lib/format";
import { toneClass } from "../lib/links";
import { mentionId, peekPlacement, PeekCache, shortName } from "../lib/peek";
import { akTokens } from "../lib/theme";
import type { CardData } from "../types";
import { Avatar, Html } from "./Bits";
import { KbIcon } from "./KbIcon";

export type CardPeekProps = {
  load: (id: number) => Promise<CardData>;
  delayMs?: number;
  ttlMs?: number;
};

type Shown = { id: number; rect: DOMRect; tokens: [string, string][] };
type Read = { data: CardData } | { error: string } | null;

const SELECTOR = "[data-card-id]";

// The mention an event is about: the element (or its ancestor) carrying data-card-id; for keyboard focus also the
// focused control's OWN mention (an option button is focusable, the mention span inside it is not) — only when it holds
// exactly one, so focus never picks one of several cards.
function mentionAt(t: Element, focus: boolean): Element | null {
  const el = t.closest?.(SELECTOR);
  if (el || !focus) return el ?? null;
  const inner = t.querySelectorAll?.(SELECTOR);
  return inner && inner.length === 1 ? inner[0]! : null;
}

export function CardPeek({ load, delayMs = 300, ttlMs = 30_000 }: CardPeekProps) {
  const [shown, setShown] = useState<Shown | null>(null);
  const [read, setRead] = useState<Read>(null);
  const cache = useRef<PeekCache<CardData> | null>(null);
  cache.current ??= new PeekCache<CardData>(ttlMs);
  const loadRef = useRef(load);
  loadRef.current = load;
  const openTimer = useRef<number | null>(null);
  const closeTimer = useRef<number | null>(null);
  const current = useRef<Element | null>(null);
  const panel = useRef<HTMLDivElement>(null);

  const clear = (t: { current: number | null }) => {
    if (t.current != null) window.clearTimeout(t.current);
    t.current = null;
  };

  const peekId = useId();
  const visible = useRef(false);
  visible.current = shown != null;

  // closes the panel and unlinks it from its mention (aria-describedby)
  const close = useCallback(() => {
    clear(openTimer);
    current.current?.removeAttribute("aria-describedby");
    current.current = null;
    setShown(null);
  }, []);

  const open = useCallback(
    (el: Element) => {
      const id = mentionId(el.getAttribute("data-card-id"));
      if (id == null) return;
      el.setAttribute("aria-describedby", peekId);
      setShown({ id, rect: el.getBoundingClientRect(), tokens: akTokens(getComputedStyle(el)) });
      setRead(null);
      cache
        .current!.get(id, (n) => loadRef.current(n))
        .then(
          (data) => setRead((r) => (current.current === el ? { data } : r)),
          (e: unknown) => setRead((r) => (current.current === el ? { error: errMsg(e) } : r)),
        );
    },
    [peekId],
  );

  useEffect(() => {
    const enter = (e: Event) => {
      const t = e.target as Element | null;
      if (!t || t.closest?.(".kb-peek")) return; // a mention inside the panel's own description opens nothing
      const el = mentionAt(t, e.type === "focusin");
      if (!el) return;
      clear(closeTimer);
      if (current.current === el) return;
      current.current?.removeAttribute("aria-describedby");
      current.current = el;
      clear(openTimer);
      // a panel already open (the pointer moves between mentions): switch at once, the old card never lingers
      if (visible.current) open(el);
      else openTimer.current = window.setTimeout(() => open(el), delayMs);
    };
    const leave = (e: Event) => {
      const t = e.target as Element | null;
      const el = t && mentionAt(t, e.type === "focusout");
      if (!el || el !== current.current) return;
      const to = (e as MouseEvent).relatedTarget as Node | null;
      if (to && (el.contains(to) || panel.current?.contains(to))) return;
      clear(openTimer);
      closeTimer.current = window.setTimeout(close, 150);
    };
    // Esc closes the panel only — inside the modal card dialog it must not also close the dialog (its cancel)
    const esc = (e: KeyboardEvent) => {
      if (e.key !== "Escape" || !current.current) return;
      if (visible.current) {
        e.preventDefault();
        e.stopPropagation();
      }
      close();
    };
    document.addEventListener("mouseover", enter);
    document.addEventListener("mouseout", leave);
    document.addEventListener("focusin", enter);
    document.addEventListener("focusout", leave);
    document.addEventListener("keydown", esc, true);
    window.addEventListener("scroll", close, true);
    return () => {
      document.removeEventListener("mouseover", enter);
      document.removeEventListener("mouseout", leave);
      document.removeEventListener("focusin", enter);
      document.removeEventListener("focusout", leave);
      document.removeEventListener("keydown", esc, true);
      window.removeEventListener("scroll", close, true);
      clear(openTimer);
      clear(closeTimer);
    };
  }, [delayMs, open, close]);

  if (!shown) return null;
  const { arrow, ...place } = peekPlacement(shown.rect, { w: window.innerWidth, h: window.innerHeight });
  const style = { ...Object.fromEntries(shown.tokens), ...place, "--kb-peek-arrow": `${arrow}px` } as CSSProperties;
  // the panel sits in a top-layer <dialog> when the mention is inside one (the card dialog is modal: anything outside
  // it is under its backdrop), else in <body>
  const host = (current.current?.closest("dialog[open]") as HTMLElement | null) ?? document.body;
  return createPortal(
    <div
      ref={panel}
      id={peekId}
      className="ak-root kb-peek"
      role="tooltip"
      data-side={place.top != null ? "below" : "above"}
      style={style}
      onMouseEnter={() => clear(closeTimer)}
      onMouseLeave={(e) => {
        // back onto its mention: that mention's enter cancels this timer — no close-and-reopen flicker
        const to = e.relatedTarget as Node | null;
        if (to instanceof Node && current.current?.contains(to)) return;
        closeTimer.current = window.setTimeout(close, 150);
      }}
    >
      <div className="kb-peek-box">
        <PeekBody id={shown.id} read={read} />
      </div>
      <i className="kb-peek-arrow" aria-hidden="true" />
    </div>,
    host,
  );
}

const MAX_PRS = 2; // the panel is a glance: a card with more PRs says how many more

function PeekBody({ id, read }: { id: number; read: Read }) {
  const typeOf = useFaceType(read && "data" in read ? read.data.agents : undefined);
  // the id is known before the read: the panel opens with it and the card's shape (kanban.css .kb-peek-bone), which
  // show only when the read takes longer than a blink
  if (!read)
    return (
      <div className="kb-peek-load" role="status">
        <p className="kb-peek-eyebrow">
          <span className="mono">#{id}</span>
          <span>loading…</span>
        </p>
        <i className="kb-peek-bone" />
        <i className="kb-peek-bone" />
        <i className="kb-peek-bone" />
      </div>
    );
  if ("error" in read)
    return (
      <div className="kb-peek-load" role="status">
        <p className="kb-peek-eyebrow">
          <span className="mono">#{id}</span>
        </p>
        <p className="kb-peek-state err">{read.error}</p>
      </div>
    );
  const c = read.data.card;
  const who = c.assignee ?? c.owner_session;
  const due = c.due ? { state: dueState(c.due, c.due_done, Date.now()), label: dueLabel(c.due, Date.now()) } : null;
  const prs = (read.data.links ?? []).filter((l) => l.kind === "pr");
  return (
    <>
      <header className="kb-peek-head">
        <p className="kb-peek-eyebrow">
          <span className="kb-peek-id mono">#{c.id}</span>
          <span className="kb-peek-project">{c.project}</span>
          <span className="kb-peek-updated">updated {isoAgo(c.updated)} ago</span>
        </p>
        <b className="kb-peek-title">{c.title}</b>
      </header>
      <p className="kb-peek-meta">
        <span className={`kb-pill kb-c-${c.column}`}>
          <i />
          {c.column_label ?? c.column}
        </span>
        {c.archived && <span className="tag">archived</span>}
        {c.needs_operator && <span className="kb-asked">? question for you</span>}
        {c.blocked && <span className="kb-extblocked">blocked externally</span>}
        {c.gate_hold && <span className="kb-held">⏳ {c.gate_hold}</span>}
        {c.progress_stale && <span className="kb-stale">⌛ {c.progress_stale}</span>}
        {c.waiting_for_worker &&
          (c.waiting_for_worker.stale ? (
            <span className="kb-stale">⌛ {c.waiting_for_worker.stale}</span>
          ) : (
            <span className="kb-held kb-workerless">waiting for a worker</span>
          ))}
        {c.blocked_by.length > 0 && <span className="kb-blocked">⧗ waits for #{c.blocked_by.join(", #")}</span>}
        {c.approved && <span className="kb-approved">✓ approved</span>}
        {c.review_round != null && <span className="kb-round">round {c.review_round}</span>}
      </p>
      {c.blocked?.reason && (
        // what it waits for outside the board, as a box (a long reason reads as text, not as a wrapped pill)
        <p className="kb-peek-ask kb-peek-ext">{c.blocked.reason}</p>
      )}
      {c.needs_operator && c.question_html && (
        // the open question, as asked (the server's render): what "question for you" is about
        <div className="kb-peek-ask">
          <Html className="md" html={c.question_html} />
        </div>
      )}
      {c.description_html && c.description?.trim() && (
        // the server's render (sanitized), a non-interactive excerpt (kanban.css): the mention itself is the link
        <Html className="md kb-peek-desc" html={c.description_html} />
      )}
      {(c.labels.length > 0 || prs.length > 0) && (
        <p className="kb-peek-refs">
          {c.labels.length > 0 && <KbIcon name="tag" title="labels" />}
          {c.labels.map((l) => (
            <span key={l} className="tag">
              {l}
            </span>
          ))}
          {prs.slice(0, MAX_PRS).map((l) => (
            <span key={l.url} className="kb-peek-pr">
              PR {l.label}
              {(l.tags ?? []).map((t, i) => (
                <span key={i} className={`kb-link-tag ${toneClass(t.tone)}`}>
                  {t.text}
                </span>
              ))}
            </span>
          ))}
          {prs.length > MAX_PRS && <span className="kb-peek-pr">+{prs.length - MAX_PRS} PRs</span>}
        </p>
      )}
      <footer className="kb-peek-foot kb-badges">
        {who ? (
          <span className="kb-peek-who">
            <Avatar name={who} email={who} type={typeOf(who)} />
            <span className="mono" title={who}>
              {shortName(who)}
            </span>
          </span>
        ) : (
          <span className="kb-peek-who">nobody on it</span>
        )}
        {c.checklist_total > 0 && (
          <span className={c.checklist_done === c.checklist_total ? "kb-cl full" : "kb-cl"}>
            <KbIcon name="check" title="checklist items done" />
            {c.checklist_done}/{c.checklist_total}
          </span>
        )}
        {c.comments > 0 && (
          <span>
            <KbIcon name="comment" title="comments" />
            {c.comments}
          </span>
        )}
        {c.attachments.length > 0 && (
          <span>
            <KbIcon name="clip" title="attachments" />
            {c.attachments.length}
          </span>
        )}
        {due && (
          <span className={`kb-due d-${due.state}`}>
            <KbIcon name="clock" title={c.due_done ? "due, complete" : "due"} />
            {due.label}
          </span>
        )}
      </footer>
    </>
  );
}
