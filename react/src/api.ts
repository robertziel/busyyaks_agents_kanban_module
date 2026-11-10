// The transport PORT: the Board and the CardDialog call these and nothing else — no fetch, no URL, no CSRF, no
// router inside the library. A host implements it over its own JSON routes (busyyaks: /api/cards/:id/move with the
// session cookie + X-CSRF-Token; content_app: its Rails routes with the devise-jwt bearer). Every method resolves with the
// engine's JSON or rejects with an Error whose `status` (when known) and `message` are the server's {error} — the
// components show them verbatim, never a substitute.
import type {
  Attachment,
  BoardData,
  BoardShape,
  BoardShapeData,
  CardData,
  LaunchesData,
  LaunchResult,
  MoveResult,
} from "./types";

export type CardPatch = {
  title?: string;
  description?: string;
  labels?: string[];
  assignee?: string | null;
  priority?: string | null;
  due?: string | null;
  due_done?: boolean;
  cover?: string | null;
  parent?: number | null;
  metadata?: Record<string, unknown> | null;
};

export interface KanbanApi {
  board(slug: string, opts: { archived: boolean }): Promise<BoardData>;
  boardRev(slug: string, opts: { archived: boolean }): Promise<string>;
  card(id: number): Promise<CardData>;
  cardRev(id: number): Promise<string>;
  createCard(slug: string, body: { title: string; column: string; description?: string }): Promise<CardData>;
  move(id: number, body: { column?: string; transition?: string; position?: number }): Promise<MoveResult>;
  update(id: number, patch: CardPatch): Promise<CardData>;
  assign(id: number, assignee: string): Promise<CardData>; // "" unassigns
  archive(id: number, archived: boolean): Promise<CardData>;
  setOwner(id: number, session: string): Promise<CardData>; // "" clears
  approve(id: number, approved: boolean): Promise<CardData>;
  dialogAnswer(id: number, key: string): Promise<CardData>;
  comment(id: number, body: string): Promise<CardData>; // + delivered
  commentUpdate(commentId: number, body: string): Promise<CardData>;
  commentDelete(commentId: number): Promise<CardData>;
  checklistCreate(cardId: number, title: string): Promise<CardData>;
  checklistUpdate(id: number, title: string): Promise<CardData>;
  checklistDelete(id: number): Promise<CardData>;
  itemCreate(checklistId: number, body: string): Promise<CardData>;
  itemUpdate(id: number, patch: { body?: string; done?: boolean }): Promise<CardData>;
  itemDelete(id: number): Promise<CardData>;
  itemConvert(id: number): Promise<CardData>;
  labelCreate(slug: string, name: string, color: string): Promise<unknown>;
  labelUpdate(id: number, patch: { name?: string; color?: string }): Promise<unknown>;
  labelDelete(id: number): Promise<unknown>;
  attach(cardId: number, file: File, onProgress?: (fraction: number) => void): Promise<Attachment>;
  attachmentDelete(id: number): Promise<CardData>;
  markdownPreview(body: string, inline: boolean): Promise<string>; // → html
  // a project's board shape (its columns with types + its workflow, kept by the engine per project): read, save (validated
  // server-side as a whole; a column with cards cannot be dropped), reset to the template
  boardShape(slug: string): Promise<BoardShapeData>;
  boardShapeSave(slug: string, shape: BoardShape): Promise<BoardShapeData>;
  boardShapeReset(slug: string): Promise<BoardShapeData>;
}

// The LAUNCH port (the LaunchBar): the types and the cap for a board, and starting a session of a type. A host
// implements it over its own routes (busyyaks: GET /api/projects/:slug/launches, POST /api/launch).
export interface LaunchApi {
  launches(slug: string): Promise<LaunchesData>;
  launch(slug: string, body: { type: string; launcher: string }): Promise<LaunchResult>;
}

// An error the host's api may throw: the server's status + {error}. Any Error works; this one carries the status.
export class KanbanApiError extends Error {
  status: number;
  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

// "422 · title is required" / "network error" — what every error line in the board shows.
export const errMsg = (e: unknown): string => {
  if (e instanceof Error) {
    const s = (e as { status?: unknown }).status;
    return typeof s === "number" && s > 0 ? `${s} · ${e.message}` : e.message;
  }
  return String(e);
};
