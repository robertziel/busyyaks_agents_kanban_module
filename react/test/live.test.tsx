// useLiveRev: a revision that changed is seen only once its refresh landed — a refresh that failed is asked again on
// the next poll (one failed refetch would keep a moved card in its old column) and its error is
// the live state's; useFetch.reload resolves to the outcome of the newest load.
import { act, renderHook, waitFor } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { useFetch, useLiveRev } from "../src";

describe("useLiveRev", () => {
  afterEach(() => vi.useRealTimers());

  it("asks a failed refresh again on the next poll, and says it failed meanwhile", async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true });
    let rev = "r1";
    let fail = true;
    let refreshes = 0;
    const onChange = () => {
      refreshes += 1;
      return fail ? Promise.reject(new Error("502 Bad Gateway")) : Promise.resolve();
    };
    const { result } = renderHook(() => useLiveRev(() => Promise.resolve(rev), onChange));
    await vi.advanceTimersByTimeAsync(10);
    expect(refreshes).toBe(0); // the first revision is the baseline
    rev = "r2";
    await vi.advanceTimersByTimeAsync(3000);
    expect(refreshes).toBe(1);
    await waitFor(() => expect(result.current.error).toBe("refresh failed: 502 Bad Gateway"));
    await vi.advanceTimersByTimeAsync(3000); // same revision, still not shown: asked again
    expect(refreshes).toBe(2);
    fail = false;
    await vi.advanceTimersByTimeAsync(3000);
    expect(refreshes).toBe(3);
    await waitFor(() => expect(result.current.error).toBeNull());
    await vi.advanceTimersByTimeAsync(3000); // shown now: nothing more to ask
    expect(refreshes).toBe(3);
  });

  it("a refresh that succeeded is not asked again", async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true });
    let rev = "r1";
    let refreshes = 0;
    renderHook(() =>
      useLiveRev(
        () => Promise.resolve(rev),
        () => {
          refreshes += 1;
        },
      ),
    );
    await vi.advanceTimersByTimeAsync(10);
    rev = "r2";
    await vi.advanceTimersByTimeAsync(9000);
    expect(refreshes).toBe(1);
  });
});

describe("useFetch reload", () => {
  it("resolves to the outcome of the newest load: null when it landed, its error when it failed", async () => {
    let fail = false;
    const { result } = renderHook(() =>
      useFetch(() => (fail ? Promise.reject(new Error("down")) : Promise.resolve("ok")), []),
    );
    await waitFor(() => expect(result.current.data).toBe("ok"));
    let out: Error | null = null;
    await act(async () => {
      out = await result.current.reload();
    });
    expect(out).toBeNull();
    fail = true;
    await act(async () => {
      out = await result.current.reload();
    });
    expect((out as Error | null)?.message).toBe("down");
  });

  it("a load overtaken by a newer one resolves to the newer one's outcome", async () => {
    const gates: { resolve: (v: string) => void; reject: (e: Error) => void }[] = [];
    const { result } = renderHook(() =>
      useFetch(() => new Promise<string>((resolve, reject) => gates.push({ resolve, reject })), []),
    );
    await waitFor(() => expect(gates.length).toBe(1));
    act(() => gates[0]!.resolve("first"));
    await waitFor(() => expect(result.current.data).toBe("first"));
    let older!: Promise<Error | null>;
    let newer!: Promise<Error | null>;
    act(() => {
      older = result.current.reload();
      newer = result.current.reload();
    });
    act(() => gates[1]!.resolve("stale"));
    act(() => gates[2]!.reject(new Error("down")));
    expect((await older)?.message).toBe("down");
    expect((await newer)?.message).toBe("down");
  });
});
