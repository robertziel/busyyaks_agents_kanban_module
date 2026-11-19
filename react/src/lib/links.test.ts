import { describe, expect, it } from "vitest";
import type { CardLink } from "../types";
import {
  hasDetail,
  hasTags,
  linkTitle,
  placePopover,
  toneClass,
  groupLinks,
  prLabelParts,
  rowTags,
  unassignReason,
} from "./links";

const box = (left: number, top: number, w: number, h: number) => ({
  left,
  top,
  width: w,
  height: h,
  right: left + w,
  bottom: top + h,
});

describe("card links", () => {
  it("a plain link keeps the url as its native title; a link with detail leaves the tooltip to the popover", () => {
    const plain: CardLink = { kind: "repo", label: "o/r", url: "https://x/o/r" };
    const rich: CardLink = { ...plain, tags: [{ text: "a", tone: "ok" }], detail: [{ label: "Repo", value: "o/r" }] };
    expect(hasTags(plain)).toBe(false);
    expect(hasDetail(plain)).toBe(false);
    expect(linkTitle(plain)).toBe("https://x/o/r");
    expect(hasTags(rich)).toBe(true);
    expect(hasDetail(rich)).toBe(true);
    expect(linkTitle(rich)).toBeUndefined();
    expect(hasDetail({ ...plain, detail: [] })).toBe(false);
  });

  it("every tone has a class; an unknown tone reads muted", () => {
    expect(["ok", "warn", "bad", "done", "muted", "info"].map(toneClass)).toEqual([
      "t-ok",
      "t-warn",
      "t-bad",
      "t-done",
      "t-muted",
      "t-info",
    ]);
    expect(toneClass("purple")).toBe("t-muted");
  });

  it("the popover sits left of the row when there is room, top-aligned and kept inside the viewport", () => {
    const view = { width: 1200, height: 800 };
    expect(placePopover(box(900, 300, 220, 28), { width: 280, height: 90 }, view)).toEqual({
      side: "left",
      left: 612,
      top: 300,
    });
    // near the bottom: lifted so it ends 8px above the edge
    expect(placePopover(box(900, 760, 220, 28), { width: 280, height: 90 }, view)).toEqual({
      side: "left",
      left: 612,
      top: 702,
    });
  });

  it("on a phone it drops below the row, clamped to the screen; above when the row is at the bottom", () => {
    const view = { width: 390, height: 700 };
    expect(placePopover(box(140, 200, 240, 28), { width: 300, height: 90 }, view)).toEqual({
      side: "below",
      left: 82,
      top: 232,
    });
    expect(placePopover(box(140, 650, 240, 28), { width: 300, height: 90 }, view)).toEqual({
      side: "above",
      left: 82,
      top: 556,
    });
    // wider than the screen minus the gutters: pinned to the left gutter
    expect(placePopover(box(140, 200, 240, 28), { width: 500, height: 90 }, view).left).toBe(8);
  });
});

describe("groupLinks", () => {
  const l = (kind: string, n: number) => ({ kind, label: `${kind}${n}`, url: `https://x/${kind}/${n}` }) as CardLink;
  it("sections in the fixed order, only those with links; repo / site / url share one; an unknown kind gets its own at the end", () => {
    const gs = groupLinks([
      l("commit", 1),
      l("url", 1),
      l("pr", 1),
      l("repo", 1),
      l("wiki", 1),
      l("pr", 2),
      l("branch", 1),
    ]);
    expect(gs.map((g) => [g.label, g.links.map((x) => x.label)])).toEqual([
      ["Pull requests", ["pr1", "pr2"]],
      ["Branches", ["branch1"]],
      ["Commits", ["commit1"]],
      ["Repo & web", ["url1", "repo1"]],
      ["wiki", ["wiki1"]],
    ]);
  });
  it("a link's group is its own sub-section of its family's, in first-seen order; only PR sections never fold", () => {
    const g = (n: number, group?: string): CardLink => ({ ...l("pr", n), ...(group ? { group } : {}) });
    const gs = groupLinks([g(1, "local"), l("commit", 1), g(2, "public"), g(3, "local"), g(4), g(5, " ")]);
    expect(gs.map((x) => [x.key, x.label, x.links.map((y) => y.label), x.fold])).toEqual([
      ["pr:local", "PRs · local", ["pr1", "pr3"], false],
      ["pr:public", "PRs · public", ["pr2"], false],
      ["pr", "Pull requests", ["pr4", "pr5"], false],
      ["commit", "Commits", ["commit1"], true],
    ]);
  });
});

describe("a grouped PR row", () => {
  const pr = (o: Partial<CardLink>): CardLink => ({ kind: "pr", label: "#5 r_local", url: "https://x/pull/5", ...o });
  const t = (text: string, tone: "info" | "ok" | "muted" = "ok") => ({ text, tone });

  it("rowTags: the tag that repeats the section's name is left out — only in a grouped rail, never the only tag", () => {
    const l = pr({ group: "local", tags: [t("Local ", "info"), t("open")] });
    expect(rowTags(l, true).map((x) => x.text)).toEqual(["open"]);
    expect(rowTags(l, false).map((x) => x.text)).toEqual(["Local ", "open"]); // a bare row has no header to say it
    expect(rowTags(pr({ group: "removed", tags: [t("removed", "muted")] }), true).map((x) => x.text)).toEqual([
      "removed",
    ]);
    expect(rowTags(pr({ tags: [t("local", "info"), t("open")] }), true).map((x) => x.text)).toEqual(["local", "open"]);
    expect(rowTags(pr({ group: "local" }), true)).toEqual([]);
  });

  it("prLabelParts: a PR's '#N repo' → the number + the repo in pieces that end at _ - . /; anything else is whole", () => {
    expect(prLabelParts(pr({ label: "#91 busyyaks_agents-kanban.module" }))).toEqual({
      ref: "#91",
      name: ["busyyaks_", "agents-", "kanban.", "module"],
    });
    expect(prLabelParts(pr({ label: "#5 repo" }))).toEqual({ ref: "#5", name: ["repo"] });
    expect(prLabelParts(pr({ label: "#5" }))).toBeNull();
    expect(prLabelParts(pr({ label: "config" }))).toBeNull();
    expect(prLabelParts({ kind: "commit", label: "#5 not a PR", url: "u" })).toBeNull();
  });

  it("unassignReason: the reason sent is the one typed, trimmed; blank = none", () => {
    expect(unassignReason("  opened for card 12 ")).toBe("opened for card 12");
    expect(unassignReason("   ")).toBe("");
  });
});
