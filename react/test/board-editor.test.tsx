// The board editor (the Board's "Workflow" button) over a FAKE api: the graph draws every column as a node with its
// type and every non-wildcard transition as an arrow; a column is added (its key from its label), retyped (Select),
// renamed, deleted (the server's refusal with the card ids shown verbatim); a transition is added from/to and edited;
// the board order is changed with ↑ ↓; Save sends the whole draft; Discard drops it; Reset goes through the api.
// The graph is laid out by dagre (lib/graph.ts): natural size, zoom, a nudge by drag, bundles and notes for hubs.
import { fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it, vi } from "vitest";
import { Board, KanbanApiError, layoutGraph, MIN_TEXT_ZOOM, type KanbanApi } from "../src";
import type { BoardShape, BoardShapeData, Card } from "../src/types";
import { boardData, fixture, TYPES } from "./fixtures";

const coding = fixture("coding");
const content = fixture("content");
const legacyV2 = fixture("legacy_v2_prereview");

// a node's box as drawn: its translate() and its rect
function boxOf(node: HTMLElement) {
  const m = /translate\(([\d.]+) ([\d.]+)\)/.exec(node.getAttribute("transform") ?? "")!;
  const rect = node.querySelector("rect")!;
  return {
    x: Number(m[1]),
    y: Number(m[2]),
    w: Number(rect.getAttribute("width")),
    h: Number(rect.getAttribute("height")),
  };
}

function api(f = coding, opts: { refuse?: string } = {}): KanbanApi & { calls: string[]; saved: BoardShape[] } {
  const calls: string[] = [];
  const saved: BoardShape[] = [];
  const cards: Card[] = [];
  let current: BoardShapeData = f.board;
  const none = () => Promise.reject(new Error("not in this test"));
  return {
    calls,
    saved,
    board: () => Promise.resolve({ ...boardData(f, cards), board: current }),
    boardRev: () => Promise.resolve("r1"),
    boardShape: (slug) => (calls.push(`boardShape ${slug}`), Promise.resolve(current)),
    boardShapeSave: (slug, shape) => {
      calls.push(`boardShapeSave ${slug}`);
      if (opts.refuse) return Promise.reject(new KanbanApiError(422, opts.refuse));
      saved.push(shape);
      current = { ...current, ...shape, updated_by: "me", updated: "2026-11-05T09:00:00Z" };
      return Promise.resolve(current);
    },
    boardShapeReset: (slug) => {
      calls.push(`boardShapeReset ${slug}`);
      current = { ...f.board, updated_by: "me", updated: "2026-11-05T09:01:00Z" };
      return Promise.resolve(current);
    },
    card: none,
    cardRev: none,
    createCard: none,
    move: none,
    update: none,
    assign: none,
    archive: none,
    setOwner: none,
    approve: none,
    dialogAnswer: none,
    comment: none,
    commentUpdate: none,
    commentDelete: none,
    checklistCreate: none,
    checklistUpdate: none,
    checklistDelete: none,
    itemCreate: none,
    itemUpdate: none,
    itemDelete: none,
    itemConvert: none,
    labelCreate: none,
    labelUpdate: none,
    labelDelete: none,
    attach: none,
    attachmentDelete: none,
    markdownPreview: none,
  };
}

const host = (a: KanbanApi) => (
  <Board api={a} me="me" slug="g/r" view={{ card: null, panel: null, archived: false }} onView={() => {}} />
);

async function open(a: KanbanApi) {
  render(host(a));
  fireEvent.click(await screen.findByRole("button", { name: "Workflow" }));
  return screen.findByRole("dialog", { name: "Board editor" });
}

