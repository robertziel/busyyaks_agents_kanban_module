// Cards glide to their new place instead of jumping there (FLIP): after every commit of the board each card is
// measured, compared with where it was, and — when it moved inside its list or to another list — a copy of it flies
// from the old spot to the new one while the card itself waits there, invisible. A card that was not on the board
// before fades in. The first load, a resized board and `prefers-reduced-motion: reduce` move nothing.
//
// A place is kept relative to the card's LIST (its left edge, its content top: the list's scrollTop is added), so
// scrolling a list or the board between two renders is never read as a move, and a column that only slid sideways
// (another one was collapsed) carries its cards without a flight. The spot a flight starts from is that place put
// back through the old list's box and scroll as they are NOW.
//
// The copy (not the card) flies, for every move: a list clips what it holds (a card translated out of it is cut at
// its edge, and one translated below its last row adds a scroll bar for the time of the flight), and the card keeps
// its real box — so the next measure reads its layout, focus stays on it and a click lands on it mid-flight.
import { useEffect, useLayoutEffect, useRef, type RefObject } from "react";

export type Box = { left: number; top: number; width: number; height: number };
export type Span = { left: number; top: number; right: number; bottom: number };
// a list's box on screen and how far it is scrolled
export type Frame = { left: number; top: number; scrollTop: number };
export type Place = { col: string; x: number; y: number; w: number; h: number };

export type GlideTuning = {
  ease: string; // a soft landing: most of the way fast, the last pixels slow (no overshoot)
  shift: number; // ms: the shortest glide inside a list
  cross: number; // ms: the shortest glide to another list
  stretch: number; // ms added for a long way
  reach: number; // px: the distance at which ~63 % of `stretch` is added
  enter: number; // ms: a card that was not on the board fades in
  enterScale: number; // … from this scale
  still: number; // px: a smaller change is not a move (sub-pixel layout)
  slack: number; // px around a flying card that must stay inside the clip for the clip to be left out (its shadow)
};

export const GLIDE: GlideTuning = {
  ease: "cubic-bezier(0.22, 1, 0.36, 1)",
  shift: 200,
  cross: 300,
  stretch: 120,
  reach: 480,
  enter: 200,
  enterScale: 0.97,
  still: 0.5,
  slack: 32,
};

// Where a card's box sits in its list: independent of the list's and the board's scroll.
export function placeOf(col: string, box: Box, frame: Frame): Place {
  return { col, x: box.left - frame.left, y: box.top - frame.top + frame.scrollTop, w: box.width, h: box.height };
}

// The box on screen of a place, through its list's frame as it is now.
export function boxOf(place: Place, frame: Frame): Box {
  return { left: frame.left + place.x, top: frame.top - frame.scrollTop + place.y, width: place.w, height: place.h };
}

// The way from one box to another: the offset the flight starts at, and its length.
export function travel(from: Box, to: Box): { dx: number; dy: number; dist: number } {
  const dx = from.left - to.left;
  const dy = from.top - to.top;
  return { dx, dy, dist: Math.hypot(dx, dy) };
}

// Did a card change place? Another list, or further than `still` px inside the same one.
export function moved(a: Place, b: Place, t: GlideTuning = GLIDE): boolean {
  return a.col !== b.col || Math.abs(a.x - b.x) > t.still || Math.abs(a.y - b.y) > t.still;
}

// How long a glide of `dist` px takes: a short base (longer to another list), growing with the way and levelling off,
// so one row down is quick and a flight across the board never drags.
export function glideMs(dist: number, crossed: boolean, t: GlideTuning = GLIDE): number {
  const base = crossed ? t.cross : t.shift;
  return Math.round(base + t.stretch * (1 - Math.exp(-Math.max(0, dist) / t.reach)));
}

// The stacking of a flight's copy above the board's other flights: the card that moved on top — `lead` = its own data
// changed in this commit (a move is the card's activity; the cards making room only shift) —, then one that went to
// another list, then the one that travelled furthest. Two cards swapping one row travel as far: only `lead` tells them.
export function stackOf(dist: number, crossed: boolean, lead: boolean): number {
  return (lead ? 2000 : 0) + (crossed ? 1000 : 0) + Math.min(999, Math.round(Math.max(0, dist)));
}

