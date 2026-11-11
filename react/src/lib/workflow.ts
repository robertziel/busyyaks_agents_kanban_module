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
// `step` = the approval step out of the card's column, `gated` = the host asks green CI of an explicit approval: the
// step's own transition is then refused while CI is not green, so the operator's other edge into the same column (the
// catch-all "Move" — an approval that asks no CI, like a drag) is listed beside it, never hidden behind it.
export type OperatorMove = { value: string; label: string; move: { transition: string; column: string } };
type Out = { name: string; to: string; to_label: string; by: string };
export function operatorMoves(ts: Out[], step: ApprovalStep | null = null, gated = false): OperatorMove[] {
  const seen = new Set<string>();
  const moves: OperatorMove[] = [];
  for (const t of ts) {
    if (t.by === "agent") continue;
    const alongStep = !!step && gated && t.to === step.to;
    const free = alongStep && t.name.toLowerCase() !== step.name.toLowerCase();
    const value = free ? `${t.to}:free` : t.to;
    if (seen.has(value)) continue;
    seen.add(value);
    const label = `${t.name} → ${t.to_label}${free ? " (CI not asked)" : ""}`;
    moves.push({ value, label, move: { transition: t.name, column: t.to } });
  }
  return moves;
}

// ── approval steps (Board#approvals) ─────────────────────────────────────────────────────────

// The approval step a card is AT (the card dialog's approve box): waiting in the step's `from` (a gate); approved in
// its `to`; or sitting UNAPPROVED in a `to` that is itself a gate — the operator dragged it there from elsewhere, its
// agent never leaves a gate unapproved, so the operator approves it where it sits (`inPlace`, Store#approve).
export type StepAt = { step: ApprovalStep; inPlace: boolean };
export function stepAt(approvals: ApprovalStep[], gates: string[], column: string, approved: boolean): StepAt | null {
  const from = approvals.find((a) => a.from === column);
  if (from) return { step: from, inPlace: false };
  const into = approvals.find((a) => a.to === column);
  if (into && (approved || gates.includes(column))) return { step: into, inPlace: !approved };
  return null;
}

// The approve button's text: the step's own name (the gate's named exit — "Approve", "Open public PR", …), so the
// operator reads what the click starts; a final step merges; in place the card stays where it is.
export function approveLabel(step: ApprovalStep, label: (k: string) => string, inPlace = false): string {
  const { name } = step;
  if (step.final) return `✓ ${name} to merge`;
  return inPlace ? `✓ ${name} in ${label(step.to)}` : `✓ ${name} → ${label(step.to)}`;
}

// The approve button's tooltip: where the card goes and what its agent is pinged to do — every column named off the board.
export function approveTitle(step: ApprovalStep, label: (k: string) => string, inPlace = false): string {
  const { name } = step;
  const where = inPlace ? `the card stays in ${label(step.to)}` : null;
  if (step.final)
    return `${name} for merge: ${where ?? `the card moves to ${label(step.to)}`}; the owner agent is pinged to merge it and move the card to ${label(step.then)}`;
  return `${name}: ${where ?? `the card moves ${label(step.from)} → ${label(step.to)}`}; the owner agent is pinged to carry on${step.then ? ` and move the card to ${label(step.then)}` : ""}`;
}

// After the approval: what its agent does next.
export function approvedNext(step: ApprovalStep, label: (k: string) => string): string {
  if (step.final) return `its agent merges and moves it to ${label(step.then)}`;
  return `its agent carries on${step.then ? ` and moves it to ${label(step.then)}` : ""}`;
}
