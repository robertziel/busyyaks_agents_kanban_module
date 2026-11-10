// The failed-start alert: a modal <dialog> (showModal) with the engine's rows, each reason verbatim; Dismiss / Esc
// remembers the dismissed ids per viewer and a newer failure opens it again; it takes the host's tokens from <html>
// and gives focus back on close.
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { LaunchFailureAlert, unseenFailures, type LaunchFailure } from "../src";

const f = (id: number, session: string): LaunchFailure => ({
  id,
  session,
  project: "g/r",
  type: "lead",
  launcher: "fullclaude",
  launched_by: "op",
  ended: "2026-11-10T10:24:23Z",
  reason: `${session} did not start: Temp directory /tmp/x is owned by uid 0`,
});

describe("unseenFailures", () => {
  it("lists every row not dismissed, whatever its id's order", () => {
    const rows = [f(2, "b"), f(3, "c")]; // 2 ended after 3: still shown once only 3 is dismissed
    expect(unseenFailures(rows, new Set())).toEqual(rows);
    expect(unseenFailures(rows, new Set([3])).map((x) => x.id)).toEqual([2]);
    expect(unseenFailures(rows, new Set([2, 3]))).toEqual([]);
  });
});

describe("LaunchFailureAlert", () => {
  beforeEach(() => window.localStorage.clear());
  afterEach(() => vi.restoreAllMocks());

  it("shows nothing without failures", () => {
    const { container } = render(<LaunchFailureAlert failures={[]} />);
    expect(container.innerHTML).toBe("");
  });

  it("opens a modal with the reasons, Dismiss closes it and a newer failure opens it again", () => {
    const showModal = vi.spyOn(HTMLDialogElement.prototype, "showModal");
    const { rerender } = render(<LaunchFailureAlert failures={[f(2, "g_r_teamlead"), f(1, "g_r_worker")]} />);
    const dialog = screen.getByRole("alertdialog");
    expect(dialog.tagName).toBe("DIALOG");
    expect(showModal).toHaveBeenCalledTimes(1);
    expect((dialog as HTMLDialogElement).open).toBe(true);
    expect(screen.getByText("2 sessions did not start")).toBeTruthy();
    expect(screen.getByText(/g_r_teamlead did not start: Temp directory/)).toBeTruthy();
    expect(document.activeElement?.textContent).toBe("Dismiss");
    fireEvent.click(screen.getByText("Dismiss"));
    expect(screen.queryByRole("alertdialog")).toBeNull();
    expect(window.localStorage.getItem("ak-launch-failure-seen")).toBe("[2,1]");
    rerender(<LaunchFailureAlert failures={[f(2, "g_r_teamlead"), f(1, "g_r_worker")]} />);
    expect(screen.queryByRole("alertdialog")).toBeNull();
    rerender(<LaunchFailureAlert failures={[f(3, "g_r_worker_1"), f(2, "g_r_teamlead")]} />);
    expect(screen.getByText("A session did not start")).toBeTruthy();
    expect(screen.getAllByRole("listitem")).toHaveLength(1);
    fireEvent(screen.getByRole("alertdialog"), new Event("cancel", { cancelable: true })); // Esc on a modal dialog
    expect(screen.queryByRole("alertdialog")).toBeNull();
    expect(window.localStorage.getItem("ak-launch-failure-seen")).toBe("[3,2]");
  });

  it("links each row to the host's project page and gives focus back on Dismiss", () => {
    const before = document.createElement("button");
    document.body.appendChild(before);
    before.focus();
    render(<LaunchFailureAlert failures={[f(1, "g_r_worker")]} projectHref={(s) => `/projects/${s}?tab=board`} />);
    expect(screen.getByText("g/r").getAttribute("href")).toBe("/projects/g/r?tab=board");
    expect(document.activeElement).toBe(screen.getByText("Dismiss"));
    fireEvent.click(screen.getByText("Dismiss"));
    expect(document.activeElement).toBe(before);
    before.remove();
  });

  it("takes the host's --ak-* tokens from <html>, not the .ak-root defaults", () => {
    const root = document.documentElement;
    root.style.setProperty("--ak-panel", "rgb(1, 2, 3)");
    try {
      render(<LaunchFailureAlert failures={[f(1, "g_r_worker")]} />);
      const dialog = screen.getByRole("alertdialog");
      expect(dialog.style.getPropertyValue("--ak-panel")).toBe("rgb(1, 2, 3)");
      expect(dialog.style.getPropertyValue("--ak-ink")).toBe(""); // not set by the host: the default stays
    } finally {
      root.style.removeProperty("--ak-panel");
    }
  });

  it("re-raises itself above a modal dialog opened after it (a card dialog)", async () => {
    render(<LaunchFailureAlert failures={[f(1, "g_r_worker")]} />);
    const alert = screen.getByRole<HTMLDialogElement>("alertdialog");
    const close = vi.spyOn(alert, "close");
    const raise = vi.spyOn(alert, "showModal");
    const card = document.createElement("dialog");
    document.body.appendChild(card);
    card.showModal();
    await waitFor(() => expect(raise).toHaveBeenCalledTimes(1));
    expect(close).toHaveBeenCalledTimes(1);
    expect(alert.open).toBe(true);
    expect(document.activeElement).toBe(screen.getByText("Dismiss"));
    card.close(); // a dialog closing does not raise it again
    await Promise.resolve();
    expect(raise).toHaveBeenCalledTimes(1);
    card.remove();
  });

  it("a dismissal stored earlier is read on mount", () => {
    window.localStorage.setItem("ak-launch-failure-seen", "[5]");
    render(<LaunchFailureAlert failures={[f(5, "old")]} />);
    expect(screen.queryByRole("alertdialog")).toBeNull();
  });
});