// How far each side of `box` reaches past `clip` (px; > 0 = that much is cut off).
export function insetOf(box: Box, clip: Span): Span {
  return {
    top: clip.top - box.top,
    right: box.left + box.width - clip.right,
    bottom: box.top + box.height - clip.bottom,
    left: clip.left - box.left,
  };
}

// True when `box` keeps at least `slack` px to every side of `clip`: nothing of it (or its shadow) is cut.
export function clear(box: Box, clip: Span, slack: number): boolean {
  const i = insetOf(box, clip);
  return Math.max(i.top, i.right, i.bottom, i.left) <= -slack;
}

// True when nothing of `box` shows inside `clip`.
export function hidden(box: Box, clip: Span): boolean {
  const i = insetOf(box, clip);
  return i.top >= box.height || i.bottom >= box.height || i.left >= box.width || i.right >= box.width;
}

// The CSS clip-path that cuts `box` to `clip`, in the box's own coordinates (it travels with the box).
export function clipPath(box: Box, clip: Span): string {
  const i = insetOf(box, clip);
  const px = (n: number) => `${Math.round(n * 10) / 10}px`;
  return `inset(${px(i.top)} ${px(i.right)} ${px(i.bottom)} ${px(i.left)})`;
}

// ── the DOM side ─────────────────────────────────────────────────────────────────────────────────────────────

type Flight = {
  el: HTMLElement; // the card, invisible at its new place
  clone: HTMLElement; // its flying copy
  anim: Animation;
  to: Place;
  toBox: Box; // where the card's box was on screen when the copy was last placed
  left: number; // the copy's fixed position
  top: number;
  dx: number; // the offset the flight started at (it eases to 0)
  dy: number;
  crossed: boolean;
  lead: boolean; // the card that moved (stackOf)
};
// a flight to start: everything it needs read before the first copy is written (one layout per run, not one per card)
type Plan = {
  s: Seen;
  from: Box;
  crossed: boolean;
  lead: boolean;
  hold?: number;
  kc: string; // the list's hue (--kc): the copy leaves its column
  focused: boolean; // the card shows a keyboard focus ring: the copy shows it while the card is hidden
};
type Entering = { el: HTMLElement; anim: Animation };
type ListFrame = { el: HTMLElement; frame: Frame; span: Span };
type Seen = { id: number; el: HTMLElement; list: ListFrame; place: Place; box: Box };

export type GlideOpts = {
  paused: boolean; // a card is dragged or a move is in flight: nothing glides, nothing is re-read
  held: number | null; // the dragged card: it will glide from the drop slot, not from where it was picked up
  updated: ReadonlyMap<number, string>; // each card's `updated` as the board shows it: a changed one = the card that moved
  // the board's own last move (a drop, a key): `n` counts them. `updated` is whole seconds, so a second move of the same
  // card within one leaves it unchanged — this names the card that moved then; read once, by the next run that glides
  own: { id: number; n: number } | null;
};

const CARDS = "li.kb-card[data-id]:not(.ro)";
const REDUCED = "(prefers-reduced-motion: reduce)";

const boxOfRect = (r: DOMRect): Box => ({ left: r.left, top: r.top, width: r.width, height: r.height });
const spanOfRect = (r: DOMRect): Span => ({ left: r.left, top: r.top, right: r.right, bottom: r.bottom });

export class Glide {
  private places: Map<number, Place> | null = null;
  private updated: ReadonlyMap<number, string> | null = null;
  private ownSeen = 0; // the `own.n` already read
  private shape = "";
  private flights = new Map<number, Flight>();
  private entering = new Map<number, Entering>();
  private origin: { id: number; place: Place | undefined } | null = null;
  private following = false;
  private layer: HTMLElement | null = null; // .kb-flights: the copies' own layer, under the board's menus
  private reduced: MediaQueryList | null = null;

