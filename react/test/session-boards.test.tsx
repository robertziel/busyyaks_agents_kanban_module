// The session boards list: read-only lanes per session; an archived board says only when it was archived; a card link
// (focus) marks its board and card and scrolls the card into view.
import { render, screen } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { SessionBoards, type Card, type SessionBoardsData } from "../src";

const card = (id: number, column: string, title: string) => ({ id, column, position: id, title }) as Card;
const data: SessionBoardsData = {
  idle_hours: 24,
  slug_prefix: "session:",
  session_boards: [
    {
      slug: "session:s1",
      session: "s1",
      archived: null,
      last_activity: "2026-11-13T10:00:00Z",
      expires: "2026-11-14T10:00:00Z",
      columns: [
        { key: "todo", label: "To do", type: "queued" },
        { key: "done", label: "Done", type: "done" },
      ],
      cards: [card(1, "todo", "Plan"), card(2, "done", "Ship")],
    },
    {
      slug: "session:old",
      session: "old",
      archived: "2026-11-12T10:00:00Z",
      last_activity: "2026-11-12T10:00:00Z",
      expires: null,
      columns: [{ key: "todo", label: "To do", type: "queued" }],
      cards: [],
    },
  ],
};
const nowS = Math.floor(new Date("2026-11-13T12:00:00Z").getTime() / 1000);

describe("SessionBoards", () => {
  afterEach(() => vi.restoreAllMocks());

  it("draws each board's lanes and when it archives; an archived one only its date", () => {
    render(<SessionBoards data={data} nowS={nowS} />);
    const live = screen.getByRole("region", { name: "session s1" });
    expect(live.textContent).toContain("2 cards");
    expect(live.textContent).toContain("archives in 22h");
    expect(live.textContent).toContain("To do · 1");
    const old = screen.getByRole("region", { name: "session old" });
    expect(old.textContent).toMatch(/archived \d{4}-\d{2}-\d{2}/);
    expect(old.textContent).not.toContain("active");
  });

  it("focus marks the board and the card and scrolls the card into view", () => {
    const scroll = vi.fn();
    Element.prototype.scrollIntoView = scroll;
    render(<SessionBoards data={data} nowS={nowS} focus={{ session: "s1", card: 2 }} />);
    expect(screen.getByRole("region", { name: "session s1" }).className).toContain("ak-sb-focus");
    const li = screen.getByText("Ship").closest("li");
    expect(li?.getAttribute("aria-current")).toBe("true");
    expect(scroll).toHaveBeenCalledWith({ block: "center" });
  });

  it("says so when there is none", () => {
    render(<SessionBoards data={{ ...data, session_boards: [] }} />);
    expect(screen.getByText(/0 session boards · archived after 24 h idle/)).toBeTruthy();
  });
});
