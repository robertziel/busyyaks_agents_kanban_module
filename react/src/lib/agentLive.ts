// The card dialog's live agent line (SPEC § 9): what a session does now, worded from the host's SessionLive. Pure, so
// the wording is tested without a DOM. A field the host could not read is left out, never guessed.
import type { Card, SessionLive } from "../types";

export type LiveLine = { text: string; tone: "working" | "blocked" | "idle" | "unknown"; running: boolean };

export function elapsed(s: number | null): string | null {
  if (s === null) return null;
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const sec = s % 60;
  if (h) return `${h}h ${m}m`;
  if (m) return `${m}m ${sec}s`;
  return `${sec}s`;
}

const COMMENT_TOOL = /(?:^|·\s*)kanban_(?:comment|comment_edit|ask|attach|handoff)$/;

// cardId: the open card — a comment tool writing on it reads "writing a comment on this card"
export function liveLine(l: SessionLive, cardId: number): LiveLine {
  if (l.state === "blocked") return { text: "waiting for you (a dialog or question)", tone: "blocked", running: true };
  if (l.state !== "working") {
    const tone = l.state === "idle" || l.state === "finished" ? "idle" : "unknown";
    return { text: l.state === "unknown" ? "state unknown" : l.state, tone, running: false };
  }
  let what: string;
  if (l.phase === "thinking") what = "thinking…";
  else if (l.phase === "writing") what = "writing…";
  else if (l.phase === "subagents") what = "waiting for its subagents";
  else if (l.phase === "tool") {
    if (l.tool && COMMENT_TOOL.test(l.tool))
      what =
        l.card === cardId
          ? "writing a comment on this card"
          : l.card === null
            ? "writing a comment"
            : `writing a comment on card ${l.card}`;
    else what = l.tool ? `running ${l.tool}` : "running a tool";
  } else what = "working";
  const bits = [what, elapsed(l.elapsed_s), l.tokens ? `${l.tokens} tokens` : null];
  if (l.subagents) bits.push(`${l.subagents} subagent${l.subagents === 1 ? "" : "s"}`);
  return { text: bits.filter((b): b is string => !!b).join(" · "), tone: "working", running: true };
}

// The session a comment's author runs in (as Bits' sessionFor: its own name, or the card's assignee → its owner session)
export function liveSessionOf(
  who: string,
  card: Pick<Card, "owner_session" | "assignee">,
  sessions: Record<string, SessionLive> | undefined,
): string | null {
  if (!sessions) return null;
  if (sessions[who]) return who;
  if (card.owner_session && who === card.assignee && sessions[card.owner_session]) return card.owner_session;
  return null;
}

// comment ids (newest first) → the newest comment of each session whose turn runs now: the one that gets the live dot
export function liveDots(
  comments: { id: number; author: string }[],
  card: Pick<Card, "owner_session" | "assignee">,
  sessions: Record<string, SessionLive> | undefined,
  cardId: number,
): Map<number, LiveLine & { session: string }> {
  const out = new Map<number, LiveLine & { session: string }>();
  const seen = new Set<string>();
  for (const c of comments) {
    const s = liveSessionOf(c.author, card, sessions);
    if (!s || seen.has(s) || !sessions) continue;
    seen.add(s);
    const line = liveLine(sessions[s]!, cardId);
    if (line.running) out.set(c.id, { ...line, session: s });
  }
  return out;
}

// what a screen reader announces for a live line: its tone in words, never the counter (it changes every poll)
export function liveAnnounce(l: LiveLine): string {
  return { working: "is working", blocked: "is waiting for you", idle: "is idle", unknown: "state unknown" }[l.tone];
}
