// Attachment helpers shared by the card dialog and the markdown editor. Pure: no DOM beyond DataTransfer reads.

export function formatBytes(n: number): string {
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`;
  return `${(n / 1024 / 1024).toFixed(1)} MB`;
}

// A drag carries files (not text or a link being dragged around the page).
export function dragHasFiles(dt: DataTransfer | null): boolean {
  return !!dt && Array.from(dt.types ?? []).includes("Files");
}

export function filesOf(dt: DataTransfer | null): File[] {
  if (!dt) return [];
  if (dt.files && dt.files.length) return Array.from(dt.files);
  return Array.from(dt.items ?? [])
    .filter((i) => i.kind === "file")
    .map((i) => i.getAsFile())
    .filter((f): f is File => !!f);
}

// A pasted screenshot arrives as "image.png" (or no name at all): give it a unique, dated name so the attachment list
// tells one paste from the next. The server still decides the type from the bytes.
export function pastedName(file: File, now: Date): string {
  const ext = (file.type.split("/")[1] || "png").replace("jpeg", "jpg").replace(/[^a-z0-9]/gi, "");
  const p = (n: number) => String(n).padStart(2, "0");
  const stamp = `${now.getFullYear()}${p(now.getMonth() + 1)}${p(now.getDate())}-${p(now.getHours())}${p(now.getMinutes())}${p(now.getSeconds())}`;
  return !file.name || /^image\.(png|jpe?g|gif|webp)$/i.test(file.name) ? `pasted-${stamp}.${ext}` : file.name;
}

// The placeholder written into the text while a file uploads; replaced by the snippet (or removed on failure).
export const placeholder = (name: string, key: number) => `![uploading ${name.replace(/[[\]]/g, "")} #${key}…]()`;

// Insert `snippet` at [start, end) as its own paragraph-ish chunk: a newline before unless at a line start, a newline
// after unless one follows. → the new text and the caret after the snippet.
export function insertAt(text: string, start: number, end: number, snippet: string): { text: string; caret: number } {
  const s = Math.max(0, Math.min(start, text.length));
  const e = Math.max(s, Math.min(end, text.length));
  const before = text.slice(0, s);
  const after = text.slice(e);
  const pre = before === "" || before.endsWith("\n") ? "" : "\n";
  const post = after.startsWith("\n") ? "" : "\n";
  const out = `${before}${pre}${snippet}${post}${after}`;
  return { text: out, caret: before.length + pre.length + snippet.length + post.length };
}

// Swap the first occurrence of `from` for `to` (to = "" drops it together with the newline insertAt added after it).
export function replacePlaceholder(text: string, from: string, to: string): string {
  const i = text.indexOf(from);
  if (i < 0) return to ? insertAt(text, text.length, text.length, to).text : text;
  if (to) return text.slice(0, i) + to + text.slice(i + from.length);
  const tail = text.slice(i + from.length);
  return text.slice(0, i) + (tail.startsWith("\n") ? tail.slice(1) : tail);
}
