// The installed picomatch is the vendored, patched copy (react/vendor/picomatch/VENDOR.md) — a
// single-branch repeated extglob compiles without a nested quantifier (GHSA-fc5q-39xc-vjpf) and still matches.
import { createRequire } from "node:module";
import { describe, expect, it } from "vitest";

interface Picomatch {
  makeRe(pattern: string): RegExp;
  isMatch(input: string, pattern: string): boolean;
}

const require = createRequire(import.meta.url);
const picomatch = require("picomatch") as Picomatch;
const pkg = require("picomatch/package.json") as { version: string };

describe("vendored picomatch", () => {
  it("is the patched copy", () => {
    expect(pkg.version).toBe("4.0.8-busyyaks.0");
  });

  it.each(["+(*)", "+(*a)", "*(*a)", "+(a*b)", "*(*.js)"])("%s compiles without a nested quantifier", (pattern) => {
    expect(picomatch.makeRe(pattern).source).not.toMatch(/\)[+*]/);
  });

  it("keeps the extglob's meaning", () => {
    expect(picomatch.isMatch("xxa", "+(*a)")).toBe(true);
    expect(picomatch.isMatch("xab", "+(*a)")).toBe(false);
    expect(picomatch.isMatch("", "*(*a)")).toBe(false);
    expect(picomatch.isMatch("a.js", "*(*.js)")).toBe(true);
    expect(picomatch.isMatch("abab", "+(a*b)")).toBe(true);
    // short on purpose: a long input would make a reverted fix hang the run instead of failing it (the
    // nested-quantifier assertions above are the regression guard)
    expect(picomatch.isMatch("a".repeat(8) + "b", "+(*a)")).toBe(false);
  });
});
