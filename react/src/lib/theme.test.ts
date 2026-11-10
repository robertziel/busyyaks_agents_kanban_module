import { describe, expect, it } from "vitest";
import { akTokens, type TokenSource } from "./theme";

const decl = (props: Record<string, string>): TokenSource => ({ getPropertyValue: (n: string) => props[n] ?? "" });

describe("akTokens", () => {
  it("returns each known --ak-* token the element resolves, trimmed", () => {
    expect(akTokens(decl({ "--ak-ink": " #1c1c1e", "--ak-panel": "rgba(255, 255, 255, .86) " }))).toEqual([
      ["--ak-ink", "#1c1c1e"],
      ["--ak-panel", "rgba(255, 255, 255, .86)"],
    ]);
  });

  it("skips tokens that resolve to nothing and names it does not know", () => {
    expect(
      akTokens(decl({ "--ak-ink-dim": "  ", "--ak-unknown": "x", color: "red", "--ak-accent": "#0a84ff" })),
    ).toEqual([["--ak-accent", "#0a84ff"]]);
  });
});
