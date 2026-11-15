import { describe, expect, it } from "vitest";
import { elapsed, liveAnnounce, liveDots, liveLine, liveSessionOf } from "./agentLive";
import { pollDelay } from "./live";
import type { SessionLive } from "../types";

const live = (l: Partial<SessionLive>): SessionLive => ({
  state: "working",
  phase: null,
  elapsed_s: null,
  tokens: null,
  tool: null,
  card: null,
  subagents: null,
  ...l,
});

describe("liveLine", () => {
  it("words each phase with what the host read", () => {
    expect(liveLine(live({ phase: "thinking", elapsed_s: 42 }), 1)).toEqual({
      text: "thinking… · 42s",
      tone: "working",
      running: true,
    });
    expect(liveLine(live({ phase: "writing", elapsed_s: 65, tokens: "↓ 1.2k" }), 1).text).toBe(
      "writing… · 1m 5s · ↓ 1.2k tokens",
    );
    expect(liveLine(live({ phase: "tool", tool: "Bash", subagents: 2 }), 1).text).toBe("running Bash · 2 subagents");
    expect(liveLine(live({ phase: "tool" }), 1).text).toBe("running a tool");
    expect(liveLine(live({}), 1).text).toBe("working");
    expect(liveLine(live({ phase: "subagents", subagents: 1 }), 1).text).toBe("waiting for its subagents · 1 subagent");
  });

  it("names the card a comment tool writes on", () => {
    const t = (card: number | null) =>
      liveLine(live({ phase: "tool", tool: "busyyaks · kanban_comment", card }), 459).text;
    expect(t(459)).toBe("writing a comment on this card");
    expect(t(12)).toBe("writing a comment on card 12");
    expect(t(null)).toBe("writing a comment");
    expect(liveLine(live({ phase: "tool", tool: "kanban_card", card: 459 }), 459).text).toBe("running kanban_card");
  });

  it("blocked, idle and unknown are not a running turn", () => {
    expect(liveLine(live({ state: "blocked" }), 1)).toEqual({
      text: "waiting for you (a dialog or question)",
      tone: "blocked",
      running: true,
    });
    expect(liveLine(live({ state: "idle" }), 1)).toEqual({ text: "idle", tone: "idle", running: false });
    expect(liveLine(live({ state: "unknown" }), 1)).toEqual({ text: "state unknown", tone: "unknown", running: false });
    expect(liveLine(live({ state: "review" }), 1)).toEqual({ text: "review", tone: "unknown", running: false });
  });

  it("formats the turn's time", () => {
    expect([elapsed(null), elapsed(0), elapsed(59), elapsed(3600 + 120 + 5)]).toEqual([null, "0s", "59s", "1h 2m"]);
  });
});

describe("liveDots", () => {
  const card = { owner_session: "acme_lead", assignee: "lead-acme" };
  const sessions = { acme_lead: live({ phase: "thinking" }), acme_worker: live({ state: "idle" }) };
  it("resolves an author to its session like the agent links", () => {
    expect(liveSessionOf("acme_lead", card, sessions)).toBe("acme_lead");
    expect(liveSessionOf("lead-acme", card, sessions)).toBe("acme_lead");
    expect(liveSessionOf("operator", card, sessions)).toBeNull();
    expect(liveSessionOf("acme_lead", card, undefined)).toBeNull();
  });
  it("marks only the newest comment of each running session", () => {
    const comments = [
      { id: 9, author: "operator" },
      { id: 8, author: "lead-acme" },
      { id: 7, author: "acme_lead" },
      { id: 6, author: "acme_worker" },
    ];
    const dots = liveDots(comments, card, sessions, 1);
    expect([...dots.keys()]).toEqual([8]);
    expect(dots.get(8)).toMatchObject({ session: "acme_lead", text: "thinking…", tone: "working" });
  });
});

describe("announcing and polling", () => {
  it("announces the state, never the ticking counter", () => {
    const a = (l: Partial<SessionLive>) => liveAnnounce(liveLine(live(l), 1));
    expect([a({ phase: "thinking", elapsed_s: 4 }), a({ phase: "thinking", elapsed_s: 7 })]).toEqual([
      "is working",
      "is working",
    ]);
    expect([a({ state: "blocked" }), a({ state: "idle" }), a({ state: "unknown" })]).toEqual([
      "is waiting for you",
      "is idle",
      "state unknown",
    ]);
  });
  it("backs off after failed polls, capped", () => {
    expect([0, 1, 2, 3, 4, 9].map((n) => pollDelay(3000, n))).toEqual([3000, 6000, 12000, 24000, 30000, 30000]);
  });
});
