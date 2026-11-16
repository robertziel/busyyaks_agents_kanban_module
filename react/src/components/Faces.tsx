// The agents at work on a card right now, as the host computed them (PresentAgent): HereNow = their faces in a stack
// (a card face on the board), AgentsAtWork = the card dialog's row of small labels, one per agent (AgentAtWork): face ·
// the session's short name · the phase in a word · elapsed; a click opens that agent's details under the row. A face / label pops in when its agent
// arrives and shrinks away when it leaves; nothing is guessed — no presence, no faces.
import { useEffect, useId, useRef, useState, type AnimationEvent, type KeyboardEvent } from "react";
import { elapsedShort, liveAnnounce, liveParts, shortSession } from "../lib/agentLive";
import { useFaceType } from "../host";
import { faceLabel, moodOf } from "../lib/face";
import { useLingering } from "../lib/linger";
import type { PresentAgent } from "../types";
import { AgentFace } from "./AgentFace";

const WHY: Record<PresentAgent["why"], string> = {
  blocked: "waiting for you on this card",
  tool: "a running tool call names this card",
  activity: "just acted on this card",
};

const sessionKey = (p: PresentAgent) => p.session;
// only the element's own exit ends it: a face inside animates too, and its animationend bubbles
const own = (e: AnimationEvent) => e.target === e.currentTarget;

// the type of a present agent: what the host said with the presence, else its face's (useFaceType: the registry's, a
// `face_roles` role)
export const presentType = (p: PresentAgent, typeOf: (name: string) => string | null): string | null =>
  p.type ?? typeOf(p.agent);

export function HereNow({
  present,
  agents,
  label,
}: {
  present: readonly PresentAgent[];
  agents?: Record<string, string>;
  label: string; // what the stack is, for a screen reader ("at work on card #3")
}) {
  const { shown, gone } = useLingering(present, sessionKey);
  const typeOf = useFaceType(agents);
  if (shown.length === 0) return null;
  return (
    <span className="kb-here" role="group" aria-label={label}>
      {shown.map(({ key, item: p, leaving }) => {
        const type = presentType(p, typeOf);
        const mood = moodOf(p.live);
        return (
          <span
            key={key}
            className={`kb-here-face${leaving ? " leaving" : ""}`}
            data-session={p.session}
            aria-hidden={leaving || undefined}
            onAnimationEnd={leaving ? (e) => own(e) && gone(key) : undefined}
          >
            <AgentFace
              name={p.agent}
              type={type}
              mood={leaving ? null : mood}
              title={`${faceLabel(p.agent, type, mood)} · ${p.session} · ${WHY[p.why]}`}
            />
          </span>
        );
      })}
    </span>
  );
}

// The phase in words; a change cross-fades: the old phase stays, fading out over the new one, until its exit ends.
function Phase({ what }: { what: string }) {
  const { shown, gone } = useLingering([what], (w) => w);
  return (
    <span className="kb-work-phases">
      {shown.map(({ key, item, leaving }) => (
        <span
          key={key}
          className={`kb-work-phase${leaving ? " out" : ""}`}
          aria-hidden={leaving || undefined}
          onAnimationEnd={leaving ? (e) => own(e) && gone(key) : undefined}
        >
          <span className="kb-agent-live-text">{item}</span>
        </span>
      ))}
    </span>
  );
}

// Everything the host said about a present agent, as label → value: the label's tooltip and its details panel
function factsOf(p: PresentAgent, cardId: number, type: string | null): [string, string][] {
  const l = p.live;
  const facts: [string, string][] = [
    ["agent", type ? `${p.agent} · ${type}` : p.agent],
    ["session", p.session],
    ["here because", WHY[p.why]],
    ["state", l.state],
  ];
  if (l.state_by) facts.push(["read from", l.state_by]);
  if (l.phase) facts.push(["phase", l.phase]);
  if (l.tool) facts.push(["tool", l.tool]);
  if (l.card !== null) facts.push(["card", l.card === cardId ? `#${l.card} (this card)` : `#${l.card}`]);
  if (l.subagents) facts.push(["subagents", String(l.subagents)]);
  if (l.tokens) facts.push(["tokens", l.tokens]);
  return facts;
}

