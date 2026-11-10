// Small shared pieces: the avatar, loading / error states, the links an agent's session offers, server-rendered HTML.
import { forwardRef, useCallback, useState, type CSSProperties, type MouseEvent, type ReactNode } from "react";
import { useKanbanHost } from "../host";
import { hue, initials } from "../lib/format";
import type { Card, SessionLinks } from "../types";

export function Avatar({ name, email }: { name: string; email: string }) {
  return (
    <span className="avatar" style={{ "--h": hue(email) } as CSSProperties} title={`${name} <${email}>`}>
      {initials(name)}
    </span>
  );
}

// Loading / error states that say what is missing. No placeholder data, ever.
export function Loading({ what }: { what: string }) {
  return (
    <p className="state loading" role="status" aria-live="polite">
      <i className="spin" aria-hidden="true" /> loading {what}…
    </p>
  );
}

export function ErrorState({ error, what, retry }: { error: Error; what: string; retry?: () => void }) {
  const status = (error as { status?: unknown }).status;
  return (
    <div className="flash bad" role="alert">
      <i className="dot bad" />
      <span>
        {what}: {typeof status === "number" && status ? `${status} · ` : ""}
        {error.message}
      </span>
      {retry && (
        <button type="button" className="btn small" onClick={retry}>
          Retry
        </button>
      )}
    </div>
  );
}

// Click to copy: the text is the button. "copied ✓" for a moment; a refused clipboard (no HTTPS, denied) says so.
export function CopyChip({
  text,
  children,
  title,
  className = "",
}: {
  text: string;
  children?: ReactNode;
  title?: string;
  className?: string;
}) {
  const [state, setState] = useState<"idle" | "done" | "fail">("idle");
  const copy = () => {
    if (!navigator.clipboard) {
      setState("fail");
      return;
    }
    navigator.clipboard.writeText(text).then(
      () => setState("done"),
      () => setState("fail"),
    );
    window.setTimeout(() => setState("idle"), 1500);
  };
  return (
    <button
      type="button"
      className={`copychip ${state} ${className}`}
      onClick={copy}
      title={title ?? `Copy: ${text}`}
      aria-label={`Copy ${text}`}
    >
      {children ?? <code>{text}</code>}
      <span className="copystate" aria-live="polite">
        {state === "done" ? "copied ✓" : state === "fail" ? "copy refused" : ""}
      </span>
    </button>
  );
}

// An agent on a card → its live session: Claude ↗ (the Remote Control page), iTerm ⧉ (copies ssh + tmux attach),
// Terminal ↗ (the team terminal view). Resolved from the card's owner session: the agent named as assignee, or an
// author that IS a session name. A session that is not live gets no buttons (nothing to open).
export function sessionFor(
  who: string,
  card: Pick<Card, "owner_session" | "assignee">,
  links: Record<string, SessionLinks> | undefined,
): [string, SessionLinks] | null {
  if (!links) return null;
  if (links[who]) return [who, links[who]];
  if (card.owner_session && who === card.assignee && links[card.owner_session])
    return [card.owner_session, links[card.owner_session]!];
  return null;
}

export function AgentLinks({
  who,
  card,
  links,
}: {
  who: string;
  card: Pick<Card, "owner_session" | "assignee">;
  links: Record<string, SessionLinks> | undefined;
}) {
  const s = sessionFor(who, card, links);
  if (!s) return null;
  const [name, l] = s;
  return (
    <span className="agent-links" title={`${who} runs in tmux session ${name}`}>
      {l.model && (
        <span className="kb-owner-model" title={`model running ${name}`}>
          {l.model}
        </span>
      )}
      {l.claude_url && (
        <a
          className="termlink claudelink"
          href={l.claude_url}
          target="_blank"
          rel="noopener"
          title={`Open ${name} in Claude (Remote Control)`}
        >
          Claude ↗
        </a>
      )}
      <CopyChip text={l.ssh_attach} className="itermcopy" title={`Copy for iTerm: ${l.ssh_attach}`}>
        <span className="termlink">iTerm ⧉</span>
      </CopyChip>
      <a
        className="termlink"
        href={l.terminal_url}
        target="_blank"
        rel="noopener"
        title={`Open ${name} in the team terminal`}
      >
        Terminal ↗
      </a>
    </span>
  );
}

// Server-rendered HTML (descriptions, comments, checklist items — sanitized by the engine's markdown port) injected
// as-is. Same-origin links inside it navigate client-side through the host's `navigate` when it gave one; an
// attachment picture (.kb-att-img) and a download are left to the dialog / the browser.
type HtmlProps = { html: string; className?: string };

export const Html = forwardRef<HTMLDivElement, HtmlProps>(function Html({ html, className = "md" }, ref) {
  const { navigate } = useKanbanHost();
  const onClick = useCallback(
    (e: MouseEvent<HTMLElement>) => {
      if (!navigate || e.defaultPrevented || e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
      const a = (e.target as HTMLElement).closest("a");
      if (!a || !e.currentTarget.contains(a)) return;
      if (a.target && a.target !== "_self") return;
      if (a.hasAttribute("download") || a.classList.contains("kb-att-img")) return;
      const url = new URL(a.href, window.location.href);
      if (url.origin !== window.location.origin) return;
      if (url.pathname === window.location.pathname && url.hash) return; // in-page anchor
      e.preventDefault();
      navigate(url.pathname + url.search + url.hash);
    },
    [navigate],
  );
  return <div ref={ref} className={className} onClick={onClick} dangerouslySetInnerHTML={{ __html: html }} />;
});
