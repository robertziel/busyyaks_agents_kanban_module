import { describe, expect, it } from "vitest";
import type { ApprovalStep } from "../types";
import { approveLabel, approveTitle, operatorMoves, stepAt } from "./workflow";

const label = (k: string) =>
  ({ review: "Human review", merged: "Merged", await: "Awaiting merge", done: "Done" })[k] ?? k;
const step: ApprovalStep = { from: "review", to: "merged", name: "Approve", final: false, then: "await" };
const last: ApprovalStep = { from: "public", to: "await", name: "Approve", final: true, then: "done" };
const out = (name: string, to: string, by = "operator") => ({ name, to, to_label: label(to), by });
// the transitions out of a gate, in the declared order: the step, a way back, an agent's edge, the catch-all
const ts = [
  out("Approve", "merged"),
  out("Rework", "doing"),
  out("Hand over", "await", "agent"),
  out("Move", "merged"),
  out("Move", "doing"),
  out("Move", "done"),
];

describe("operatorMoves", () => {
  it("lists one entry per target the operator may reach, the first declared name winning", () =>
    expect(operatorMoves(ts).map((m) => [m.value, m.label])).toEqual([
      ["merged", "Approve → Merged"],
      ["doing", "Rework → doing"],
      ["done", "Move → Done"],
    ]));
  it("sends the transition's name and its column", () =>
    expect(operatorMoves(ts)[0]!.move).toEqual({ transition: "Approve", column: "merged" }));
  it("never hides the free edge into the step's target behind the CI-gated one", () => {
    const moves = operatorMoves(ts, step, true);
    expect(moves.map((m) => [m.value, m.label])).toEqual([
      ["merged", "Approve → Merged"],
      ["doing", "Rework → doing"],
      ["merged:free", "Move → Merged (CI not asked)"],
      ["done", "Move → Done"],
    ]);
    expect(moves[2]!.move).toEqual({ transition: "Move", column: "merged" });
  });
  it("lists the step's own transition too when the catch-all is declared first", () =>
    expect(operatorMoves([out("Move", "merged"), out("approve", "merged")], step, true).map((m) => m.label)).toEqual([
      "Move → Merged (CI not asked)",
      "approve → Merged",
    ]));
  it("has nothing to add without a green-CI gate or away from a step", () => {
    expect(operatorMoves(ts, step, false)).toEqual(operatorMoves(ts));
    expect(operatorMoves(ts, null, true)).toEqual(operatorMoves(ts));
  });
});

describe("stepAt", () => {
  const steps = [step, last];
  const gates = ["review", "public", "await"];
  it("is the step out of the card's gate", () =>
    expect(stepAt(steps, gates, "review", false)).toEqual({ step, inPlace: false }));
  it("is the step into the column of an approved card", () =>
    expect(stepAt(steps, gates, "merged", true)).toEqual({ step, inPlace: false }));
  it("is the step into a GATE for a card dragged there unapproved: approved in place", () =>
    expect(stepAt(steps, gates, "await", false)).toEqual({ step: last, inPlace: true }));
  it("is nothing for an unapproved card in a target no agent is held in, or off every step", () => {
    expect(stepAt(steps, gates, "merged", false)).toBeNull();
    expect(stepAt(steps, gates, "doing", true)).toBeNull();
  });
});

describe("the approve button", () => {
  it("names the step and where the card goes", () => {
    expect(approveLabel(step, label)).toBe("✓ Approve → Merged");
    expect(approveLabel(last, label)).toBe("✓ Approve to merge");
    expect(approveTitle(step, label)).toContain("the card moves Human review → Merged");
  });
  it("says the card stays when it is approved in place", () => {
    expect(approveLabel(step, label, true)).toBe("✓ Approve in Merged");
    expect(approveTitle(last, label, true)).toBe(
      "Approve for merge: the card stays in Awaiting merge; the owner agent is pinged to merge it and move the card to Done",
    );
  });
});
