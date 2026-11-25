import { describe, expect, it } from "vitest";
import {
  elapsed,
  elapsedShort,
  shortSession,
  liveAnnounce,
  liveDots,
  liveLine,
  liveMoods,
  liveParts,
  liveSessionOf,
  ownerStatus,
  workingPhase,
  workingWords,
} from "./agentLive";
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
    expect([null, 0, 59, 60, 2650, 3600 + 120 + 5].map(elapsedShort)).toEqual([null, "0s", "59s", "1m", "44m", "1h"]);
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

describe("workingPhase (the board's blue glow)", () => {
  const card = { owner_session: "lead" };
  it("glows on each phase a working owner session shows evidence of", () => {
    for (const phase of ["thinking", "tool", "writing", "subagents"] as const)
      expect(workingPhase(card, "working", { lead: live({ phase }) })).toBe(phase);
    expect(workingWords("tool")).toBe("running a tool");
    expect(workingWords("subagents")).toBe("waiting on its subagents"); // "its agent is waiting on its subagents"
  });
  it("does not glow without evidence, for an idle / blocked / unknown session, or another session working", () => {
    expect(workingPhase(card, "working", { lead: live({}) })).toBeNull(); // working, no phase read: no guess
    for (const state of ["idle", "finished", "blocked", "review", "unknown"])
      expect(workingPhase(card, "working", { lead: live({ state, phase: "thinking" }) })).toBeNull();
    expect(workingPhase(card, "working", { other: live({ phase: "thinking" }) })).toBeNull();
    expect(workingPhase({ owner_session: null }, "working", { lead: live({ phase: "thinking" }) })).toBeNull();
  });
  it("does not glow on a card in a done or cancelled column (finished work)", () => {
    expect(workingPhase(card, "review", { lead: live({ phase: "thinking" }) })).toBe("thinking");
    for (const t of ["done", "cancelled"] as const)
      expect(workingPhase(card, t, { lead: live({ phase: "thinking" }) })).toBeNull();
  });
  it("does not glow when the live read failed or has not answered (sessions null)", () => {
    expect(workingPhase(card, "working", null)).toBeNull();
  });
});

describe("liveParts", () => {
  it("gives the strip what it does and each counter apart; the line is the same words joined", () => {
    const l = live({ phase: "tool", tool: "Bash", elapsed_s: 65, tokens: "↓ 1.2k", subagents: 2 });
    const p = liveParts(l, 1);
    expect(p.what).toBe("running Bash");
    expect(p.meta).toEqual(["1m 5s", "↓ 1.2k tokens", "2 subagents"]);
    expect(p.text).toBe(liveLine(l, 1).text);
    expect(liveParts(live({ state: "blocked", elapsed_s: 9 }), 1).meta).toEqual([]); // no counter while it waits
    expect(liveParts(live({ phase: "thinking" }), 1).meta).toEqual([]); // nothing read, nothing shown
  });
});

describe("liveMoods", () => {
  it("the newest comment of each live session wears its mood; older ones and unread sessions stay still", () => {
    const card = { owner_session: "s1", assignee: "lead-s1" };
    const comments = [
      { id: 9, author: "lead-s1" },
      { id: 8, author: "s2" },
      { id: 7, author: "lead-s1" },
      { id: 6, author: "ann@example.com" },
      { id: 5, author: "s3" },
    ];
    const sessions = {
      s1: live({ phase: "thinking" }),
      s2: live({ state: "idle" }),
      s3: live({ state: "unknown" }),
    };
    expect([...liveMoods(comments, card, sessions)]).toEqual([
      [9, "thinking"],
      [8, "sleeping"],
    ]);
    expect(liveMoods(comments, card, undefined).size).toBe(0);
  });
});

