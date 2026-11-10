// The Launch bar: one split pill per agent type (the main half starts a session of that type, the menu half picks
// one of the type's launchers — remembered per viewer and type), and the cap line "N / M running". Data and
// verdicts come from the engine (api.launches / api.launch): a pill is greyed with the cap it hits, and the server's
// refusal (422 with who runs) is shown verbatim — the bar counts nothing itself.
import { useEffect, useState } from "react";
import { errMsg, type LaunchApi } from "../api";
import { useFetch } from "../lib/fetch";
import { capLine, launchBlocked, launcherLock, pickLauncher } from "../lib/launch";
import type { LaunchesData, LaunchResult } from "../types";
import { Select } from "./Select";

export type LaunchBarProps = {
  api: LaunchApi;
  slug: string;
  onLaunched?: (r: LaunchResult) => void; // the host shows its own verdict (Remote Control, trust prompt) from r.result
  className?: string;
  refreshEvery?: number; // ms; 0 = never
};

function readKey(k: string): string | null {
  try {
    return window.localStorage.getItem(k);
  } catch {
    return null;
  }
}
function writeKey(k: string, v: string) {
  try {
    window.localStorage.setItem(k, v);
  } catch {
    /* per-viewer convenience only */
  }
}

export function LaunchBar({ api, slug, onLaunched, className, refreshEvery = 15_000 }: LaunchBarProps) {
  const { data, error, reload } = useFetch<LaunchesData>(() => api.launches(slug), [api, slug]);
  const [busy, setBusy] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [choice, setChoice] = useState<Record<string, string>>({});
  useEffect(() => {
    if (!refreshEvery) return;
    // a hidden tab does not poll; coming back refreshes at once
    const tick = () => {
      if (!document.hidden) void reload();
    };
    const t = window.setInterval(tick, refreshEvery);
    document.addEventListener("visibilitychange", tick);
    return () => {
      window.clearInterval(t);
      document.removeEventListener("visibilitychange", tick);
    };
  }, [refreshEvery, reload]);
  if (error)
    return (
      <span className={`ak-launchbar ${className ?? ""}`}>
        <span className="ak-cap bad">launches: {error.message}</span>
      </span>
    );
  if (!data) return null;
  const cap = capLine(data.concurrency, data.sessions_error);
  const run = async (type: string, launcher: string) => {
    setErr(null);
    setBusy(type);
    try {
      const r = await api.launch(slug, { type, launcher });
      onLaunched?.(r);
      await reload();
    } catch (e) {
      setErr(errMsg(e));
    } finally {
      setBusy(null);
    }
  };
  return (
    <span className={`ak-launchbar ${className ?? ""}`}>
      {data.types.map((t) => {
        const key = `ak-launcher:${t.key}`;
        const lock = launcherLock(t);
        const launcher = lock ? pickLauncher(t, null) : (choice[t.key] ?? pickLauncher(t, readKey(key)));
        const label = t.launchers.find((l) => l.key === launcher)?.label ?? launcher;
        const blocked = launchBlocked(t, data.concurrency, data.sessions_error);
        const title =
          blocked ??
          `start a ${t.key} session (${label})${lock ? ` — ${lock}` : ""}${t.takes.length ? ` — adopts ownerless cards in ${t.takes.join(", ")}` : ""}`;
        return (
          <span className="ak-launch" key={t.key} data-type={t.key}>
            <button
              type="button"
              className={`btn small ak-launch-main${t.prompt ? " primary" : ""}`}
              disabled={!!blocked || busy !== null}
              title={title}
              onClick={() => void run(t.key, launcher)}
            >
              {busy === t.key ? "Launching…" : t.label}
              {t.running ? <span className="ak-launch-n">{t.running}</span> : null}
            </button>
            {t.launchers.length > 1 ? (
              <span className="ak-launch-menu-wrap" title={lock ?? undefined} data-locked={lock ? "" : undefined}>
                <Select
                  options={t.launchers.map((l) => ({ value: l.key, label: l.label }))}
                  value={launcher}
                  onChange={(v) => {
                    writeKey(key, v);
                    setChoice((c) => ({ ...c, [t.key]: v }));
                  }}
                  align="end"
                  disabled={busy !== null || lock !== null}
                  className={`btn small ak-launch-menu${t.prompt ? " primary" : ""}`}
                  ariaLabel={`${t.label} launcher`}
                >
                  <span className="sel-label">{label}</span>
                  <span className="chev" aria-hidden="true" />
                </Select>
              </span>
            ) : null}
          </span>
        );
      })}
      {data.types
        .filter((t) => t.max_per_project !== null && (t.sessions_here?.length ?? 0) >= t.max_per_project)
        .map((t) => (
          <span
            className="ak-cap warn"
            key={`held-${t.key}`}
            data-held={t.key}
            title={`${t.label} is held by this session — stop it to launch another`}
          >
            {t.label}: {t.sessions_here!.join(", ")}
          </span>
        ))}
      <span
        className={`ak-cap ${cap.tone}`}
        title="registered agent sessions running on the host / the cap (concurrency.max_sessions)"
      >
        {cap.text}
      </span>
      {err && <span className="ak-cap bad">{err}</span>}
    </span>
  );
}
