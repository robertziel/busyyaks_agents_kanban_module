// The session boards (HostConfig#session_boards), read-only: one board per agent session, attached to no project —
// only its session writes it (kanban_session_board + the card tools). The host fetches Api#session_boards and passes
// the data; this draws each board's columns with their card titles, the session, the last activity and when it is
// archived (idle_hours with no activity; an archived one keeps its cards, archived). Its .ak-root would reset the
// --ak-* tokens to the engine's defaults: it takes the values the host resolves on <html> (lib/theme.ts), as the
// failed-start alert does. `focus` (a card's link: the host's ?session=&card=) marks that board and card and scrolls
// the card into view.
import { useEffect, useLayoutEffect, useRef } from "react";
import { isoAgo, isoAt, now } from "../lib/format";
import { leftLabel, secondsLeft, sessionBoardLanes } from "../lib/sessionBoards";
import { akTokens } from "../lib/theme";
import type { SessionBoardsData } from "../types";

export type SessionBoardsFocus = { session?: string | null; card?: number | null };
export type SessionBoardsProps = { data: SessionBoardsData; nowS?: number; focus?: SessionBoardsFocus };

export function SessionBoards({ data, nowS = now(), focus }: SessionBoardsProps) {
  const ref = useRef<HTMLDivElement>(null);
  const target = focus?.card ?? null;
  useEffect(() => {
    if (target == null) return;
    ref.current?.querySelector(`[data-card="${target}"]`)?.scrollIntoView({ block: "center" });
  }, [target, data]);
  useLayoutEffect(() => {
    const d = ref.current;
    if (!d) return;
    for (const [name, value] of akTokens(getComputedStyle(document.documentElement))) d.style.setProperty(name, value);
  });
  if (data.session_boards.length === 0) {
    return (
      <div ref={ref} className="ak-root ak-sb-empty">
        0 session boards · archived after {data.idle_hours} h idle
      </div>
    );
  }
  return (
    <div ref={ref} className="ak-root ak-sb">
      {data.session_boards.map((b) => {
        const lanes = sessionBoardLanes(b);
        const left = secondsLeft(b, nowS);
        return (
          <section
            key={b.slug}
            className={`ak-sb-board${focus?.session === b.session ? " ak-sb-focus" : ""}`}
            aria-label={`session ${b.session}`}
          >
            <header className="ak-sb-head">
              <span className="ak-sb-session">{b.session}</span>
              <span className="ak-sb-meta">
                {b.archived
                  ? `archived ${isoAt(b.archived)}`
                  : `${b.cards.length} cards · active ${isoAgo(b.last_activity)} ago · archives in ${leftLabel(left)}`}
              </span>
            </header>
            <div className="ak-sb-lanes">
              {lanes.map((l) => (
                <div key={l.column.key} className={`ak-sb-lane ak-sb-${l.column.type}`}>
                  <div className="ak-sb-lane-head">
                    {l.column.label} · {l.cards.length}
                  </div>
                  <ul className="ak-sb-cards">
                    {l.cards.map((c) => (
                      <li
                        key={c.id}
                        data-card={c.id}
                        className={`ak-sb-card${c.id === target ? " ak-sb-focus" : ""}`}
                        aria-current={c.id === target ? "true" : undefined}
                      >
                        <span className="ak-sb-id">#{c.id}</span> {c.title}
                      </li>
                    ))}
                  </ul>
                </div>
              ))}
            </div>
          </section>
        );
      })}
    </div>
  );
}
