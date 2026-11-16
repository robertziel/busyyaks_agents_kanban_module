import { describe, expect, it } from "vitest";
import { foldSummary, labelPrefix } from "./summary";

describe("foldSummary", () => {
  it("folds the empty columns and merges consecutive columns that share a label prefix", () => {
    const r = foldSummary([
      { key: "backlog", label: "Backlog", count: 19 },
      { key: "todo", label: "To do", count: 0 },
      { key: "l_rev", label: "Local: Agent review", count: 0 },
      { key: "l_hr", label: "Local: Human review", count: 3 },
      { key: "l_m", label: "Local: Merged", count: 4 },
      { key: "p_c", label: "Public: Create PR", count: 1 },
      { key: "p_h", label: "Public: Human review", count: 0 },
      { key: "done", label: "Done", count: 45 },
    ]);
    expect(r.empty.map((c) => c.key)).toEqual(["todo", "l_rev", "p_h"]);
    expect(r.items).toEqual([
      { kind: "column", key: "backlog", label: "Backlog", count: 19 },
      {
        kind: "group",
        prefix: "Local",
        count: 7,
        members: [
          { key: "l_hr", label: "Human review", count: 3 },
          { key: "l_m", label: "Merged", count: 4 },
        ],
      },
      { kind: "group", prefix: "Public", count: 1, members: [{ key: "p_c", label: "Create PR", count: 1 }] },
      { kind: "column", key: "done", label: "Done", count: 45 },
    ]);
  });

  it("a prefix only one column has keeps that column's own label", () => {
    const r = foldSummary([
      { key: "a", label: "QA: manual", count: 2 },
      { key: "b", label: "Done", count: 1 },
    ]);
    expect(r.items).toEqual([
      { kind: "column", key: "a", label: "QA: manual", count: 2 },
      { kind: "column", key: "b", label: "Done", count: 1 },
    ]);
  });

  it("labelPrefix splits '<Group>: <rest>' only", () => {
    expect(labelPrefix("Local: Merged")).toEqual({ prefix: "Local", rest: "Merged" });
    expect(labelPrefix("Done")).toBeNull();
    expect(labelPrefix("a:b")).toBeNull();
  });
});
