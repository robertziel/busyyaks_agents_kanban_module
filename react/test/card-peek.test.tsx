// CardPeek: a hover (or focus) on anything with data-card-id opens that card's details after the delay — read once per
// ttl through the host's load, a failed read shown as its reason — and leaving the mention closes it; the placement and
// the id parsing are pure.
import { act, fireEvent, render, screen } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { CardPeek, KanbanApiError, mentionId, PeekCache, peekPlacement, shortName, type CardData } from "../src";

const data = (id: number, over: Record<string, unknown> = {}) =>
  ({
    card: {
      id,
      project: "g/r",
      column: "doing",
      column_label: "In progress",
      title: `Card ${id} title`,
      labels: ["ui"],
      assignee: "worker-a",
      owner_session: "g_r_worker",
      needs_operator: true,
      blocked: null,
      approved: null,
      review_round: null,
      archived: null,
      updated: new Date().toISOString(),
      checklist_done: 1,
      checklist_total: 3,
      due: null,
      due_done: false,
      comments: 0,
      attachments: [],
      blocked_by: [],
      gate_hold: null,
      description: "**why** it matters",
      description_html: "<p><strong>why</strong> it matters</p>",
      ...over,
    },
    activity: [],
  }) as unknown as CardData;

describe("mentionId", () => {
  it("reads a positive integer only", () => {
    expect(mentionId("7")).toBe(7);
    expect(mentionId("0")).toBeNull();
    expect(mentionId("4a")).toBeNull();
    expect(mentionId("")).toBeNull();
    expect(mentionId(null)).toBeNull();
  });
});

describe("peekPlacement", () => {
  const vp = { w: 1000, h: 800 };
  it("goes below a mention in the upper part, above one low on the screen, inside the viewport", () => {
    expect(peekPlacement({ left: 100, right: 140, top: 100, bottom: 120 }, vp)).toEqual({
      left: 100,
      top: 129,
      width: 340,
      arrow: 20,
    });
    expect(peekPlacement({ left: 900, right: 940, top: 700, bottom: 720 }, vp)).toEqual({
      left: 652,
      bottom: 109,
      width: 340,
      arrow: 268,
    });
  });
  it("narrows to a phone's width", () => {
    expect(peekPlacement({ left: 50, right: 90, top: 10, bottom: 30 }, { w: 320, h: 600 })).toEqual({
      left: 8,
      top: 39,
      width: 304,
      arrow: 62,
    });
  });
  it("the arrow points near the start of a wide mention and stays clear of the panel's corners", () => {
    expect(peekPlacement({ left: 100, right: 900, top: 100, bottom: 120 }, vp).arrow).toBe(20);
    expect(peekPlacement({ left: 100, right: 110, top: 100, bottom: 120 }, vp).arrow).toBe(18);
    expect(peekPlacement({ left: 990, right: 998, top: 100, bottom: 120 }, vp).arrow).toBe(322);
  });
});

describe("PeekCache", () => {
  it("reads a card once per ttl and asks again after a failure", async () => {
    let t = 0;
    const c = new PeekCache<number>(1000, () => t);
    const load = vi.fn((id: number) => Promise.resolve(id * 2));
    await c.get(1, load);
    await c.get(1, load);
    expect(load).toHaveBeenCalledTimes(1);
    t = 1000;
    await c.get(1, load);
    expect(load).toHaveBeenCalledTimes(2);
    const bad = vi.fn(() => Promise.reject(new Error("nope")));
    await expect(c.get(2, bad)).rejects.toThrow("nope");
    await expect(c.get(2, bad)).rejects.toThrow("nope");
    expect(bad).toHaveBeenCalledTimes(2);
  });
});

