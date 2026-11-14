import { describe, expect, it } from "vitest";
import { leftLabel, secondsLeft, sessionBoardLanes } from "./sessionBoards";
import type { Card, SessionBoard } from "../types";

const card = (id: number, column: string, position: number) => ({ id, column, position, title: `c${id}` }) as Card;
const board = (over: Partial<SessionBoard> = {}): SessionBoard => ({
  slug: "session:s1",
  session: "s1",
  archived: null,
  last_activity: "2026-11-13T10:00:00Z",
  expires: "2026-11-14T10:00:00Z",
  columns: [
    { key: "todo", label: "To do", type: "queued" },
    { key: "done", label: "Done", type: "done" },
  ],
  cards: [card(3, "todo", 1), card(1, "todo", 0), card(2, "done", 0)],
  ...over,
});

describe("sessionBoardLanes", () => {
  it("keeps the board's column order and sorts cards by position", () => {
    const lanes = sessionBoardLanes(board());
    expect(lanes.map((l) => l.column.key)).toEqual(["todo", "done"]);
    expect(lanes[0]?.cards.map((c) => c.id)).toEqual([1, 3]);
    expect(lanes[1]?.cards.map((c) => c.id)).toEqual([2]);
  });
  it("throws on a card in a column the board does not list", () => {
    expect(() => sessionBoardLanes(board({ cards: [card(9, "gone", 0)] }))).toThrow(/unknown column gone/);
  });
});

describe("secondsLeft / leftLabel", () => {
  const t = Math.floor(new Date("2026-11-13T10:00:00Z").getTime() / 1000);
  it("counts down to expires", () => {
    expect(secondsLeft(board(), t)).toBe(86400);
    expect(leftLabel(secondsLeft(board(), t))).toBe("24h");
    expect(leftLabel(secondsLeft(board(), t + 86400 - 120))).toBe("2m");
    expect(leftLabel(secondsLeft(board(), t + 90000))).toBe("now");
  });
  it("is null for an archived board", () => {
    expect(secondsLeft(board({ archived: "2026-11-14T10:00:00Z" }), t)).toBeNull();
    expect(leftLabel(null)).toBe("—");
  });
});
