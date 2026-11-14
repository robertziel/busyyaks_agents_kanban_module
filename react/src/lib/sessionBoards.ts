// Pure helpers of the session boards list (components/SessionBoards.tsx).
import type { Card, SessionBoard, SessionBoardColumn } from "../types";

export type SessionBoardLane = { column: SessionBoardColumn; cards: Card[] };

// The board's columns in its order, each with its cards in their position order; a card whose column the board does
// not list is an engine bug — thrown, never dropped.
export function sessionBoardLanes(b: SessionBoard): SessionBoardLane[] {
  const lanes = b.columns.map((column) => ({ column, cards: [] as Card[] }));
  for (const c of b.cards) {
    const lane = lanes.find((l) => l.column.key === c.column);
    if (!lane) throw new Error(`session board ${b.slug}: card ${c.id} sits in unknown column ${c.column}`);
    lane.cards.push(c);
  }
  for (const l of lanes) l.cards.sort((x, y) => x.position - y.position || x.id - y.id);
  return lanes;
}

// Seconds left before the board is archived (0 once due; null for an archived board).
export function secondsLeft(b: SessionBoard, nowS: number): number | null {
  if (b.archived || !b.expires) return null;
  return Math.max(0, Math.floor(new Date(b.expires).getTime() / 1000) - nowS);
}

// "23h" / "45m" / "now" — the label of secondsLeft.
export function leftLabel(s: number | null): string {
  if (s == null) return "—";
  if (s <= 0) return "now";
  if (s < 3600) return `${Math.ceil(s / 60)}m`;
  return `${Math.floor(s / 3600)}h`;
}
