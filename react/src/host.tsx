// What the host injects, available to every component below the Board: the api port, who the viewer is (the
// operator's name, as the engine records it), client-side navigation for same-origin links inside rendered markdown
// (a router's navigate; absent = ordinary links), the host's speech-to-text port (absent = no dictation), the card dialog's
// terminals renderer (absent = no Terminals section), the host config and the project's board (its columns with their
// types, its workflow and the rules derived from them) the server sent.
import { createContext, useContext, type ReactNode } from "react";
import type { KanbanApi } from "./api";
import type { DictationApi } from "./lib/dictation";
import type { BoardShapeData, CardFull, HostConfig } from "./types";

export type KanbanHostValue = {
  api: KanbanApi;
  me: string;
  config: HostConfig;
  board: BoardShapeData;
  navigate: ((path: string) => void) | null;
  // the host's URL that opens a card on a board (the card dialog's "card #N" chips, the archived list)
  cardHref: ((slug: string, id: number) => string) | null;
  // speech to text for the comment box (the mic button, its shortcut); null = the host offers none: no mic is shown
  dictation: DictationApi | null;
  // the card dialog's Terminals section: what the host renders for a card's agent sessions (live terminals); null = the
  // host offers none: no section. A host's renderer may answer null for a card with nothing to show (no section either)
  cardTerminals: ((card: CardFull) => ReactNode) | null;
};

const Ctx = createContext<KanbanHostValue | null>(null);
export const KanbanHostProvider = Ctx.Provider;

export function useKanbanHost(): KanbanHostValue {
  const v = useContext(Ctx);
  if (!v) throw new Error("agents_kanban: a component rendered outside <Board> (no KanbanHostProvider)");
  return v;
}

// The host value when a component may render outside a Board (Html inside the CardPeek, which the host mounts once for
// the whole page): null there — no client-side navigation is offered, links are ordinary links.
export function useKanbanHostIfAny(): KanbanHostValue | null {
  return useContext(Ctx);
}

// A column's label on this board — a key the board no longer has (an old card's history) shows as the key itself.
export const colLabel = (board: { columns: { key: string; label: string }[] }, k: string): string =>
  board.columns.find((c) => c.key === k)?.label ?? k;
