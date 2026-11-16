// Things that come and go (the agents at work on a card): one that left stays in the list, marked `leaving`, until
// its exit animation ends — the caller's onAnimationEnd calls `gone(key)`. Under prefers-reduced-motion nothing
// lingers: it is gone at once.
import { useCallback, useLayoutEffect, useRef, useState } from "react";

const REDUCED = "(prefers-reduced-motion: reduce)";

export type Lingering<T> = { key: string; item: T; leaving: boolean };

// pure: the items now + what left since `prev` (kept in `leavers` until gone)
export function linger<T>(
  prev: readonly T[],
  leavers: Map<string, T>,
  items: readonly T[],
  keyOf: (t: T) => string,
  instant: boolean,
): Lingering<T>[] {
  const here = new Set(items.map(keyOf));
  if (instant) leavers.clear();
  else for (const p of prev) if (!here.has(keyOf(p))) leavers.set(keyOf(p), p);
  for (const k of here) leavers.delete(k);
  return [
    ...items.map((item) => ({ key: keyOf(item), item, leaving: false })),
    ...[...leavers].map(([key, item]) => ({ key, item, leaving: true })),
  ];
}

export function useLingering<T>(
  items: readonly T[],
  keyOf: (t: T) => string,
): { shown: Lingering<T>[]; gone: (key: string) => void } {
  const prev = useRef<readonly T[]>([]);
  const leavers = useRef(new Map<string, T>());
  const [, bump] = useState(0);
  // render reads the refs and works on a copy; the copy is committed only once React commits this render (a render it
  // throws away changes nothing — no leaver is lost)
  const next = new Map(leavers.current);
  const shown = linger(prev.current, next, items, keyOf, window.matchMedia(REDUCED).matches);
  useLayoutEffect(() => {
    prev.current = items;
    leavers.current = next;
  });
  const gone = useCallback((key: string) => {
    if (leavers.current.delete(key)) bump((n) => n + 1);
  }, []);
  return { shown, gone };
}
