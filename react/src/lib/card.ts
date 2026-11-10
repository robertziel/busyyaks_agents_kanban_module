// Quick-add text → a card: a short title plus the rest as the description, so nothing typed or pasted is lost.
// Multi-line: first line is the title. One long line: its first sentence (or a word-boundary cut) is the title
// and the whole text becomes the description.
export const TITLE_MAX = 200; // the engine limit (AgentsKanban::Store::MAX_TITLE)
const SHORT = 120;

export function splitCard(text: string): { title: string; description: string } {
  const t = text.replace(/\r\n?/g, "\n").trim();
  if (!t) return { title: "", description: "" };
  const nl = t.indexOf("\n");
  if (nl >= 0) {
    const first = t.slice(0, nl).trim();
    const rest = t.slice(nl + 1).trim();
    if (first.length <= SHORT) return { title: first, description: rest };
    const head = cut(first);
    return { title: head, description: t };
  }
  if (t.length <= SHORT) return { title: t, description: "" };
  return { title: cut(t), description: t };
}

function cut(s: string): string {
  const sentence = s.match(/^(.{12,}?[.!?])(\s|$)/)?.[1] ?? s.match(/^(.{12,}?)\s[—–-]\s/)?.[1];
  if (sentence && sentence.length <= SHORT) return sentence.trim();
  const slice = s.slice(0, 100);
  const sp = slice.lastIndexOf(" ");
  return `${(sp > 40 ? slice.slice(0, sp) : slice).replace(/[\s,;:(]+$/, "")}…`;
}

// In-card reference chips (server-rendered by CardLinks): "comment #148", or a bare #148 that is an activity on this
// card, links to "#a-148" — the anchor on that activity entry in the dialog.
export const activityAnchorId = (id: number) => `a-${id}`;

// "#a-148" → 148; any other href (a card ?card= link, GitHub, a page anchor) → null.
export function activityAnchor(href: string | null | undefined): number | null {
  const m = /^#a-(\d{1,9})$/.exec(href ?? "");
  return m ? Number(m[1]) : null;
}

// The activity entries that carry someone's words: always shown in the dialog. Every other kind is an event
// (move/edit/owner/handoff/…), shown only with "Show details" — a handoff's and an ask's words are a normal comment.
export const SPOKEN: ReadonlySet<string> = new Set(["comment", "question", "answer"]);

// Jumping to activity id: null when it is not on this card; otherwise whether "Show details" must be switched on first.
export function jumpNeedsDetails(
  activity: { id: number; kind: string }[],
  id: number,
  details: boolean,
): boolean | null {
  const e = activity.find((a) => a.id === id);
  if (!e) return null;
  return !details && !SPOKEN.has(e.kind);
}
