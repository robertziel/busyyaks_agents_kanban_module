import { describe, expect, it } from "vitest";
import {
  faceType,
  globMatch,
  faceLabel,
  moodOf,
  MOODS,
  MOOD_WORDS,
  typeBackdrop,
  typeHue,
  typeToken,
  wearsFace,
  agentFace,
  EYES,
} from "./face";

describe("agentFace", () => {
  it("draws the same face for the same name, every time", () => {
    expect(agentFace("worker-7")).toEqual(agentFace("worker-7"));
    const faces = new Set(["a", "b", "c", "d", "e", "f", "g", "h"].map((n) => agentFace(n).eyes));
    expect(faces).toEqual(new Set(EYES)); // names differ → both shapes are drawn
  });

  it("is two eyes of one of the shapes, nothing else", () => {
    for (const n of ["a", "b", "c", "d"]) expect(Object.keys(agentFace(n))).toEqual(["eyes"]);
  });
});

describe("wearsFace", () => {
  it("a person (an email address) keeps the initials; any other identity wears a face", () => {
    expect(wearsFace("ann@example.com")).toBe(false);
    expect(wearsFace("lead-s1")).toBe(true);
    expect(wearsFace("s1")).toBe(true);
  });
});

describe("the backdrop", () => {
  it("is the TYPE's colour: stable, the same for every agent of the type, different between types", () => {
    expect(typeHue("alpha")).toBe(typeHue("alpha"));
    const hues = ["alpha", "beta", "gamma", "delta"].map(typeHue);
    expect(new Set(hues).size).toBe(4);
    for (const h of hues) {
      expect(h).toBeGreaterThanOrEqual(0);
      expect(h).toBeLessThan(360);
    }
    expect(typeBackdrop("alpha")).toBe(`var(--ak-face-type-alpha, hsl(${typeHue("alpha")} 62% 58%))`);
  });

  it("no type → no colour of its own (the stylesheet's neutral one)", () => {
    expect(typeBackdrop(null)).toBeUndefined();
    expect(typeBackdrop(undefined)).toBeUndefined();
    expect(typeBackdrop("")).toBeUndefined();
  });

  it("a type key becomes a valid custom-property name", () => {
    expect(typeToken("code review/2")).toBe("--ak-face-type-code-review-2");
  });
});

describe("moodOf", () => {
  const m = (state: string, phase: string | null = null) => moodOf({ state, phase });
  it("a working session wears its phase; none read = working", () => {
    expect(m("working", "thinking")).toBe("thinking");
    expect(m("working", "tool")).toBe("tool");
    expect(m("working", "writing")).toBe("writing");
    expect(m("working", "subagents")).toBe("subagents");
    expect(m("working")).toBe("working");
    expect(m("working", "a phase this version does not know")).toBe("working");
  });

  it("blocked waits for you, idle sleeps, finished is awake, anything else is a still face", () => {
    expect(m("blocked", "thinking")).toBe("blocked");
    expect(m("idle")).toBe("sleeping");
    expect(m("finished")).toBe("idle");
    expect(m("unknown")).toBeNull();
    expect(m("review")).toBeNull();
  });

  it("every mood has its words", () => {
    for (const mood of MOODS) expect(MOOD_WORDS[mood]).toBeTruthy();
    expect(faceLabel("lead-s1", "lead", "thinking")).toBe("lead-s1 · lead agent · thinking");
    expect(faceLabel("lead-s1", null, null)).toBe("lead-s1");
  });
});

describe("faceType", () => {
  const roles = { reviewer: ["reviewer-*", "critic-?"], qa: ["qa-*", "reviewer-qa-*"] };

  it("a registered agent wears its type — whatever role its name looks like", () => {
    expect(faceType("lead-s1", { "lead-s1": "lead" }, roles)).toBe("lead");
    expect(faceType("reviewer-9", { "reviewer-9": "worker" }, roles)).toBe("worker");
  });

  it("an unregistered name wears the first role, in the config's order, one of whose globs matches", () => {
    expect(faceType("reviewer-x", { "lead-s1": "lead" }, roles)).toBe("reviewer");
    expect(faceType("qa-7", {}, roles)).toBe("qa");
    expect(faceType("reviewer-qa-1", undefined, roles)).toBe("reviewer"); // both match: the first wins
    expect(faceType("critic-a", null, roles)).toBe("reviewer");
  });

  it("no match, or no roles on this host (null) → no type: the neutral disc", () => {
    expect(faceType("stranger", {}, roles)).toBeNull();
    expect(faceType("critic-ab", {}, roles)).toBeNull();
    expect(faceType("reviewer-x", {}, null)).toBeNull();
    expect(faceType("reviewer-x", undefined, undefined)).toBeNull();
    expect(faceType("lead-s1", { "lead-s1": "lead" }, null)).toBe("lead");
  });

  it("a glob: * any run (none too), ? exactly one character, the rest literal, the whole name", () => {
    expect(globMatch("qa-*", "qa-")).toBe(true);
    expect(globMatch("qa-*", "qa-1-b")).toBe(true);
    expect(globMatch("qa-*", "x-qa-1")).toBe(false);
    expect(globMatch("*-qa", "x-qa")).toBe(true);
    expect(globMatch("qa-?", "qa-1")).toBe(true);
    expect(globMatch("qa-?", "qa-")).toBe(false);
    expect(globMatch("qa-?", "qa-12")).toBe(false);
    expect(globMatch("a.b", "a.b")).toBe(true);
    expect(globMatch("a.b", "axb")).toBe(false);
    expect(globMatch("a+(b)[c]{d}|$^\\", "a+(b)[c]{d}|$^\\")).toBe(true);
    expect(globMatch("qa", "QA")).toBe(false);
  });
});
