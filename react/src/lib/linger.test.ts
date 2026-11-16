import { describe, expect, it } from "vitest";
import { linger } from "./linger";

const key = (s: string) => s;

describe("linger", () => {
  it("keeps what left, marked leaving, until it is gone; what came back is no longer leaving", () => {
    const leavers = new Map<string, string>();
    expect(linger([], leavers, ["a", "b"], key, false).map((l) => [l.key, l.leaving])).toEqual([
      ["a", false],
      ["b", false],
    ]);
    expect(linger(["a", "b"], leavers, ["b"], key, false).map((l) => [l.key, l.leaving])).toEqual([
      ["b", false],
      ["a", true],
    ]);
    // still leaving at the next render, until its exit ends
    expect(linger(["b"], leavers, ["b"], key, false).map((l) => l.key)).toEqual(["b", "a"]);
    leavers.delete("a");
    expect(linger(["b"], leavers, ["b"], key, false).map((l) => l.key)).toEqual(["b"]);
    // back before its exit ended
    linger(["b"], leavers, [], key, false);
    expect(linger([], leavers, ["b"], key, false)).toEqual([{ key: "b", item: "b", leaving: false }]);
  });

  it("nothing lingers under reduced motion", () => {
    const leavers = new Map<string, string>();
    expect(linger(["a", "b"], leavers, ["b"], key, true).map((l) => l.key)).toEqual(["b"]);
  });
});