  // After a commit: `root` is the board's .ak-root element.
  run(root: HTMLElement, opts: GlideOpts): void {
    const board = root.querySelector<HTMLElement>(".kb");
    if (!board) return this.reset();
    if (opts.paused) return this.hold(board, opts.held);
    this.origin = null;

    const lists = new Map<string, ListFrame>();
    for (const el of board.querySelectorAll<HTMLElement>("ol.kb-list")) {
      const col = el.closest<HTMLElement>("[data-col]")?.dataset.col;
      if (col === undefined) throw new Error("kanban: a list of the board is in no column (no data-col above it)");
      lists.set(col, frameOf(el));
    }
    const prev = this.places;
    const before = this.updated;
    this.updated = opts.updated;
    const own = opts.own && opts.own.n !== this.ownSeen ? opts.own.id : null;
    if (opts.own) this.ownSeen = opts.own.n;
    const lead = (id: number) => id === own || (before !== null && before.get(id) !== opts.updated.get(id));
    const next = new Map<number, Place>();
    const seen: Seen[] = [];
    for (const [col, list] of lists) {
      for (const el of list.el.querySelectorAll<HTMLElement>(CARDS)) {
        const id = Number(el.dataset.id);
        // a card fading in is scaled: its box is not its layout — it keeps the place read when the fade began
        const fading = this.entering.get(id);
        const kept = fading?.el === el ? prev?.get(id) : undefined;
        if (kept) {
          next.set(id, kept);
          continue;
        }
        const box = boxOfRect(el.getBoundingClientRect());
        const place = placeOf(col, box, list.frame);
        next.set(id, place);
        seen.push({ id, el, list, place, box });
      }
    }
    // the board's width or its open lists changed: every card reflowed, nothing moved
    const shape = `${board.clientWidth}|${[...lists.keys()].join("|")}`;
    const reshaped = shape !== this.shape;
    this.places = next;
    this.shape = shape;
    if (!prev || reshaped || window.matchMedia(REDUCED).matches) return this.settle();

    // ── read: every box, hue and focus the flights need, before anything is written ──
    const boardSpan = spanOfRect(board.getBoundingClientRect());
    const hue = new Map<ListFrame, string>(); // one style read per list
    const kcOf = (l: ListFrame) => {
      let v = hue.get(l);
      if (v === undefined) hue.set(l, (v = getComputedStyle(l.el).getPropertyValue("--kc")));
      return v;
    };
    const plan = (s: Seen, from: Box, crossed: boolean, isLead: boolean, hold?: number): Plan => ({
      s,
      from,
      crossed,
      lead: isLead,
      hold,
      kc: kcOf(s.list),
      focused: s.el.matches(":focus-visible"),
    });
    const plans: Plan[] = [];
    const retarget: number[] = []; // flights that end now: their card moved again
    const remount: Seen[] = []; // flights whose card React mounted anew (another list, another day group)
    const still: Seen[] = []; // the board's own move already in its slot (a drop lands there)
    const entering: Seen[] = [];
    for (const s of seen) {
      const flying = this.flights.get(s.id);
      if (flying) {
        if (flying.el !== s.el) remount.push(s);
        if (!moved(flying.to, s.place)) continue; // still heading where it is: the flight is left alone
        retarget.push(s.id);
        const crossed = flying.crossed || flying.to.col !== s.place.col;
        plans.push(plan(s, this.where(flying), crossed, flying.lead || lead(s.id))); // on from where it is now
        continue;
      }
      const was = prev.get(s.id);
      const old = was && lists.get(was.col);
      if (!was || !old)
        entering.push(s); // new, unfolded, back from a filter, or out of a list collapsed now
      else if (moved(was, s.place)) plans.push(plan(s, boxOf(was, old.frame), was.col !== s.place.col, lead(s.id)));
      else if (s.id === own) still.push(s);
    }
    const flying = plans.filter(
      (p) => !(hidden(p.from, clipOf(p, boardSpan)) && hidden(p.s.box, clipOf(p, boardSpan))),
    );
    const longest = Math.max(0, ...flying.map((p) => p.hold ?? glideMs(travel(p.from, p.s.box).dist, p.crossed)));
    // the card that moved is already in its slot (dropped there) while the cards making room still glide across it: it
    // gets a copy too, standing still on top for as long as they move
    if (longest > 0) for (const s of still) flying.push(plan(s, s.box, false, true, longest));
    const layer = flying.length > 0 ? this.layerIn(root) : null;
    const offset = layer ? this.offsetOf(layer) : { left: 0, top: 0 };

    // ── write ──
    for (const [id, f] of this.flights) if (!next.has(id)) this.land(id, f);
    for (const s of remount) {
      const f = this.flights.get(s.id)!;
      f.el = s.el;
      s.el.style.opacity = "0";
    }
    for (const id of retarget) this.land(id, this.flights.get(id)!);
    for (const s of entering) this.enter(s.id, s.el);
    if (layer) for (const p of flying) this.fly(layer, p, offset, boardSpan);
  }