describe("CardPeek", () => {
  beforeEach(() => vi.useFakeTimers());
  afterEach(() => vi.useRealTimers());

  const page = (load: (id: number) => Promise<CardData>) =>
    render(
      <div>
        <CardPeek load={load} delayMs={200} />
        <p>
          see{" "}
          <a href="/x?card=7" data-card-id="7">
            card #7
          </a>{" "}
          and <span>plain</span>
        </p>
      </div>,
    );

  it("opens the card's details after the delay and closes when the pointer leaves", async () => {
    const load = vi.fn((id: number) => Promise.resolve(data(id)));
    page(load);
    const a = screen.getByText("card #7");
    fireEvent.mouseOver(a);
    expect(screen.queryByRole("tooltip")).toBeNull();
    await act(() => vi.advanceTimersByTimeAsync(200));
    const tip = screen.getByRole("tooltip");
    expect(load).toHaveBeenCalledWith(7);
    expect(tip.textContent).toContain("#7");
    expect(tip.textContent).toContain("Card 7 title");
    expect(tip.textContent).toContain("In progress");
    expect(tip.textContent).toContain("? question for you");
    expect(tip.textContent).toContain("ui");
    expect(tip.textContent).toContain("worker-a");
    expect(tip.querySelector(".kb-cl")?.textContent).toBe("checklist items done1/3");
    expect(tip.querySelector(".kb-pill")?.textContent).toBe("In progress");
    expect(tip).toHaveAttribute("data-side", "below");
    expect(tip.style.getPropertyValue("--kb-peek-arrow")).toMatch(/^\d+px$/);
    expect(tip.querySelector(".kb-peek-arrow")).not.toBeNull();
    expect(tip.querySelector(".kb-peek-desc strong")?.textContent).toBe("why");
    fireEvent.mouseOut(a, { relatedTarget: screen.getByText("plain") });
    await act(() => vi.advanceTimersByTimeAsync(200));
    expect(screen.queryByRole("tooltip")).toBeNull();
  });

  it("shows the id and the card's shape while the read runs", async () => {
    let done!: (d: CardData) => void;
    page(() => new Promise<CardData>((r) => (done = r)));
    fireEvent.mouseOver(screen.getByText("card #7"));
    await act(() => vi.advanceTimersByTimeAsync(200));
    const tip = screen.getByRole("tooltip");
    expect(screen.getByRole("status").textContent).toBe("#7loading…");
    expect(tip.querySelectorAll(".kb-peek-bone")).toHaveLength(3);
    await act(async () => {
      done(data(7));
      await Promise.resolve();
    });
    expect(screen.queryByRole("status")).toBeNull();
    expect(tip.textContent).toContain("Card 7 title");
  });

  it("shows the open question, why it is blocked, its PRs, its counts and its due date", async () => {
    const due = new Date(Date.now() - 2 * 86_400_000).toISOString();
    page((id) =>
      Promise.resolve({
        ...data(id, {
          question_html: "<p>Ship <em>now</em>?</p>",
          blocked: { reason: "CI is down", url: "https://ci.example/1", by: "a", at: null },
          blocked_by: [7, 9],
          gate_hold: "PR #7: CI is still running",
          approved: "2026-01-01T00:00:00Z",
          review_round: 2,
          comments: 4,
          attachments: [{}, {}],
          due,
        }),
        links: [
          { kind: "repo", label: "g/r", url: "https://github.com/g/r" },
          { kind: "pr", label: "#5", url: "https://github.com/g/r/pull/5", tags: [{ text: "merged", tone: "ok" }] },
          { kind: "pr", label: "#6", url: "https://github.com/g/r/pull/6" },
          { kind: "pr", label: "#8", url: "https://github.com/g/r/pull/8" },
        ],
      } as unknown as CardData),
    );
    fireEvent.mouseOver(screen.getByText("card #7"));
    await act(() => vi.advanceTimersByTimeAsync(200));
    const tip = screen.getByRole("tooltip");
    expect(tip.querySelector(".kb-peek-ask em")?.textContent).toBe("now");
    expect(tip.querySelector(".kb-extblocked")?.textContent).toBe("blocked externally");
    expect(tip.querySelector(".kb-peek-ext")?.textContent).toBe("CI is down");
    expect(tip.querySelector(".kb-blocked")?.textContent).toBe("⧗ waits for #7, #9");
    expect(tip.querySelector(".kb-held")?.textContent).toBe("⏳ PR #7: CI is still running");
    expect(tip.querySelector(".kb-approved")?.textContent).toBe("✓ approved");
    expect(tip.querySelector(".kb-round")?.textContent).toBe("round 2");
    const prs = [...tip.querySelectorAll(".kb-peek-pr")].map((e) => e.textContent);
    expect(prs).toEqual(["PR #5merged", "PR #6", "+1 PRs"]);
    expect(tip.querySelector(".kb-peek-pr .kb-link-tag")).toHaveClass("t-ok");
    expect(prs).toHaveLength(3);
    expect(tip.textContent).toContain("comments4");
    expect(tip.textContent).toContain("attachments2");
    expect(tip.querySelector(".kb-due")).toHaveClass("d-overdue");
  });

  it("a card nobody holds, with no question, labels or description, says so and shows no empty parts", async () => {
    page((id) =>
      Promise.resolve(
        data(id, {
          assignee: null,
          owner_session: null,
          needs_operator: false,
          labels: [],
          description: "",
          description_html: "",
          checklist_total: 0,
        }),
      ),
    );
    fireEvent.mouseOver(screen.getByText("card #7"));
    await act(() => vi.advanceTimersByTimeAsync(200));
    const tip = screen.getByRole("tooltip");
    expect(tip.querySelector(".kb-peek-who")?.textContent).toBe("nobody on it");
    for (const part of [".kb-peek-ask", ".kb-peek-desc", ".kb-peek-refs", ".kb-cl", ".kb-due", ".kb-asked"])
      expect(tip.querySelector(part)).toBeNull();
  });

  it("shows the server's reason when the card cannot be read", async () => {
    page(() => Promise.reject(new KanbanApiError(404, "no card 7")));
    fireEvent.mouseOver(screen.getByText("card #7"));
    await act(() => vi.advanceTimersByTimeAsync(200));
    const tip = screen.getByRole("tooltip");
    expect(tip.querySelector(".kb-peek-eyebrow")?.textContent).toBe("#7");
    expect(tip.querySelector(".kb-peek-state")?.textContent).toBe("404 · no card 7");
  });

  it("a pointer that passes over the mention quicker than the delay opens nothing", async () => {
    const load = vi.fn((id: number) => Promise.resolve(data(id)));
    page(load);
    const a = screen.getByText("card #7");
    fireEvent.mouseOver(a);
    fireEvent.mouseOut(a, { relatedTarget: screen.getByText("plain") });
    await act(() => vi.advanceTimersByTimeAsync(500));
    expect(load).not.toHaveBeenCalled();
    expect(screen.queryByRole("tooltip")).toBeNull();
  });

  it("Esc closes it and only it (a modal card dialog under it keeps its Esc)", async () => {
    page((id) => Promise.resolve(data(id)));
    const a = screen.getByText("card #7");
    fireEvent.mouseOver(a);
    await act(() => vi.advanceTimersByTimeAsync(200));
    const tip = screen.getByRole("tooltip");
    expect(a).toHaveAttribute("aria-describedby", tip.id);
    const heard = vi.fn();
    document.body.addEventListener("keydown", heard);
    const ev = new KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true });
    act(() => {
      a.dispatchEvent(ev);
    });
    document.body.removeEventListener("keydown", heard);
    expect(ev.defaultPrevented).toBe(true);
    expect(heard).not.toHaveBeenCalled();
    expect(screen.queryByRole("tooltip")).toBeNull();
    expect(a).not.toHaveAttribute("aria-describedby");
  });

  it("keyboard focus on a control holding one mention (an option button) opens it; one holding two opens nothing", async () => {
    const load = vi.fn((id: number) => Promise.resolve(data(id)));
    render(
      <div>
        <CardPeek load={load} delayMs={200} />
        <button type="button">
          Hold <span data-card-id="5">#5</span>
        </button>
        <button type="button">
          <span data-card-id="6">#6</span> or <span data-card-id="7">#7</span>
        </button>
      </div>,
    );
    const [one, two] = screen.getAllByRole("button");
    fireEvent.focusIn(two!);
    await act(() => vi.advanceTimersByTimeAsync(300));
    expect(load).not.toHaveBeenCalled();
    fireEvent.focusIn(one!);
    await act(() => vi.advanceTimersByTimeAsync(200));
    expect(load).toHaveBeenCalledWith(5);
    expect(screen.getByRole("tooltip").textContent).toContain("Card 5 title");
    fireEvent.focusOut(one!, { relatedTarget: two });
    await act(() => vi.advanceTimersByTimeAsync(200));
    expect(screen.queryByRole("tooltip")).toBeNull();
  });
});

