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

type Att = {
  id: number;
  comment_id: number | null;
  filename: string;
  size: number;
  uploaded_by: string;
  created: string;
  url: string;
  download_url: string;
};
type Act = { id: number; at: string; kind: string; author: string; body: string };

// The card's attachments as the dialog's strip shows them: newest first (the latest is the first miniature).
export function newestFirst<T extends { id: number; created: string }>(files: T[]): T[] {
  return [...files].sort((a, b) => Date.parse(b.created) - Date.parse(a.created) || b.id - a.id);
}

// attachment id → the comment that shows it: the one it belongs to (comment_id), else the first comment whose markdown
// links it (an agent's kanban_attach, then a comment naming the snippet). A comment_id whose comment is not in the
// activity counts as none. An attachment in no comment is absent.
export function commentOf(files: Att[], activity: Act[]): Map<number, number> {
  const comments = activity.filter((e) => e.kind === "comment").sort((a, b) => a.id - b.id);
  const out = new Map<number, number>();
  for (const a of files) {
    if (a.comment_id != null && comments.some((e) => e.id === a.comment_id)) {
      out.set(a.id, a.comment_id);
      continue;
    }
    const c = comments.find((e) => e.body.includes(`(${a.url})`) || e.body.includes(`(${a.download_url})`));
    if (c) out.set(a.id, c.id);
  }
  return out;
}

// "attached <name> (<size>)" event id → the attachment it logged, for the attachments no comment shows: the timeline
// shows that file where it was added. The event is written in the upload's transaction, so it is joined on the author,
// the name and size it names (sizeMatches) and its time (within SAME_UPLOAD_S of the file's), each file once; an event
// whose file was deleted (or that a comment shows) matches nothing and stays a plain event. The one case its text
// cannot tell apart: two uploads by one author, one name, within SAME_UPLOAD_S and half a size step of each other, the
// first deleted — that event may show the second file (the event row names no attachment id).
export const SAME_UPLOAD_S = 2;
export function eventFiles<T extends Att>(files: T[], activity: Act[], inComment: Map<number, number>): Map<number, T> {
  const left = files.filter((a) => !inComment.has(a.id)).sort((a, b) => a.id - b.id);
  const out = new Map<number, T>();
  for (const e of [...activity].filter((x) => x.kind === "attachment").sort((a, b) => a.id - b.id)) {
    const at = Date.parse(e.at);
    const i = left.findIndex(
      (a) =>
        a.uploaded_by === e.author &&
        e.body.startsWith(`attached ${a.filename} (`) &&
        sizeMatches(e.body.slice(`attached ${a.filename} `.length), a.size) &&
        Math.abs(Date.parse(a.created) - at) <= SAME_UPLOAD_S * 1000,
    );
    if (i < 0) continue;
    out.set(e.id, left.splice(i, 1)[0] as T);
  }
  return out;
}

const UNIT: Record<string, number> = { KB: 1024, MB: 1024 * 1024 };

// "(222.9 KB)" names `bytes`: the engine writes B whole and KB / MB with one decimal, so the file's size in that unit
// is within half a step of the number (either side of a rounding tie: Ruby and JS round ties differently).
export function sizeMatches(text: string, bytes: number): boolean {
  const m = /^\((?:(\d+) B|(\d+\.\d) (KB|MB))\)$/.exec(text);
  if (!m) return false;
  if (m[1] !== undefined) return Number(m[1]) === bytes;
  const unit = UNIT[m[3] ?? ""];
  return unit !== undefined && Math.abs(bytes / unit - Number(m[2])) <= 0.05 + 1e-9;
}
