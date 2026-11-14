import { describe, expect, it } from "vitest";
import { GLIDE, boxOf, clear, clipPath, glideMs, hidden, stackOf, insetOf, moved, placeOf, travel } from "./glide";

const box = { left: 240, top: 180, width: 220, height: 60 };
const clip = { left: 0, top: 100, right: 1000, bottom: 700 };

describe("a card's place", () => {
  it("is relative to its list and independent of the list's scroll", () => {
    const p = placeOf("todo", box, { left: 230, top: 100, scrollTop: 0 });
    expect(p).toEqual({ col: "todo", x: 10, y: 80, w: 220, h: 60 });
    // the list scrolled 50 px (the card's box went up 50) and the board 300 px sideways (list and card went left)
    const scrolled = placeOf("todo", { ...box, left: -60, top: 130 }, { left: -70, top: 100, scrollTop: 50 });
    expect(scrolled).toEqual(p);
    expect(moved(p, scrolled)).toBe(false);
  });

  it("goes back on screen through the list's frame as it is now", () => {
    const p = placeOf("todo", box, { left: 230, top: 100, scrollTop: 0 });
    expect(boxOf(p, { left: 230, top: 100, scrollTop: 0 })).toEqual(box);
    expect(boxOf(p, { left: -70, top: 100, scrollTop: 50 })).toEqual({ ...box, left: -60, top: 130 });
  });

  it("moved: another list, or further than the sub-pixel threshold", () => {
    const p = { col: "todo", x: 0, y: 80, w: 220, h: 60 };
    expect(moved(p, { ...p, y: 80 + GLIDE.still })).toBe(false);
    expect(moved(p, { ...p, y: 81 })).toBe(true);
    expect(moved(p, { ...p, x: -1 })).toBe(true);
    expect(moved(p, { ...p, col: "doing" })).toBe(true);
    expect(moved(p, { ...p, w: 300, h: 90 })).toBe(false); // a resized card stays where it is
  });
});

describe("a flight", () => {
  it("starts at the offset of the old box from the new one", () => {
    expect(travel({ ...box, left: 540, top: 580 }, box)).toEqual({ dx: 300, dy: 400, dist: 500 });
    expect(travel(box, box)).toEqual({ dx: 0, dy: 0, dist: 0 });
  });

  it("is short for a row, longer for a long way and to another list, and levels off", () => {
    expect(glideMs(0, false)).toBe(GLIDE.shift);
    expect(glideMs(0, true)).toBe(GLIDE.cross);
    expect(glideMs(66, false)).toBe(215);
    expect(glideMs(480, true)).toBe(376);
    expect(glideMs(500, false)).toBeLessThan(glideMs(500, true));
    expect(glideMs(1e6, false)).toBe(GLIDE.shift + GLIDE.stretch);
    expect(glideMs(1e6, true)).toBe(GLIDE.cross + GLIDE.stretch);
    expect(glideMs(-5, false)).toBe(GLIDE.shift);
    const steps = [0, 50, 200, 800, 3000].map((d) => glideMs(d, true));
    expect([...steps].sort((a, b) => a - b)).toEqual(steps);
  });
});

describe("the clip", () => {
  it("insetOf: how far each side reaches past it", () => {
    expect(insetOf(box, clip)).toEqual({ top: -80, right: -540, bottom: -460, left: -240 });
    expect(insetOf({ ...box, top: 70 }, clip).top).toBe(30);
    expect(insetOf({ ...box, left: 900 }, clip).right).toBe(120);
  });

  it("clear: the box and its shadow keep off every edge", () => {
    expect(clear(box, clip, 32)).toBe(true);
    expect(clear({ ...box, top: 120 }, clip, 32)).toBe(false); // 20 px under the top edge
    expect(clear({ ...box, top: 132 }, clip, 32)).toBe(true);
    expect(clear({ ...box, top: 660 }, clip, 32)).toBe(false); // over the bottom edge
  });

  it("hidden: nothing of the box shows", () => {
    expect(hidden(box, clip)).toBe(false);
    expect(hidden({ ...box, top: 41 }, clip)).toBe(false); // 1 px shows
    expect(hidden({ ...box, top: 40 }, clip)).toBe(true);
    expect(hidden({ ...box, top: 700 }, clip)).toBe(true);
    expect(hidden({ ...box, left: -220 }, clip)).toBe(true);
    expect(hidden({ ...box, left: 1000 }, clip)).toBe(true);
    expect(hidden({ ...box, left: 999 }, clip)).toBe(false);
  });

  it("clipPath: the cut in the box's own coordinates", () => {
    expect(clipPath({ ...box, top: 70 }, clip)).toBe("inset(30px -540px -570px -240px)");
    expect(clipPath({ ...box, left: 900.26, top: 180 }, clip)).toBe("inset(-80px 120.3px -460px -900.3px)");
  });
});

describe("stacking", () => {
  it("the card that moved flies on top, then one that changed list, then the one that travelled furthest", () => {
    const room = stackOf(72, false, false); // one row down, making room
    expect(stackOf(72, false, true)).toBeGreaterThan(room); // a one-row swap: as far, only `lead` tells them
    expect(stackOf(300, false, false)).toBeGreaterThan(room);
    expect(stackOf(10, true, false)).toBeGreaterThan(stackOf(5000, false, false)); // another list beats any distance
    expect(stackOf(0, false, true)).toBeGreaterThan(stackOf(5000, true, false)); // the card that moved beats all
    expect(stackOf(5000, true, true)).toBe(3999);
    expect(stackOf(-3, false, false)).toBe(0);
  });
});
