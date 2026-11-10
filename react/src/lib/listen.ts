// Who is listening on a card and what happened to its last ping (the waiting count is the server's: BoardData.waiting).
// Column sets come from the board config (listened / waiting) — one definition, never repeated here.
import type { Card, Ping } from "../types";

// An assignee but no owner session, in a column where somebody should be working: comments would reach nobody.
export function noListener(
  c: Pick<Card, "assignee" | "owner_session" | "column">,
  listened: readonly string[],
): boolean {
  return !!c.assignee && !c.owner_session && listened.includes(c.column);
}

export type PingLine = { tone: "ok" | "warn" | "bad"; text: string; hint: string | null };

// The latest ping as one line: sent / failed + reason / pending + why it is not delivered yet. "a question is on its
// screen" / "a dialog is on its screen" = the session is blocked on a permission or question dialog: answer it there.
export function pingLine(p: Ping): PingLine {
  const n = p.attempts > 1 ? ` · ${p.attempts} tries` : "";
  if (p.status === "sent") return { tone: "ok", text: `sent to ${p.session}`, hint: null };
  if (p.status === "failed")
    return { tone: "bad", text: `failed · ${p.error ?? "no reason recorded"}${n}`, hint: null };
  const blocked = /question is on its screen|dialog is on its screen/i.test(p.error ?? "");
  return {
    tone: "warn",
    text: `pending${p.error ? ` · ${p.error}` : " · not tried yet"}${n}`,
    hint: blocked
      ? `${p.session} is blocked on a dialog (permission or question) — answer it in the session; the ping is typed in after`
      : null,
  };
}
