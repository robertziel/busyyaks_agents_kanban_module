// The Launch bar's pure rules: why a type cannot start now (the cap it hits), the cap line, the launcher a viewer
// last picked per type. Every number comes from the engine's Api#launches — nothing is counted here.
import type { Concurrency, LaunchType } from "../types";

// null = may start; else the reason, worded like the engine's refusal (the server is the judge; this only greys the button).
export function launchBlocked(t: LaunchType, conc: Concurrency | null, sessionsError: string | null): string | null {
  if (sessionsError) return `sessions unknown: ${sessionsError}`;
  if (!conc) return "sessions unknown";
  if (conc.max_sessions !== null && conc.running >= conc.max_sessions)
    return `${conc.running}/${conc.max_sessions} sessions running — the host's cap`;
  if (t.max !== null && (t.running ?? 0) >= t.max)
    return `${t.running}/${t.max} ${t.key} sessions running — this type's cap`;
  if (t.max_per_project !== null && (t.running_here ?? 0) >= t.max_per_project)
    return `${t.running_here}/${t.max_per_project} ${t.key} already runs for this project${t.sessions_here?.length ? `: ${t.sessions_here.join(", ")}` : ""}`;
  return null;
}

// Why the launcher menu is locked: "follows the lead session g_r_teamlead (localclaude)" · null = free to pick.
export function launcherLock(t: LaunchType): string | null {
  return t.follows ? `follows the ${t.follows.type} session ${t.follows.session} (${t.follows.launcher})` : null;
}

// "2 / 6 running" · "sessions unknown: launcher down"
export function capLine(
  conc: Concurrency | null,
  sessionsError: string | null,
): { text: string; tone: "ok" | "warn" | "bad" } {
  if (sessionsError) return { text: `sessions unknown: ${sessionsError}`, tone: "bad" };
  if (!conc) return { text: "sessions unknown", tone: "bad" };
  if (conc.max_sessions === null) return { text: `${conc.running} running`, tone: "ok" };
  const full = conc.running >= conc.max_sessions;
  return { text: `${conc.running} / ${conc.max_sessions} running`, tone: full ? "warn" : "ok" };
}

// The launcher to start a type with: the followed session's while one runs (the engine refuses any other), else the
// viewer's remembered choice when the type still offers it, else the type's first.
export function pickLauncher(t: LaunchType, remembered: string | null): string {
  if (t.follows) return t.follows.launcher;
  if (remembered && t.launchers.some((l) => l.key === remembered)) return remembered;
  return t.launchers[0]?.key ?? "";
}
