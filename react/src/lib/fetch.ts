// One async resource: what the api answered, the error it raised (kept beside the last good data, never in its
// place), and a reload. Stale-while-revalidate at component scope — the library keeps no global cache, so two hosts
// (or two boards on one page) never share state by accident.
import { useCallback, useEffect, useRef, useState } from "react";

export type Resource<T> = {
  data: T | undefined;
  error: Error | undefined;
  loading: boolean;
  reload: () => Promise<void>;
};

export function useFetch<T>(fn: () => Promise<T>, deps: unknown[]): Resource<T> {
  const [data, setData] = useState<T | undefined>(undefined);
  const [error, setError] = useState<Error | undefined>(undefined);
  const [loading, setLoading] = useState(true);
  const latest = useRef(fn);
  latest.current = fn;
  const seq = useRef(0);
  const reload = useCallback(async () => {
    const n = ++seq.current;
    try {
      const d = await latest.current();
      if (n !== seq.current) return; // a newer call landed meanwhile
      setData(d);
      setError(undefined);
    } catch (e) {
      if (n !== seq.current) return;
      setError(e instanceof Error ? e : new Error(String(e)));
    } finally {
      if (n === seq.current) setLoading(false);
    }
  }, []);
  const version = useDepsVersion(deps);
  useEffect(() => {
    setLoading(true);
    void reload(); // never rejects: a failure is kept in `error`
  }, [version, reload]);
  return { data, error, loading: loading && data === undefined, reload };
}

// A counter that moves when `deps` changes — same length and every item Object.is-equal to the last render's, as React
// compares a dependency list — so a caller-supplied list can drive an effect whose own list is a literal.
function useDepsVersion(deps: unknown[]): number {
  const last = useRef<{ deps: unknown[]; version: number } | null>(null);
  const prev = last.current;
  if (!prev || prev.deps.length !== deps.length || prev.deps.some((d, i) => !Object.is(d, deps[i]))) {
    last.current = { deps, version: (prev?.version ?? 0) + 1 };
  }
  return last.current!.version;
}
