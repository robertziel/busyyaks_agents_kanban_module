// Edge auto-scroll while a card is dragged: the pointer near the board's left or right edge scrolls the lists
// sideways, slow at the zone's inner border and faster toward the edge (eased), the speed itself eased in and out so
// the scroll starts and stops softly. Native drag and drop scrolls a page, never an inner scroller sideways.

export type EdgeScrollTuning = {
  zone: number; // px from the edge where scrolling starts (capped at a fifth of the scroller's width)
  maxSpeed: number; // px/s at the edge (and past it)
  ease: number; // ms: the time constant the speed rises toward a faster target with (a soft start)
  settle: number; // ms: the time constant it falls with (short: the lists stop near where the pointer left the edge)
};

export const EDGE_SCROLL: EdgeScrollTuning = { zone: 96, maxSpeed: 1500, ease: 110, settle: 40 };

export type Span = { left: number; right: number; top: number; bottom: number };

// The width (px) of the edge zone of a scroller `width` px wide: where the pointer starts the scroll, and how wide
// the board draws its edge bands.
export function edgeZone(width: number, t: EdgeScrollTuning = EDGE_SCROLL): number {
  return Math.max(0, Math.min(t.zone, width / 5));
}

// The target speed (px/s; < 0 = left) for a pointer at (x, y) over a scroller whose box is `box`, which can still
// scroll `room.left` px left and `room.right` px right. 0 outside the box's height, in the middle, or with no room.
export function edgeSpeed(
  x: number,
  y: number,
  box: Span,
  room: { left: number; right: number },
  t: EdgeScrollTuning = EDGE_SCROLL,
): number {
  if (y < box.top || y > box.bottom) return 0;
  const zone = edgeZone(box.right - box.left, t);
  if (zone === 0) return 0;
  const depth = (d: number) => Math.min(1, Math.max(0, (zone - d) / zone));
  const l = depth(x - box.left);
  const r = depth(box.right - x);
  if (l > 0 && room.left > 0) return -t.maxSpeed * l * l;
  if (r > 0 && room.right > 0) return t.maxSpeed * r * r;
  return 0;
}

// What the board draws on an edge while a card is dragged: nothing ("off": the lists cannot scroll that way), a band
// as wide as the zone ("on"), or a stronger one ("hot": the pointer is inside that zone, the lists are scrolling).
export type EdgeBand = "off" | "on" | "hot";
export type EdgeBands = { zone: number; left: EdgeBand; right: EdgeBand };

// The bands for a scroller whose box is `box` with `room` left to scroll each way, the pointer at `pointer` (null: no
// pointer over the page). The same zone and the same room as edgeSpeed: a hot band is an edge that scrolls.
export function edgeBands(
  pointer: { x: number; y: number } | null,
  box: Span,
  room: { left: number; right: number },
  t: EdgeScrollTuning = EDGE_SCROLL,
): EdgeBands {
  const zone = edgeZone(box.right - box.left, t);
  const speed = pointer ? edgeSpeed(pointer.x, pointer.y, box, room, t) : 0;
  const band = (has: boolean, scrolling: boolean): EdgeBand => (!has || zone === 0 ? "off" : scrolling ? "hot" : "on");
  return { zone, left: band(room.left > 0, speed < 0), right: band(room.right > 0, speed > 0) };
}

// Below this speed (px/s, under half a pixel a frame) the lists are at rest: the tail of the decay moves nothing visible.
const REST = 30;

// A pointer no dragover has confirmed for this long is gone (it left the window and no dragleave said so). Browsers
// repeat dragover under a still pointer — the HTML spec every 350 ms ± 200 ms — so this is past the slowest repeat.
export const STALE_MS = 600;

// One frame of the eased speed: `v` follows `target` over `dt` ms, rising with t.ease, falling with t.settle.
export function easeSpeed(v: number, target: number, dt: number, t: EdgeScrollTuning = EDGE_SCROLL): number {
  const speedingUp = Math.abs(target) > Math.abs(v) && Math.sign(target) * Math.sign(v) >= 0; // same way (or from rest), faster
  const tau = speedingUp ? t.ease : t.settle; // slowing down or reversing: the short one
  const next = v + (target - v) * (1 - Math.exp(-dt / tau));
  return Math.abs(next) < REST && target === 0 ? 0 : next;
}

