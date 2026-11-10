import { describe, expect, it } from "vitest";
import { noListener, pingLine } from "./listen";
import type { Ping } from "../types";

const LISTENED = ["todo", "doing", "qa", "human_check"];
const ping = (p: Partial<Ping>): Ping => ({
  at: "2026-11-02T16:00:00+01:00",
  done_at: null,
  session: "acme_shop",
  reason: "comment",
  status: "pending",
  error: null,
  attempts: 1,
  ...p,
});

describe("noListener", () => {
  it("flags an assignee with no owner session in a working column", () => {
    expect(noListener({ assignee: "claude-shop-lead", owner_session: null, column: "doing" }, LISTENED)).toBe(true);
    expect(noListener({ assignee: "claude-shop-lead", owner_session: null, column: "human_check" }, LISTENED)).toBe(
      true,
    );
  });
  it("is quiet with an owner, without an assignee, or outside the working columns", () => {
    expect(noListener({ assignee: "a", owner_session: "s", column: "doing" }, LISTENED)).toBe(false);
    expect(noListener({ assignee: null, owner_session: null, column: "doing" }, LISTENED)).toBe(false);
    expect(noListener({ assignee: "a", owner_session: null, column: "backlog" }, LISTENED)).toBe(false);
    expect(noListener({ assignee: "a", owner_session: null, column: "merged" }, LISTENED)).toBe(false);
  });
});

describe("pingLine", () => {
  it("says sent", () => {
    expect(pingLine(ping({ status: "sent" }))).toEqual({ tone: "ok", text: "sent to acme_shop", hint: null });
  });
  it("says failed with the reason", () => {
    expect(pingLine(ping({ status: "failed", error: "owner session x is gone" })).text).toBe(
      "failed · owner session x is gone",
    );
    expect(pingLine(ping({ status: "failed" })).text).toBe("failed · no reason recorded");
  });
  it("explains a pending ping blocked on a dialog", () => {
    const l = pingLine(ping({ error: "a question is on its screen", attempts: 4 }));
    expect(l.tone).toBe("warn");
    expect(l.text).toBe("pending · a question is on its screen · 4 tries");
    expect(l.hint).toMatch(/blocked on a dialog/);
  });
  it("says a fresh pending ping was not tried yet", () => {
    expect(pingLine(ping({ attempts: 0 }))).toEqual({ tone: "warn", text: "pending · not tried yet", hint: null });
  });
});
