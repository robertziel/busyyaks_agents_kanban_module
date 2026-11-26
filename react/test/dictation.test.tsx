// The comment box's dictation over a fake DictationApi and a fake microphone: the mic shows only when the host injects
// the port; Dictate → listening → Stop puts the words into the comment, which Comment sends; Alt+M anywhere in the card does
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

function fakeApi(extra: Partial<KanbanApi> = {}): KanbanApi & { calls: string[] } {
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
    ...extra,
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

function renderBoardIn(dictation?: DictationApi, extra: Partial<KanbanApi> = {}) {
  const api = fakeApi(extra);
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
    await screen.findByRole("textbox", { name: "Comment" }, SLOW);
    expect(screen.queryByRole("button", { name: "Dictate" })).toBeNull();
  });

  it("Dictate → listening → Stop writes the words into the comment; Comment sends them", async () => {
    mic.open = () => Promise.resolve(speakingMic());
    const transcribe = vi.fn(() =>
      Promise.resolve({
        text: " Ship it today.",
        words: [w(" Ship", 0.0, 0.3), w(" it", 0.3, 0.6), w(" today.", 0.6, 0.9)],
      }),
    );
    const api = renderBoard({ transcribe, shortcut: ALT_M });
    const box = await screen.findByRole("textbox", { name: "Comment" }, SLOW);
    fireEvent.click(screen.getByRole("button", { name: "Dictate" }));
    expect(await screen.findByText(/listening/, undefined, SLOW)).toBeInTheDocument();
    expect(box).toHaveAttribute("readonly");
    fireEvent.click(screen.getByRole("button", { name: "Stop dictation" }));
    await waitFor(() => expect(box).toHaveValue("Ship it today."), SLOW);
    expect(box).not.toHaveAttribute("readonly");
    expect(transcribe).toHaveBeenCalledTimes(1);
    fireEvent.click(screen.getByRole("button", { name: "Comment" }));
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
    const box = await screen.findByRole("textbox", { name: "Comment" }, SLOW);
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
    const box = await screen.findByRole("textbox", { name: "Comment" }, SLOW);
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
    const box = await screen.findByRole("textbox", { name: "Comment" }, SLOW);
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
    await screen.findByRole("textbox", { name: "Comment" }, SLOW);
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
    await screen.findByRole("textbox", { name: "Comment" }, SLOW);
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
    await screen.findByRole("textbox", { name: "Comment" }, SLOW);
    fireEvent.click(screen.getByRole("button", { name: "Dictate" }));
    view.unmount();
    resolve({ sampleRate: 16000, samples: () => [], level: () => 0, release });
    await waitFor(() => expect(release).toHaveBeenCalledTimes(1), SLOW);
  });

  it("a refused microphone and a failed transcription show their reason", async () => {
    mic.open = () => Promise.reject(Object.assign(new Error("Permission denied"), { name: "NotAllowedError" }));
    renderBoard({ transcribe: () => Promise.reject(new Error("502 · speech server unreachable")), shortcut: ALT_M });
    await screen.findByRole("textbox", { name: "Comment" }, SLOW);
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

  it("while it dictates, Comment waits and Ctrl+Enter stops the mic; Esc stops it and keeps the card open", async () => {
    mic.open = () => Promise.resolve(speakingMic());
    const api = renderBoard({
      transcribe: () => Promise.resolve({ text: "", words: [w(" Ship", 0, 0.5)] }),
      shortcut: ALT_M,
    });
    const box = await screen.findByRole("textbox", { name: "Comment" }, SLOW);
    fireEvent.change(box, { target: { value: "Draft" } });
    fireEvent.click(screen.getByRole("button", { name: "Dictate" }));
    await screen.findByText(/listening/, undefined, SLOW);
    expect(screen.getByRole("button", { name: "Comment" })).toBeDisabled();
    fireEvent.keyDown(box, { key: "Enter", code: "Enter", ctrlKey: true });
    await waitFor(() => expect(box).toHaveValue("Draft Ship"), SLOW);
    expect(api.calls).toEqual([]); // nothing was posted
    expect(screen.getByRole("button", { name: "Comment" })).toBeEnabled();
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
    const box = await screen.findByRole("textbox", { name: "Comment" }, SLOW);
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

  it("a kept recording locks the box until Retry or Discard: no edit, no Comment, no Ctrl+Enter, no second recording", async () => {
    mic.open = () => Promise.resolve(speakingMic());
    const transcribe = vi.fn(() => Promise.reject(new Error("speech server unreachable")));
    const { api } = renderBoardIn({ transcribe, shortcut: ALT_M });
    const box = await screen.findByRole("textbox", { name: "Comment" }, SLOW);
    fireEvent.change(box, { target: { value: "Note:" } });
    fireEvent.click(screen.getByRole("button", { name: "Dictate" }));
    await screen.findByText(/listening/, undefined, SLOW);
    fireEvent.click(screen.getByRole("button", { name: "Stop dictation" }));
    expect(await screen.findByRole("alert", undefined, SLOW)).toHaveTextContent("Your recording is kept.");
    expect(box).toHaveAttribute("readonly");
    expect(screen.getByRole("button", { name: "Comment" })).toBeDisabled();
    fireEvent.keyDown(box, { key: "Enter", ctrlKey: true });
    fireEvent.click(screen.getByRole("button", { name: "Dictate" }));
    expect(screen.queryByText(/listening/)).toBeNull();
    fireEvent.click(screen.getByRole("button", { name: "Discard" }));
    expect(screen.queryByRole("alert")).toBeNull();
    expect(box).not.toHaveAttribute("readonly");
    expect(box).toHaveValue("Note:");
    expect(screen.getByRole("button", { name: "Comment" })).toBeEnabled();
    expect(api.calls.filter((c) => c.startsWith("comment"))).toEqual([]);
  });

  it("no upload while it dictates; no dictation while an upload runs", async () => {
    mic.open = () => Promise.resolve(speakingMic());
    let land: (a: { markdown: string }) => void = () => {};
    const attach = vi.fn(() => new Promise((r) => (land = r as typeof land)));
    renderBoardIn({ transcribe: () => Promise.resolve({ text: "hi", words: [w(" hi", 0.0, 0.3)] }), shortcut: ALT_M }, {
      attach,
    } as unknown as Partial<KanbanApi>);
    const box = await screen.findByRole("textbox", { name: "Comment" }, SLOW);
    const file = new File(["x"], "a.png", { type: "image/png" });
    fireEvent.paste(box, { clipboardData: { files: [file], items: [] } });
    expect(attach).toHaveBeenCalledTimes(1);
    fireEvent.click(screen.getByRole("button", { name: "Dictate" }));
    expect(await screen.findByRole("alert")).toHaveTextContent("Wait for the upload to finish");
    expect(screen.queryByText(/listening/)).toBeNull();
    act(() => land({ markdown: "![a.png](/a/1)" }));
    await waitFor(() => expect((box as HTMLTextAreaElement).value).toContain("![a.png](/a/1)"));
    fireEvent.click(screen.getByRole("button", { name: "Dictate" }));
    await screen.findByText(/listening/, undefined, SLOW);
    fireEvent.paste(box, { clipboardData: { files: [file], items: [] } });
    expect(attach).toHaveBeenCalledTimes(1);
  });

  it("a recording that heard nothing says so instead of settling as done", async () => {
    mic.open = () => Promise.resolve(speakingMic());
    mic.open = () => Promise.resolve(speakingMic());
    renderBoard({ transcribe: () => Promise.resolve({ text: "", words: [] }), shortcut: ALT_M });
    await screen.findByRole("textbox", { name: "Comment" }, SLOW);
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
    await screen.findByRole("textbox", { name: "Comment" }, SLOW);
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
    const box = await screen.findByRole("textbox", { name: "Comment" }, SLOW);
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
    await screen.findByRole("textbox", { name: "Comment" }, SLOW);
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
    await screen.findByRole("textbox", { name: "Comment" }, SLOW);
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

// card 662: the quick-add's mic — the spoken words become a card at once (description = the whole text) and it opens
describe("quick-add dictation", () => {
  function renderQuickAdd(dictation?: DictationApi, extra: Partial<KanbanApi> = {}) {
    const created: { title: string; description?: string; column: string }[] = [];
    const onView = vi.fn();
    const api = fakeApi({
      createCard: (_slug, body) => {
        created.push(body);
        return Promise.resolve({ card: { ...theCard, id: 42 }, activity: [] } as unknown as CardData);
      },
      ...extra,
    });
    render(
      <Board
        api={api}
        me="me"
        slug="g/r"
        view={{ card: null, panel: null, archived: false }}
        onView={onView}
        dictation={dictation}
      />,
    );
    return { created, onView };
  }
  const openAdd = async () => {
    fireEvent.click((await screen.findAllByText("+ Add a card", undefined, SLOW))[1]!);
    return screen.getByRole("textbox", { name: /New card title/ });
  };

  it("no DictationApi → no mic beside Add", async () => {
    renderQuickAdd();
    await openAdd();
    expect(screen.queryByRole("button", { name: "Dictate" })).toBeNull();
  });

  it("Dictate → Stop creates the card with the words as title and description, then opens it", async () => {
    mic.open = () => Promise.resolve(speakingMic());
    const transcribe = vi.fn(() =>
      Promise.resolve({
        text: " Fix the login button.",
        words: [w(" Fix", 0, 0.2), w(" the", 0.2, 0.3), w(" login", 0.3, 0.6), w(" button.", 0.6, 0.9)],
      }),
    );
    const { created, onView } = renderQuickAdd({ transcribe, shortcut: null });
    const box = await openAdd();
    fireEvent.click(screen.getByRole("button", { name: "Dictate" }));
    await screen.findByRole("button", { name: "Stop dictation" }, SLOW);
    expect(box).toHaveAttribute("readonly");
    expect(screen.getByRole("button", { name: "Add" })).toBeDisabled();
    fireEvent.click(screen.getByRole("button", { name: "Stop dictation" }));
    await waitFor(() => expect(created).toHaveLength(1), SLOW);
    expect(created[0]).toEqual({
      title: "Fix the login button.",
      description: "Fix the login button.",
      column: created[0]!.column,
    });
    await waitFor(() => expect(onView).toHaveBeenCalledWith({ card: 42, panel: null }), SLOW);
  });

  it("a failed transcription creates nothing and says why; nothing heard creates nothing", async () => {
    mic.open = () => Promise.resolve(speakingMic());
    const transcribe = vi.fn<DictationApi["transcribe"]>(() =>
      Promise.reject(new Error("502 · speech server unreachable")),
    );
    const { created } = renderQuickAdd({ transcribe, shortcut: null });
    await openAdd();
    fireEvent.click(screen.getByRole("button", { name: "Dictate" }));
    fireEvent.click(await screen.findByRole("button", { name: "Stop dictation" }, SLOW));
    expect(await screen.findByRole("alert", undefined, SLOW)).toHaveTextContent(
      "Couldn't transcribe: 502 · speech server unreachable",
    );
    transcribe.mockImplementation(() => Promise.resolve({ text: "", words: [] }));
    fireEvent.click(screen.getByRole("button", { name: "Dictate" }));
    fireEvent.click(await screen.findByRole("button", { name: "Stop dictation" }, SLOW));
    expect(await screen.findByText("Nothing heard.", undefined, SLOW)).toBeInTheDocument();
    expect(created).toHaveLength(0);
  });

  it("text typed before the mic stays in front of the spoken words, in the box and the created card", async () => {
    mic.open = () => Promise.resolve(speakingMic());
    const transcribe = vi.fn(() =>
      Promise.resolve({ text: " login button", words: [w(" login", 0, 0.3), w(" button", 0.3, 0.6)] }),
    );
    const { created } = renderQuickAdd({ transcribe, shortcut: null });
    const box = await openAdd();
    fireEvent.change(box, { target: { value: "Fix the" } });
    fireEvent.click(screen.getByRole("button", { name: "Dictate" }));
    fireEvent.click(await screen.findByRole("button", { name: "Stop dictation" }, SLOW));
    await waitFor(() => expect(created).toHaveLength(1), SLOW);
    expect(created[0]).toMatchObject({ title: "Fix the login button", description: "Fix the login button" });
  });

  it("Cancel while the last words are transcribed creates nothing and opens nothing", async () => {
    mic.open = () => Promise.resolve(speakingMic());
    let answer: (t: { text: string; words: ReturnType<typeof w>[] }) => void = () => {};
    const transcribe = vi.fn<DictationApi["transcribe"]>(() => new Promise((r) => (answer = r)));
    const { created, onView } = renderQuickAdd({ transcribe, shortcut: null });
    await openAdd();
    fireEvent.click(screen.getByRole("button", { name: "Dictate" }));
    fireEvent.click(await screen.findByRole("button", { name: "Stop dictation" }, SLOW));
    await waitFor(() => expect(transcribe).toHaveBeenCalled(), SLOW);
    fireEvent.click(screen.getByRole("button", { name: "Cancel" }));
    await act(async () => {
      answer({ text: " Too late.", words: [w(" Too", 0, 0.3), w(" late.", 0.3, 0.6)] });
      await new Promise((r) => setTimeout(r, 50));
    });
    expect(created).toHaveLength(0);
    expect(onView).not.toHaveBeenCalled();
  });

  it("closing the box another way (another list's + Add a card) stops the recording", async () => {
    const released = vi.fn();
    mic.open = () => Promise.resolve({ ...speakingMic(), release: released });
    const { created } = renderQuickAdd({ transcribe: () => Promise.resolve({ text: "", words: [] }), shortcut: null });
    await openAdd();
    fireEvent.click(screen.getByRole("button", { name: "Dictate" }));
    await screen.findByRole("button", { name: "Stop dictation" }, SLOW);
    fireEvent.click(screen.getAllByText("+ Add a card")[0]!);
    await waitFor(() => expect(released).toHaveBeenCalled(), SLOW);
    expect(screen.queryByRole("button", { name: "Stop dictation" })).toBeNull();
    expect(created).toHaveLength(0);
  });

  it("Enter while it records adds nothing (the words are not final yet)", async () => {
    mic.open = () => Promise.resolve(speakingMic());
    const { created } = renderQuickAdd({ transcribe: () => Promise.resolve({ text: "", words: [] }), shortcut: null });
    const box = await openAdd();
    fireEvent.change(box, { target: { value: "Typed" } });
    fireEvent.click(screen.getByRole("button", { name: "Dictate" }));
    await screen.findByRole("button", { name: "Stop dictation" }, SLOW);
    fireEvent.keyDown(box, { key: "Enter" });
    await act(async () => new Promise((r) => setTimeout(r, 30)));
    expect(created).toHaveLength(0);
  });

  it("a refused microphone says why and the mic is ready again; typing clears the message", async () => {
    mic.open = () => Promise.reject(Object.assign(new Error("Permission denied"), { name: "NotAllowedError" }));
    renderQuickAdd({ transcribe: () => Promise.resolve({ text: "", words: [] }), shortcut: null });
    const box = await openAdd();
    fireEvent.click(screen.getByRole("button", { name: "Dictate" }));
    expect(await screen.findByRole("alert")).toHaveTextContent("Microphone blocked — allow it for this site");
    expect(screen.getByRole("button", { name: "Dictate" })).toHaveAttribute("data-phase", "idle");
    fireEvent.change(box, { target: { value: "typed instead" } });
    expect(screen.queryByRole("alert")).toBeNull();
  });
});

// card 662: the open card's title and description dictate too
describe("title and description dictation", () => {
  const words = { text: " Ship it today.", words: [w(" Ship", 0.0, 0.3), w(" it", 0.3, 0.6), w(" today.", 0.6, 0.9)] };

  it("the title's mic: the words go after the title, the box is read-only while it records, Stop saves it", async () => {
    mic.open = () => Promise.resolve(speakingMic());
    const updates: unknown[] = [];
    renderBoardIn(
      { transcribe: () => Promise.resolve(words), shortcut: null },
      {
        update: (_id, body) => {
          updates.push(body);
          return Promise.resolve({} as CardData);
        },
      },
    );
    const title = await screen.findByRole("textbox", { name: "Title" }, SLOW);
    fireEvent.click(screen.getByRole("button", { name: "Dictate title" }));
    await screen.findByRole("button", { name: "Stop dictation" }, SLOW);
    expect(title).toHaveAttribute("readonly");
    // the words not final yet are already in the box: a blur now would save them without the guard
    await waitFor(() => expect(title).toHaveValue("Talk Ship it today."), { timeout: 6000 });
    fireEvent.blur(title); // a blur while it records saves nothing: the words are not final
    await act(async () => new Promise((r) => setTimeout(r, 30)));
    expect(updates).toHaveLength(0);
    fireEvent.click(screen.getByRole("button", { name: "Stop dictation" }));
    await waitFor(() => expect(updates).toEqual([{ title: "Talk Ship it today." }]), SLOW);
    expect(title).not.toHaveAttribute("readonly");
  });

  it("Esc while the title records stops it and keeps the card open", async () => {
    mic.open = () => Promise.resolve(speakingMic());
    const updates: unknown[] = [];
    const { container } = renderBoardIn(
      { transcribe: () => Promise.resolve(words), shortcut: null },
      {
        update: (_id, body) => {
          updates.push(body);
          return Promise.resolve({} as CardData);
        },
      },
    );
    await screen.findByRole("textbox", { name: "Title" }, SLOW);
    fireEvent.click(screen.getByRole("button", { name: "Dictate title" }));
    await screen.findByRole("button", { name: "Stop dictation" }, SLOW);
    const dialog = container.querySelector("dialog")!;
    fireEvent(dialog, new Event("cancel", { cancelable: true }));
    await waitFor(() => expect(updates).toEqual([{ title: "Talk Ship it today." }]), SLOW);
    expect(dialog).toHaveAttribute("open");
  });

  it("the description editor's mic: words at the caret, Save waits, Esc stops it without closing the editor", async () => {
    mic.open = () => Promise.resolve(speakingMic());
    const updates: unknown[] = [];
    renderBoardIn(
      { transcribe: () => Promise.resolve(words), shortcut: null },
      {
        update: (_id, body) => {
          updates.push(body);
          return Promise.resolve({} as CardData);
        },
      },
    );
    fireEvent.click(await screen.findByText("Add a more detailed description…", undefined, SLOW));
    const box = screen.getByRole("textbox", { name: "Description" });
    const editor = box.closest(".mde")!;
    fireEvent.click(within(editor as HTMLElement).getByRole("button", { name: "Dictate" }));
    await within(editor as HTMLElement).findByRole("button", { name: "Stop dictation" }, SLOW);
    const save = screen.getByRole("button", { name: "Save" });
    expect(save).toBeDisabled();
    fireEvent.keyDown(box, { key: "Escape" });
    await waitFor(() => expect(box).toHaveValue("Ship it today."), SLOW);
    expect(screen.getByRole("textbox", { name: "Description" })).toBe(box); // the editor stayed open
    await waitFor(() => expect(save).not.toBeDisabled(), SLOW);
    fireEvent.click(save);
    await waitFor(() => expect(updates).toEqual([{ description: "Ship it today." }]), SLOW);
  });

  it("a live re-render while the comment records keeps Esc stopping it (the card stays open)", async () => {
    mic.open = () => Promise.resolve(speakingMic());
    const api = fakeApi();
    const dictation = { transcribe: () => Promise.resolve(words), shortcut: null };
    const onView = vi.fn();
    const board = (archived: boolean) => (
      <Board
        api={api}
        me="me"
        slug="g/r"
        view={{ card: 7, panel: null, archived }}
        onView={onView}
        dictation={dictation}
      />
    );
    const view = render(board(false));
    const box = await screen.findByRole("textbox", { name: "Comment" }, SLOW);
    fireEvent.click(within(box.closest(".mde") as HTMLElement).getByRole("button", { name: "Dictate" }));
    await screen.findByRole("button", { name: "Stop dictation" }, SLOW);
    view.rerender(board(true)); // the Board re-renders the open dialog (a live poll does the same)
    view.rerender(board(false));
    const dialog = view.baseElement.querySelector("dialog")!;
    fireEvent(dialog, new Event("cancel", { cancelable: true }));
    await waitFor(() => expect(box).toHaveValue("Ship it today."), SLOW);
    expect(onView).not.toHaveBeenCalledWith(expect.objectContaining({ card: null }));
  });

  it("one microphone at a time: the description's mic stops the title's recording first", async () => {
    let opened = 0;
    mic.open = () => {
      opened++;
      return Promise.resolve(speakingMic());
    };
    const updates: unknown[] = [];
    renderBoardIn(
      { transcribe: () => Promise.resolve(words), shortcut: null },
      {
        update: (_id, body) => {
          updates.push(body);
          return Promise.resolve({} as CardData);
        },
      },
    );
    await screen.findByRole("textbox", { name: "Title" }, SLOW);
    fireEvent.click(screen.getByRole("button", { name: "Dictate title" }));
    await screen.findByRole("button", { name: "Stop dictation" }, SLOW);
    fireEvent.click(screen.getByText("Add a more detailed description…"));
    const editor = screen.getByRole("textbox", { name: "Description" }).closest(".mde") as HTMLElement;
    fireEvent.click(within(editor).getByRole("button", { name: "Dictate" }));
    await waitFor(() => expect(updates).toEqual([{ title: "Talk Ship it today." }]), SLOW); // the title stopped + saved
    await within(editor).findByRole("button", { name: "Stop dictation" }, SLOW);
    expect(screen.getAllByRole("button", { name: "Stop dictation" })).toHaveLength(1);
    expect(opened).toBe(2);
  });

  it("dictating into an existing description puts the words after it (the editor opens with the caret at the end)", async () => {
    mic.open = () => Promise.resolve(speakingMic());
    const withDesc: CardData = {
      card: {
        ...theCard,
        attachments: [],
        description: "Old text.",
        description_html: "<p>Old text.</p>",
        checklists: [],
      },
      activity: [],
      pings: [],
      links: [],
    };
    renderBoardIn(
      { transcribe: () => Promise.resolve(words), shortcut: null },
      { card: () => Promise.resolve(withDesc) },
    );
    fireEvent.click(await screen.findByRole("button", { name: "Edit" }, SLOW));
    const box = screen.getByRole("textbox", { name: "Description" });
    const editor = box.closest(".mde") as HTMLElement;
    fireEvent.click(within(editor).getByRole("button", { name: "Dictate" }));
    fireEvent.click(await within(editor).findByRole("button", { name: "Stop dictation" }, SLOW));
    await waitFor(() => expect(box).toHaveValue("Old text. Ship it today."), SLOW);
  });
});

// card 662: a Cancel while the dictated card is still being created: the card exists, its dialog does not open
describe("quick-add dictation, a Cancel during the create", () => {
  it("the card is made, its dialog does not open", async () => {
    mic.open = () => Promise.resolve(speakingMic());
    let made: (d: CardData) => void = () => {};
    const created: unknown[] = [];
    const onView = vi.fn();
    const api = fakeApi({
      createCard: (_slug, body) => {
        created.push(body);
        return new Promise<CardData>((r) => (made = r));
      },
    });
    render(
      <Board
        api={api}
        me="me"
        slug="g/r"
        view={{ card: null, panel: null, archived: false }}
        onView={onView}
        dictation={{
          transcribe: () => Promise.resolve({ text: " Fix it.", words: [w(" Fix", 0, 0.3), w(" it.", 0.3, 0.6)] }),
          shortcut: null,
        }}
      />,
    );
    fireEvent.click((await screen.findAllByText("+ Add a card", undefined, SLOW))[1]!);
    fireEvent.click(screen.getByRole("button", { name: "Dictate" }));
    fireEvent.click(await screen.findByRole("button", { name: "Stop dictation" }, SLOW));
    await waitFor(() => expect(created).toHaveLength(1), SLOW);
    fireEvent.click(screen.getByRole("button", { name: "Cancel" }));
    await act(async () => {
      made({ card: { ...theCard, id: 43 }, activity: [] } as unknown as CardData);
      await new Promise((r) => setTimeout(r, 30));
    });
    expect(onView).not.toHaveBeenCalledWith(expect.objectContaining({ card: 43 }));
  });
});
