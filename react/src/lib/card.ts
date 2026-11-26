import type { ApprovedQueue, Card, CarriedOn } from "../types";
// Quick-add text → a card: a short title plus the rest as the description, so nothing typed or pasted is lost.
// Multi-line: first line is the title. One long line: its first sentence (or a word-boundary cut) is the title
// and the whole text becomes the description.
export const TITLE_MAX = 200; // the engine limit (AgentsKanban::Store::MAX_TITLE)
const SHORT = 120;

export function splitCard(text: string): {
  title: string;
  description: string;
} {
  const t = text.replace(/\r\n?/g, "\n").trim();
  if (!t) return { title: "", description: "" };
  const nl = t.indexOf("\n");
  if (nl >= 0) {
    const first = t.slice(0, nl).trim();
    const rest = t.slice(nl + 1).trim();
    if (first.length <= SHORT) return { title: first, description: rest };
    const head = cut(first);
    return { title: head, description: t };
  }
  if (t.length <= SHORT) return { title: t, description: "" };
  return { title: cut(t), description: t };
}

// card 662: a quick-add filled by dictation becomes a card at once — its title as splitCard cuts it, its description the
// whole spoken text (also when the title already holds all of it), so the opened card shows every word heard
export function dictatedCard(text: string): { title: string; description: string } {
  const { title } = splitCard(text);
  return { title, description: title ? text.replace(/\r\n?/g, "\n").trim() : "" };
}

function cut(s: string): string {
  const sentence = s.match(/^(.{12,}?[.!?])(\s|$)/)?.[1] ?? s.match(/^(.{12,}?)\s[—–-]\s/)?.[1];
  if (sentence && sentence.length <= SHORT) return sentence.trim();
  const slice = s.slice(0, 100);
  const sp = slice.lastIndexOf(" ");
  return `${(sp > 40 ? slice.slice(0, sp) : slice).replace(/[\s,;:(]+$/, "")}…`;
}

// In-card reference chips (server-rendered by CardLinks): "comment #148", or a bare #148 that is an activity on this
// card, links to "#a-148" — the anchor on that activity entry in the dialog.
export const activityAnchorId = (id: number) => `a-${id}`;

// "#a-148" → 148; any other href (a card ?card= link, GitHub, a page anchor) → null.
export function activityAnchor(href: string | null | undefined): number | null {
  const m = /^#a-(\d{1,9})$/.exec(href ?? "");
  return m ? Number(m[1]) : null;
}

// The activity entries that carry someone's words: always shown in the dialog. Every other kind is an event
// (move/edit/owner/handoff/…), shown only with "Show details" — a handoff's and an ask's words are a normal comment.
export const SPOKEN: ReadonlySet<string> = new Set(["comment", "question", "answer"]);

// Jumping to activity id: null when it is not on this card; otherwise whether "Show details" must be switched on first.
export function jumpNeedsDetails(
  activity: { id: number; kind: string }[],
  id: number,
  details: boolean,
): boolean | null {
  const e = activity.find((a) => a.id === id);
  if (!e) return null;
  return !details && !SPOKEN.has(e.kind);
}

// A card face's classes: `needs-you` (the red highlight) exactly when the server says the card waits for the operator
// now (Card.waiting — the rule the "N waiting for you" count uses; the client never re-derives it). Every card the board
// shows is decorated, so a face without a boolean `waiting` is a server bug: it throws, never reads as "not waiting".
// `agent-working` (the blue glow) when its owner session works now (s.working: lib/agentLive.ts workingPhase); a card
// that needs the operator shows only the red highlight — needs-you wins.
export function cardFaceClass(
  c: { id: number; waiting?: boolean | null; cover?: string | null },
  s: { dragging: boolean; busy: boolean; working: boolean },
): string {
  if (typeof c.waiting !== "boolean") throw new Error(`card ${c.id}: no waiting on its face (an undecorated card)`);
  return [
    "kb-card",
    s.dragging && "dragging",
    s.busy && "busy",
    c.cover && "has-cover",
    c.waiting === true && "needs-you",
    c.waiting === false && s.working && "agent-working",
  ]
    .filter(Boolean)
    .join(" ");
}

// An approved gate card its agent carries on: "approved · <owner> merging" when its next step is the done
// column, else "approved · <owner> → <next column>". The server sets carried_on only on a card a session owns, so a
// card without an owner here is a server bug: it throws instead of naming nobody.
export function carriedOnText(c: Pick<Card, "id" | "owner_session">, on: CarriedOn): string {
  const who = c.owner_session;
  if (!who) throw new Error(`card ${c.id}: carried_on without an owner session`);
  return on.final ? `approved · ${who} merging` : `approved · ${who} → ${on.next_label}`;
}

// The approved queue on a card face: "queue 2/3" while other approved cards share its column, with the
// cards ahead for the tooltip; alone in it → null (nothing to order).
export function approvedQueueText(q: ApprovedQueue | null | undefined): { text: string; title: string } | null {
  if (!q || q.of < 2) return null;
  const ahead = q.ahead.map((a) => `#${a.id}${a.priority ? ` (${a.priority})` : ""}`).join(", ");
  return {
    text: `queue ${q.position}/${q.of}`,
    title: `approved queue by priority: ${q.position} of ${q.of}${ahead ? ` — ahead: ${ahead}` : " — next"}`,
  };
}

// Bring an activity entry into view and focus it (a screen reader hears where it landed): centred, or its top at the
// top when it is taller than half its scroll box (centring a tall comment hides its header). Instant, never smooth: the
// lazily loaded pictures of the entries above it load as the dialog scrolls past them and push the target down, so
// every size change of its list re-aligns it for JUMP_SETTLE_MS — until the reader acts (wheel, touch, a key, a
// pointer). A picture that loads later than that no longer moves the view. Returns the stop (also run on unmount and
// before the next jump).
export const JUMP_SETTLE_MS = 5000;
const JUMP_STOPS = ["wheel", "touchstart", "keydown", "pointerdown"] as const;
export function jumpTo(el: HTMLElement): () => void {
  let box: HTMLElement | null = el.parentElement;
  while (box && !/(auto|scroll)/.test(getComputedStyle(box).overflowY)) box = box.parentElement;
  const align = () => {
    const view = box ? box.clientHeight : window.innerHeight;
    el.scrollIntoView({
      block: el.getBoundingClientRect().height > view / 2 ? "start" : "center",
      behavior: "instant",
    });
  };
  align();
  el.focus({ preventScroll: true });
  const ro = new ResizeObserver(align);
  if (el.parentElement) ro.observe(el.parentElement);
  const stop = () => {
    ro.disconnect();
    clearTimeout(t);
    for (const k of JUMP_STOPS) window.removeEventListener(k, stop, true);
  };
  const t = setTimeout(stop, JUMP_SETTLE_MS);
  for (const k of JUMP_STOPS) window.addEventListener(k, stop, { capture: true, passive: true });
  return stop;
}
