import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  EDGE_SCROLL,
  STALE_MS,
  easeSpeed,
  edgeBands,
  edgeScroller,
  edgeSpeed,
  edgeZone,
  glideTo,
  nearestStart,
} from "./autoscroll";

const box = { left: 100, right: 1100, top: 50, bottom: 650 };
const room = { left: 300, right: 300 };
const max = EDGE_SCROLL.maxSpeed;

describe("edgeSpeed", () => {
  it("is 0 in the middle, above or below the board, or with no room that way", () => {
    expect(edgeSpeed(600, 300, box, room)).toBe(0);
    expect(edgeSpeed(105, 20, box, room)).toBe(0);
    expect(edgeSpeed(105, 700, box, room)).toBe(0);
    expect(edgeSpeed(105, 300, box, { left: 0, right: 300 })).toBe(0);
    expect(edgeSpeed(1095, 300, box, { left: 300, right: 0 })).toBe(0);
  });
  it("scrolls left near the left edge, right near the right edge, faster toward the edge", () => {
    const inner = edgeSpeed(100 + 80, 300, box, room);
    const edge = edgeSpeed(100 + 5, 300, box, room);
    expect(inner).toBeLessThan(0);
    expect(edge).toBeLessThan(inner);
    expect(edgeSpeed(1100 - 5, 300, box, room)).toBeCloseTo(-edge);
    expect(edgeSpeed(100 + EDGE_SCROLL.zone, 300, box, room)).toBe(0);
  });
  it("is the full speed at and past the edge", () => {
    expect(edgeSpeed(100, 300, box, room)).toBe(-max);
    expect(edgeSpeed(20, 300, box, room)).toBe(-max);
    expect(edgeSpeed(1200, 300, box, room)).toBe(max);
  });
  it("caps the zone at a fifth of a narrow board", () => {
    const narrow = { left: 0, right: 300, top: 0, bottom: 100 };
    expect(edgeSpeed(61, 50, narrow, room)).toBe(0);
    expect(edgeSpeed(59, 50, narrow, room)).toBeLessThan(0);
  });
});

describe("edgeZone", () => {
  it("is the tuning's zone, capped at a fifth of a narrow scroller, never negative", () => {
    expect(edgeZone(1000)).toBe(EDGE_SCROLL.zone);
    expect(edgeZone(300)).toBe(60);
    expect(edgeZone(0)).toBe(0);
    expect(edgeZone(-10)).toBe(0);
  });
});

describe("edgeBands", () => {
  const mid = { x: 600, y: 300 };
  it("shows a band on every side the lists can still scroll toward, as wide as the zone", () => {
    expect(edgeBands(mid, box, room)).toEqual({ zone: EDGE_SCROLL.zone, left: "on", right: "on" });
    expect(edgeBands(null, box, room)).toEqual({ zone: EDGE_SCROLL.zone, left: "on", right: "on" });
  });
  it("hides the side with no room: the left at the start, the right at the end, both when nothing scrolls", () => {
    expect(edgeBands(mid, box, { left: 0, right: 300 })).toMatchObject({ left: "off", right: "on" });
    expect(edgeBands(mid, box, { left: 300, right: 0 })).toMatchObject({ left: "on", right: "off" });
    expect(edgeBands(mid, box, { left: 0, right: 0 })).toMatchObject({ left: "off", right: "off" });
  });
  it("is hot on the side whose zone holds the pointer, exactly where edgeSpeed scrolls", () => {
    expect(edgeBands({ x: 105, y: 300 }, box, room)).toMatchObject({ left: "hot", right: "on" });
    expect(edgeBands({ x: 1095, y: 300 }, box, room)).toMatchObject({ left: "on", right: "hot" });
    expect(edgeBands({ x: 20, y: 300 }, box, room)).toMatchObject({ left: "hot" }); // past the edge
    expect(edgeBands({ x: 100 + EDGE_SCROLL.zone, y: 300 }, box, room)).toMatchObject({ left: "on", right: "on" });
    for (const x of [100, 150, 195, 196, 600, 1004, 1005, 1100])
      expect(
        edgeBands({ x, y: 300 }, box, room).left === "hot" || edgeBands({ x, y: 300 }, box, room).right === "hot",
      ).toBe(edgeSpeed(x, 300, box, room) !== 0);
  });
  it("is not hot above or below the board, nor on a side with no room", () => {
    expect(edgeBands({ x: 105, y: 20 }, box, room)).toMatchObject({ left: "on", right: "on" });
    expect(edgeBands({ x: 105, y: 700 }, box, room)).toMatchObject({ left: "on", right: "on" });
    expect(edgeBands({ x: 105, y: 300 }, box, { left: 0, right: 300 })).toMatchObject({ left: "off", right: "on" });
  });
  it("uses the narrow board's zone, and shows nothing on a board with no width", () => {
    const narrow = { left: 0, right: 300, top: 0, bottom: 100 };
    expect(edgeBands({ x: 59, y: 50 }, narrow, room)).toEqual({ zone: 60, left: "hot", right: "on" });
    expect(edgeBands({ x: 61, y: 50 }, narrow, room)).toEqual({ zone: 60, left: "on", right: "on" });
    expect(edgeBands(null, { left: 0, right: 0, top: 0, bottom: 100 }, room)).toEqual({
      zone: 0,
      left: "off",
      right: "off",
    });
  });
});

