// CardPeek's pure parts: which card a mention names, where the panel goes, and the per-card read cache.

// data-card-id="7" → 7; anything that is not a plain positive integer → null (nothing opens).
export function mentionId(v: string | null | undefined): number | null {
  if (!v || !/^\d{1,9}$/.test(v)) return null;
  const n = Number(v);
  return n > 0 ? n : null;
}

export const PEEK_W = 340; // the panel's width (kanban.css .kb-peek keeps the same number)
const GAP = 9; // room for the arrow (kanban.css .kb-peek-arrow: a 10px square turned 45°, its tip 7px out)
const EDGE = 8;
const ARROW_INSET = 18; // the arrow keeps clear of the panel's rounded corners
const ARROW_REACH = 20; // on a wide mention (a whole row) the arrow points near its start, not at its middle

// Below the mention when the lower half of the viewport has room, else above it; left-aligned with it, kept inside the
// viewport (a phone: the panel narrows to the viewport minus its edges). `arrow` = where along the panel's edge its
// arrow sits (px from the panel's left): under the mention's middle, at most ARROW_REACH into a wide one.
export function peekPlacement(
  r: { left: number; right: number; top: number; bottom: number },
  vp: { w: number; h: number },
): { left: number; top?: number; bottom?: number; width: number; arrow: number } {
  const width = Math.min(PEEK_W, vp.w - 2 * EDGE);
  const left = Math.max(EDGE, Math.min(r.left, vp.w - width - EDGE));
  const at = r.left + Math.min((r.right - r.left) / 2, ARROW_REACH) - left;
  const arrow = Math.round(Math.max(ARROW_INSET, Math.min(at, width - ARROW_INSET)));
  if (r.bottom <= vp.h * 0.55) return { left, top: r.bottom + GAP, width, arrow };
  return { left, bottom: vp.h - r.top + GAP, width, arrow };
}

// One read per card per ttl: a hover over the same mention again reuses it. A failed read is not kept (the next hover
// asks again); the failure itself is shown, never an older answer.
export class PeekCache<T> {
  private rows = new Map<number, { at: number; p: Promise<T> }>();
  constructor(
    private ttlMs: number,
    private clock: () => number = () => Date.now(),
  ) {}

  get(id: number, load: (id: number) => Promise<T>): Promise<T> {
    const row = this.rows.get(id);
    if (row && this.clock() - row.at < this.ttlMs) return row.p;
    const p = load(id);
    this.rows.set(id, { at: this.clock(), p });
    p.catch(() => {
      if (this.rows.get(id)?.p === p) this.rows.delete(id);
    });
    return p;
  }
}

// A long agent name keeps both ends ("claude-…_worker_15"): agents share a prefix, the end tells them apart. The full
// name is the title.
export function shortName(name: string, max = 22): string {
  if (name.length <= max) return name;
  const tail = Math.ceil((max - 1) * 0.6);
  return `${name.slice(0, max - 1 - tail)}…${name.slice(-tail)}`;
}
