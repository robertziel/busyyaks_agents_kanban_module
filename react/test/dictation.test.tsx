// The comment box's dictation over a fake DictationApi and a fake microphone: the mic shows only when the host injects
// the port; Dictate → listening → Stop puts the words into the comment, which Save sends; Alt+M anywhere in the card does
// the same; a refused microphone or a failed transcription shows the reason.
import { act, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { Board, type DictationApi, type KanbanApi, type MicCapture } from "../src";
import type { Card, CardData } from "../src/types";
import { clock, LEVEL_BARS } from "../src/components/MicButton";
import { boardData, fixture } from "./fixtures";

const mic = vi.hoisted(() => ({ open: null as null | (() => Promise<MicCapture>) }));
vi.mock("../src/lib/dictation", async (orig) => ({
  ...(await orig<typeof import("../src/lib/dictation")>()),
  openMic: () => mic.open!(),
}));

const coding = fixture("coding");
// the mic opens through the button's morph: a slower CI container needs more than the default 1 s to see it
const SLOW = { timeout: 3000 };
const w = (word: string, start: number, end: number) => ({ word, start, end });
const ALT_M = { code: "KeyM", alt: true, ctrl: false, meta: false, shift: false };
const theCard = {
  id: 7,
  project: "g/r",
  owner_session: "s1",
  owner_socket: null,
  approved: null,
  approved_by: null,
  column: "doing",
  position: 0,
  title: "Talk",
  labels: [],
  assignee: null,
  priority: null,
  comments: 0,
  due: null,
  due_done: false,
  cover: null,
  has_description: false,
  checklist_done: 0,
  checklist_total: 0,
  attachments: 0,
  parent: null,
  children: 0,
  blocked_by: [],
  needs_operator: false,
  waiting: false,
  blocked: null,
  review_round: null,
  metadata: null,
  created_by: "op",
  created: "2026-11-01T10:00:00Z",
  updated: new Date().toISOString(),
  archived: null,
  transitions: [],
} as Card;

function fakeApi(): KanbanApi & { calls: string[] } {
  const calls: string[] = [];
  const cardData: CardData = {
    card: { ...theCard, attachments: [], description: "", description_html: "", checklists: [] },
    activity: [],
    pings: [],
    links: [],
  };
  const data = boardData(coding, [theCard]);
  const known: Partial<KanbanApi> = {
    board: () => Promise.resolve(data),
    boardRev: () => Promise.resolve("r1"),
    card: () => Promise.resolve(cardData),
    cardRev: () => Promise.resolve("c1"),
    markdownPreview: () => Promise.resolve("<p>preview</p>"),
    comment: (id, body) => {
      calls.push(`comment ${id} ${body}`);
      return Promise.resolve({ ...cardData, delivered: "queued: s1" } as CardData);
    },
  };
  return new Proxy({ calls } as KanbanApi & { calls: string[] }, {
    get: (t, k: string) =>
      k === "calls" ? t.calls : ((known as Record<string, unknown>)[k] ?? (() => Promise.resolve({}))),
  });
}

// one second of sound (a steady 0.1: a silent window is never sent)
const speakingMic = (): MicCapture => {
  const chunks = [new Float32Array(16000).fill(0.1)];
  return { sampleRate: 16000, samples: () => chunks, level: () => 0, release: () => {} };
};

function renderBoard(dictation?: DictationApi) {
  return renderBoardIn(dictation).api;
}

function renderBoardIn(dictation?: DictationApi) {
  const api = fakeApi();
  const view = render(
    <Board
      api={api}
      me="me"
      slug="g/r"
      view={{ card: 7, panel: null, archived: false }}
      onView={() => {}}
      dictation={dictation}
    />,
  );
  return { api, container: view.baseElement };
}

// jsdom has no layout, so no scrollIntoView: the shortcut calls it on every hold
Element.prototype.scrollIntoView = () => {};

describe("comment dictation", () => {
  it("no DictationApi → no mic", async () => {
    renderBoard();
    await screen.findByRole("textbox", { name: "Comment" });
    expect(screen.queryByRole("button", { name: "Dictate" })).toBeNull();
  });

  it("Dictate → listening → Stop writes the words into the comment; Save sends them", async () => {
    mic.open = () => Promise.resolve(speakingMic());
    const transcribe = vi.fn(() =>
      Promise.resolve({
        text: " Ship it today.",
        words: [w(" Ship", 0.0, 0.3), w(" it", 0.3, 0.6), w(" today.", 0.6, 0.9)],
      }),
    );
    const api = renderBoard({ transcribe, shortcut: ALT_M });
    const box = await screen.findByRole("textbox", { name: "Comment" });
    fireEvent.click(screen.getByRole("button", { name: "Dictate" }));
    expect(await screen.findByText(/listening/, undefined, SLOW)).toBeInTheDocument();
    expect(box).toHaveAttribute("readonly");
    fireEvent.click(screen.getByRole("button", { name: "Stop dictation" }));
    await waitFor(() => expect(box).toHaveValue("Ship it today."), SLOW);
    expect(box).not.toHaveAttribute("readonly");
    expect(transcribe).toHaveBeenCalledTimes(1);
    fireEvent.click(screen.getByRole("button", { name: "Save" }));
    await waitFor(() => expect(api.calls).toContain("comment 7 Ship it today."), SLOW);
  });

  it("Alt+M on the just-opened card (the focus is on the dialog itself) starts it; in the box it stops it", async () => {
    mic.open = () => Promise.resolve(speakingMic());
    renderBoard({
      transcribe: () =>
        Promise.resolve({
          text: "and the tests",
          words: [w(" and", 0.0, 0.3), w(" the", 0.3, 0.6), w(" tests", 0.6, 0.9)],
        }),
      shortcut: ALT_M,
    });
    const box = await screen.findByRole("textbox", { name: "Comment" });
    fireEvent.change(box, { target: { value: "Fix login" } });
    // push-to-talk: held down → recording (the key's auto-repeat changes nothing); released → stopped
    const dialog = screen.getByRole("dialog", { name: "Card" });
    fireEvent.keyDown(dialog, { key: "µ", code: "KeyM", altKey: true });
    expect(
      await screen.findByText(/listening… release ⌥M to stop|listening… release Alt\+M to stop/, undefined, SLOW),
    ).toBeInTheDocument();
    fireEvent.keyDown(box, { key: "µ", code: "KeyM", altKey: true, repeat: true });
    fireEvent.keyDown(dialog, { key: "µ", code: "KeyM", altKey: true, repeat: true });
    expect(screen.getByRole("button", { name: "Stop dictation" })).toBeInTheDocument();
    fireEvent.keyUp(window, { key: "µ", code: "KeyM", altKey: true });
    await waitFor(() => expect(box).toHaveValue("Fix login and the tests"), SLOW);
    // from a field inside the card (its title); releasing the modifier first stops it too
    fireEvent.keyDown(screen.getByDisplayValue("Talk"), { key: "µ", code: "KeyM", altKey: true });
    expect(await screen.findByText(/listening/, undefined, SLOW)).toBeInTheDocument();
    fireEvent.keyUp(window, { key: "Alt", code: "AltLeft" });
    await waitFor(() => expect(box).toHaveValue("Fix login and the tests and the tests"), SLOW);
  });

  it("the shortcut works wherever the focus is: another editor (which keeps its keys), the page body; no µ is typed; the comment box scrolls into view", async () => {
    mic.open = () => Promise.resolve(speakingMic());
    const scrolled: Element[] = [];
    Element.prototype.scrollIntoView = function (this: Element) {
      scrolled.push(this);
    };
    renderBoard({ transcribe: () => Promise.resolve({ text: "", words: [w(" hi", 0, 0.3)] }), shortcut: ALT_M });
    const box = await screen.findByRole("textbox", { name: "Comment" });
    fireEvent.click(screen.getByRole("button", { name: /Add a more detailed description/ })); // its editor stops every key
    const desc = await screen.findByRole("textbox", { name: "Description" });
    desc.focus();
    const typed = fireEvent.keyDown(desc, { key: "µ", code: "KeyM", altKey: true });
    expect(typed).toBe(false); // default prevented: "µ" never lands in the description
    expect(await screen.findByText(/listening/, undefined, SLOW)).toBeInTheDocument();
    // the comment box (far below on a long card) is brought on screen: the listening state is where the user looks
    expect(scrolled.some((el) => el.contains(box))).toBe(true);
    fireEvent.keyUp(window, { key: "µ", code: "KeyM", altKey: true });
    await waitFor(() => expect(box).toHaveValue("hi"), SLOW);
    // focus on the page body (a click on plain text in some browsers)
    fireEvent.keyDown(document.body, { key: "µ", code: "KeyM", altKey: true });
    expect(await screen.findByText(/listening/, undefined, SLOW)).toBeInTheDocument();
    fireEvent.keyUp(window, { key: "µ", code: "KeyM", altKey: true });
    await waitFor(() => expect(box).toHaveValue("hi hi"), SLOW);
  });

  it("push-to-talk: released before the mic opened stops it once open; the window losing focus stops it", async () => {
    let open: (m: MicCapture) => void = () => {};
    mic.open = () => new Promise((r) => (open = r));
    const transcribe = vi.fn(() => Promise.resolve({ text: "", words: [w(" hi", 0, 0.3)] }));
    renderBoard({ transcribe, shortcut: ALT_M });
    const box = await screen.findByRole("textbox", { name: "Comment" });
    const dialog = screen.getByRole("dialog", { name: "Card" });
    fireEvent.keyDown(dialog, { key: "µ", code: "KeyM", altKey: true });
    fireEvent.keyUp(window, { key: "µ", code: "KeyM", altKey: true }); // a tap: released while the mic opens
    open(speakingMic());
    await waitFor(() => expect(box).toHaveValue("hi"), SLOW);
    expect(screen.getByRole("button", { name: "Dictate" })).toBeInTheDocument();
    mic.open = () => Promise.resolve(speakingMic());
    fireEvent.keyDown(dialog, { key: "µ", code: "KeyM", altKey: true });
    await screen.findByText(/listening/, undefined, SLOW);
    fireEvent.blur(window); // the key-up will never come
    await waitFor(() => expect(box).toHaveValue("hi hi"), SLOW);
  });

  it("the host's own shortcut starts it, the default one does not; null = the mic button only", async () => {
    mic.open = () => Promise.resolve(speakingMic());
    const ctrlShiftD = { code: "KeyD", alt: false, ctrl: true, meta: false, shift: true };
    renderBoard({
      transcribe: () => Promise.resolve({ text: "hi", words: [w(" hi", 0.0, 0.3)] }),
      shortcut: ctrlShiftD,
    });
    await screen.findByRole("textbox", { name: "Comment" });
    expect(screen.getByRole("button", { name: "Dictate" })).toHaveAttribute("title", "Dictate (hold Ctrl+Shift+D)");
    const dialog = screen.getByRole("dialog", { name: "Card" });
    fireEvent.keyDown(dialog, { key: "µ", code: "KeyM", altKey: true });
    expect(screen.queryByText(/listening/)).toBeNull();
    fireEvent.keyDown(dialog, { key: "D", code: "KeyD", ctrlKey: true, shiftKey: true });
    expect(await screen.findByText(/listening… release Ctrl\+Shift\+D to stop/, undefined, SLOW)).toBeInTheDocument();
  });

  it("no shortcut: the mic button works, no key starts it", async () => {
    mic.open = () => Promise.resolve(speakingMic());
    renderBoard({ transcribe: () => Promise.resolve({ text: "hi", words: [w(" hi", 0.0, 0.3)] }), shortcut: null });
    await screen.findByRole("textbox", { name: "Comment" });
    fireEvent.keyDown(screen.getByRole("dialog", { name: "Card" }), { key: "µ", code: "KeyM", altKey: true });
    expect(screen.queryByText(/listening/)).toBeNull();
    expect(screen.getByRole("button", { name: "Dictate" })).toHaveAttribute("title", "Dictate");
    fireEvent.click(screen.getByRole("button", { name: "Dictate" }));
    expect(await screen.findByText(/listening… click the mic to stop/, undefined, SLOW)).toBeInTheDocument();
  });

  it("closing the card while the mic is still opening releases it", async () => {
    let resolve: (m: MicCapture) => void = () => {};
    mic.open = () => new Promise((r) => (resolve = r));
    const release = vi.fn();
    const api = fakeApi();
    const view = render(
      <Board
        api={api}
        me="me"
        slug="g/r"
        view={{ card: 7, panel: null, archived: false }}
        onView={() => {}}
        dictation={{ transcribe: () => Promise.resolve({ text: "x", words: [w(" x", 0.0, 0.3)] }), shortcut: ALT_M }}
      />,
    );
    await screen.findByRole("textbox", { name: "Comment" });
    fireEvent.click(screen.getByRole("button", { name: "Dictate" }));
    view.unmount();
    resolve({ sampleRate: 16000, samples: () => [], level: () => 0, release });
    await waitFor(() => expect(release).toHaveBeenCalledTimes(1), SLOW);
  });

  it("a refused microphone and a failed transcription show their reason", async () => {
    mic.open = () => Promise.reject(Object.assign(new Error("Permission denied"), { name: "NotAllowedError" }));
    renderBoard({ transcribe: () => Promise.reject(new Error("502 · speech server unreachable")), shortcut: ALT_M });
    await screen.findByRole("textbox", { name: "Comment" });
    fireEvent.click(screen.getByRole("button", { name: "Dictate" }));
    expect(await screen.findByRole("alert")).toHaveTextContent("Microphone blocked — allow it for this site");
    mic.open = () => Promise.resolve(speakingMic());
    fireEvent.click(screen.getByRole("button", { name: "Dictate" }));
    await screen.findByText(/listening/, undefined, SLOW);
    fireEvent.click(screen.getByRole("button", { name: "Stop dictation" }));
    expect(await screen.findByRole("alert")).toHaveTextContent(
      "Couldn't transcribe: 502 · speech server unreachable. Your recording is kept.",
    );
  });

  it("while it dictates, Save waits and Ctrl+Enter stops the mic; Esc stops it and keeps the card open", async () => {
    mic.open = () => Promise.resolve(speakingMic());
    const api = renderBoard({
      transcribe: () => Promise.resolve({ text: "", words: [w(" Ship", 0, 0.5)] }),
      shortcut: ALT_M,
    });
    const box = await screen.findByRole("textbox", { name: "Comment" });
    fireEvent.change(box, { target: { value: "Draft" } });
    fireEvent.click(screen.getByRole("button", { name: "Dictate" }));
    await screen.findByText(/listening/, undefined, SLOW);
    expect(screen.getByRole("button", { name: "Save" })).toBeDisabled();
    fireEvent.keyDown(box, { key: "Enter", code: "Enter", ctrlKey: true });
    await waitFor(() => expect(box).toHaveValue("Draft Ship"), SLOW);
    expect(api.calls).toEqual([]); // nothing was posted
    expect(screen.getByRole("button", { name: "Save" })).toBeEnabled();
    // again, now stopped by Esc on the card: the dialog's cancel stops the mic instead of closing
    fireEvent.click(screen.getByRole("button", { name: "Dictate" }));
    await screen.findByText(/listening/, undefined, SLOW);
    const dialog = screen.getByRole("dialog", { name: "Card" });
    fireEvent(dialog, new Event("cancel", { cancelable: true }));
    await waitFor(() => expect(box).toHaveValue("Draft Ship Ship"), SLOW);
    expect(screen.getByRole("dialog", { name: "Card" })).toBeInTheDocument();
  });

  it("a failed final pass keeps the recording: Retry sends it again and the words land", async () => {
    mic.open = () => Promise.resolve(speakingMic());
    let fail = true;
    const transcribe = vi.fn(() =>
      fail
        ? Promise.reject(new Error("speech server unreachable"))
        : Promise.resolve({ text: "", words: [w(" Ship", 0, 0.5)] }),
    );
    renderBoard({ transcribe, shortcut: ALT_M });
    const box = await screen.findByRole("textbox", { name: "Comment" });
    fireEvent.click(screen.getByRole("button", { name: "Dictate" }));
    await screen.findByText(/listening/, undefined, SLOW);
    fireEvent.click(screen.getByRole("button", { name: "Stop dictation" }));
    expect(await screen.findByRole("alert")).toHaveTextContent("Your recording is kept.");
    fail = false;
    fireEvent.click(screen.getByRole("button", { name: "Retry" }));
    await waitFor(() => expect(box).toHaveValue("Ship"), SLOW);
    expect(screen.queryByRole("alert")).toBeNull();
    expect(transcribe).toHaveBeenCalledTimes(2);
  });

  it("a recording that heard nothing says so instead of settling as done", async () => {
    mic.open = () => Promise.resolve(speakingMic());
    mic.open = () => Promise.resolve(speakingMic());
    renderBoard({ transcribe: () => Promise.resolve({ text: "", words: [] }), shortcut: ALT_M });
    await screen.findByRole("textbox", { name: "Comment" });
    fireEvent.click(screen.getByRole("button", { name: "Dictate" }));
    await screen.findByText(/listening/, undefined, SLOW);
    fireEvent.click(screen.getByRole("button", { name: "Stop dictation" }));
    expect(await screen.findByText("nothing heard")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Dictate" })).toHaveAttribute("data-phase", "idle");
  });

  it("the mic is a pill while it listens: phases, the tools off, the real level on the bars, the time; then it settles", async () => {
    let level = 0;
    const chunks = [new Float32Array(16000).fill(0.1)];
    mic.open = () =>
      Promise.resolve({ sampleRate: 16000, samples: () => chunks, level: () => level, release: () => {} });
    // the animation frames, run by hand
    let frames: [number, FrameRequestCallback][] = [];
    let frameId = 0;
    vi.stubGlobal("requestAnimationFrame", (f: FrameRequestCallback) => frames.push([++frameId, f]) && frameId);
    vi.stubGlobal("cancelAnimationFrame", (id: number) => (frames = frames.filter(([n]) => n !== id)));
    const t0 = performance.now();
    const run = (ms: number) => {
      const due = frames;
      frames = [];
      due.forEach(([, f]) => f(t0 + ms));
    };
    let answer: (t: { text: string; words: { word: string; start: number; end: number }[] }) => void = () => {};
    const transcribe = () =>
      new Promise<{ text: string; words: { word: string; start: number; end: number }[] }>((r) => (answer = r));
    renderBoard({ transcribe, shortcut: ALT_M });
    await screen.findByRole("textbox", { name: "Comment" });
    const button = screen.getByRole("button", { name: "Dictate" });
    const bold = screen.getByRole("button", { name: "Bold (Ctrl+B)" });
    expect(button).toHaveAttribute("data-phase", "idle");
    expect(bold).toBeEnabled();
    fireEvent.click(button);
    expect(button).toHaveAttribute("data-phase", "starting");
    expect(button).toHaveAttribute("aria-disabled", "true");
    await screen.findByText(/listening/, undefined, SLOW);
    expect(button).toHaveAttribute("data-phase", "rec");
    expect(button).toHaveAttribute("aria-pressed", "true");
    expect(button).not.toHaveAttribute("aria-disabled");
    expect(button).toHaveAttribute("title", "Stop dictation");
    expect(bold).toBeDisabled(); // the text is read-only: nothing formats it
    // the tools stepped aside: inert and out of the accessibility tree (they keep their place, so nothing moves)
    const tools = bold.closest(".mde-tools")!;
    expect(tools).toHaveAttribute("inert");
    expect(tools).toHaveAttribute("aria-hidden", "true");
    expect(tools).toContainElement(document.querySelector(".t-attach"));
    expect(document.querySelector(".t-attach")).toBeDisabled();
    expect(screen.queryByRole("button", { name: "Bold (Ctrl+B)" })).toBeNull();
    expect(screen.queryByRole("button", { name: "Attach a file" })).toBeNull();
    expect(tools).not.toContainElement(button); // the mic is not one of them
    const bars = Array.from(button.querySelectorAll<HTMLElement>(".mic-bars > i"));
    expect(bars).toHaveLength(LEVEL_BARS);
    const bar = (i: number) => Number(bars[i]!.style.getPropertyValue("--ak-bar"));
    // silence: the bars rest
    run(100);
    expect(bar(3)).toBe(0);
    // a loud microphone: the middle bar rises first, the halo with it; the edges follow
    level = 0.3;
    run(200);
    expect(bar(3)).toBeGreaterThan(0.8);
    expect(bar(0)).toBe(0);
    expect(Number(button.style.getPropertyValue("--ak-mic-level"))).toBeGreaterThan(0.8);
    for (let i = 1; i <= 12; i++) run(200 + i * 16);
    expect(bar(0)).toBeGreaterThan(0.2);
    expect(bar(0)).toBeLessThan(bar(3));
    // quiet again: they fall, slower than they rose
    level = 0;
    run(420);
    expect(bar(3)).toBeGreaterThan(0.5);
    run(3000);
    expect(bar(3)).toBeLessThan(0.01);
    run(65_900);
    expect(button.querySelector(".mic-time")).toHaveTextContent("1:05");

    fireEvent.click(button);
    await screen.findByText("transcribing…");
    expect(button).toHaveAttribute("data-phase", "stt");
    expect(button).toHaveAttribute("aria-disabled", "true");
    expect(button).toHaveAttribute("title", "Transcribing…");
    expect(button).toHaveAccessibleName("Transcribing");
    expect(frames).toEqual([]); // the pending frame is cancelled: the level is read only while recording
    expect(bars[3]!.style.getPropertyValue("--ak-bar")).toBe("");
    expect(button.style.getPropertyValue("--ak-mic-level")).toBe("");
    fireEvent.click(button); // a click while it transcribes changes nothing
    expect(button).toHaveAttribute("data-phase", "stt");

    vi.useFakeTimers();
    await act(async () => {
      answer({ text: "Done.", words: [w(" Done.", 0.0, 0.3)] });
      await Promise.resolve();
    });
    expect(screen.getByRole("textbox", { name: "Comment" })).toHaveValue("Done.");
    expect(button).toHaveAttribute("data-phase", "done");
    expect(button).toHaveAccessibleName("Dictate");
    expect(bold).toBeEnabled();
    expect(tools).not.toHaveAttribute("inert");
    expect(tools).not.toHaveAttribute("aria-hidden");
    expect(screen.getByRole("button", { name: "Attach a file" })).toBeEnabled();
    act(() => void vi.advanceTimersByTime(2000));
    expect(button).toHaveAttribute("data-phase", "idle");
    vi.useRealTimers();
    vi.unstubAllGlobals();
  });

  it("the words not confirmed yet are tinted behind the text; a failed dictation does not settle as done", async () => {
    const chunks = [new Float32Array(32000).fill(0.1)];
    mic.open = () => Promise.resolve({ sampleRate: 16000, samples: () => chunks, level: () => 0, release: () => {} });
    vi.useFakeTimers({ toFake: ["setInterval", "clearInterval"] });
    const answers = [
      { text: "", words: [{ word: " Ship", start: 0, end: 0.4 }] },
      {
        text: "",
        words: [
          { word: " Ship", start: 0, end: 0.4 },
          { word: " it", start: 0.4, end: 0.7 },
        ],
      },
    ];
    const transcribe = vi.fn(() => {
      const a = answers.shift();
      return a ? Promise.resolve(a) : Promise.reject(new Error("502 · speech server unreachable"));
    });
    const { container } = renderBoardIn({ transcribe, shortcut: ALT_M });
    const box = await screen.findByRole("textbox", { name: "Comment" });
    fireEvent.change(box, { target: { value: "Fix:" } });
    fireEvent.click(screen.getByRole("button", { name: "Dictate" }));
    await screen.findByText(/listening/, undefined, SLOW);
    expect(container.querySelector(".mde-ghost")).toBeNull();
    await act(() => vi.advanceTimersByTimeAsync(2500));
    expect(box).toHaveValue("Fix: Ship");
    expect(container.querySelector(".mde-ghost mark")).toHaveTextContent("Ship"); // nothing agreed yet
    expect(container.querySelector(".mde-ghost")).toHaveTextContent("Fix: Ship");
    await act(() => vi.advanceTimersByTimeAsync(2500));
    expect(box).toHaveValue("Fix: Ship it");
    expect(container.querySelector(".mde-ghost mark")!.textContent).toBe("it"); // "Ship" is confirmed
    vi.useRealTimers();
    fireEvent.click(screen.getByRole("button", { name: "Stop dictation" }));
    expect(await screen.findByRole("alert")).toHaveTextContent("Couldn't transcribe: 502 · speech server unreachable.");
    expect(container.querySelector(".mde-ghost")).toBeNull();
    expect(screen.getByRole("button", { name: "Dictate" })).toHaveAttribute("data-phase", "idle"); // not "done"
  });

  it("a window the speech server did not answer: the pill and the status warn while it retries, then listen again", async () => {
    const chunks = [new Float32Array(32000).fill(0.1)];
    mic.open = () => Promise.resolve({ sampleRate: 16000, samples: () => chunks, level: () => 0, release: () => {} });
    vi.useFakeTimers({ toFake: ["setInterval", "clearInterval"] });
    const answers: (() => Promise<{ text: string; words: { word: string; start: number; end: number }[] }>)[] = [
      () => Promise.reject(new Error("502 · speech server unreachable")),
      () => Promise.resolve({ text: "", words: [w(" Ship", 0, 0.4)] }),
    ];
    const transcribe = vi.fn(() => answers.shift()!());
    const { container } = renderBoardIn({ transcribe, shortcut: ALT_M });
    await screen.findByRole("textbox", { name: "Comment" });
    const button = screen.getByRole("button", { name: "Dictate" });
    fireEvent.click(button);
    await screen.findByText(/listening/, undefined, SLOW);
    const editor = button.closest(".mde")!;
    expect(editor).toHaveClass("has-mic");
    expect(editor).not.toHaveClass("is-warn");
    expect(button).not.toHaveAttribute("data-warn");
    await act(() => vi.advanceTimersByTimeAsync(2500));
    expect(screen.getByRole("status")).toHaveTextContent("can't reach the speech server — retrying");
    expect(screen.getByRole("status")).toHaveClass("is-warn");
    expect(editor).toHaveClass("is-warn"); // the pill, its ring and the editor's border take the warning tone
    expect(button).toHaveAttribute("data-warn");
    expect(button).toHaveAccessibleName("Stop dictation"); // still recording: stop works
    await act(() => vi.advanceTimersByTimeAsync(2500));
    expect(screen.getByRole("status")).toHaveTextContent(/listening/);
    expect(editor).not.toHaveClass("is-warn");
    expect(button).not.toHaveAttribute("data-warn");
    expect(container.querySelector(".mde-ghost mark")).toHaveTextContent("Ship");
    vi.useRealTimers();
  });

  it("the mic keeps its place: one slot beside the tools, still there under Preview while it records", async () => {
    mic.open = () => Promise.resolve(speakingMic());
    renderBoard({ transcribe: () => Promise.resolve({ text: "", words: [] }), shortcut: ALT_M });
    await screen.findByRole("textbox", { name: "Comment" });
    const button = screen.getByRole("button", { name: "Dictate" });
    const slot = button.closest(".mde-dict")!;
    const kit = slot.parentElement!;
    expect(kit).toHaveClass("mde-kit");
    expect(kit.querySelector(".mde-tools")).not.toBeNull();
    fireEvent.click(button);
    const status = await screen.findByText(/listening/, undefined, SLOW);
    expect(slot).toContainElement(status); // the status sits with the pill, out of the bar's flow
    fireEvent.click(within(kit.closest(".mde")!).getByRole("tab", { name: "Preview" }));
    expect(screen.getByRole("button", { name: "Stop dictation" })).toBeInTheDocument(); // a recording never loses its stop
    fireEvent.click(screen.getByRole("button", { name: "Stop dictation" }));
    await waitFor(() => expect(screen.queryByRole("button", { name: "Stop dictation" })).toBeNull(), SLOW);
    expect(screen.queryByRole("button", { name: "Dictate" })).toBeNull(); // idle under Preview: no mic, as before
  });

  it("clock: m:ss", () => {
    expect(clock(0)).toBe("0:00");
    expect(clock(9_999)).toBe("0:09");
    expect(clock(75_000)).toBe("1:15");
    expect(clock(-5)).toBe("0:00");
  });
});
