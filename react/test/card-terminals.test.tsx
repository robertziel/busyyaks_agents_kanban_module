// The card dialog's Terminals section: the host's cardTerminals renderer is shown for the open card, under its own
// heading; no renderer, or a renderer that answers null for this card, shows no section.
import { render, screen, waitFor } from "@testing-library/react";
import type { ReactNode } from "react";
import { describe, expect, it } from "vitest";
import { Board, type KanbanApi } from "../src";
import type { Card, CardData, CardFull } from "../src/types";
import { boardData, fixture } from "./fixtures";

const coding = fixture("coding");
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

function renderBoard(cardTerminals?: (card: CardFull) => ReactNode) {
  render(
    <Board
      api={fakeApi()}
      me="me"
      slug="g/r"
      view={{ card: 7, panel: null, archived: false }}
      onView={() => {}}
      cardTerminals={cardTerminals}
    />,
  );
}

describe("card terminals slot", () => {
  it("renders the host's terminals for the open card under a Terminals heading", async () => {
    const seen: number[] = [];
    renderBoard((card) => {
      seen.push(card.id);
      return <p>terminal of {card.owner_session}</p>;
    });
    expect(await screen.findByText("terminal of s1")).toBeInTheDocument();
    expect(screen.getByRole("heading", { name: "Terminals" })).toBeInTheDocument();
    expect(seen).toContain(7);
  });

  it("no renderer: no Terminals section", async () => {
    renderBoard();
    await screen.findByRole("heading", { name: "Description" });
    expect(screen.queryByRole("heading", { name: "Terminals" })).toBeNull();
  });

  it("a renderer that answers null for the card: no section", async () => {
    renderBoard(() => null);
    await waitFor(() => expect(screen.getByRole("heading", { name: "Description" })).toBeInTheDocument());
    expect(screen.queryByRole("heading", { name: "Terminals" })).toBeNull();
  });
});
