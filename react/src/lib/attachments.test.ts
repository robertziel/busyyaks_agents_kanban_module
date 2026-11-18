import { describe, expect, it } from "vitest";
import {
  commentOf,
  eventFiles,
  formatBytes,
  insertAt,
  newestFirst,
  pastedName,
  placeholder,
  replacePlaceholder,
  sizeMatches,
} from "./attachments";

describe("formatBytes", () => {
  it("scales", () => {
    expect(formatBytes(0)).toBe("0 B");
    expect(formatBytes(1023)).toBe("1023 B");
    expect(formatBytes(1536)).toBe("1.5 KB");
    expect(formatBytes(25 * 1024 * 1024)).toBe("25.0 MB");
  });
});

describe("insertAt", () => {
  it("puts the snippet on its own line in the middle of text", () => {
    expect(insertAt("ab", 1, 1, "X")).toEqual({ text: "a\nX\nb", caret: 4 });
  });
  it("adds no extra newline at a line start or before a newline", () => {
    expect(insertAt("a\n\nb", 2, 2, "X")).toEqual({ text: "a\nX\nb", caret: 3 });
    expect(insertAt("", 0, 0, "X")).toEqual({ text: "X\n", caret: 2 });
  });
  it("replaces a selection and clamps out-of-range offsets", () => {
    expect(insertAt("hello world", 6, 11, "X").text).toBe("hello \nX\n");
    expect(insertAt("ab", 9, 9, "X").text).toBe("ab\nX\n");
  });
});

describe("placeholders", () => {
  const ph = placeholder("shot [1].png", 3);
  it("are unique per upload and contain no brackets from the name", () => {
    expect(ph).toBe("![uploading shot 1.png #3…]()");
  });
  it("are swapped for the snippet", () => {
    const t = insertAt("see", 3, 3, ph).text;
    expect(replacePlaceholder(t, ph, "![shot.png](/api/attachments/7)")).toBe("see\n![shot.png](/api/attachments/7)\n");
  });
  it("are dropped on failure with the newline after them", () => {
    const t = insertAt("a\n", 2, 2, ph).text;
    expect(replacePlaceholder(t, ph, "")).toBe("a\n");
  });
  it("append the snippet when the user deleted the placeholder meanwhile", () => {
    expect(replacePlaceholder("text", ph, "S")).toBe("text\nS\n");
    expect(replacePlaceholder("text", ph, "")).toBe("text");
  });
});

describe("pastedName", () => {
  const at = new Date(2026, 10, 2, 9, 5, 7);
  it("names clipboard screenshots by time", () => {
    expect(pastedName(new File(["x"], "image.png", { type: "image/png" }), at)).toBe("pasted-20261102-090507.png");
    expect(pastedName(new File(["x"], "", { type: "image/jpeg" }), at)).toBe("pasted-20261102-090507.jpg");
  });
  it("keeps a real file name", () => {
    expect(pastedName(new File(["x"], "build.log", { type: "text/plain" }), at)).toBe("build.log");
  });
});

const att = (
  id: number,
  o: Partial<{ comment_id: number | null; filename: string; size: number; uploaded_by: string; created: string }> = {},
) => ({
  id,
  comment_id: o.comment_id ?? null,
  filename: o.filename ?? `f${id}.png`,
  size: o.size ?? 1024,
  uploaded_by: o.uploaded_by ?? "agent",
  created: o.created ?? `2026-11-18T10:00:0${id % 10}+01:00`,
  url: `/api/attachments/${id}`,
  download_url: `/api/attachments/${id}/download`,
});
const ev = (id: number, kind: string, body: string, at = "2026-11-18T10:00:00+01:00", author = "agent") => ({
  id,
  at,
  kind,
  author,
  body,
});

describe("newestFirst", () => {
  it("puts the latest upload first, the higher id first within a second", () => {
    const files = [
      att(1, { created: "2026-11-15T18:00:00+01:00" }),
      att(3, { created: "2026-11-18T09:00:00+01:00" }),
      att(2, { created: "2026-11-18T09:00:00+01:00" }),
    ];
    expect(newestFirst(files).map((a) => a.id)).toEqual([3, 2, 1]);
    expect(files.map((a) => a.id)).toEqual([1, 3, 2]); // the input is not reordered
  });
});

