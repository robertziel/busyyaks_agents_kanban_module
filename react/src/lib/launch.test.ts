import { describe, expect, it } from "vitest";
import type { Concurrency, LaunchType } from "../types";
import { buttonText, capLine, launchBlocked, launcherLock, leadEnded, offered, pickLauncher } from "./launch";

const type = (o: Partial<LaunchType> = {}): LaunchType => ({
  key: "lead",
  label: "Launch",
  launchers: [
    { key: "a", label: "A" },
    { key: "b", label: "B" },
  ],
  model: null,
  takes: ["working"],
  max: null,
  max_per_project: 1,
  prompt: true,
  running: 0,
  running_here: 0,
  under: null,
  launchable: true,
  launch_label: null,
  ...o,
});
const conc = (running: number, max = 6): Concurrency => ({
  max_sessions: max,
  running,
  free: Math.max(max - running, 0),
  sessions: [],
  types: {},
});

describe("launchBlocked", () => {
  it("is free under every cap", () => expect(launchBlocked(type(), conc(2), null)).toBeNull());
  it("names the host cap first", () =>
    expect(launchBlocked(type({ running: 1, running_here: 1 }), conc(6), null)).toBe(
      "6/6 sessions running — the host's cap",
    ));
  it("then the type cap", () =>
    expect(launchBlocked(type({ max: 2, running: 2 }), conc(3), null)).toBe(
      "2/2 lead sessions running — this type's cap",
    ));
  it("names the session holding the per-project cap", () =>
    expect(
      launchBlocked(type({ running: 1, running_here: 1, sessions_here: ["demo_app_teamlead"] }), conc(1), null),
    ).toBe("1/1 lead already runs for this project: demo_app_teamlead"));
  it("then the per-project cap", () =>
    expect(launchBlocked(type({ running: 1, running_here: 1 }), conc(1), null)).toBe(
      "1/1 lead already runs for this project",
    ));
  it("never guesses when the sessions are unknown", () => {
    expect(launchBlocked(type(), null, null)).toBe("sessions unknown");
    expect(launchBlocked(type(), conc(0), "launcher not reachable")).toBe("sessions unknown: launcher not reachable");
  });
});

describe("no host cap (max_sessions null)", () => {
  const open = (running: number): Concurrency => ({ max_sessions: null, running, free: null, sessions: [], types: {} });
  it("never blocks on the host", () => expect(launchBlocked(type(), open(50), null)).toBeNull());
  it("shows only the running count", () => expect(capLine(open(7), null)).toEqual({ text: "7 running", tone: "ok" }));
});

describe("capLine", () => {
  it("shows running / max", () => expect(capLine(conc(2), null)).toEqual({ text: "2 / 6 running", tone: "ok" }));
  it("warns when full", () => expect(capLine(conc(6), null)).toEqual({ text: "6 / 6 running", tone: "warn" }));
  it("says why it does not know", () =>
    expect(capLine(null, "down")).toEqual({ text: "sessions unknown: down", tone: "bad" }));
});

describe("pickLauncher", () => {
  it("keeps a remembered launcher the type still offers, else the first", () => {
    expect(pickLauncher(type(), "b")).toBe("b");
    expect(pickLauncher(type(), "zzz")).toBe("a");
    expect(pickLauncher(type(), null)).toBe("a");
    expect(pickLauncher(type({ launchers: [] }), null)).toBe("");
  });
});

describe("under a lead (lead-first boards)", () => {
  const follows = { type: "lead", session: "g_r_teamlead", launcher: "b" };
  it("the lead's launcher wins over a remembered one", () =>
    expect(pickLauncher(type({ key: "team", under: "lead", follows }), "a")).toBe("b"));
  it("locks the menu with the lead it runs under", () => {
    expect(launcherLock(type({ follows }))).toBe("runs under the lead session g_r_teamlead (b)");
    expect(launcherLock(type())).toBeNull();
  });
  it("greys a type under a lead while no lead runs, and frees it once one does", () => {
    expect(launchBlocked(type({ key: "team", under: "lead", follows: null }), conc(0), null)).toBe(
      "no lead runs for this board — launch the lead first",
    );
    expect(launchBlocked(type({ key: "team", under: "lead", follows }), conc(1), null)).toBeNull();
  });
  it("sessions unknown beats the lead rule (never a guess)", () =>
    expect(launchBlocked(type({ under: "lead" }), null, null)).toBe("sessions unknown"));
});

describe("offered", () => {
  it("leaves out a type with launchable: false (only its lead's kanban_spawn starts one), keeps the order", () => {
    const ts = [
      type({ key: "lead" }),
      type({ key: "worker", under: "lead", launchable: false }),
      type({ key: "plain" }),
    ];
    expect(offered(ts).map((t) => t.key)).toEqual(["lead", "plain"]);
  });
});

describe("buttonText", () => {
  it("is the launch label when the type has one, else the label", () => {
    expect(buttonText(type({ label: "Team lead", launch_label: "Launch team lead" }))).toBe("Launch team lead");
    expect(buttonText(type({ label: "Sub team" }))).toBe("Sub team");
    expect(buttonText({ label: "Team lead" })).toBe("Team lead");
  });
});

describe("leadEnded", () => {
  const at = "2026-11-25T10:00:00Z";
  it("marks a session of an old name and names today's", () => {
    const t = leadEnded({ session: "tl_g_r", reason: "gone", at, old_name: "by_g_r_teamlead" });
    expect(t).toMatch(/^tl_g_r \(old name · a launch now names it by_g_r_teamlead\) ended .* \(gone\)$/);
  });
  it("says today's name as it is", () => {
    expect(leadEnded({ session: "by_g_r_teamlead", reason: null, at, old_name: null })).toMatch(
      /^by_g_r_teamlead ended /,
    );
    expect(leadEnded({ session: "by_g_r_teamlead", reason: null, at })).not.toMatch(/old name/);
  });
});