describe("BoardEditor", () => {
  it("draws the columns as typed nodes and the transitions as arrows; wildcard ones are listed, not drawn", async () => {
    const dlg = await open(api());
    const nodes = within(dlg).getAllByRole("button", { name: /^Column / });
    expect(nodes.map((n) => n.getAttribute("aria-label"))).toEqual([
      "Column Backlog (Parked)",
      "Column To do (Queued)",
      "Column In progress (Working)",
      "Column QA (Review)",
      "Column Human Check (Gate)",
      "Column Ready to merge (Gate)",
      "Column Merged (Done)",
    ]);
    const arrows = within(dlg).getAllByRole("button", { name: /^Transition / });
    // 7 named transitions over 9 (from, to) pairs: Hand over and Fixes needed have two sources each
    expect(arrows).toHaveLength(9);
    expect(arrows[0]!.getAttribute("aria-label")).toBe("Transition Prioritise: Backlog → To do");
    expect(within(dlg).getByRole("group", { name: "Workflow graph: 7 columns, 9 arrows" })).toBeInTheDocument();
    expect(within(dlg).getByText("Move")).toBeInTheDocument(); // the any → any catch-all, in the list
    expect(within(dlg).getByText("any → any · any")).toBeInTheDocument();
  });

  it("a content board draws its four columns and only the list for its catch-all", async () => {
    const dlg = await open(api(content));
    expect(within(dlg).getAllByRole("button", { name: /^Column / })).toHaveLength(4);
    expect(within(dlg).queryAllByRole("button", { name: /^Transition / })).toHaveLength(0);
  });

  it("adds a column (key from the label), retypes it, reorders it, connects it and saves the whole draft", async () => {
    const a = api();
    const dlg = await open(a);
    fireEvent.click(within(dlg).getByRole("button", { name: "+ Column" }));
    const label = within(dlg).getByLabelText<HTMLInputElement>("Column label");
    expect(label.value).toBe("New column");
    fireEvent.change(label, { target: { value: "In staging" } });
    expect(within(dlg).getByText("in_staging")).toBeInTheDocument(); // the new column's key follows its label
    fireEvent.click(within(dlg).getByRole("button", { name: "Column type" }));
    fireEvent.click(
      await within(within(dlg).getByRole("listbox", { name: "Column type" })).findByRole("option", { name: "Review" }),
    );
    expect(within(dlg).getByRole("button", { name: "Column In staging (Review)" })).toBeInTheDocument();
    fireEvent.click(within(dlg).getByRole("button", { name: "Move In staging earlier" }));
    fireEvent.click(within(dlg).getByRole("button", { name: "Move In staging earlier" }));
    // a transition into it, from the first two columns' default then retargeted
    fireEvent.click(within(dlg).getByRole("button", { name: "+ Transition" }));
    fireEvent.change(within(dlg).getByLabelText("Transition name"), { target: { value: "Deploy" } });
    fireEvent.click(within(dlg).getByRole("button", { name: "Transition to" }));
    fireEvent.click(
      await within(within(dlg).getByRole("listbox", { name: "Transition to" })).findByRole("option", {
        name: "In staging",
      }),
    );
    const from = within(dlg).getByRole("group", { name: "Transition from" });
    fireEvent.click(within(from).getByLabelText("Backlog")); // untick the default
    fireEvent.click(within(from).getByLabelText("QA"));
    expect(within(dlg).getByRole("button", { name: "Transition Deploy: QA → In staging" })).toBeInTheDocument();
    fireEvent.click(within(dlg).getByRole("button", { name: "Save" }));
    await waitFor(() => expect(a.saved).toHaveLength(1));
    const s = a.saved[0]!;
    expect(s.columns.map((c) => c.key)).toEqual([
      "backlog",
      "todo",
      "doing",
      "qa",
      "human_check",
      "in_staging",
      "ready",
      "merged",
    ]); // added last, moved earlier twice
    const added = s.columns.find((c) => c.key === "in_staging")!;
    expect(added).toEqual({ key: "in_staging", label: "In staging", type: "review", hide_after_hours: 72 }); // no position: the layout is automatic
    expect(s.transitions[s.transitions.length - 1]).toEqual({
      name: "Deploy",
      from: "qa",
      to: "in_staging",
      by: "any",
    });
    expect(s.transitions.find((t) => t.name === "Move")!.from).toBe("*"); // "*" round-trips
    expect(await within(dlg).findByText(/saved by me/)).toBeInTheDocument();
  });

  it("clicking an arrow edits it: name, who takes it, delete", async () => {
    const a = api();
    const dlg = await open(a);
    fireEvent.click(within(dlg).getByRole("button", { name: "Transition Approve: Human Check → Ready to merge" }));
    const name = within(dlg).getByLabelText<HTMLInputElement>("Transition name");
    expect(name.value).toBe("Approve");
    fireEvent.change(name, { target: { value: "Ship it" } });
    fireEvent.click(within(dlg).getByRole("button", { name: "Transition taken by" }));
    fireEvent.click(
      await within(within(dlg).getByRole("listbox", { name: "Transition taken by" })).findByRole("option", {
        name: "anyone",
      }),
    );
    expect(
      within(dlg).getByRole("button", { name: "Transition Ship it: Human Check → Ready to merge" }),
    ).toBeInTheDocument();
    fireEvent.click(within(dlg).getByRole("button", { name: "Transition Merge: Ready to merge → Merged" }));
    fireEvent.click(within(dlg).getByRole("button", { name: "Delete transition" }));
    expect(within(dlg).queryByRole("button", { name: /^Transition Merge/ })).toBeNull();
    fireEvent.click(within(dlg).getByRole("button", { name: "Save" }));
    await waitFor(() => expect(a.saved).toHaveLength(1));
    expect(a.saved[0]!.transitions.find((t) => t.name === "Ship it")).toEqual({
      name: "Ship it",
      from: "human_check",
      to: "ready",
      by: "any",
    });
    expect(a.saved[0]!.transitions.some((t) => t.name === "Merge")).toBe(false);
  });

  it("deleting a column drops it and its arrows from the draft; the server's refusal (cards in it) is shown verbatim and the draft kept", async () => {
    const a = api(coding, {
      refuse: "cannot remove a column with cards: QA (qa) holds cards #4, #9 — move them first",
    });
    const dlg = await open(a);
    fireEvent.click(within(dlg).getByRole("button", { name: "Column QA (Review)" }));
    fireEvent.click(within(dlg).getByRole("button", { name: "Delete column QA" }));
    expect(within(dlg).queryByRole("button", { name: "Column QA (Review)" })).toBeNull();
    expect(within(dlg).queryByRole("button", { name: /→ QA$/ })).toBeNull();
    expect(
      within(dlg).getByRole("button", { name: "Transition Hand over: In progress → Human Check" }),
    ).toBeInTheDocument();
    fireEvent.click(within(dlg).getByRole("button", { name: "Save" }));
    expect(await within(dlg).findByRole("alert")).toHaveTextContent(
      "422 · cannot remove a column with cards: QA (qa) holds cards #4, #9 — move them first",
    );
    expect(within(dlg).getAllByRole("button", { name: /^Column / })).toHaveLength(6); // the draft stays
    fireEvent.click(within(dlg).getByRole("button", { name: "Discard" }));
    expect(within(dlg).getAllByRole("button", { name: /^Column / })).toHaveLength(7);
  });

  it("↑ ↓ change the board order; Reset to template goes through the api", async () => {
    const a = api();
    const dlg = await open(a);
    fireEvent.click(within(dlg).getByRole("button", { name: "Move QA up" }));
    const order = within(dlg).getByRole("region", { name: "Columns in board order" });
    expect(
      within(order)
        .getAllByRole("listitem")
        .map((li) => li.textContent),
    ).toEqual(expect.arrayContaining([expect.stringMatching(/^QA/)]));
    expect(within(order).getAllByRole("listitem")[2]!.textContent).toMatch(/^QA/);
    fireEvent.click(within(dlg).getByRole("button", { name: "Save" }));
    await waitFor(() => expect(a.saved).toHaveLength(1));
    expect(a.saved[0]!.columns.map((c) => c.key)).toEqual([
      "backlog",
      "todo",
      "qa",
      "doing",
      "human_check",
      "ready",
      "merged",
    ]);
    fireEvent.click(within(dlg).getByRole("button", { name: "Reset to template" }));
    await waitFor(() => expect(a.calls).toContain("boardShapeReset g/r"));
  });

  it("on a touch screen: a tap selects a node, a touch drag moves it, a touch drag from a port connects two nodes", async () => {
    const a = api();
    const dlg = await open(a);
    const touch = { pointerType: "touch", pointerId: 7, button: 0, isPrimary: true };
    const node = within(dlg).getByRole("button", { name: "Column Backlog (Parked)" });
    const svg = within(dlg).getByRole("group", { name: /^Workflow graph/ });
    const b0 = boxOf(node);
    // tap = down on the node's box, up on the (pointer-captured) node, then the browser's click lands on the SVG itself
    // (Chromium retargets it to the common ancestor): the selection made on the down must survive that click
    fireEvent.pointerDown(node.querySelector("rect")!, { ...touch, clientX: b0.x + 10, clientY: b0.y + 10 });
    fireEvent.pointerUp(node, { ...touch, clientX: b0.x + 10, clientY: b0.y + 10 });
    fireEvent.click(svg);
    expect(within(dlg).getByRole("region", { name: "Column" })).toBeInTheDocument();
    // a press on the empty canvas deselects
    fireEvent.pointerDown(svg, { ...touch, clientX: 600, clientY: 300 });
    fireEvent.pointerUp(svg, { ...touch });
    expect(within(dlg).queryByRole("region", { name: "Column" })).toBeNull();
    fireEvent.pointerDown(node.querySelector("rect")!, { ...touch, clientX: b0.x + 10, clientY: b0.y + 10 });
    fireEvent.pointerUp(node, { ...touch, clientX: b0.x + 10, clientY: b0.y + 10 });
    expect(
      within(dlg).getByText("Placed by the automatic layout; drag the node to nudge it for this session."),
    ).toBeInTheDocument();
    // the node and its port refuse the browser's pan, so a finger drag reaches the editor (touch-action: none)
    const css = readFileSync(join(__dirname, "..", "src", "styles", "kanban.css"), "utf8");
    expect(css).toMatch(/\.ak-root \.kb-be-node \{[^}]*touch-action: none/);
    expect(css).toMatch(/\.ak-root \.kb-be-port \{[^}]*touch-action: none/);
    // drag by (+50, +60)
    fireEvent.pointerDown(node, { ...touch, clientX: b0.x + 10, clientY: b0.y + 10 });
    fireEvent.pointerMove(svg, { ...touch, clientX: b0.x + 60, clientY: b0.y + 70 });
    fireEvent.pointerUp(svg, { ...touch });
    expect(boxOf(node)).toMatchObject({ x: b0.x + 50, y: b0.y + 60 });
    expect(
      within(dlg).getByText("Dragged aside for this session; Auto-layout puts it back. Positions are not saved."),
    ).toBeInTheDocument();
    // a cancelled pointer (the browser took the gesture) ends the drag without a move
    fireEvent.pointerDown(node, { ...touch, clientX: b0.x + 60, clientY: b0.y + 70 });
    fireEvent.pointerCancel(svg, { ...touch });
    fireEvent.pointerMove(svg, { ...touch, clientX: 400, clientY: 400 });
    expect(boxOf(node)).toMatchObject({ x: b0.x + 50, y: b0.y + 60 });
    expect(
      within(dlg).getByText("Dragged aside for this session; Auto-layout puts it back. Positions are not saved."),
    ).toBeInTheDocument();
    // connect: from Backlog's port onto To do (graph units = client px on the 1:1 jsdom box)
    const b1 = boxOf(within(dlg).getByRole("button", { name: "Column To do (Queued)" }));
    const port = within(dlg).getByLabelText("Connect from Backlog");
    fireEvent.pointerDown(port, { ...touch, clientX: b0.x + 50 + b0.w, clientY: b0.y + 60 + b0.h / 2 });
    fireEvent.pointerMove(svg, { ...touch, clientX: b1.x + 20, clientY: b1.y + 20 });
    fireEvent.pointerUp(svg, { ...touch, clientX: b1.x + 20, clientY: b1.y + 20 });
    expect(within(dlg).getByRole("region", { name: "Transition" })).toBeInTheDocument();
    fireEvent.change(within(dlg).getByLabelText("Transition name"), { target: { value: "Pick" } });
    expect(within(dlg).getByRole("button", { name: "Transition Pick: Backlog → To do" })).toBeInTheDocument();
  });

  it("the graph is drawn at its natural size (the layout's bounds), left to right along the board order; − / + / Fit zoom it", async () => {
    const dlg = await open(api());
    const svg = within(dlg).getByRole("group", { name: /^Workflow graph/ });
    const l = layoutGraph(coding.shape.columns, coding.shape.transitions, {
      typeLabel: (c) => TYPES.find((t) => t.key === c.type)!.label,
    });
    expect(svg.getAttribute("viewBox")).toBe(`0 0 ${l.w} ${l.h}`);
    expect([svg.getAttribute("width"), svg.getAttribute("height")]).toEqual([String(l.w), String(l.h)]); // zoom 1 = 1 unit per px
    const xs = coding.shape.columns.map(
      (c) => boxOf(within(dlg).getByRole("button", { name: new RegExp(`^Column ${c.label} `) })).x,
    );
    for (let i = 1; i < xs.length; i++) expect(xs[i]!).toBeGreaterThan(xs[i - 1]!);
    fireEvent.click(within(dlg).getByRole("button", { name: "Zoom out" }));
    expect(svg.getAttribute("width")).toBe(String(Math.round(l.w * 0.8)));
    fireEvent.click(within(dlg).getByRole("button", { name: "Zoom in" }));
    fireEvent.click(within(dlg).getByRole("button", { name: "Zoom in" }));
    expect(svg.getAttribute("width")).toBe(String(Math.round(l.w * 1.2)));
    fireEvent.click(within(dlg).getByRole("button", { name: "Fit the graph to its box" })); // jsdom: a box of no size = zoom 1
    expect(svg.getAttribute("width")).toBe(String(l.w));
    // labels stay readable at zoom 1: the natural size, never scaled down to a box
    const css = readFileSync(join(__dirname, "..", "src", "styles", "kanban.css"), "utf8");
    const px = (sel: string) =>
      Number(css.match(new RegExp(`${sel.replace(/[.-]/g, "\\$&")} \\{[^}]*font-size: ([\\d.]+)px`))?.[1]);
    expect(px(".ak-root .kb-be-nlabel")).toBeGreaterThanOrEqual(12);
    expect(px(".ak-root .kb-be-elabel")).toBeGreaterThanOrEqual(12);
    expect(css).toMatch(/\.ak-root \.kb-be-graph \{[^}]*align-self: start/); // no empty two thirds: the box is the graph's height
    expect(css).not.toMatch(/\.kb-be-graph svg \{[^}]*min-width/); // never stretched to the box: a stretch would rescale the text
  });

  it("dragging a node nudges it for the session: Save sends no position, Auto-layout puts it back", async () => {
    const a = api();
    const dlg = await open(a);
    const node = within(dlg).getByRole("button", { name: "Column Backlog (Parked)" });
    const svg = within(dlg).getByRole("group", { name: /^Workflow graph/ });
    const b0 = boxOf(node);
    const auto = within(dlg).getByRole("button", { name: "Auto-layout" });
    expect(auto).toBeDisabled();
    fireEvent.pointerDown(node, { clientX: b0.x + 10, clientY: b0.y + 10, button: 0, pointerId: 1 });
    fireEvent.pointerMove(svg, { clientX: b0.x + 110, clientY: b0.y + 60, pointerId: 1 });
    fireEvent.pointerUp(svg, { pointerId: 1 });
    expect(boxOf(node)).toMatchObject({ x: b0.x + 100, y: b0.y + 50 });
    expect(auto).toBeEnabled();
    // the arrow out of the moved node now starts on its new border
    const d = within(dlg)
      .getByRole("button", { name: "Transition Prioritise: Backlog → To do" })
      .querySelector("path.kb-be-line")!
      .getAttribute("d")!;
    const [sx, sy] = d.replace("M ", "").split(" ").slice(0, 2).map(Number) as [number, number];
    expect(sx).toBeGreaterThanOrEqual(b0.x + 100);
    expect(sx).toBeLessThanOrEqual(b0.x + 100 + b0.w + 0.1);
    expect(sy).toBeGreaterThanOrEqual(b0.y + 50);
    // a nudge alone is not a change to save; with a change, Save sends the shape without any position
    expect(within(dlg).getByRole("button", { name: "Save" })).toBeDisabled();
    fireEvent.click(within(dlg).getByRole("button", { name: "Transition Merge: Ready to merge → Merged" }));
    fireEvent.change(within(dlg).getByLabelText("Transition name"), { target: { value: "Ship" } });
    fireEvent.click(within(dlg).getByRole("button", { name: "Save" }));
    await waitFor(() => expect(a.saved).toHaveLength(1));
    expect(a.saved[0]!.columns.map((c) => Object.keys(c).sort())).toEqual(
      coding.shape.columns.map(() => ["hide_after_hours", "key", "label", "type"]),
    );
    // saved: the graph is laid out again from the saved shape (the nudge is for reading, not a stored intent)
    expect(boxOf(within(dlg).getByRole("button", { name: "Column Backlog (Parked)" }))).toMatchObject({
      x: b0.x,
      y: b0.y,
    });
    fireEvent.pointerDown(within(dlg).getByRole("button", { name: "Column Backlog (Parked)" }), {
      clientX: b0.x + 10,
      clientY: b0.y + 10,
      button: 0,
      pointerId: 1,
    });
    fireEvent.pointerMove(svg, { clientX: b0.x + 30, clientY: b0.y + 10, pointerId: 1 });
    fireEvent.pointerUp(svg, { pointerId: 1 });
    expect(boxOf(within(dlg).getByRole("button", { name: "Column Backlog (Parked)" })).x).toBe(b0.x + 20);
    fireEvent.click(within(dlg).getByRole("button", { name: "Auto-layout" }));
    expect(boxOf(within(dlg).getByRole("button", { name: "Column Backlog (Parked)" })).x).toBe(b0.x);
  });

  // the default view at 1920 × 1080: the graph box measured 1435 wide, max-height calc(100vh − 230px) = 850
  for (const name of ["legacy_v2_prereview", "local_v3"] as const) {
    it(`the default view shows the whole ${name} graph at a readable size: folded into rows, no horizontal scroll`, async () => {
      const box = { w: 1435, maxH: 850 };
      const gcs = window.getComputedStyle.bind(window);
      const width = vi.spyOn(Element.prototype, "clientWidth", "get").mockImplementation(function (this: Element) {
        return this.classList.contains("kb-be-graph") ? box.w : 0;
      });
      const style = vi.spyOn(window, "getComputedStyle").mockImplementation((el: Element, pseudo?: string | null) => {
        const st = gcs(el, pseudo);
        if (!el.classList.contains("kb-be-graph")) return st;
        return new Proxy(st, { get: (t, k) => (k === "maxHeight" ? `${box.maxH}px` : (Reflect.get(t, k) as unknown)) });
      });
      try {
        const f = fixture(name);
        const dlg = await open(api(f));
        const svg = within(dlg).getByRole("group", { name: /^Workflow graph/ });
        const [, , vw, vh] = svg.getAttribute("viewBox")!.split(" ").map(Number) as [number, number, number, number];
        const zoom = Number(svg.getAttribute("width")) / vw;
        const l = layoutGraph(f.shape.columns, f.shape.transitions, {
          typeLabel: (c) => TYPES.find((t) => t.key === c.type)!.label,
          maxWidth: (box.w - 2) / MIN_TEXT_ZOOM,
        });
        expect([vw, vh]).toEqual([l.w, l.h]); // the folded layout
        expect(l.rows).toBeGreaterThan(1);
        expect(Number(svg.getAttribute("width"))).toBeLessThanOrEqual(box.w - 2); // no horizontal scroll (the box has a 1px border)
        expect(Number(svg.getAttribute("height"))).toBeLessThanOrEqual(box.maxH - 2); // the whole graph, no vertical scroll
        expect(zoom).toBeGreaterThanOrEqual(MIN_TEXT_ZOOM); // every text ≥ 11px (graph-layout.test.ts: SMALLEST_FONT_PX)
        // − / + leave the automatic zoom; Fit returns to it
        fireEvent.click(within(dlg).getByRole("button", { name: "Zoom in" }));
        expect(Number(svg.getAttribute("width"))).toBe(
          Math.round(vw * Math.min(2, Math.round((zoom + 0.2) * 100) / 100)),
        );
        fireEvent.click(within(dlg).getByRole("button", { name: "Fit the graph to its box" }));
        expect(Number(svg.getAttribute("width"))).toBe(Math.round(vw * zoom));
      } finally {
        width.mockRestore();
        style.mockRestore();
      }
    });
  }

  it("the 13-column legacy v2 board: a transition from 6 columns is ONE bundle (junction + label), not 5 labelled arrows; clicking it edits the transition", async () => {
    const a = api(legacyV2);
    const dlg = await open(a);
    expect(
      within(dlg).getByRole("group", { name: "Workflow graph: 13 columns, 12 arrows, 2 bundles" }),
    ).toBeInTheDocument();
    expect(
      within(dlg).queryAllByRole("button", { name: /^Transition Ask the operator: .* → Human input$/ }),
    ).toHaveLength(1);
    const bundle = within(dlg).getByRole("button", { name: "Transition Ask the operator: 6 columns → Human input" });
    expect(bundle.querySelectorAll("path.kb-be-stub")).toHaveLength(6);
    expect(bundle.querySelector(".kb-be-junction")).not.toBeNull();
    expect(bundle.textContent).toContain("Ask the operator · 6");
    fireEvent.click(bundle);
    expect(within(dlg).getByLabelText<HTMLInputElement>("Transition name").value).toBe("Ask the operator");
    expect(bundle.classList.contains("sel")).toBe(true);
    // every column's full label is drawn (wrapped, never cut)
    const approved = within(dlg).getByRole("button", { name: "Column PR approved (mirror) (Review)" });
    expect([...approved.querySelectorAll("text.kb-be-nlabel")].map((t) => t.textContent)).toEqual([
      "PR approved",
      "(mirror)",
    ]);
  });

  it("a transition from more than half the columns is a NOTE on its target node, not lines; clicking the note edits it", async () => {
    const shape = legacyV2.shape;
    const keys = shape.columns.map((c) => c.key);
    const f = {
      ...legacyV2,
      shape: {
        ...shape,
        transitions: [
          ...shape.transitions,
          {
            name: "Cancel",
            from: keys.filter((k) => k !== "backlog" && k !== "merged"),
            to: "backlog",
            by: "operator" as const,
          },
        ],
      },
    };
    f.board = { ...legacyV2.board, ...f.shape };
    const dlg = await open(api(f));
    expect(
      within(dlg).getByRole("group", { name: "Workflow graph: 13 columns, 12 arrows, 2 bundles, 1 notes" }),
    ).toBeInTheDocument();
    const note = within(dlg).getByRole("button", { name: "Transition Cancel: 11 of 13 columns → Backlog" });
    expect(note.tagName).toBe("text");
    expect(note.textContent).toBe("← Cancel · 11 of 13 columns");
    fireEvent.click(note);
    expect(within(dlg).getByLabelText<HTMLInputElement>("Transition name").value).toBe("Cancel");
    expect(within(dlg).queryByRole("region", { name: "Column" })).toBeNull(); // the click did not select the node
    // a control of its own, not a button inside the node's button; Enter / Space on it select the transition, not the column
    expect(note.closest('[role="button"][aria-label^="Column "]')).toBeNull();
    fireEvent.click(within(dlg).getByRole("button", { name: "Transition Prioritise: Backlog → To do" }));
    expect(within(dlg).getByLabelText<HTMLInputElement>("Transition name").value).toBe("Prioritise");
    fireEvent.keyDown(note, { key: "Enter" });
    expect(within(dlg).getByLabelText<HTMLInputElement>("Transition name").value).toBe("Cancel");
    expect(within(dlg).queryByRole("region", { name: "Column" })).toBeNull();
    fireEvent.keyDown(within(dlg).getByRole("button", { name: "Column Backlog (Parked)" }), { key: " " });
    expect(within(dlg).getByRole("region", { name: "Column" })).toBeInTheDocument();
    // listed beside the any-column transitions
    const list = within(dlg).getByRole("region", { name: "Transitions not drawn as arrows" });
    expect(
      within(list).getByRole("button", { name: /^Cancel note on Backlog: 11 of 13 columns → Backlog · operator$/ }),
    ).toBeInTheDocument();
  });
});
