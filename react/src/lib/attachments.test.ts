import { describe, expect, it } from "vitest";
import { formatBytes, insertAt, pastedName, placeholder, replacePlaceholder } from "./attachments";

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
