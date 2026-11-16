// The card dialog's live agent line (SPEC § 9): what a session does now, worded from the host's SessionLive. Pure, so
// the wording is tested without a DOM. A field the host could not read is left out, never guessed.
import type { Card, ColumnTypeKey, SessionLive } from "../types";
import { moodOf, type Mood } from "./face";

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

// the largest unit only: what a small label has room for ("44m", "2h", "42s")
export function elapsedShort(s: number | null): string | null {
  if (s === null) return null;
  if (s >= 3600) return `${Math.floor(s / 3600)}h`;
  if (s >= 60) return `${Math.floor(s / 60)}m`;
  return `${s}s`;
}

// A session's name as a small label shows it: the part that tells it from its neighbours. Sessions of one board start
// with the project's name (the slug, or its last part, with every other character as "_"), so that prefix is dropped;
// what is still longer than `max` is cut in the MIDDLE — the end (the number, the role) is what differs. The full name
// stays in the tooltip and the details.
export function shortSession(session: string, project: string, max = 14): string {
  const norm = (s: string) => s.replace(/[^A-Za-z0-9_-]/g, "_");
  let name = session;
  for (const prefix of [norm(project), norm(project.split("/").pop()!)]) {
    if (
      prefix &&
      session.length > prefix.length + 1 &&
      session.startsWith(prefix) &&
      /[_-]/.test(session[prefix.length]!)
    ) {
      name = session.slice(prefix.length + 1);
      break;
    }
  }
  if (name.length <= max) return name;
  const tail = Math.ceil((max - 1) * 0.65);
  return `${name.slice(0, max - 1 - tail)}…${name.slice(-tail)}`;
}

const COMMENT_TOOL = /(?:^|·\s*)kanban_(?:comment|comment_edit|ask|attach|handoff)$/;

// The line in parts (the agent-at-work strip shows each on its own): what it does, in words, and the counters the
// host read. cardId: the open card — a comment tool writing on it reads "writing a comment on this card".
// `brief` = the same in a word or two, what a small label has room for: the tool's OWN name (the last part of
// "server · tool"), never the counters.
export type LiveParts = LiveLine & { what: string; brief: string; meta: string[] };

export function liveParts(l: SessionLive, cardId: number): LiveParts {
  if (l.state === "blocked") {
    const what = "waiting for you (a dialog or question)";
    return { what, brief: "needs you", meta: [], text: what, tone: "blocked", running: true };
  }
  if (l.state !== "working") {
    const tone = l.state === "idle" || l.state === "finished" ? "idle" : "unknown";
    const what = l.state === "unknown" ? "state unknown" : l.state;
    return { what, brief: l.state, meta: [], text: what, tone, running: false };
  }
  let what: string;
  let brief: string = l.phase ?? "working";
  if (l.phase === "thinking") what = "thinking…";
  else if (l.phase === "writing") what = "writing…";
  else if (l.phase === "subagents") what = "waiting for its subagents";
  else if (l.phase === "tool") {
    brief = l.tool ? l.tool.split("·").pop()!.trim() : "tool";
    if (l.tool && COMMENT_TOOL.test(l.tool))
      what =
        l.card === cardId
          ? "writing a comment on this card"
          : l.card === null
            ? "writing a comment"
            : `writing a comment on card ${l.card}`;
    else what = l.tool ? `running ${l.tool}` : "running a tool";
  } else what = "working";
  const meta = [elapsed(l.elapsed_s), l.tokens ? `${l.tokens} tokens` : null];
  if (l.subagents) meta.push(`${l.subagents} subagent${l.subagents === 1 ? "" : "s"}`);
  const shown = meta.filter((b): b is string => !!b);
  return { what, brief, meta: shown, text: [what, ...shown].join(" · "), tone: "working", running: true };
}

export function liveLine(l: SessionLive, cardId: number): LiveLine {
  const { text, tone, running } = liveParts(l, cardId);
  return { text, tone, running };
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

// comment ids (newest first) → the mood of the face on the newest comment of each session the host reads live: that
// one face moves, the same agent's older comments stay still
export function liveMoods(
  comments: { id: number; author: string }[],
  card: Pick<Card, "owner_session" | "assignee">,
  sessions: Record<string, SessionLive> | undefined,
): Map<number, Mood> {
  const out = new Map<number, Mood>();
  const seen = new Set<string>();
  for (const c of comments) {
    const s = liveSessionOf(c.author, card, sessions);
    if (!s || seen.has(s) || !sessions) continue;
    seen.add(s);
    const mood = moodOf(sessions[s]!);
    if (mood) out.set(c.id, mood);
  }
  return out;
}

// what a screen reader announces for a live line: its tone in words, never the counter (it changes every poll)
export function liveAnnounce(l: LiveLine): string {
  return { working: "is working", blocked: "is waiting for you", idle: "is idle", unknown: "state unknown" }[l.tone];
}

// The board's working glow (SPEC § 9): the phase a card's OWNER session is in, read off the host's boardLive answer —
// only a working session with evidence of what it does (thinking · tool · writing · subagents) glows; idle, blocked,
// unknown, a working session with no phase (no evidence), no owner, a card in a done / cancelled column (finished work:
// its session works on something else), or a failed / unread poll (`sessions` null) → null.
export type WorkingPhase = Exclude<SessionLive["phase"], null>;
const WORKING: readonly WorkingPhase[] = ["thinking", "tool", "writing", "subagents"];
export function workingPhase(
  card: Pick<Card, "owner_session">,
  column: ColumnTypeKey,
  sessions: Record<string, SessionLive> | null,
): WorkingPhase | null {
  if (!sessions || !card.owner_session || column === "done" || column === "cancelled") return null;
  const l = sessions[card.owner_session];
  if (!l || l.state !== "working" || l.phase === null) return null;
  return WORKING.includes(l.phase) ? l.phase : null;
}

// the face's words for it (title / aria): what the owner session does, never the counters
const WORKING_WORDS: Record<WorkingPhase, string> = {
  thinking: "thinking",
  tool: "running a tool",
  writing: "writing",
  subagents: "waiting on its subagents",
};
export function workingWords(phase: WorkingPhase): string {
  return WORKING_WORDS[phase];
}
