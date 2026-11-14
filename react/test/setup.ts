import "@testing-library/jest-dom/vitest";

// jsdom has no ResizeObserver and its <dialog> has no showModal/close: the board sizes its lists with the first and
// opens the card modal with the second. Stubs, so the tests see the real components, not a branch written for them.
class RO {
  observe() {}
  disconnect() {}
  unobserve() {}
}
(globalThis as unknown as { ResizeObserver: typeof RO }).ResizeObserver = RO;
// jsdom has no PointerEvent (the board editor drags nodes and draws links with pointer events): a MouseEvent with pointerId
if (!("PointerEvent" in globalThis)) {
  class PE extends MouseEvent {
    pointerId: number;
    pointerType: string;
    constructor(type: string, init: MouseEventInit & { pointerId?: number; pointerType?: string } = {}) {
      super(type, init);
      this.pointerId = init.pointerId ?? 0;
      this.pointerType = init.pointerType ?? "mouse";
    }
  }
  (globalThis as unknown as { PointerEvent: typeof PE }).PointerEvent = PE;
}
const dlg = HTMLDialogElement.prototype as HTMLDialogElement & { showModal: () => void; close: () => void };
if (!dlg.showModal) {
  dlg.showModal = function (this: HTMLDialogElement) {
    this.setAttribute("open", "");
  };
  dlg.close = function (this: HTMLDialogElement) {
    this.removeAttribute("open");
  };
}

// jsdom has no matchMedia (the board asks it for prefers-reduced-motion before a card glides) and no Web Animations
// (a moved card's copy glides with Element.animate): no query matches, and an animation runs until a test ends it
// with finish() — onfinish — or the code cancels it — oncancel.
const media = new Map<string, MediaQueryList & { set(matches: boolean): void }>();
window.matchMedia = (query: string) => {
  let m = media.get(query);
  if (!m) {
    const listeners = new Set<(e: MediaQueryListEvent) => void>();
    const q = {
      matches: false,
      media: query,
      onchange: null,
      addEventListener: (_: string, l: (e: MediaQueryListEvent) => void) => void listeners.add(l),
      removeEventListener: (_: string, l: (e: MediaQueryListEvent) => void) => void listeners.delete(l),
      addListener() {},
      removeListener() {},
      dispatchEvent: () => false,
      // a test switches the query: its listeners hear the change
      set(matches: boolean) {
        q.matches = matches;
        for (const l of listeners) l({ matches, media: query } as MediaQueryListEvent);
      },
    };
    m = q as unknown as MediaQueryList & { set(matches: boolean): void };
    media.set(query, m);
  }
  return m;
};
class Anim {
  // where a flight is: the eased progress (a test sets it to stand a flight midway)
  progress = 0;
  effect = { getComputedTiming: () => ({ progress: this.progress }) };
  onfinish: (() => void) | null = null;
  oncancel: (() => void) | null = null;
  playState = "running";
  finish() {
    if (this.playState !== "running") return;
    this.playState = "finished";
    this.onfinish?.();
  }
  cancel() {
    if (this.playState !== "running") return;
    this.playState = "idle";
    this.oncancel?.();
  }
}
Element.prototype.animate = () => new Anim() as unknown as Animation;
