// The LaunchBar over a fake LaunchApi: a pill per type with the type's launchers, the cap line, a greyed pill with
// the cap it hits, a launch through the port, and the server's refusal shown verbatim.
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { LaunchBar, type LaunchApi } from "../src";
import type { Concurrency, LaunchesData, LaunchResult } from "../src/types";

const conc = (running: number, types: Concurrency["types"] = {}): Concurrency => ({
  max_sessions: 3,
  running,
  free: 3 - running,
  sessions: [],
  types,
});
const data = (running = 1, runningHere = 0): LaunchesData => ({
  types: [
    {
      key: "lead",
      label: "Launch",
      launchers: [
        { key: "fullclaude", label: "fullclaude" },
        { key: "localclaude", label: "localclaude" },
      ],
      model: null,
      takes: ["working"],
      max: null,
      max_per_project: 1,
      prompt: true,
      running: runningHere,
      running_here: runningHere,
    },
    {
      key: "plain",
      label: "Plain",
      launchers: [{ key: "fullclaude", label: "fullclaude" }],
      model: null,
      takes: [],
      max: null,
      max_per_project: null,
      prompt: false,
      running: 0,
      running_here: 0,
    },
  ],
  concurrency: conc(running),
  sessions_error: null,
});

function fakeApi(d: LaunchesData, refuse?: string): LaunchApi & { calls: unknown[] } {
  const calls: unknown[] = [];
  return {
    calls,
    launches: () => Promise.resolve(d),
    launch: (slug, body) => {
      calls.push([slug, body]);
      if (refuse) return Promise.reject(Object.assign(new Error(refuse), { status: 422 }));
      const r: LaunchResult = {
        session: "g_r_1",
        type: body.type,
        launcher: body.launcher,
        agent: "claude-g_r_1",
        adopted: [],
        result: { remote_control: "on" },
        concurrency: conc(2),
      };
      return Promise.resolve(r);
    },
  };
}

const lead = () => document.querySelector<HTMLButtonElement>('[data-type="lead"] .ak-launch-main')!;

describe("LaunchBar", () => {
  it("renders a pill per type, the launcher menu for a type with several, and the cap line", async () => {
    render(<LaunchBar api={fakeApi(data())} slug="g/r" refreshEvery={0} />);
    expect(await screen.findByText("1 / 3 running")).toBeInTheDocument();
    expect(lead()).toBeEnabled();
    expect(screen.getByRole("button", { name: "Plain" })).toBeEnabled();
    expect(screen.getByLabelText("Launch launcher")).toBeInTheDocument();
    expect(screen.queryByLabelText("Plain launcher")).toBeNull();
  });

  it("launches through the port with the type and its default launcher and reports the result", async () => {
    const api = fakeApi(data());
    const got: LaunchResult[] = [];
    render(<LaunchBar api={api} slug="g/r" refreshEvery={0} onLaunched={(r) => got.push(r)} />);
    await screen.findByText("1 / 3 running");
    fireEvent.click(lead());
    await waitFor(() => expect(got).toHaveLength(1));
    expect(api.calls).toEqual([["g/r", { type: "lead", launcher: "fullclaude" }]]);
    expect(got[0]!.session).toBe("g_r_1");
  });

  it("greys a type at its cap with the reason, and the host's cap greys every type", async () => {
    render(<LaunchBar api={fakeApi(data(1, 1))} slug="g/r" refreshEvery={0} />);
    await screen.findByText("1 / 3 running");
    expect(lead()).toBeDisabled();
    expect(lead()).toHaveAttribute("title", "1/1 lead already runs for this project");
    expect(screen.getByRole("button", { name: "Plain" })).toBeEnabled();
    render(<LaunchBar api={fakeApi(data(3))} slug="x" refreshEvery={0} />);
    await waitFor(() => expect(screen.getAllByText("3 / 3 running")).toHaveLength(1));
    const plains = screen.getAllByRole("button", { name: "Plain" });
    expect(plains[1]).toBeDisabled();
    expect(plains[1]).toHaveAttribute("title", "3/3 sessions running — the host's cap");
  });

  it("shows the server's refusal verbatim and says when the sessions are unknown", async () => {
    const api = fakeApi(
      data(),
      "2/2 team sessions are running — this type's cap (agent_types[team].max): a (team, p), b (team, q)",
    );
    render(<LaunchBar api={api} slug="g/r" refreshEvery={0} />);
    fireEvent.click(await screen.findByRole("button", { name: "Plain" }));
    expect(await screen.findByText(/422 · 2\/2 team sessions are running/)).toBeInTheDocument();
    const down = fakeApi({ ...data(), concurrency: null, sessions_error: "launcher not reachable" });
    render(<LaunchBar api={down} slug="g/r" refreshEvery={0} />);
    expect(await screen.findByText("sessions unknown: launcher not reachable")).toBeInTheDocument();
  });

  it("a type following the board's lead launches with the lead's launcher, its menu locked with who is followed", async () => {
    const d = data();
    d.types.push({
      key: "team",
      label: "Sub team",
      launchers: [
        { key: "fullclaude", label: "fullclaude" },
        { key: "localclaude", label: "localclaude" },
      ],
      model: null,
      takes: [],
      max: null,
      max_per_project: null,
      prompt: true,
      running: 0,
      running_here: 0,
      launcher_follows: "lead",
      follows: { type: "lead", session: "g_r_teamlead", launcher: "localclaude" },
    });
    const api = fakeApi(d);
    render(<LaunchBar api={api} slug="g/r" refreshEvery={0} />);
    await screen.findByText("1 / 3 running");
    expect(screen.getByLabelText("Sub team launcher")).toBeDisabled();
    expect(document.querySelector('[data-type="team"] .ak-launch-menu-wrap')).toHaveAttribute(
      "title",
      "follows the lead session g_r_teamlead (localclaude)",
    );
    expect(screen.getByLabelText("Sub team launcher")).toHaveTextContent("localclaude");
    fireEvent.click(document.querySelector<HTMLButtonElement>('[data-type="team"] .ak-launch-main')!);
    await waitFor(() => expect(api.calls).toEqual([["g/r", { type: "team", launcher: "localclaude" }]]));
  });
});