describe("the small label's words", () => {
  const brief = (l: Partial<SessionLive>) => liveParts(live(l), 1).brief;

  it("brief: the phase in a word, a tool by its OWN name (never its server), never a counter", () => {
    expect(brief({ phase: "thinking", elapsed_s: 42 })).toBe("thinking");
    expect(brief({ phase: "writing", tokens: "↓ 1k" })).toBe("writing");
    expect(brief({ phase: "subagents", subagents: 3 })).toBe("subagents");
    expect(brief({ phase: "tool", tool: "busyyaks · kanban_card" })).toBe("kanban_card");
    expect(brief({ phase: "tool", tool: "busyyaks · kanban_comment", card: 1 })).toBe("kanban_comment");
    expect(brief({ phase: "tool", tool: "Bash" })).toBe("Bash");
    expect(brief({ phase: "tool" })).toBe("tool");
    expect(brief({})).toBe("working");
    expect(brief({ state: "blocked" })).toBe("needs you");
    expect(brief({ state: "idle" })).toBe("idle");
    expect(brief({ state: "finished" })).toBe("finished");
    expect(brief({ state: "unknown" })).toBe("unknown");
  });

  it("shortSession: the project's name in front is dropped — the slug or its last part, as a session spells it", () => {
    expect(shortSession("acme_storefront_teamlead", "acme/storefront")).toBe("teamlead");
    expect(shortSession("acme_storefront_worker_2", "acme/storefront")).toBe("worker_2");
    expect(shortSession("storefront-worker_3", "acme/storefront")).toBe("worker_3");
    expect(shortSession("my_app_worker", "my.app")).toBe("worker");
    // not this project's prefix, or nothing after it: the name as it is
    expect(shortSession("other_worker", "acme/storefront")).toBe("other_worker");
    expect(shortSession("storefront", "acme/storefront")).toBe("storefront");
    expect(shortSession("storefront_", "acme/storefront")).toBe("storefront_");
    expect(shortSession("stores_worker", "acme/storefront")).toBe("stores_worker");
  });

  it("shortSession: a name still too long is cut in the middle — its end is what differs", () => {
    const a = shortSession("storefront_worker-7-agent-faces-review_2", "acme/storefront");
    const b = shortSession("storefront_worker-7-agent-faces-review_3", "acme/storefront");
    expect(a).toBe("work…-review_2");
    expect(a).toHaveLength(14);
    expect(b).toBe("work…-review_3");
    expect(shortSession("exactly_14_chr", "x")).toBe("exactly_14_chr");
  });
});

describe("ownerStatus (the card face's tag beside the assignee)", () => {
  const card: Parameters<typeof ownerStatus>[0] = {
    owner_session: "w1",
    assignee: "worker-w1",
    gate_hold: null,
    blocked: null,
    needs_operator: false,
    waiting: false,
    waiting_for_worker: null,
  };
  const at = (l: Partial<SessionLive>, c: Partial<typeof card> = {}) =>
    ownerStatus({ ...card, ...c }, "working", { w1: live(l) });
  it("says what a working owner session does: its phase or tool, and for how long", () => {
    expect(at({ phase: "thinking", elapsed_s: 125 })).toEqual({
      text: "thinking · 2m",
      tone: "working",
      title: "w1: thinking… · 2m 5s",
    });
    expect(at({ phase: "tool", tool: "busyyaks · kanban_card" })?.text).toBe("kanban_card");
    expect(at({ phase: "tool", tool: "Bash", elapsed_s: 7 })?.text).toBe("Bash · 7s");
    expect(at({})?.text).toBe("working"); // working, no phase read: no guess
  });
  it("says needs you for a session stopped on a dialog", () => {
    expect(at({ state: "blocked" })).toMatchObject({ text: "needs you", tone: "blocked" });
  });
  it("names what an idle owner's card waits for, else idle", () => {
    expect(at({ state: "idle" })).toMatchObject({ text: "idle", tone: "idle" });
    expect(at({ state: "finished" })?.text).toBe("finished");
    expect(at({ state: "idle" }, { gate_hold: "PR #7: CI is still running" })).toEqual({
      text: "waiting for CI",
      tone: "wait",
      title: "w1 is idle — PR #7: CI is still running",
    });
    expect(at({ state: "idle" }, { blocked: { reason: "upstream", url: null, by: null, at: null } })?.text).toBe(
      "blocked externally",
    );
    expect(at({ state: "idle" }, { waiting: true })?.text).toBe("waiting for you");
    expect(at({ state: "idle" }, { needs_operator: true, gate_hold: "x" })).toMatchObject({
      text: "waiting for your answer",
      tone: "blocked", // red: it needs you, as a dialog does
    });
    // a working session's own phase wins over what the card waits for
    expect(at({ phase: "thinking" }, { gate_hold: "x" })?.text).toBe("thinking");
  });
  it("says unknown / not running as the host read it, never a guess", () => {
    expect(at({ state: "unknown" })).toMatchObject({ text: "unknown", tone: "unknown" });
    expect(ownerStatus(card, "working", { other: live({}) })).toMatchObject({ text: "not running", tone: "unknown" });
  });
  it("shows no tag without an owner or assignee, for a card waiting for a worker, a finished card, or no live read", () => {
    const l = { w1: live({ phase: "thinking" }) };
    expect(ownerStatus({ ...card, owner_session: null }, "working", l)).toBeNull();
    expect(ownerStatus({ ...card, assignee: null }, "working", l)).toBeNull();
    expect(ownerStatus({ ...card, waiting_for_worker: { since: null, stale: null } }, "working", l)).toBeNull();
    for (const t of ["done", "cancelled"] as const) expect(ownerStatus(card, t, l)).toBeNull();
    expect(ownerStatus(card, "working", null)).toBeNull();
  });
});
