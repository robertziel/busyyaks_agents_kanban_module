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