  // Where a flight's copy is now, its layout box without the lift's scale: the eased offset still to go.
  private where(f: Flight): Box {
    const left = 1 - (f.anim.effect?.getComputedTiming().progress ?? 1);
    return { ...f.toBox, left: f.toBox.left + f.dx * left, top: f.toBox.top + f.dy * left };
  }

  // the copies' layer: fixed over the window inside the board's root, so the board's tokens apply to them
  private layerIn(root: HTMLElement): HTMLElement {
    if (this.layer?.parentElement === root) return this.layer;
    this.layer?.remove();
    const el = document.createElement("div");
    el.className = "kb-flights";
    el.setAttribute("aria-hidden", "true");
    root.append(el);
    return (this.layer = el);
  }

  // An ancestor with a transform / filter / backdrop-filter makes `fixed` relative to itself: the layer sits at the
  // window's 0,0 unless one does, and where it really is says by how much every copy is off (one read per run).
  private offsetOf(layer: HTMLElement): { left: number; top: number } {
    const r = layer.getBoundingClientRect();
    return { left: r.left, top: r.top };
  }

  // The board is gone (loading, an error, unmounted): forget everything — its next cards are a first load.
  reset(): void {
    this.settle();
    this.layer?.remove();
    this.layer = null;
    this.places = null;
    this.updated = null;
    this.shape = "";
    this.origin = null;
  }

  // every flight and fade ends now, each card shown where it is
  private settle(): void {
    for (const [id, f] of this.flights) this.land(id, f);
    for (const e of [...this.entering.values()]) e.anim.cancel();
    this.entering.clear();
  }

  // While a card is dragged its place is the drop slot under the pointer, so after the drop it settles from there;
  // over no slot it is where it was picked up. The slot pushes the cards below it: those are not re-read.
  private hold(board: HTMLElement, held: number | null): void {
    if (held === null) return; // a move is in flight, no card in hand: the next run reads where it went
    if (!this.places) return; // the board was never read (first load): nothing glides from anywhere yet
    if (this.origin?.id !== held) this.origin = { id: held, place: this.places.get(held) };
    const origin = this.origin.place;
    if (!origin) return; // the card in hand was not on the board at the last read: it fades in where it lands
    const ghost = board.querySelector<HTMLElement>("ol.kb-list > li.kb-ghost");
    if (!ghost) {
      // the pointer is over no list: a drop there moves nothing (Board's onDrop needs a slot), so the card is
      // where it was picked up — that IS its place, not a stand-in for one
      this.places.set(held, origin);
      return;
    }
    const list = ghost.closest<HTMLElement>("ol.kb-list");
    const col = list?.closest<HTMLElement>("[data-col]")?.dataset.col;
    if (!list || col === undefined) throw new Error("kanban: the drop slot is in no list of a column (no data-col)");
    const r = ghost.getBoundingClientRect();
    const slot = { left: r.left, top: r.top, width: origin.w, height: origin.h };
    this.places.set(held, placeOf(col, slot, frameOf(list).frame));
  }

  // Starts a planned flight: writes only (everything was read by `run`).
  private fly(layer: HTMLElement, p: Plan, offset: { left: number; top: number }, board: Span): void {
    const { s, from, crossed, lead } = p;
    const clip = clipOf(p, board);
    const { dx, dy, dist } = travel(from, s.box);
    const ms = p.hold ?? glideMs(dist, crossed);

    const clone = s.el.cloneNode(true) as HTMLElement;
    for (const a of ["data-id", "tabindex", "draggable"]) clone.removeAttribute(a);
    clone.setAttribute("aria-hidden", "true");
    clone.setAttribute("inert", "");
    clone.classList.remove("dragging", "busy");
    clone.classList.add("kb-glide");
    if (crossed) clone.classList.add("kb-fly");
    if (p.focused) clone.classList.add("kb-glide-focus");
    const left = s.box.left - offset.left;
    const top = s.box.top - offset.top;
    const cs = clone.style;
    cs.position = "fixed";
    cs.boxSizing = "border-box";
    cs.margin = "0";
    cs.pointerEvents = "none";
    cs.left = `${left}px`;
    cs.top = `${top}px`;
    cs.width = `${s.box.width}px`;
    cs.height = `${s.box.height}px`;
    cs.opacity = "1";
    cs.zIndex = String(stackOf(dist, crossed, lead)); // within .kb-flights, which sits under the board's menus
    cs.setProperty("--kb-glide-ms", `${ms}ms`);
    cs.setProperty("--kc", p.kc);
    layer.append(clone);

    const cut = !(clear(from, clip, GLIDE.slack) && clear(s.box, clip, GLIDE.slack));
    const anim = clone.animate(
      [
        { translate: `${dx}px ${dy}px`, ...(cut && { clipPath: clipPath(from, clip) }) },
        { translate: "0px 0px", ...(cut && { clipPath: clipPath(s.box, clip) }) },
      ],
      { duration: ms, easing: GLIDE.ease },
    );
    const flight: Flight = { el: s.el, clone, anim, to: s.place, toBox: s.box, left, top, dx, dy, crossed, lead };
    s.el.style.opacity = "0";
    this.flights.set(s.id, flight);
    anim.onfinish = () => {
      if (this.flights.get(s.id) === flight) this.land(s.id, flight);
    };
    this.follow(true);
  }