describe("commentOf", () => {
  it("is the comment a file belongs to, else the first comment that links it", () => {
    const files = [att(1, { comment_id: 50 }), att(2), att(3), att(4), att(5, { comment_id: 51 })];
    const activity = [
      ev(50, "comment", "the file's own comment"),
      ev(60, "comment", "see ![f2.png](/api/attachments/2) and [log](/api/attachments/3/download)"),
      ev(70, "comment", "again ![f2.png](/api/attachments/2)"),
      ev(80, "attachment", "attached f4.png (1 KB)"),
      ev(90, "comment", "no file /api/attachments/4 here, nor (/api/attachments/44)"),
    ];
    // 5 belongs to comment 51, which is not in the activity: counted as in no comment
    expect([...commentOf(files, activity)]).toEqual([
      [1, 50],
      [2, 60],
      [3, 60],
    ]);
  });
});

describe("eventFiles", () => {
  it("joins each attachment event to the file it logged: author, name, time", () => {
    const files = [
      att(1, { filename: "a.png", created: "2026-11-18T10:00:00+01:00" }),
      att(2, { filename: "a.png", created: "2026-11-18T11:00:01+01:00" }),
      att(3, { filename: "b.png", created: "2026-11-18T12:00:00+01:00", uploaded_by: "op" }),
      att(4, { filename: "c.png", created: "2026-11-18T13:00:00+01:00" }),
    ];
    const activity = [
      ev(10, "attachment", "attached a.png (1.0 KB)", "2026-11-18T10:00:01+01:00"),
      ev(11, "attachment", "attached a.png (2.0 KB)", "2026-11-18T10:30:00+01:00"), // a deleted upload of the same name
      ev(12, "attachment", "attached a.png (1.0 KB)", "2026-11-18T11:00:00+01:00"),
      ev(13, "attachment", "attached b.png (1.0 KB)", "2026-11-18T12:00:00+01:00"), // another author
      ev(14, "attachment", "attached c.png (1.0 KB)", "2026-11-18T13:00:00+01:00"),
      ev(15, "comment", "attached a.png (1.0 KB)", "2026-11-18T10:00:00+01:00"),
    ];
    const inComment = new Map([[4, 99]]); // a comment shows c.png: its event stays plain
    const got = eventFiles(files, activity, inComment);
    expect([...got].map(([e, a]) => [e, a.id])).toEqual([
      [10, 1],
      [12, 2],
    ]);
  });
});

describe("sizeMatches", () => {
  it("reads the size the engine wrote: B exact, KB / MB within half a step", () => {
    expect(sizeMatches("(1023 B)", 1023)).toBe(true);
    expect(sizeMatches("(1023 B)", 1022)).toBe(false);
    expect(sizeMatches("(222.9 KB)", 228300)).toBe(true);
    expect(sizeMatches("(222.9 KB)", 229000)).toBe(false);
    expect(sizeMatches("(1.2 KB)", 1280)).toBe(true); // a rounding tie (1.25): Ruby's 1.2 …
    expect(sizeMatches("(1.3 KB)", 1280)).toBe(true); // … or JS's 1.3
    expect(sizeMatches("(1.1 MB)", 1153434)).toBe(true);
    expect(sizeMatches("(1.1 KB)", 1153434)).toBe(false);
    expect(sizeMatches("(1 KB)", 1024)).toBe(false);
    expect(sizeMatches("(1.0 KB) extra", 1024)).toBe(false);
  });
});

describe("eventFiles and sizes", () => {
  it("a deleted upload's event never shows the next file of the same name a second later", () => {
    const files = [att(2, { filename: "a.png", size: 2048, created: "2026-11-18T10:00:01+01:00" })];
    const activity = [
      ev(10, "attachment", "attached a.png (1.0 KB)", "2026-11-18T10:00:00+01:00"), // the deleted 1 KB a.png
      ev(11, "attachment", "attached a.png (2.0 KB)", "2026-11-18T10:00:01+01:00"),
    ];
    expect([...eventFiles(files, activity, new Map())].map(([e, a]) => [e, a.id])).toEqual([[11, 2]]);
  });
});
