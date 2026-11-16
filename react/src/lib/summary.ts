// The board header's folded column counts (Board summary="folded"): the empty columns hidden behind one "+N empty"
// toggle, and the columns whose labels share a "<Group>: " prefix merged into one pill ("Build 7") that names its
// non-empty members ("Test 3 · Deploy 4"). Only the board's own labels decide a group — no key is named here.
// Order is the board's; nothing is counted twice: a group's count is its members' sum.

export type SumColumn = { key: string; label: string; count: number };
export type SumItem =
  | { kind: "column"; key: string; label: string; count: number }
  | { kind: "group"; prefix: string; count: number; members: { key: string; label: string; count: number }[] };

const PREFIX = /^([^:]{1,40}):\s+(.+)$/;

// the "<Group>: <rest>" split of a label, or null when it has none
export function labelPrefix(label: string): { prefix: string; rest: string } | null {
  const m = PREFIX.exec(label);
  return m?.[1] && m[2] ? { prefix: m[1].trim(), rest: m[2].trim() } : null;
}

// → the pills to show (non-empty columns, consecutive same-prefix columns as one group) + the empty columns folded away.
// A prefix shared by one column only stays that column's own label.
export function foldSummary(cols: SumColumn[]): { items: SumItem[]; empty: SumColumn[] } {
  const per = new Map<string, number>();
  cols.forEach((c) => {
    const p = labelPrefix(c.label);
    if (p) per.set(p.prefix, (per.get(p.prefix) ?? 0) + 1);
  });
  const items: SumItem[] = [];
  const empty: SumColumn[] = [];
  for (const c of cols) {
    if (c.count === 0) {
      empty.push(c);
      continue;
    }
    const p = labelPrefix(c.label);
    if (!p || (per.get(p.prefix) ?? 0) < 2) {
      items.push({ kind: "column", key: c.key, label: c.label, count: c.count });
      continue;
    }
    const last = items[items.length - 1];
    if (last?.kind === "group" && last.prefix === p.prefix) {
      last.count += c.count;
      last.members.push({ key: c.key, label: p.rest, count: c.count });
    } else {
      items.push({
        kind: "group",
        prefix: p.prefix,
        count: c.count,
        members: [{ key: c.key, label: p.rest, count: c.count }],
      });
    }
  }
  return { items, empty };
}
