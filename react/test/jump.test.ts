import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { JUMP_SETTLE_MS, jumpTo } from "../src/lib/card";

// a DOM test (jsdom), so here and not beside lib/card.ts: a host that vendors src/ runs its lib tests without a DOM
describe("jumpTo", () => {
  // jsdom has no layout: a scroll box of a set height, an entry of a set height, scrollIntoView recorded, and every
  // ResizeObserver kept with what it watches so a test can fire "its list changed size"
  let calls: (ScrollIntoViewOptions | undefined)[];
  let watching: Map<Element, () => void>;
  let box: HTMLDivElement;
  let list: HTMLOListElement;
  let el: HTMLLIElement;
  let height: number;
  const original = Object.getOwnPropertyDescriptor(Element.prototype, "scrollIntoView");
  const resized = () => watching.get(list)?.();
  const stops: (() => void)[] = [];
  const jump = () => {
    const stop = jumpTo(el);
    stops.push(stop);
    return stop;
  };
  beforeEach(() => {
    vi.useFakeTimers();
    calls = [];
    watching = new Map();
    vi.stubGlobal(
      "ResizeObserver",
      class {
        private els: Element[] = [];
        constructor(private cb: () => void) {}
        observe(e: Element) {
          this.els.push(e);
          watching.set(e, this.cb);
        }
        disconnect() {
          for (const e of this.els) if (watching.get(e) === this.cb) watching.delete(e);
        }
        unobserve() {}
      },
    );
    Element.prototype.scrollIntoView = function (o?: boolean | ScrollIntoViewOptions) {
      calls.push(typeof o === "object" ? o : undefined);
    };
    box = document.createElement("div");
    box.style.overflowY = "auto";
    Object.defineProperty(box, "clientHeight", { configurable: true, get: () => 800 });
    list = document.createElement("ol");
    el = document.createElement("li");
    el.tabIndex = -1;
    height = 100;
    el.getBoundingClientRect = () => ({ height }) as DOMRect;
    list.append(el);
    box.append(list);
    document.body.append(box);
  });
  afterEach(() => {
    for (const stop of stops.splice(0)) stop();
    vi.restoreAllMocks();
    vi.clearAllTimers();
    box.remove();
    if (original) Object.defineProperty(Element.prototype, "scrollIntoView", original);
    else delete (Element.prototype as Partial<Element>).scrollIntoView;
    vi.unstubAllGlobals();
    vi.useRealTimers();
  });

  it("aligns at once, instant, centred when short; focuses the entry", () => {
    jump();
    expect(calls).toEqual([{ block: "center", behavior: "instant" }]);
    expect(document.activeElement).toBe(el);
  });

  it("top-aligns an entry taller than half its scroll box, read at every align (a resize / rotation)", () => {
    height = 500; // > 800 / 2
    jump();
    expect(calls.at(-1)?.block).toBe("start");
    Object.defineProperty(box, "clientHeight", { configurable: true, get: () => 1200 }); // rotated: 500 < 600
    resized();
    expect(calls.at(-1)?.block).toBe("center");
  });

  it("re-aligns on its list's size changes until JUMP_SETTLE_MS, then never again", () => {
    jump();
    resized();
    resized();
    expect(calls).toHaveLength(3);
    vi.advanceTimersByTime(JUMP_SETTLE_MS);
    resized();
    expect(calls).toHaveLength(3);
    expect(watching.has(list)).toBe(false); // observer disconnected
  });

  it.each(["wheel", "touchstart", "keydown", "pointerdown"])("the reader's %s stops it", (kind) => {
    jump();
    window.dispatchEvent(new Event(kind));
    resized();
    expect(calls).toHaveLength(1);
    expect(watching.has(list)).toBe(false);
    // the settle timer cleared: it never runs the stop a second time (jsdom's focus keeps a timer of its own, so the
    // count of pending timers proves nothing)
    const remove = vi.spyOn(window, "removeEventListener");
    vi.advanceTimersByTime(JUMP_SETTLE_MS);
    expect(remove).not.toHaveBeenCalled();
  });

  it("the returned stop (unmount, the next jump) ends it and removes every listener", () => {
    const add = vi.spyOn(window, "addEventListener");
    const remove = vi.spyOn(window, "removeEventListener");
    const stop = jump();
    stop();
    resized();
    expect(calls).toHaveLength(1);
    const removed = remove.mock.calls.length;
    vi.advanceTimersByTime(JUMP_SETTLE_MS); // the settle timer cleared: no second stop
    expect(remove.mock.calls).toHaveLength(removed);
    const added = add.mock.calls.map((c) => c[0]).sort();
    expect(remove.mock.calls.map((c) => c[0]).sort()).toEqual(added);
    expect(added).toEqual(["keydown", "pointerdown", "touchstart", "wheel"]);
    // a second jump after the stop works on its own
    jump();
    resized();
    expect(calls).toHaveLength(3);
  });
});
