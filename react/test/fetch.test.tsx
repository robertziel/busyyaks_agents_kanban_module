// useFetch: the effect re-runs when the caller's deps change — compared item by item like a React
// dependency list — and not when the host merely re-renders with an equal list; a failure is kept beside the data.
import { act, renderHook, waitFor } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { useFetch } from "../src";

describe("useFetch", () => {
  it("loads once per change of deps, not per render", async () => {
    let calls = 0;
    const { result, rerender } = renderHook(
      ({ id, tag }: { id: number; tag: string }) => useFetch(() => Promise.resolve(`${++calls}:${id}`), [id, tag]),
      {
        initialProps: { id: 1, tag: "a" },
      },
    );
    await waitFor(() => expect(result.current.data).toBe("1:1"));
    rerender({ id: 1, tag: "a" }); // a new array, equal items
    rerender({ id: 1, tag: "a" });
    expect(calls).toBe(1);
    rerender({ id: 2, tag: "a" });
    await waitFor(() => expect(result.current.data).toBe("2:2"));
    rerender({ id: 2, tag: "b" });
    await waitFor(() => expect(result.current.data).toBe("3:2"));
    expect(calls).toBe(3);
  });

  it("reads the latest fn and keeps the last good data beside an error", async () => {
    let fail = false;
    const { result } = renderHook(() =>
      useFetch(() => (fail ? Promise.reject(new Error("down")) : Promise.resolve("ok")), []),
    );
    await waitFor(() => expect(result.current.data).toBe("ok"));
    fail = true;
    await act(() => result.current.reload());
    await waitFor(() => expect(result.current.error?.message).toBe("down"));
    expect(result.current.data).toBe("ok");
  });
});