// One agent as a small label: its face, `name` (the session's short name), the phase in a word, the elapsed time. The
// tooltip carries every fact in full; `details` = the id of the panel a click opens.
export function AgentAtWork({
  agent: p,
  cardId,
  name,
  type,
  open,
  details,
  onToggle,
  leaving = false,
  onGone,
}: {
  agent: PresentAgent;
  cardId: number;
  name: string; // shortSession: the part of the session's name that tells it from the others
  type: string | null; // presentType: the face's colour
  open: boolean;
  details: string;
  onToggle: () => void;
  leaving?: boolean;
  onGone?: () => void;
}) {
  const parts = liveParts(p.live, cardId);
  const mood = moodOf(p.live);
  const time = parts.running ? elapsedShort(p.live.elapsed_s) : null;
  const tip = [parts.text, ...factsOf(p, cardId, type).map(([k, v]) => `${k}: ${v}`)].join("\n");
  return (
    <li
      className={`kb-agent-live t-${parts.tone}${open ? " open" : ""}${leaving ? " leaving" : ""}`}
      data-session={p.session}
      aria-hidden={leaving || undefined}
      onAnimationEnd={leaving && onGone ? (e) => own(e) && onGone() : undefined}
    >
      <button
        type="button"
        className="kb-work-label"
        aria-expanded={open}
        aria-controls={open ? details : undefined}
        aria-label={`${p.session}: ${parts.what}, ${open ? "hide" : "show"} details`}
        title={tip}
        disabled={leaving}
        onClick={onToggle}
      >
        <AgentFace name={p.agent} type={type} mood={leaving ? null : mood} />
        <b className="kb-work-who">{name}</b>
        <Phase what={parts.brief} />
        {time && <span className="kb-work-meta">{time}</span>}
      </button>
    </li>
  );
}

// The card dialog's row: one label per present agent, side by side, wrapping; the open one's details under the row.
// Always there while the host answers (empty = no height: it opens and closes with the first / last agent instead of
// pushing the comments), with ONE live region: a screen reader hears who arrived, who left and whose state changed —
// once per change, never the counters.
export function AgentsAtWork({
  present,
  cardId,
  project,
  agents,
}: {
  present: readonly PresentAgent[];
  cardId: number;
  project: string; // the card's project: its sessions' names start with it (shortSession)
  agents?: Record<string, string>;
}) {
  const { shown, gone } = useLingering(present, sessionKey);
  const typeOf = useFaceType(agents);
  const [open, setOpen] = useState<string | null>(null);
  const details = useId();
  const opened = present.find((p) => p.session === open);

  const [said, setSaid] = useState("");
  const heard = useRef(new Map<string, string>());
  const states = JSON.stringify(
    present.map((p) => [p.session, shortSession(p.session, project), liveAnnounce(liveParts(p.live, cardId))]),
  );
  useEffect(() => {
    const now = JSON.parse(states) as [string, string, string][];
    const before = heard.current;
    const news = now
      .filter(([s, , words]) => before.get(s)?.endsWith(` ${words}`) !== true)
      .map(([, n, w]) => `${n} ${w}`);
    const here = new Set(now.map(([s]) => s));
    for (const [s, line] of before) if (!here.has(s)) news.push(`${line.slice(0, line.indexOf(" "))} left`);
    heard.current = new Map(now.map(([s, n, w]) => [s, `${n} ${w}`]));
    if (news.length) setSaid(news.join(", "));
  }, [states]);

  // Esc with the details open closes them and gives the focus back to their label — not the whole card dialog
  const onKey = (e: KeyboardEvent<HTMLLIElement>) => {
    if (e.key !== "Escape" || !opened) return;
    e.preventDefault();
    e.stopPropagation();
    e.nativeEvent.stopPropagation();
    e.currentTarget.querySelector<HTMLElement>(".kb-agent-live.open > button")?.focus();
    setOpen(null);
  };
  return (
    <li className={`kb-agents-live${present.length ? "" : " empty"}`} onKeyDown={onKey}>
      <span className="kb-sr-only" aria-live="polite">
        {said}
      </span>
      <div className="kb-agents-live-in">
        {shown.length > 0 && (
          <ul className="kb-work-labels" aria-label={`at work on card #${cardId} now`}>
            {shown.map(({ key, item, leaving }) => (
              <AgentAtWork
                key={key}
                agent={item}
                cardId={cardId}
                name={shortSession(item.session, project)}
                type={presentType(item, typeOf)}
                open={!leaving && open === key}
                details={details}
                onToggle={() => setOpen(open === key ? null : key)}
                leaving={leaving}
                onGone={() => gone(key)}
              />
            ))}
          </ul>
        )}
        {opened && (
          <dl className="kb-work-details" id={details} data-session={opened.session}>
            {factsOf(opened, cardId, presentType(opened, typeOf)).map(([k, v]) => (
              <div key={k}>
                <dt>{k}</dt>
                <dd>{v}</dd>
              </div>
            ))}
          </dl>
        )}
      </div>
    </li>
  );
}
