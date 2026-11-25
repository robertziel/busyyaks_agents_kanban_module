// One async resource: what the api answered, the error it raised (kept beside the last good data, never in its
// place), and a reload. Stale-while-revalidate at component scope — the library keeps no global cache, so two hosts
// (or two boards on one page) never share state by accident.
import { useCallback, useEffect, useRef, useState } from "react";

export type Resource<T> = {
  data: T | undefined;
  error: Error | undefined;
  loading: boolean;
  // resolves to the outcome of the newest load: null = its data is shown, else its error (kept in `error`); a load a
  // newer one overtook resolves to the newer one's outcome. Never rejects.
  reload: () => Promise<Error | null>;
};

export function useFetch<T>(fn: () => Promise<T>, deps: unknown[]): Resource<T> {
  const [data, setData] = useState<T | undefined>(undefined);
  const [error, setError] = useState<Error | undefined>(undefined);
  const [loading, setLoading] = useState(true);
  const latest = useRef(fn);
  latest.current = fn;
  const seq = useRef(0);
  const newest = useRef<Promise<Error | null> | null>(null);
  const reload = useCallback((): Promise<Error | null> => {
    const n = ++seq.current;
    const load = (async (): Promise<Error | null> => {
      try {
        const d = await latest.current();
        if (n !== seq.current) return newest.current!; // a newer call went out meanwhile: its outcome is the one shown
        setData(d);
        setError(undefined);
        return null;
      } catch (e) {
        if (n !== seq.current) return newest.current!;
        const err = e instanceof Error ? e : new Error(String(e));
        setError(err);
        return err;
      } finally {
        if (n === seq.current) setLoading(false);
      }
    })();
    newest.current = load;
    return load;
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

// A live poll's onChange from a resource's reload: rejects with the reload's error, so useLiveRev asks it again on
// the next poll instead of taking the new revision as shown.
export function refreshOrThrow(reload: Resource<unknown>["reload"]): () => Promise<void> {
  return async () => {
    const e = await reload();
    if (e) throw e;
  };
}
