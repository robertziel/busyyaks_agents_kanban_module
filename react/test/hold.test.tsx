// ON HOLD: with the host's optional api.hold, the board header carries an "On hold · N" toggle that swaps
// the columns for the board's cards on hold (api.board with onHold), the composer is gone there, and the card dialog
// puts a card on hold / releases it through api.hold. A host without api.hold shows neither.
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { useState } from "react";
import { describe, expect, it } from "vitest";
import { Board, type BoardView, type KanbanApi } from "../src";
import type { BoardData, Card, CardData } from "../src/types";
import { boardData, fixture } from "./fixtures";

const coding = fixture("coding");

const card = (o: Partial<Card>): Card => ({
  id: 1,
  project: "g/r",
  owner_session: null,
  owner_socket: null,
  approved: null,
  approved_by: null,
  column: "doing",
  position: 0,
  title: "Card",
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
  on_hold: null,
  transitions: [],
  ...o,
});

const normal = card({ id: 1, title: "Shipping now" });
const parked = card({ id: 2, title: "Not public yet", on_hold: { at: "2026-11-20T10:00:00Z", by: "op" } });

function api(withHold: boolean): KanbanApi & { calls: string[] } {
  const calls: string[] = [];
  const view = (onHold: boolean): BoardData => ({
    ...boardData(coding, onHold ? [parked] : [normal]),
    view: onHold ? "on_hold" : "board",
    on_hold_count: 1,
  });
  const cardData = (id: number): CardData => ({
    card: { ...(id === 2 ? parked : normal), attachments: [], description: "", description_html: "", checklists: [] },
    activity: [],
    pings: [],
    links: [],
  });
  const no = () => Promise.reject(new Error("not in this test"));
  const a: KanbanApi & { calls: string[] } = {
    calls,
    board: (_s, o) => {
      calls.push(`board onHold=${String(!!o.onHold)}`);
      return Promise.resolve(view(!!o.onHold));
    },
    boardRev: () => Promise.resolve("r1"),
    card: (id) => Promise.resolve(cardData(id)),
    cardRev: () => Promise.resolve("c1"),
    createCard: no,
    move: no,
    update: no,
    assign: no,
    archive: no,
    setOwner: no,
    approve: no,
    dialogAnswer: no,
    comment: no,
    commentUpdate: no,
    commentDelete: no,
    checklistCreate: no,
    checklistUpdate: no,
    checklistDelete: no,
    itemCreate: no,
    itemUpdate: no,
    itemDelete: no,
    itemConvert: no,
    labelCreate: no,
    labelUpdate: no,
    labelDelete: no,
    attach: no,
    attachmentDelete: no,
    markdownPreview: () => Promise.resolve(""),
    boardShape: no,
    boardShapeSave: no,
    boardShapeReset: no,
  };
  if (withHold)
    a.hold = (id, on) => {
      calls.push(`hold ${id} ${String(on)}`);
      return Promise.resolve(cardData(id));
    };
  return a;
}

function Host({ api, initial }: { api: KanbanApi; initial?: BoardView }) {
  const [view, setView] = useState<BoardView>(initial ?? { card: null, panel: null, archived: false });
  return <Board api={api} me="me" slug="g/r" view={view} onView={(c) => setView((v) => ({ ...v, ...c }))} />;
}

describe("On hold", () => {
  it("the toggle swaps the board's cards for the cards on hold, in the same columns, with no composer", async () => {
    const a = api(true);
    render(<Host api={a} />);
    await screen.findByText("Shipping now");
    expect(screen.getAllByText(/\+ Add a card/).length).toBeGreaterThan(0);
    const toggle = screen.getByRole("button", { name: /On hold · 1/ });
    expect(toggle.getAttribute("aria-pressed")).toBe("false");
    fireEvent.click(toggle);
    await screen.findByText("Not public yet");
    expect(screen.queryByText("Shipping now")).toBeNull();
    expect(screen.getByRole("button", { name: /On hold · 1/ }).getAttribute("aria-pressed")).toBe("true");
    expect(screen.getByRole("status").textContent).toMatch(/hidden from every agent/);
    expect(screen.queryByText(/\+ Add a card/)).toBeNull();
    expect(a.calls).toContain("board onHold=true");
  });

  it("the card dialog puts a card on hold and releases a held one through api.hold", async () => {
    const a = api(true);
    const { unmount } = render(<Host api={a} initial={{ card: 1, panel: null, archived: false }} />);
    fireEvent.click(await screen.findByRole("button", { name: /Put on hold/ }));
    await waitFor(() => expect(a.calls).toContain("hold 1 true"));
    unmount();
    render(<Host api={a} initial={{ card: 2, panel: null, archived: false, onHold: true }} />);
    expect(await screen.findByText(/^on hold /)).toBeTruthy();
    fireEvent.click(await screen.findByRole("button", { name: /Release hold/ }));
    await waitFor(() => expect(a.calls).toContain("hold 2 false"));
  });

  it("a host without api.hold shows no toggle and no button, and never asks for the on-hold view", async () => {
    const a = api(false);
    render(<Host api={a} initial={{ card: 1, panel: null, archived: false, onHold: true }} />);
    await screen.findAllByText("Shipping now");
    expect(screen.queryByRole("button", { name: /On hold/ })).toBeNull();
    expect(screen.queryByRole("button", { name: /Put on hold/ })).toBeNull();
    expect(a.calls.every((c) => c === "board onHold=false")).toBe(true);
  });
});
