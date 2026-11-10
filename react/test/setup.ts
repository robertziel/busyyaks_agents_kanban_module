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