  private land(id: number, f: Flight): void {
    this.flights.delete(id);
    f.anim.onfinish = null;
    f.anim.cancel();
    f.clone.remove();
    f.el.style.removeProperty("opacity");
    if (this.flights.size === 0) this.follow(false);
  }

  private enter(id: number, el: HTMLElement): void {
    const anim = el.animate([{ offset: 0, opacity: 0, scale: GLIDE.enterScale }], {
      duration: GLIDE.enter,
      easing: GLIDE.ease,
    });
    const entry: Entering = { el, anim };
    this.entering.set(id, entry);
    const done = () => {
      if (this.entering.get(id) === entry) this.entering.delete(id);
    };
    anim.onfinish = done;
    anim.oncancel = done;
  }

  // While copies fly: a scroll of a list, the board or the page moves each copy with its card; a resize reflows the
  // board (nothing moved: every flight lands at once, as a reshaped board does on its next commit); reduced motion
  // switched on lands them too.
  private follow(on: boolean): void {
    if (on === this.following) return;
    this.following = on;
    this.reduced ??= window.matchMedia(REDUCED);
    if (on) {
      window.addEventListener("scroll", this.onScroll, { capture: true, passive: true });
      window.addEventListener("resize", this.onStop);
      this.reduced.addEventListener("change", this.onReduced);
    } else {
      window.removeEventListener("scroll", this.onScroll, { capture: true });
      window.removeEventListener("resize", this.onStop);
      this.reduced.removeEventListener("change", this.onReduced);
    }
  }

  // The scroll event is dispatched in the frame's "update the rendering" steps, before its style, layout and paint,
  // so a copy moved here is drawn in the same frame as its card. All boxes are read first, then written.
  private onScroll = (): void => {
    const live = [...this.flights.values()].filter((f) => f.el.isConnected); // a replaced card: the next commit
    const boxes = live.map((f) => boxOfRect(f.el.getBoundingClientRect()));
    live.forEach((f, i) => {
      const now = boxes[i]!;
      f.left += now.left - f.toBox.left;
      f.top += now.top - f.toBox.top;
      f.toBox = now;
      f.clone.style.left = `${f.left}px`;
      f.clone.style.top = `${f.top}px`;
    });
  };

  private onStop = (): void => this.settle();
  private onReduced = (e: MediaQueryListEvent): void => {
    if (e.matches) this.settle();
  };
}

// inside a list a card never covers the list's header; on its way to another list it flies over them
function clipOf(p: Plan, board: Span): Span {
  return p.crossed ? board : { ...board, top: p.s.list.span.top };
}

function frameOf(el: HTMLElement): ListFrame {
  const r = el.getBoundingClientRect();
  return { el, frame: { left: r.left, top: r.top, scrollTop: el.scrollTop }, span: spanOfRect(r) };
}

// Call from the board on every render: `root` is its .ak-root element (null while the board shows no lists).
export function useGlide(root: RefObject<HTMLElement | null>, opts: GlideOpts): void {
  const glide = useRef<Glide | null>(null);
  const { paused, held, updated, own } = opts;
  useLayoutEffect(() => {
    glide.current ??= new Glide();
    if (root.current) glide.current.run(root.current, { paused, held, updated, own });
    else glide.current.reset();
  });
  useEffect(() => () => glide.current?.reset(), []);
}
