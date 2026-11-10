// Pure helpers for the workflow editor: a transition's `from` as the editor's checkboxes (column keys in board order)
// and back to the declared form the engine stores — "*" when every column is ticked, one key, else the list.
import type { ApprovalStep, WorkflowTransition } from "../types";

export const ANY = "*";

export function fromKeys(from: string | string[], keys: string[]): string[] {
  if (from === ANY) return [...keys];
  const list = Array.isArray(from) ? from : [from];
  return list.filter((k) => keys.includes(k));
}

export function declareFrom(ticked: string[], keys: string[]): string | string[] {
  const ordered = keys.filter((k) => ticked.includes(k));
  if (ordered.length === keys.length) return ANY;
  return ordered.length === 1 ? ordered[0]! : ordered;
}

// A new row: from the first column to the second, anyone may take it — the name is the operator's to write.
export const blankTransition = (keys: string[]): WorkflowTransition => ({
  name: "",
  from: keys[0] ?? "",
  to: keys[1] ?? keys[0] ?? "",
  by: "any",
});

// The card dialog's Transition list: the transitions out of the card's column the OPERATOR may take (by operator / any),
// one entry per target column (the first declared name wins), each carrying the move to send — the transition's name and
// its column (the column names the target of a "*" fan-out, and makes the server take exactly this edge).
export type OperatorMove = { value: string; label: string; move: { transition: string; column: string } };
export function operatorMoves(ts: { name: string; to: string; to_label: string; by: string }[]): OperatorMove[] {
  const seen = new Set<string>();
  return ts
    .filter((t) => t.by !== "agent" && !seen.has(t.to) && (seen.add(t.to), true))
    .map((t) => ({ value: t.to, label: `${t.name} → ${t.to_label}`, move: { transition: t.name, column: t.to } }));
}

// ── approval steps (Board#approvals) ─────────────────────────────────────────────────────────

// The approve button's text: the step's own name (the gate's named exit — "Approve", "Open public PR", …), so the
// operator reads what the click starts; a final step merges.
export function approveLabel(step: ApprovalStep, label: (k: string) => string): string {
  const { name } = step;
  return step.final ? `✓ ${name} to merge` : `✓ ${name} → ${label(step.to)}`;
}

// The approve button's tooltip: where the card goes and what its agent is pinged to do — every column named off the board.
export function approveTitle(step: ApprovalStep, label: (k: string) => string): string {
  const { name } = step;
  if (step.final)
    return `${name} for merge: the card moves to ${label(step.to)}; the owner agent is pinged to merge it and move the card to ${label(step.then)}`;
  return `${name}: the card moves ${label(step.from)} → ${label(step.to)}; the owner agent is pinged to carry on${step.then ? ` and move the card to ${label(step.then)}` : ""}`;
}

// After the approval: what its agent does next.
export function approvedNext(step: ApprovalStep, label: (k: string) => string): string {
  if (step.final) return `its agent merges and moves it to ${label(step.then)}`;
  return `its agent carries on${step.then ? ` and moves it to ${label(step.then)}` : ""}`;
}