// Drives `el.scrollLeft` from pointer positions (dragover's clientX/Y) on animation frames; stop() ends it. onScroll
// runs after every frame that moved the lists (the drop slot under a still pointer changes with them).
export function edgeScroller(
  el: HTMLElement,
  onScroll: (x: number, y: number) => void,
  t: EdgeScrollTuning = EDGE_SCROLL,
) {
  let pointer: { x: number; y: number } | null = null;
  let seen = -1; // the frame time the pointer was first seen at (-1: a move since the last frame)
  let v = 0;
  let pos = el.scrollLeft;
  let frame = 0;
  let last = 0;
  const tick = (now: number) => {
    const dt = last ? Math.min(50, now - last) : 16;
    last = now;
    if (pointer && seen < 0) seen = now;
    else if (pointer && now - seen > STALE_MS) pointer = null;
    if (Math.abs(el.scrollLeft - pos) > 2) pos = el.scrollLeft; // the viewer scrolled it themselves
    const r = el.getBoundingClientRect();
    const max = el.scrollWidth - el.clientWidth;
    const target = pointer ? edgeSpeed(pointer.x, pointer.y, r, { left: pos, right: max - pos }, t) : 0;
    v = easeSpeed(v, target, dt, t);
    if (v === 0) {
      frame = 0;
      last = 0;
      return;
    }
    pos = Math.min(max, Math.max(0, pos + (v * dt) / 1000));
    el.scrollLeft = pos;
    if (pointer) onScroll(pointer.x, pointer.y);
    frame = requestAnimationFrame(tick);
  };
  return {
    move(x: number, y: number) {
      pointer = { x, y };
      seen = -1;
      if (!frame) frame = requestAnimationFrame(tick);
    },
    leave() {
      pointer = null;
    },
    // the pointer the scroll runs on (null: none, left the window, or gone stale)
    pointer() {
      return pointer;
    },
    stop() {
      pointer = null;
      v = 0;
      if (frame) cancelAnimationFrame(frame);
      frame = 0;
      last = 0;
    },
  };
}

// The scroll offset (clamped to the scroller's range) of the child start nearest to its current scroll: where the lists
// glide to after a drag, since they snap to list starts.
export function nearestStart(el: HTMLElement): number {
  const starts = listStarts(el);
  const best = starts.reduce((a, b) => (Math.abs(b - el.scrollLeft) < Math.abs(a - el.scrollLeft) ? b : a));
  return clampScroll(el, best);
}

// A step never stops at a list start closer than this (px): at the far right the last start can sit a few px before
// the end of the range, and a step there would barely move.
export const STEP_MIN = 48;

// The scroll offset of the next list start at least STEP_MIN past the current scroll toward `dir` (clamped to the
// scroller's range): where a click on an edge's step area glides the lists — one list sideways, so the snap agrees.
export function stepStart(el: HTMLElement, dir: "left" | "right"): number {
  const at = el.scrollLeft;
  const starts = listStarts(el);
  const next =
    dir === "right"
      ? starts.filter((s) => s >= at + STEP_MIN).reduce((a, b) => Math.min(a, b), Infinity)
      : starts.filter((s) => s <= at - STEP_MIN).reduce((a, b) => Math.max(a, b), -Infinity);
  return clampScroll(el, next);
}

// Which way the lists can still scroll (more than a pixel): the sides whose step area the board shows.
export function stepRoom(el: HTMLElement): { left: boolean; right: boolean } {
  return { left: el.scrollLeft > 1, right: el.scrollWidth - el.clientWidth - el.scrollLeft > 1 };
}

// The scroll offset each list (a child of the scroller) starts at.
function listStarts(el: HTMLElement): number[] {
  const r = el.getBoundingClientRect();
  const starts = Array.from(
    el.children,
    (c) => c.getBoundingClientRect().left - r.left - el.clientLeft + el.scrollLeft,
  );
  if (starts.length === 0) throw new Error("kanban: the board has no lists to snap to");
  return starts;
}

function clampScroll(el: HTMLElement, left: number): number {
  return Math.min(el.scrollWidth - el.clientWidth, Math.max(0, left));
}

// Glides `el.scrollLeft` to `left` over `ms` on animation frames (ease-out cubic: fast, then settling), then calls done.
// The browser's own smooth scrollTo is not used: a re-render right after a drop interrupts it. Returns a cancel that
// stops the glide where it is (done is not called).
export function glideTo(el: HTMLElement, left: number, ms: number, done: () => void): () => void {
  const from = el.scrollLeft;
  let start = -1;
  let frame = 0;
  const tick = (now: number) => {
    if (start < 0) start = now;
    const k = Math.min(1, (now - start) / ms);
    el.scrollLeft = from + (left - from) * (1 - (1 - k) ** 3);
    if (k < 1) frame = requestAnimationFrame(tick);
    else {
      frame = 0;
      done();
    }
  };
  frame = requestAnimationFrame(tick);
  return () => {
    if (frame) cancelAnimationFrame(frame);
    frame = 0;
  };
}
