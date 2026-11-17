import { describe, expect, it } from "vitest";
import {
  activityAnchor,
  activityAnchorId,
  cardFaceClass,
  carriedOnText,
  jumpNeedsDetails,
  splitCard,
  TITLE_MAX,
} from "./card";

describe("splitCard", () => {
  it("keeps a short line as the title", () => {
    expect(splitCard("  Fix radar tiles ")).toEqual({
      title: "Fix radar tiles",
      description: "",
    });
  });
  it("uses the first line as title and the rest as description", () => {
    expect(splitCard("Deploy shop\nthat deploys to shop.example.com (shop branch)\nthen smoke")).toEqual({
      title: "Deploy shop",
      description: "that deploys to shop.example.com (shop branch)\nthen smoke",
    });
  });
  it("cuts a long single line at its first sentence and keeps everything in the description", () => {
    const t =
      "Set up the Jenkins pipeline. It runs on every push to the shop branch that deploys to shop.example.com and posts the status back to GitHub so reviewers see it.";
    const r = splitCard(t);
    expect(r.title).toBe("Set up the Jenkins pipeline.");
    expect(r.description).toBe(t);
  });
  it("cuts a long line without sentences at a word boundary under the server limit", () => {
    const t = "word ".repeat(80).trim();
    const r = splitCard(t);
    expect(r.title.endsWith("…")).toBe(true);
    expect(r.title.length).toBeLessThanOrEqual(TITLE_MAX);
    expect(r.description).toBe(t);
  });
});

describe("activity anchors", () => {
  it("reads only #a-<id> hrefs", () => {
    expect(activityAnchor("#a-148")).toBe(148);
    expect(activityAnchor("#a-x")).toBeNull();
    expect(activityAnchor("/projects/o/r?tab=board&card=10")).toBeNull();
    expect(activityAnchor("https://github.com/o/r/pull/148")).toBeNull();
    expect(activityAnchor(null)).toBeNull();
    expect(activityAnchorId(148)).toBe("a-148");
  });
  it("switches details on only for a hidden event on this card", () => {
    const act = [
      { id: 148, kind: "comment" },
      { id: 117, kind: "move" },
      { id: 120, kind: "handoff" },
    ];
    expect(jumpNeedsDetails(act, 120, false)).toBe(true);
    expect(jumpNeedsDetails(act, 148, false)).toBe(false);
    expect(jumpNeedsDetails(act, 117, false)).toBe(true);
    expect(jumpNeedsDetails(act, 117, true)).toBe(false);
    expect(jumpNeedsDetails(act, 999, false)).toBeNull();
  });
});

describe("cardFaceClass", () => {
  const idle = { dragging: false, busy: false, working: false };
  it("highlights a card only when the server says it waits for the operator", () => {
    expect(cardFaceClass({ id: 1, waiting: true }, idle)).toBe("kb-card needs-you");
    expect(cardFaceClass({ id: 1, waiting: false }, idle)).toBe("kb-card");
  });
  it("throws on an undecorated card instead of reading it as not waiting", () => {
    expect(() => cardFaceClass({ id: 7, waiting: null }, idle)).toThrow("card 7: no waiting on its face");
    expect(() => cardFaceClass({ id: 8 }, idle)).toThrow("card 8: no waiting on its face");
  });
  it("keeps the other states", () => {
    expect(cardFaceClass({ id: 1, waiting: true, cover: "red" }, { dragging: true, busy: true, working: false })).toBe(
      "kb-card dragging busy has-cover needs-you",
    );
  });
  it("glows a card whose owner session works, unless it needs the operator (needs-you wins)", () => {
    const working = { ...idle, working: true };
    expect(cardFaceClass({ id: 1, waiting: false }, working)).toBe("kb-card agent-working");
    expect(cardFaceClass({ id: 1, waiting: true }, working)).toBe("kb-card needs-you");
    expect(cardFaceClass({ id: 1, waiting: false }, idle)).toBe("kb-card");
  });
});

// an approved gate card its agent carries on — never "needs you", its badge names who and where next
describe("carriedOnText", () => {
  it("names the owner and the merge on a final step", () => {
    expect(
      carriedOnText({ id: 1, owner_session: "shop_lead" }, { next_column: "done", next_label: "Done", final: true }),
    ).toBe("approved · shop_lead merging");
  });
  it("names the next column otherwise", () => {
    expect(
      carriedOnText(
        { id: 1, owner_session: "shop_lead" },
        { next_column: "deploy", next_label: "Deploy check", final: false },
      ),
    ).toBe("approved · shop_lead → Deploy check");
  });
  it("throws on a card nobody owns: the server never carries one on", () => {
    expect(() =>
      carriedOnText({ id: 7, owner_session: null }, { next_column: "done", next_label: "Done", final: true }),
    ).toThrow(/: carried_on without an owner session$/);
  });
});