describe("shortName", () => {
  it("keeps both ends of a long agent name", () => {
    expect(shortName("worker-a")).toBe("worker-a");
    const n = "claude-demo_project_worker_15";
    const s = shortName(n);
    expect(s.length).toBe(22);
    expect(s.startsWith("claude-")).toBe(true);
    expect(s.endsWith("_worker_15")).toBe(true);
  });
});

describe("CardPeek hover intent", () => {
  beforeEach(() => vi.useFakeTimers());
  afterEach(() => vi.useRealTimers());

  it("back from the panel onto its mention keeps it open (no close-and-reopen), and a second mention switches at once", async () => {
    const load = vi.fn((id: number) => Promise.resolve(data(id)));
    render(
      <div>
        <CardPeek load={load} delayMs={200} />
        <a href="/a" data-card-id="1">
          one
        </a>
        <a href="/b" data-card-id="2">
          two
        </a>
      </div>,
    );
    const one = screen.getByText("one");
    fireEvent.mouseOver(one);
    await act(() => vi.advanceTimersByTimeAsync(200));
    const tip = screen.getByRole("tooltip");
    fireEvent.mouseOut(one, { relatedTarget: tip });
    fireEvent.mouseLeave(tip, { relatedTarget: one });
    fireEvent.mouseOver(one);
    await act(() => vi.advanceTimersByTimeAsync(400));
    expect(screen.getByRole("tooltip")).toBe(tip);
    fireEvent.mouseOver(screen.getByText("two"));
    await act(() => vi.advanceTimersByTimeAsync(0));
    expect(screen.getByRole("tooltip").textContent).toContain("Card 2 title");
  });
});
