// Live updates by polling a revision: every `every` ms (tab visible, not paused) `fetchRev()` → the rev string; when
// it differs from the last one seen, call onChange (the caller refetches). Pausing (a drag, a save in flight) only
// delays: the next poll after it ends catches up. A failed poll is reported, never treated as "no change".
import { useEffect, useRef, useState } from "react";

export type LiveState = { at: number | null; error: string | null };

export function useLiveRev(
  fetchRev: (() => Promise<string>) | null,
  onChange: () => void,
  opts: { every?: number; paused?: () => boolean } = {},
): LiveState {
  const every = opts.every ?? 3000;
  const last = useRef<string | null>(null);
  const change = useRef(onChange);
  const paused = useRef(opts.paused);
  const fetcher = useRef(fetchRev);
  change.current = onChange;
  paused.current = opts.paused;
  fetcher.current = fetchRev;
  const [state, setState] = useState<LiveState>({ at: null, error: null });
  const key = fetchRev ? 1 : 0;

  useEffect(() => {
    if (!key) return;
    last.current = null;
    let stop = false;
    // a slow poll is never overlapped by the next one (no pile-up on a slow server); one that has not settled after
    // 5 intervals (a stalled connection) no longer blocks: the next tick goes out
    let inFlightSince = 0;
    const tick = async () => {
      if (stop || document.hidden || paused.current?.() || !fetcher.current) return;
      if (inFlightSince && Date.now() - inFlightSince < every * 5) return;
      const mine = Date.now();
      inFlightSince = mine;
      try {
        const rev = await fetcher.current();
        if (stop) return;
        if (last.current !== null && rev !== last.current) change.current();
        last.current = rev;
        setState({ at: Date.now(), error: null });
      } catch (e) {
        if (!stop) setState((s) => ({ ...s, error: e instanceof Error ? e.message : String(e) }));
      } finally {
        if (inFlightSince === mine) inFlightSince = 0;
      }
    };
    void tick();
    const id = window.setInterval(() => void tick(), every);
    const vis = () => void tick();
    document.addEventListener("visibilitychange", vis);
    return () => {
      stop = true;
      window.clearInterval(id);
      document.removeEventListener("visibilitychange", vis);
    };
  }, [key, every]);

  return state;
}

// A value polled every `every` ms while the tab is visible (fetch null = nothing to poll: value stays null). The last
// good value is kept beside a failed poll's error, never replaced by a substitute; a slow poll is never overlapped.
// Failures back off: after n failed polls in a row the next waits every × 2^n, at most POLL_BACKOFF_MAX_MS; the first
// success polls at `every` again.
export const POLL_BACKOFF_MAX_MS = 30_000;
export function pollDelay(every: number, failures: number): number {
  return Math.min(every * 2 ** failures, Math.max(every, POLL_BACKOFF_MAX_MS));
}
export function useLivePoll<T>(
  fetch: (() => Promise<T>) | null,
  every = 3000,
): { value: T | null; error: string | null } {
  const fetcher = useRef(fetch);
  fetcher.current = fetch;
  const [state, setState] = useState<{ value: T | null; error: string | null }>({ value: null, error: null });
  const key = fetch ? 1 : 0;

  useEffect(() => {
    if (!key) return;
    let stop = false;
    // as useLiveRev: one that has not settled after 5 intervals (a stalled connection) no longer blocks the next
    let inFlightSince = 0;
    let failures = 0;
    let lastAt = 0;
    const tick = async () => {
      if (stop || document.hidden || !fetcher.current) return;
      if (inFlightSince && Date.now() - inFlightSince < every * 5) return;
      if (failures && Date.now() - lastAt < pollDelay(every, failures) - every / 2) return; // backing off
      const mine = Date.now();
      inFlightSince = mine;
      lastAt = mine;
      try {
        const value = await fetcher.current();
        failures = 0;
        if (!stop) setState({ value, error: null });
      } catch (e) {
        failures += 1;
        if (!stop) setState((s) => ({ ...s, error: e instanceof Error ? e.message : String(e) }));
      } finally {
        if (inFlightSince === mine) inFlightSince = 0;
      }
    };
    void tick();
    const id = window.setInterval(() => void tick(), every);
    const vis = () => void tick();
    document.addEventListener("visibilitychange", vis);
    return () => {
      stop = true;
      window.clearInterval(id);
      document.removeEventListener("visibilitychange", vis);
    };
  }, [key, every]);

  return state;
}