describe("easeSpeed", () => {
  it("approaches the target gradually, never overshooting", () => {
    let v = 0;
    const seen: number[] = [];
    for (let i = 0; i < 30; i++) seen.push((v = easeSpeed(v, max, 16)));
    expect(seen[0]).toBeGreaterThan(0);
    expect(seen[0]).toBeLessThan(max / 4);
    for (let i = 1; i < seen.length; i++) expect(seen[i]).toBeGreaterThan(seen[i - 1]!);
    expect(v).toBeLessThanOrEqual(max);
    expect(v).toBeGreaterThan(max * 0.95);
  });
  it("falls faster than it rises: the lists stop within ~0.1 s of the pointer leaving the edge", () => {
    let v = max;
    let coast = 0;
    let ms = 0;
    while (v !== 0) {
      v = easeSpeed(v, 0, 16);
      coast += (v * 16) / 1000;
      ms += 16;
    }
    expect(ms).toBeLessThanOrEqual(192);
    expect(coast).toBeLessThan(max * (EDGE_SCROLL.settle / 1000) * 1.2);
    expect(EDGE_SCROLL.settle).toBeLessThan(EDGE_SCROLL.ease);
  });
  it("comes to rest at exactly 0 once the target is 0", () => {
    let v = max;
    let n = 0;
    while (v !== 0 && n < 200) {
      v = easeSpeed(v, 0, 16);
      n++;
    }
    expect(v).toBe(0);
    expect(n).toBeGreaterThan(3);
  });
});

describe("easeSpeed reversal", () => {
  it("a reversal slows down with the short constant first", () => {
    const rev = easeSpeed(max, -max, 16);
    const fromRest = easeSpeed(0, -max, 16);
    expect(rev).toBeLessThan(max);
    expect(max - rev).toBeGreaterThan(-fromRest); // falls faster than a start from rest rises
  });
});

// a scroller box 1000 px wide at x 0..1000, y 0..600, holding 2000 px of lists (max scrollLeft 1000)
function stubEl(scrollWidth = 2000) {
  const el = {
    scrollLeft: 0,
    scrollWidth,
    clientWidth: 1000,
    getBoundingClientRect: () => ({ left: 0, right: 1000, top: 0, bottom: 600 }),
  };
  return el;
}

describe("edgeScroller", () => {
  let frames: Map<number, FrameRequestCallback>;
  let now: number;
  let id: number;
  beforeEach(() => {
    frames = new Map();
    now = 1000;
    id = 0;
    vi.stubGlobal("requestAnimationFrame", (cb: FrameRequestCallback) => (frames.set(++id, cb), id));
    vi.stubGlobal("cancelAnimationFrame", (n: number) => frames.delete(n));
  });
  afterEach(() => vi.unstubAllGlobals());
  // run n frames of 16 ms (each frame's callback may ask for the next one)
  const run = (n: number) => {
    for (let i = 0; i < n && frames.size; i++) {
      now += 16;
      const [k, cb] = [...frames.entries()][0]!;
      frames.delete(k);
      cb(now);
    }
  };
  const make = (scrollWidth?: number) => {
    const el = stubEl(scrollWidth);
    const scrolled: number[] = [];
    const s = edgeScroller(el as unknown as HTMLElement, (x) => scrolled.push(x));
    return { el, s, scrolled };
  };

  it("scrolls right at the right edge, gradually, clamped at the end, and reports every moving frame", () => {
    const { el, s, scrolled } = make();
    s.move(995, 300);
    const seen: number[] = [];
    for (let i = 0; i < 120; i++) {
      run(1);
      seen.push(el.scrollLeft);
      s.move(995, 300);
    }
    expect(seen[0]).toBeGreaterThan(0);
    expect(seen[0]).toBeLessThan(20);
    expect(seen[5]).toBeGreaterThan(seen[0]!);
    expect(Math.max(...seen)).toBe(1000);
    expect(Math.min(...seen)).toBeGreaterThanOrEqual(0);
    expect(scrolled.length).toBeGreaterThan(10);
    expect(scrolled.every((x) => x === 995)).toBe(true);
  });

  it("leave() at full speed: coasts under 70 px and rests within 200 ms, then asks for no frame", () => {
    const { el, s } = make(20000);
    el.scrollLeft = 100;
    s.move(1000, 300);
    for (let i = 0; i < 60; i++) {
      run(1);
      s.move(1000, 300);
    }
    s.leave();
    const at = el.scrollLeft;
    expect(at).toBeLessThan(19000); // still moving, not held by the clamp
    let ms = 0;
    while (frames.size && ms < 1000) {
      run(1);
      ms += 16;
    }
    expect(el.scrollLeft - at).toBeLessThan(70);
    expect(ms).toBeLessThanOrEqual(200);
    expect(frames.size).toBe(0);
  });

  it("a pointer no dragover confirms for STALE_MS is dropped: the lists stop", () => {
    const { el, s } = make();
    s.move(995, 300); // one dragover, then none (the pointer left the window, no dragleave)
    run(Math.ceil(STALE_MS / 16) + 30);
    expect(frames.size).toBe(0);
    const at = el.scrollLeft;
    run(10);
    expect(el.scrollLeft).toBe(at);
  });

  it("pointer() is the pointer the scroll runs on: null before a move, after leave(), stop() and once stale", () => {
    const { s } = make();
    expect(s.pointer()).toBeNull();
    s.move(995, 300);
    expect(s.pointer()).toEqual({ x: 995, y: 300 });
    s.leave();
    expect(s.pointer()).toBeNull();
    s.move(995, 300);
    run(Math.ceil(STALE_MS / 16) + 5);
    expect(s.pointer()).toBeNull();
    s.move(995, 300);
    s.stop();
    expect(s.pointer()).toBeNull();
  });

  it("stop() cancels the pending frame; a later move starts again", () => {
    const { el, s } = make();
    s.move(995, 300);
    run(3);
    s.stop();
    expect(frames.size).toBe(0);
    const at = el.scrollLeft;
    s.move(995, 300);
    run(3);
    expect(el.scrollLeft).toBeGreaterThan(at);
  });

  it("follows the viewer's own scroll instead of jumping back", () => {
    const { el, s } = make();
    s.move(995, 300);
    run(3);
    el.scrollLeft = 500;
    s.move(995, 300);
    run(1);
    expect(el.scrollLeft).toBeGreaterThan(500);
    expect(el.scrollLeft).toBeLessThan(560);
  });

  it("no movement in the middle: no frame keeps running", () => {
    const { el, s } = make();
    s.move(500, 300);
    run(5);
    expect(el.scrollLeft).toBe(0);
    expect(frames.size).toBe(0);
  });
});

