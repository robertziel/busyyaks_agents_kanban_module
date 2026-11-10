// What the host injects, available to every component below the Board: the api port, who the viewer is (the
// operator's name, as the engine records it), client-side navigation for same-origin links inside rendered markdown
// (a router's navigate; absent = ordinary links), the host config and the project's board (its columns with their
// types, its workflow and the rules derived from them) the server sent.
import { createContext, useContext } from "react";
import type { KanbanApi } from "./api";
import type { BoardShapeData, HostConfig } from "./types";

export type KanbanHostValue = {
  api: KanbanApi;
  me: string;
  config: HostConfig;
  board: BoardShapeData;
  navigate: ((path: string) => void) | null;
  // the host's URL that opens a card on a board (the card dialog's "card #N" chips, the archived list)
  cardHref: ((slug: string, id: number) => string) | null;
};

const Ctx = createContext<KanbanHostValue | null>(null);
export const KanbanHostProvider = Ctx.Provider;

export function useKanbanHost(): KanbanHostValue {
  const v = useContext(Ctx);
  if (!v) throw new Error("agents_kanban: a component rendered outside <Board> (no KanbanHostProvider)");
  return v;
}

// A column's label on this board — a key the board no longer has (an old card's history) shows as the key itself.
export const colLabel = (board: { columns: { key: string; label: string }[] }, k: string): string =>
  board.columns.find((c) => c.key === k)?.label ?? k;
