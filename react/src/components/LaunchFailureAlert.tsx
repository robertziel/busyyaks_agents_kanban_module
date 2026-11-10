// The failed-start alert: a modal over the whole page the moment a session the board started (a launch from the bar,
// a spawn for a card) never came up — claude refused to start, so the host killed it and the engine released its
// cards. The rows are the engine's (Api#waiting `launch_failures`, the host polls it everywhere); this only remembers,
// per viewer, the ids dismissed (pruned to the rows the engine still lists), so the next failure opens it again —
// a spawn retried after its backoff that fails again is a new failure and alerts again.
// A native <dialog> opened with showModal(): the top layer, above any other modal (the card dialog is one too) and every
// host overlay — a modal opened AFTER it (a card dialog from the URL) would stack above it, so it re-raises itself
// (close + showModal = the top of the top layer) whenever another <dialog> opens; the page beneath is inert, so focus stays inside; Esc = the dialog's cancel = Dismiss; on close the
// browser returns focus to where it was. Its .ak-root would reset the --ak-* tokens to the engine's defaults (and their
// prefers-color-scheme dark set): it takes the values the host resolves on <html> instead (lib/theme.ts), so a host
// theme on :root (busyyaks' skins) applies; a host with no tokens there keeps the defaults.
import { useEffect, useRef, useState } from "react";
import { isoAt } from "../lib/format";
import { unseenFailures } from "../lib/launch";
import { akTokens } from "../lib/theme";
import type { LaunchFailure } from "../types";

export type LaunchFailureAlertProps = {
  failures: LaunchFailure[];
  storageKey?: string; // localStorage key of the dismissed ids (a JSON array)
  projectHref?: (slug: string) => string; // the host's URL of the project's board: each row links there
};

function readSeen(k: string): Set<number> {
  try {
    const v: unknown = JSON.parse(window.localStorage.getItem(k) ?? "[]");
    return new Set(Array.isArray(v) ? v.filter((x): x is number => typeof x === "number") : []);
  } catch {
    return new Set();
  }
}

export function LaunchFailureAlert({
  failures,
  storageKey = "ak-launch-failure-seen",
  projectHref,
}: LaunchFailureAlertProps) {
  const [seen, setSeen] = useState<Set<number>>(() => readSeen(storageKey));
  const shown = unseenFailures(failures, seen);
  const ok = useRef<HTMLButtonElement>(null);
  const ref = useRef<HTMLDialogElement>(null);
  const open = shown.length > 0;
  const dismiss = () => {
    // the ids the engine still lists, so the set stays as small as its list (≤ LAUNCH_FAILURES_SHOWN)
    const next = new Set(failures.map((f) => f.id));
    try {
      window.localStorage.setItem(storageKey, JSON.stringify([...next]));
    } catch {
      /* per-viewer convenience: without storage it is dismissed for this page only */
    }
    setSeen(next);
  };
  const onDismiss = useRef(dismiss);
  onDismiss.current = dismiss;
  useEffect(() => {
    const d = ref.current;
    if (!open || !d) return;
    const back = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    for (const [name, value] of akTokens(getComputedStyle(document.documentElement))) d.style.setProperty(name, value);
    if (!d.open) d.showModal();
    ok.current?.focus();
    const onCancel = (e: Event) => {
      e.preventDefault();
      onDismiss.current();
    };
    d.addEventListener("cancel", onCancel);
    const raise = new MutationObserver((changes) => {
      if (!changes.some((c) => c.target !== d && c.target instanceof HTMLDialogElement && c.target.open)) return;
      if (d.open) d.close();
      d.showModal();
      ok.current?.focus();
    });
    raise.observe(document.body, { subtree: true, attributes: true, attributeFilter: ["open"] });
    return () => {
      raise.disconnect();
      d.removeEventListener("cancel", onCancel);
      if (d.open) d.close();
      if (back?.isConnected) back.focus();
    };
  }, [open]);
  if (!open) return null;
  return (
    <dialog ref={ref} className="ak-root ak-alert" role="alertdialog" aria-labelledby="ak-alert-title">
      <h2 id="ak-alert-title">
        {shown.length === 1 ? "A session did not start" : `${shown.length} sessions did not start`}
      </h2>
      <ul>
        {shown.map((f) => (
          <li key={f.id} data-failure={f.id}>
            <div className="ak-alert-head">
              <code>{f.session}</code>
              <span className="muted">
                {projectHref ? <a href={projectHref(f.project)}>{f.project}</a> : f.project} · {f.type}
                {f.launcher ? ` · ${f.launcher}` : ""} · by {f.launched_by} · {isoAt(f.ended)}
              </span>
            </div>
            <pre className="ak-alert-reason">{f.reason}</pre>
          </li>
        ))}
      </ul>
      <div className="ak-alert-actions">
        <button ref={ok} type="button" className="btn primary" onClick={dismiss}>
          Dismiss
        </button>
      </div>
    </dialog>
  );
}
