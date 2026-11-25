// Live updates by polling a revision: every `every` ms (tab visible, not paused) `fetchRev()` → the rev string; when
// it differs from the last one SHOWN, call onChange (the caller refetches). Pausing (a drag, a save in flight) only
// delays: the next poll after it ends catches up. A failed poll is reported, never treated as "no change".
// A revision counts as shown only once onChange settled: one that rejects (the refetch failed) leaves the last shown
// revision as it was, so the next poll refetches again, and its error is the live state's ("refresh failed: …") —
// never a board that silently keeps a card in its old column under a green live mark.
import { useEffect, useRef, useState } from "react";

export type LiveState = { at: number | null; error: string | null };

export function useLiveRev(
  fetchRev: (() => Promise<string>) | null,
  onChange: () => void | Promise<unknown>,
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
        if (last.current !== null && rev !== last.current) {
          try {
            await change.current();
          } catch (e) {
            if (!stop)
              setState((s) => ({ ...s, error: `refresh failed: ${e instanceof Error ? e.message : String(e)}` }));
            return; // `last` stays: the next poll refetches
          }
          if (stop) return;
        }
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
// good value is kept beside a failed poll's error, never replaced by a substitute; a poll in flight is not overlapped
// until it has been pending for 5 intervals (a stalled connection then no longer blocks the next).
// Failures back off: after n failed polls in a row the next waits every × 2^n, at most POLL_BACKOFF_MAX_MS; the first
// success polls at `every` again.
// `opts.key`: what the value is OF (e.g. the board's slug) — a new key drops the value and error at once and polls
// afresh, so one board never shows another's answer. `opts.staleAfter` (ms): a value with no newer answer for that long
// is dropped and the error says "live state unknown: no answer for N s" — an old answer is never shown as live.
export const POLL_BACKOFF_MAX_MS = 30_000;
export function pollDelay(every: number, failures: number): number {
  return Math.min(every * 2 ** failures, Math.max(every, POLL_BACKOFF_MAX_MS));
}
export function useLivePoll<T>(
  fetch: (() => Promise<T>) | null,
  every = 3000,
  opts: { key?: string; staleAfter?: number } = {},
): { value: T | null; error: string | null } {
  const fetcher = useRef(fetch);
  fetcher.current = fetch;
  const [state, setState] = useState<{ value: T | null; error: string | null }>({ value: null, error: null });
  const key = fetch ? 1 : 0;
  const of = opts.key ?? "";
  const staleAfter = opts.staleAfter ?? 0;
  if (staleAfter < 0) throw new Error(`useLivePoll: staleAfter must be ≥ 0 ms, got ${staleAfter}`);
  // a new key: the old key's answer is dropped in this very render, never shown for the new one
  const [shownOf, setShownOf] = useState(of);
  if (shownOf !== of) {
    setShownOf(of);
    setState({ value: null, error: null });
  }

  useEffect(() => {
    if (!key) return;
    let stop = false;
    let staleTimer = 0;
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
        if (!stop) {
          setState({ value, error: null });
          if (staleAfter) {
            window.clearTimeout(staleTimer);
            staleTimer = window.setTimeout(() => {
              if (!stop)
                setState({
                  value: null,
                  error: `live state unknown: no answer for ${Math.round(staleAfter / 1000)} s`,
                });
            }, staleAfter);
          }
        }
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
      window.clearTimeout(staleTimer);
      document.removeEventListener("visibilitychange", vis);
    };
  }, [key, every, of, staleAfter]);

  return state;
}