describe("nearestStart", () => {
  // lists 230 px apart (220 wide + 10 gap) in a 1000 px box holding 1600 px (max scrollLeft 600)
  const board = (scrollLeft: number, lists = 7) => {
    const el = {
      scrollLeft,
      scrollWidth: 1600,
      clientWidth: 1000,
      clientLeft: 0,
      getBoundingClientRect: () => ({ left: 50 }),
      children: Array.from({ length: lists }, (_, i) => ({
        getBoundingClientRect: () => ({ left: 50 + i * 230 - scrollLeft }),
      })),
    };
    return el as unknown as HTMLElement;
  };
  it("picks the nearest list start, either way", () => {
    expect(nearestStart(board(124))).toBe(230);
    expect(nearestStart(board(90))).toBe(0);
    expect(nearestStart(board(230))).toBe(230);
  });
  it("clamps to the end of the range", () => {
    expect(nearestStart(board(590))).toBe(600);
  });
  it("refuses a board with no lists", () => {
    expect(() => nearestStart(board(0, 0))).toThrow(/no lists/);
  });
});

describe("glideTo", () => {
  let frames: Map<number, FrameRequestCallback>;
  let id: number;
  beforeEach(() => {
    frames = new Map();
    id = 0;
    vi.stubGlobal("requestAnimationFrame", (cb: FrameRequestCallback) => (frames.set(++id, cb), id));
    vi.stubGlobal("cancelAnimationFrame", (n: number) => frames.delete(n));
  });
  afterEach(() => vi.unstubAllGlobals());
  const runAll = (from = 0) => {
    const seen: number[] = [];
    let now = from;
    for (let i = 0; i < 100 && frames.size; i++) {
      const [k, cb] = [...frames.entries()][0]!;
      frames.delete(k);
      cb(now);
      now += 16;
      seen.push(el.scrollLeft);
    }
    return seen;
  };
  let el: { scrollLeft: number };
  it("moves monotonically, fastest first, lands exactly, calls done once", () => {
    el = { scrollLeft: 124 };
    let done = 0;
    glideTo(el as unknown as HTMLElement, 230, 280, () => done++);
    const seen = runAll();
    expect(seen.at(-1)).toBe(230);
    expect(done).toBe(1);
    for (let i = 1; i < seen.length; i++) expect(seen[i]).toBeGreaterThanOrEqual(seen[i - 1]!);
    expect(seen[2]! - seen[1]!).toBeGreaterThan(seen.at(-1)! - seen.at(-2)!);
    expect(seen.length).toBeGreaterThan(10);
  });
  it("cancel stops it where it is, without done", () => {
    el = { scrollLeft: 100 };
    let done = 0;
    const cancel = glideTo(el as unknown as HTMLElement, 0, 280, () => done++);
    const [k, cb] = [...frames.entries()][0]!;
    frames.delete(k);
    cb(0);
    cancel();
    expect(frames.size).toBe(0);
    expect(done).toBe(0);
    expect(el.scrollLeft).toBe(100);
  });
});
