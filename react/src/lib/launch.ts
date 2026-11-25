// The Launch bar's pure rules: why a type cannot start now (the cap it hits), the cap line, the launcher a viewer
// last picked per type. Every number comes from the engine's Api#launches — nothing is counted here.
import type { BoardLead, Concurrency, LaunchFailure, LaunchType } from "../types";
import { isoAt } from "./format";

// null = may start; else the reason, worded like the engine's refusal (the server is the judge; this only greys the button).
export function launchBlocked(t: LaunchType, conc: Concurrency | null, sessionsError: string | null): string | null {
  if (sessionsError) return `sessions unknown: ${sessionsError}`;
  if (!conc) return "sessions unknown";
  if (t.under && !t.follows) return `no ${t.under} runs for this board — launch the ${t.under} first`;
  if (conc.max_sessions !== null && conc.running >= conc.max_sessions)
    return `${conc.running}/${conc.max_sessions} sessions running — the host's cap`;
  if (t.max !== null && (t.running ?? 0) >= t.max)
    return `${t.running}/${t.max} ${t.key} sessions running — this type's cap`;
  if (t.max_per_project !== null && (t.running_here ?? 0) >= t.max_per_project)
    return `${t.running_here}/${t.max_per_project} ${t.key} already runs for this project${t.sessions_here?.length ? `: ${t.sessions_here.join(", ")}` : ""}`;
  return null;
}

// Why the launcher menu is locked: "runs under the lead session g_r_teamlead (localclaude)" · null = free to pick.
export function launcherLock(t: LaunchType): string | null {
  return t.follows ? `runs under the ${t.follows.type} session ${t.follows.session} (${t.follows.launcher})` : null;
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

// The launcher to start a type with: its lead's while one runs (the engine refuses any other), else the
// viewer's remembered choice when the type still offers it, else the type's first.
export function pickLauncher(t: LaunchType, remembered: string | null): string {
  if (t.follows) return t.follows.launcher;
  if (remembered && t.launchers.some((l) => l.key === remembered)) return remembered;
  return t.launchers[0]?.key ?? "";
}

// The failed starts this viewer has not dismissed: every row whose id is not in the dismissed set (the engine orders
// by when the start ended, so a set — not a highest id — keeps a lower id that ended later), newest first as sent.
export function unseenFailures(failures: LaunchFailure[], dismissed: ReadonlySet<number>): LaunchFailure[] {
  return failures.filter((f) => !dismissed.has(f.id));
}

// The types the Launch bar offers: every one but those with launchable: false (only their lead's kanban_spawn starts
// one — a worker for a card), in the engine's order.
export const offered = (types: LaunchType[]): LaunchType[] => types.filter((t) => t.launchable);

// A type's button text: its launch_label ("Launch team lead"), else its label.
export const buttonText = (t: { label: string; launch_label?: string | null }): string => t.launch_label ?? t.label;

// The board banner's "· <session> ended …" part: a session registered under an earlier session_name (old_name = the
// name a launch gets now) is said as old, never shown as if it were today's lead.
export function leadEnded(ended: NonNullable<BoardLead["ended"]>): string {
  const name = ended.old_name ? `${ended.session} (old name · a launch now names it ${ended.old_name})` : ended.session;
  return `${name} ended ${isoAt(ended.at)}${ended.reason ? ` (${ended.reason})` : ""}`;
}
