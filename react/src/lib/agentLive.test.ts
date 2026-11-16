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
