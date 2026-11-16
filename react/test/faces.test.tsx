// Agent faces: a registered agent wears a yak face coloured by its agent TYPE and moving with its live mood, a person
// keeps the initials; the agents at work on a card right now (the host's presence) stand on the card face and in the
// card dialog, arrive and leave; a host with no presence port shows none.
import { act, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { Avatar, Board, MOODS, typeHue, AgentFace, type KanbanApi } from "../src";
import type { Activity, BoardPresence, Card, CardData, PresentAgent, SessionLive, SessionsLive } from "../src/types";
import { boardData, fixture } from "./fixtures";

const coding = fixture("coding");
const REDUCED = "(prefers-reduced-motion: reduce)";
const reduced = (on: boolean) =>
  (window.matchMedia(REDUCED) as MediaQueryList & { set(matches: boolean): void }).set(on);
afterEach(() => reduced(false));

const card = (o: Partial<Card>): Card => ({
  id: 1,
  project: "g/r",
  owner_session: null,
  owner_socket: null,
  approved: null,
  approved_by: null,
  column: "doing",
  position: 0,
  title: "T",
  labels: [],
  assignee: null,
  priority: null,
  comments: 0,
  due: null,
  due_done: false,
  cover: null,
  has_description: false,
  checklist_done: 0,
  checklist_total: 0,
  attachments: 0,
  parent: null,
  children: 0,
  blocked_by: [],
  needs_operator: false,
  waiting: false,
  blocked: null,
  review_round: null,
  metadata: null,
  created_by: "op",
  created: "2026-11-01T10:00:00Z",
  updated: new Date().toISOString(),
  archived: null,
  transitions: [],
  ...o,
});

const live = (l: Partial<SessionLive> = {}): SessionLive => ({
  state: "working",
  state_by: "screen",
  phase: "thinking",
  elapsed_s: 42,
  tokens: null,
  tool: null,
  card: null,
  subagents: null,
  ...l,
});
const agent = (session: string, name: string, type: string | null, l: Partial<SessionLive> = {}): PresentAgent => ({
  session,
  agent: name,
  type,
  live: live(l),
  why: "activity",
});
const comment = (id: number, author: string): Activity => ({
  id,
  at: "2026-11-01T10:00:00Z",
  kind: "comment",
  author,
  body: `c${id}`,
  body_html: `<p>c${id}</p>`,
});

type World = {
  cards: Card[];
  agents?: Record<string, string>;
  activity?: Activity[];
  sessions?: () => SessionsLive; // absent = the host has no sessionsLive port
  presence?: () => BoardPresence; // absent = the host has no boardPresence port
};

function fakeApi(w: World): KanbanApi {
  const data = { ...boardData(coding, w.cards), agents: w.agents };
  const cardData = (id: number): CardData => ({
    card: {
      ...w.cards.find((c) => c.id === id)!,
      attachments: [],
      description: "",
      description_html: "",
      checklists: [],
    },
    activity: w.activity ?? [],
    agents: w.agents,
    pings: [],
    links: [],
  });
  const known: Partial<KanbanApi> = {
    board: () => Promise.resolve(data),
    boardRev: () => Promise.resolve("r1"),
    card: (id) => Promise.resolve(cardData(id)),
    cardRev: () => Promise.resolve("c1"),
    sessionsLive: w.sessions && (() => Promise.resolve(w.sessions!())),
    boardPresence: w.presence && (() => Promise.resolve(w.presence!())),
  };
  const optional = new Set(["sessionsLive", "boardPresence"]);
  return new Proxy({} as KanbanApi, {
    get: (_, k: string) =>
      (known as Record<string, unknown>)[k] ?? (optional.has(k) ? undefined : () => Promise.resolve({})),
  });
}

const show = (w: World, open: number | null = null, me = "ann@example.com") =>
  render(
    <Board api={fakeApi(w)} me={me} slug="g/r" view={{ card: open, panel: null, archived: false }} onView={() => {}} />,
  );
// the live polls run again at once when the tab becomes visible: the next read without waiting an interval
const pollNow = () => act(() => void document.dispatchEvent(new Event("visibilitychange")));
const cardFace = (id: number) => document.querySelector<HTMLElement>(`li[data-id="${id}"]`)!;
const sessionsHere = (root: ParentNode, sel = ".kb-here-face") =>
  [...root.querySelectorAll<HTMLElement>(sel)].map(
    (e) => `${e.dataset.session}${e.classList.contains("leaving") ? " (leaving)" : ""}`,
  );

describe("AgentFace", () => {
  it("is an svg face: the backdrop its type's colour, its mood a class, its name + type + mood said in words", () => {
    render(<AgentFace name="worker-7" type="worker" mood="tool" />);
    const face = screen.getByRole("img", { name: "worker-7 · worker agent · running a tool" });
    expect(face.tagName.toLowerCase()).toBe("svg");
    expect(face).toHaveClass("ak-face", "m-tool");
    expect(face.style.getPropertyValue("--yf-bg")).toBe(
      `var(--ak-face-type-worker, hsl(${typeHue("worker")} 62% 58%))`,
    );
    // eyes only: two eyes (open) + their closed line, nothing else drawn on the disc
    expect(face.querySelectorAll(".yf-eye")).toHaveLength(2);
    expect(face.querySelector(".yf-shut")).not.toBeNull();
    expect([...face.querySelectorAll("circle, rect, path")].map((e) => e.getAttribute("class"))).toEqual(
      expect.arrayContaining(["yf-bg", "yf-eye", "yf-shut"]),
    );
    expect(face.querySelectorAll("circle, rect, path, text")).toHaveLength(4);
  });

  it("two agents of one type share the backdrop; no type → no colour of its own; no mood → still eyes", () => {
    const { container } = render(
      <>
        <AgentFace name="worker-1" type="worker" />
        <AgentFace name="worker-2" type="worker" />
        <AgentFace name="stranger" />
      </>,
    );
    const [a, b, c] = [...container.querySelectorAll<SVGElement>("svg.ak-face")];
    expect(a!.style.getPropertyValue("--yf-bg")).toBe(b!.style.getPropertyValue("--yf-bg"));
    expect(c!.style.getPropertyValue("--yf-bg")).toBe("");
    expect(c!.getAttribute("class")).toBe("ak-face");
  });

  it("Avatar: an agent wears the face, a person keeps the initials", () => {
    const { container } = render(
      <>
        <Avatar name="lead-s1" email="lead-s1" type="lead" mood="sleeping" />
        <Avatar name="Ann Lee" email="ann@example.com" type="lead" mood="sleeping" />
      </>,
    );
    expect(container.querySelectorAll("svg.ak-face")).toHaveLength(1);
    expect(screen.getByRole("img", { name: "lead-s1 · lead agent · sleeping" })).toHaveClass("m-sleeping");
    expect(container.querySelector(".avatar")).toHaveTextContent("AL");
  });

  it("stands still under prefers-reduced-motion: every moving part of a face and the strip has no animation", () => {
    const css = readFileSync(join(__dirname, "..", "src", "styles", "kanban.css"), "utf8");
    const block = css.slice(css.lastIndexOf("@media (prefers-reduced-motion: reduce)"));
    // !important: a mood rule (.ak-face.m-sleeping .yf-look, .ak-face[data-mood] .yf-eye) outranks `.ak-face *`
    const still = /^([^{]*)\{[^}]*?animation: none !important;\s*transition: none !important;\s*\}/m.exec(
      block.slice(block.indexOf("{") + 1),
    )![1]!;
    for (const sel of [".ak-face *", ".kb-here-face", "li.kb-agent-live", ".kb-work-phase", ".kb-work-details"])
      expect(still).toContain(sel);
    // every keyframes a face runs is on a descendant of .ak-face (so the rule above stops it)
    const faces = css
      .slice(css.indexOf("/* Agent faces"), css.indexOf("/* a face in the places"))
      .replace(/\/\*[\s\S]*?\*\//g, "");
    for (const m of faces.matchAll(/^([^@{}]+)\{[^}]*animation:/gm))
      for (const sel of m[1]!.split(",")) expect(sel.trim()).toMatch(/^(\.ak-face|\.yf-)/);
    // every mood has a still POSE of its own — the --yf-* of its rule (where the eyes look, how open each is), closed
    // eyes for sleeping; no animation in it — so the faces differ when nothing moves…
    const rules = [...faces.matchAll(/^([^@{}]+)\{([^}]*)\}/gm)].filter((r) => !/animation/.test(r[2]!));
    const poses = MOODS.map((m) =>
      rules
        .filter((r) => r[1]!.includes(`.m-${m} `))
        .map(
          (r) => `${r[1]!.trim().replace(`.m-${m}`, "")} {${r[2]!.replace(/\/\*.*?\*\//g, "").replace(/\s+/g, " ")}}`,
        )
        .join(""),
    );
    for (const pose of poses) expect(pose).toMatch(/(--yf-(x|y|sx|sy)|opacity):/);
    expect(new Set(poses).size).toBe(MOODS.length);
    // …and far enough apart to tell at 16px (a face is 64 units wide: 4 units = 1px there): any two moods differ by
    // closed eyes, or the gaze by ≥ 5 units, or an eye's width / height by ≥ a quarter
    const num = (pose: string, v: string, none: number) =>
      parseFloat(new RegExp(`--yf-${v}: ([^;]+);`).exec(pose)?.[1] ?? `${none}`);
    const shape = poses.map((pose) => ({
      tx: num(pose, "x", 0),
      ty: num(pose, "y", 0),
      sx: num(pose, "sx", 1),
      sy: num(pose, "sy", 1),
      shut: /\.yf-shut \{[^}]*opacity: 1/.test(pose),
    }));
    // the poses are what the eyes wear, moving or not: the base transform and every keyframe are written around them
    expect(faces).toMatch(/\.ak-face \.yf-look \{[^}]*transform: translate\(var\(--yf-x\), var\(--yf-y\)\);/);
    expect(faces).toMatch(/\.ak-face \.yf-eye \{[^}]*transform: scale\(var\(--yf-sx\), var\(--yf-sy\)\);/);
    for (const t of faces.matchAll(/transform: ([^;]+);/g)) expect(t[1]).toMatch(/var\(--yf-(x|sx)\)/);
    expect(shape[MOODS.indexOf("subagents")]!.tx).not.toBe(0); // the parse reads the stylesheet
    for (const [i, a] of shape.entries())
      for (const [j, b] of shape.entries()) {
        if (j <= i) continue;
        const apart =
          a.shut !== b.shut ||
          Math.max(Math.abs(a.tx - b.tx), Math.abs(a.ty - b.ty)) >= 5 ||
          Math.max(Math.abs(a.sx - b.sx), Math.abs(a.sy - b.sy)) >= 0.25;
        expect(apart, `${MOODS[i]} vs ${MOODS[j]}`).toBe(true);
      }
  });
});

describe("faces in the card dialog", () => {
  it("a registered agent's comment wears its type's colour and its session's mood; a person's keeps the initials", async () => {
    show(
      {
        cards: [card({ id: 3, owner_session: "s1", assignee: "lead-s1" })],
        agents: { "lead-s1": "lead" },
        activity: [comment(10, "lead-s1"), comment(11, "ann@example.com"), comment(12, "lead-s1")],
        sessions: () => ({ sessions: { s1: live({ phase: "writing" }) }, present: [] }),
      },
      3,
    );
    const newest = (await screen.findByText("c12")).closest("li")!;
    await waitFor(() => expect(newest.querySelector("svg.ak-face")).toHaveClass("m-writing"));
    const face = newest.querySelector<SVGElement>("svg.ak-face")!;
    expect(face.dataset.type).toBe("lead");
    expect(face.style.getPropertyValue("--yf-bg")).toContain("--ak-face-type-lead");
    // its older comment: the same face, still
    const older = screen.getByText("c10").closest("li")!.querySelector<SVGElement>("svg.ak-face")!;
    expect(older.getAttribute("class")).toBe("ak-face");
    expect(older.style.getPropertyValue("--yf-bg")).toBe(face.style.getPropertyValue("--yf-bg"));
    const person = screen.getByText("c11").closest("li")!;
    expect(person.querySelector("svg.ak-face")).toBeNull();
    // a person: the picture the host's avatar_url names (the coding fixture's: by the email's SHA-256), never a face
    await waitFor(() => expect(person.querySelector("img.avatar")).not.toBeNull());
    expect(person.querySelector("img.avatar")!.getAttribute("src")).toMatch(
      /^https:\/\/gravatar\.com\/avatar\/[0-9a-f]{64}\?/,
    );
  });

  it("a subagent no session registered wears its role's colour (the host's face_roles); a registered type wins", async () => {
    expect(coding.host.face_roles).toEqual({ reviewer: ["reviewer-*"], qa: ["qa-*"] });
    show(
      {
        cards: [card({ id: 3 })],
        agents: { "lead-s1": "lead", "qa-lead": "lead" },
        activity: [comment(10, "reviewer-x"), comment(11, "qa-7"), comment(12, "qa-lead"), comment(13, "stranger")],
      },
      3,
    );
    const face = async (c: string) =>
      (await screen.findByText(c)).closest("li")!.querySelector<SVGElement>("svg.ak-face")!;
    const reviewer = await face("c10");
    expect(reviewer.dataset.type).toBe("reviewer");
    expect(reviewer.style.getPropertyValue("--yf-bg")).toBe(
      `var(--ak-face-type-reviewer, hsl(${typeHue("reviewer")} 62% 58%))`,
    );
    expect(reviewer).toHaveAccessibleName("reviewer-x · reviewer agent");
    expect((await face("c11")).dataset.type).toBe("qa");
    expect((await face("c12")).dataset.type).toBe("lead"); // registered: its type, whatever its name looks like
    const stranger = await face("c13");
    expect(stranger.dataset.type).toBeUndefined();
    expect(stranger.style.getPropertyValue("--yf-bg")).toBe("");
  });

  it("the operator keeps the initials when its name is no email (a host with no sign-in)", async () => {
    show({ cards: [card({ id: 3 })], activity: [comment(10, "operator"), comment(11, "lead-s1")] }, 3, "operator");
    const op = (await screen.findByText("c10")).closest("li")!;
    expect(op.querySelector("svg.ak-face")).toBeNull();
    expect(op.querySelector(".avatar")).toHaveTextContent("O");
    expect(screen.getByText("c11").closest("li")!.querySelector("svg.ak-face")).not.toBeNull();
  });

  it("shows who is here now — one small label each, in one row, the assignee's own face moving — and lets go of one that left", async () => {
    let present = [
      agent("s1", "lead-s1", "lead"),
      agent("w2", "worker-2", "worker", { phase: "tool", tool: "Bash", elapsed_s: 2650, tokens: "↓ 1.2k" }),
    ];
    show(
      {
        cards: [card({ id: 3, owner_session: "s1", assignee: "lead-s1" })],
        agents: { "lead-s1": "lead" },
        sessions: () => ({ sessions: {}, present }),
      },
      3,
    );
    const label = (await screen.findByText("Bash")).closest<HTMLElement>(".kb-agent-live")!;
    expect(label.dataset.session).toBe("w2");
    expect(label.querySelector("svg.ak-face")).toHaveClass("m-tool");
    // face · session · the phase in a word (the tool's own name) · elapsed (the largest unit) — no tokens on the label
    expect(label.querySelector(".kb-work-label")).toHaveTextContent(/w2Bash44m$/);
    expect(label).not.toHaveTextContent("tokens");
    const dialog = label.closest<HTMLElement>("[data-card]")!;
    // one row holds every label: the one place the dialog says who is here
    const row = screen.getByRole("list", { name: "at work on card #3 now" });
    expect(row).toHaveClass("kb-work-labels");
    expect(sessionsHere(row, ":scope > li.kb-agent-live")).toEqual(["s1", "w2"]);
    expect(dialog.querySelectorAll("li.kb-agent-live")).toHaveLength(2);
    expect(dialog.querySelector(".kb-here")).toBeNull();
    expect(dialog.querySelector(".kb-member svg.ak-face")).toHaveClass("m-thinking"); // the assignee is here: its face moves

    // every fact is in the label's tooltip; a click (it is a button: keyboard too) opens them under the row
    const button = screen.getByRole("button", { name: "w2: running Bash, show details" });
    for (const fact of [
      "running Bash · 44m 10s · ↓ 1.2k tokens",
      "agent: worker-2 · worker",
      "session: w2",
      "here because: just acted on this card",
      "state: working",
      "read from: screen",
      "phase: tool",
      "tool: Bash",
      "tokens: ↓ 1.2k",
    ])
      expect(button.title.split("\n")).toContain(fact);
    expect(button).toHaveAttribute("aria-expanded", "false");
    expect(dialog.querySelector(".kb-work-details")).toBeNull();
    fireEvent.click(button);
    const details = dialog.querySelector<HTMLElement>(".kb-work-details")!;
    expect(button).toHaveAttribute("aria-expanded", "true");
    expect(button).toHaveAttribute("aria-controls", details.id);
    expect(details).toHaveTextContent("toolBash");
    expect(details).toHaveTextContent("agentworker-2 · worker");
    expect(details).toHaveTextContent("tokens↓ 1.2k");
    // one panel: opening another label's details replaces it; a second click closes
    fireEvent.click(screen.getByRole("button", { name: "s1: thinking…, show details" }));
    expect(dialog.querySelectorAll(".kb-work-details")).toHaveLength(1);
    expect(dialog.querySelector(".kb-work-details")).toHaveTextContent("agentlead-s1 · lead");
    fireEvent.click(screen.getByRole("button", { name: "s1: thinking…, hide details" }));
    expect(dialog.querySelector(".kb-work-details")).toBeNull();
    // Esc closes the open details and gives the focus back to their label — the card dialog stays open
    const again = screen.getByRole("button", { name: "w2: running Bash, show details" });
    fireEvent.click(again);
    again.blur();
    const escaped = fireEvent.keyDown(again, { key: "Escape" });
    expect(escaped).toBe(false); // handled: default prevented
    expect(dialog.querySelector(".kb-work-details")).toBeNull();
    expect(again).toHaveFocus();
    expect(dialog).toBeInTheDocument();
    fireEvent.click(again);

    present = [present[0]!];
    pollNow();
    await waitFor(() => expect(sessionsHere(dialog, "li.kb-agent-live")).toEqual(["s1", "w2 (leaving)"]));
    expect(label.querySelector("[aria-live]")).toBeNull(); // one live region, the row's
    expect(dialog.querySelectorAll(".kb-agents-live [aria-live]")).toHaveLength(1);
    await waitFor(() => expect(dialog.querySelector(".kb-agents-live > [aria-live]")).toHaveTextContent(/^w2 left$/));
    expect(label).toHaveAttribute("aria-hidden", "true");
    expect(label.querySelector("button")).toBeDisabled();
    expect(dialog.querySelector(".kb-work-details")).toBeNull(); // its details left with it
    fireEvent.animationEnd(label);
    expect(sessionsHere(dialog, "li.kb-agent-live")).toEqual(["s1"]);

    present = [];
    reduced(true); // no exit to wait for
    pollNow();
    await waitFor(() => expect(dialog.querySelector("li.kb-agent-live")).toBeNull());
    // the row stays, closed (no height, no list): it opens again with the next agent instead of pushing the comments
    expect(dialog.querySelector(".kb-agents-live")).toHaveClass("empty");
    expect(dialog.querySelector(".kb-work-labels")).toBeNull();
    expect(dialog.querySelector(".kb-member svg.ak-face")!.getAttribute("class")).toBe("ak-face"); // and it stands still
  });

  it("ownership alone is not presence: the owner's live session with no `present` entry gets no label", async () => {
    show(
      {
        cards: [card({ id: 3, owner_session: "s1", assignee: "lead-s1" })],
        activity: [comment(10, "lead-s1")],
        sessions: () => ({ sessions: { s1: live({ phase: "thinking" }) }, present: [] }),
      },
      3,
    );
    const dialog = (await screen.findByLabelText("Comment")).closest<HTMLElement>("[data-card]")!;
    // the answer has landed: the owner's comment wears its live mood (no time window — the DOM says so)
    const own = (await screen.findByText("c10")).closest("li")!;
    await waitFor(() => expect(own.querySelector("svg.ak-face")).toHaveClass("m-thinking"));
    expect(dialog.querySelector("li.kb-agent-live")).toBeNull();
    expect(dialog.querySelector(".kb-agents-live")).toHaveClass("empty");
    expect(dialog.querySelector(".kb-agents-live [aria-live]")).toBeEmptyDOMElement();
  });

  it("a failed poll shows nobody here — never the last answer, not even leaving", async () => {
    let fail = false;
    show(
      {
        cards: [card({ id: 3, owner_session: "s1" })],
        sessions: () => {
          if (fail) throw new Error("launcher down");
          return { sessions: {}, present: [agent("w2", "worker-2", "worker", { phase: "tool", tool: "Bash" })] };
        },
      },
      3,
    );
    expect(await screen.findByText("Bash")).toBeInTheDocument();
    fail = true;
    pollNow();
    expect(await screen.findByText(/live status: .*launcher down/)).toBeInTheDocument();
    expect(document.querySelector("li.kb-agent-live")).toBeNull();
    expect(document.querySelector(".kb-agents-live")).toBeNull();
  });

  it('an answer with no `present` list is a failed read, said as one — never "nobody is here"', async () => {
    show(
      {
        cards: [card({ id: 3, owner_session: "s1" })],
        sessions: () => ({ sessions: {} }) as unknown as SessionsLive,
      },
      3,
    );
    expect(await screen.findByText(/live status: .*the answer has no present list/)).toBeInTheDocument();
    expect(document.querySelector(".kb-agents-live")).toBeNull();
  });

  it("only a state change is announced: the counter ticks in the label, never in the live region", async () => {
    let l: Partial<SessionLive> = { phase: "thinking", elapsed_s: 42 };
    show(
      {
        cards: [card({ id: 3, owner_session: "s1" })],
        sessions: () => ({ sessions: {}, present: [agent("s1", "lead-s1", "lead", l)] }),
      },
      3,
    );
    const label = (await screen.findByText("thinking")).closest<HTMLElement>(".kb-agent-live")!;
    const row = label.closest<HTMLElement>(".kb-agents-live")!;
    const said = row.querySelector<HTMLElement>(":scope > [aria-live]")!;
    expect(row.querySelectorAll("[aria-live]")).toHaveLength(1);
    expect(label).not.toHaveAttribute("aria-live");
    expect(said).toHaveClass("kb-sr-only");
    await waitFor(() => expect(said).toHaveTextContent(/^s1 is working$/));
    expect(label.querySelector(".kb-work-meta")).toHaveTextContent(/^42s$/);
    l = { phase: "writing", elapsed_s: 125 };
    pollNow();
    await waitFor(() => expect(label.querySelector(".kb-work-meta")).toHaveTextContent(/^2m$/));
    expect(said).toHaveTextContent(/^s1 is working$/); // same state: nothing new to say
    l = { state: "blocked", phase: null };
    pollNow();
    await waitFor(() => expect(said).toHaveTextContent(/^s1 is waiting for you$/));
    expect(label).toHaveClass("t-blocked");
  });

  it("several agents arriving at once are ONE announcement, by their short names; the label shows the part of a session's name that differs", async () => {
    show(
      {
        cards: [card({ id: 3, project: "acme/storefront" })],
        sessions: () => ({
          sessions: {},
          present: [
            agent("acme_storefront_teamlead", "lead-1", "lead"),
            agent("acme_storefront_worker_2", "worker-2", "worker", { phase: "tool", tool: "busyyaks · kanban_card" }),
            agent("storefront-plain", "plain-1", "plain", { state: "idle", phase: null }),
          ],
        }),
      },
      3,
    );
    const label = (await screen.findByText("kanban_card")).closest<HTMLElement>(".kb-agent-live")!;
    expect(label.querySelector(".kb-work-who")).toHaveTextContent(/^worker_2$/);
    expect(label.dataset.session).toBe("acme_storefront_worker_2");
    // the full name and the full phase: the accessible name, the tooltip
    const button = screen.getByRole("button", {
      name: "acme_storefront_worker_2: running busyyaks · kanban_card, show details",
    });
    expect(button.title).toContain("session: acme_storefront_worker_2");
    expect(button.title).toContain("tool: busyyaks · kanban_card");
    const row = label.closest<HTMLElement>(".kb-agents-live")!;
    expect([...row.querySelectorAll(".kb-work-who")].map((e) => e.textContent)).toEqual([
      "teamlead",
      "worker_2",
      "plain",
    ]);
    expect(row.querySelectorAll("[aria-live]")).toHaveLength(1);
    // the announcement is written by an effect after the labels render: wait for the DOM, never a time window
    await waitFor(() =>
      expect(row.querySelector("[aria-live]")).toHaveTextContent(
        /^teamlead is working, worker_2 is working, plain is idle$/,
      ),
    );
  });

  it("a session stopped on a dialog on this card is here, waiting for you: the warn tone, the wide eyes, why in the tooltip", async () => {
    const blocked: PresentAgent = {
      ...agent("w3", "worker-3", "worker", { state: "blocked", phase: null }),
      why: "blocked",
    };
    show(
      {
        cards: [card({ id: 3 })],
        sessions: () => ({ sessions: {}, present: [blocked, agent("s1", "lead-s1", "lead")] }),
      },
      3,
    );
    const label = (await screen.findByText("needs you")).closest<HTMLElement>(".kb-agent-live")!;
    expect(label).toHaveClass("t-blocked");
    expect(label.dataset.session).toBe("w3");
    expect(label.querySelector("svg.ak-face")).toHaveClass("m-blocked");
    const button = screen.getByRole("button", { name: "w3: waiting for you (a dialog or question), show details" });
    expect(button.title.split("\n")).toContain("here because: waiting for you on this card");
    expect(button.title.split("\n")).toContain("state: blocked");
    const row = label.closest<HTMLElement>(".kb-agents-live")!;
    expect(sessionsHere(row, "li.kb-agent-live")).toEqual(["w3", "s1"]); // the host's order: blocked first
    await waitFor(() =>
      expect(row.querySelector("[aria-live]")).toHaveTextContent(/^w3 is waiting for you, s1 is working$/),
    );
  });

  it("a phase change cross-fades: the old phase stays, fading out, until its exit ends", async () => {
    let phase: SessionLive["phase"] = "thinking";
    show(
      {
        cards: [card({ id: 3, owner_session: "s1" })],
        sessions: () => ({ sessions: { s1: live({ phase }) }, present: [agent("s1", "lead-s1", "lead", { phase })] }),
      },
      3,
    );
    const first = await screen.findByText("thinking");
    const phases = first.closest<HTMLElement>(".kb-work-phases")!;
    phase = "writing";
    pollNow();
    expect(await screen.findByText("writing")).toBeInTheDocument();
    const out = phases.querySelector<HTMLElement>(".kb-work-phase.out")!;
    expect(out).toHaveTextContent("thinking");
    expect(out).toHaveAttribute("aria-hidden", "true");
    fireEvent.animationEnd(out);
    expect(phases.querySelectorAll(".kb-work-phase")).toHaveLength(1);
  });
});

describe("faces on the board", () => {
  it("the agents at work on a card stand beside its assignee, arrive and leave; the assignee is not shown twice", async () => {
    let cards: BoardPresence["cards"] = {
      "1": [agent("s1", "lead-s1", "lead", { phase: "writing" }), agent("w2", "worker-2", "worker")],
    };
    show({
      cards: [card({ id: 1, assignee: "lead-s1", owner_session: "s1" }), card({ id: 2, position: 1, title: "Quiet" })],
      agents: { "lead-s1": "lead" },
      presence: () => ({ cards }),
    });
    await waitFor(() => expect(sessionsHere(cardFace(1))).toEqual(["w2"]));
    const who = cardFace(1).querySelector<HTMLElement>(".kb-who")!;
    expect(who.querySelectorAll("svg.ak-face")).toHaveLength(2); // worker-2 + the assignee, once
    expect(screen.getByRole("img", { name: /^worker-2 · worker agent · thinking · w2/ })).toHaveClass("m-thinking");
    expect(who.querySelector(":scope > svg.ak-face")).toHaveClass("m-writing"); // the assignee's own face wears its mood
    expect(cardFace(2).querySelector("svg.ak-face")).toBeNull();

    // the lead looks at card 2, the worker leaves card 1
    cards = { "1": [agent("s1", "lead-s1", "lead", { phase: "writing" })], "2": [agent("s9", "lead-s9", "lead")] };
    pollNow();
    await waitFor(() => expect(sessionsHere(cardFace(2))).toEqual(["s9"]));
    expect(sessionsHere(cardFace(1))).toEqual(["w2 (leaving)"]);
    fireEvent.animationEnd(cardFace(1).querySelector(".kb-here-face.leaving")!);
    expect(sessionsHere(cardFace(1))).toEqual([]);

    cards = {};
    pollNow();
    await waitFor(() => expect(sessionsHere(cardFace(2))).toEqual(["s9 (leaving)"]));
    expect(who.querySelector(":scope > svg.ak-face")!.getAttribute("class")).toBe("ak-face"); // gone: a still face again
  });

  it("under reduced motion a face that left is gone at once", async () => {
    reduced(true);
    let cards: BoardPresence["cards"] = { "1": [agent("w2", "worker-2", "worker")] };
    show({ cards: [card({ id: 1 })], presence: () => ({ cards }) });
    await waitFor(() => expect(sessionsHere(cardFace(1))).toEqual(["w2"]));
    cards = {};
    pollNow();
    await waitFor(() => expect(sessionsHere(cardFace(1))).toEqual([]));
  });

  it("a host with no presence port shows the assignee's face, still, and nobody else", async () => {
    show({ cards: [card({ id: 1, assignee: "lead-s1" })], agents: { "lead-s1": "lead" } });
    await screen.findByRole("img", { name: "lead-s1 · lead agent" });
    expect(document.querySelector(".kb-here")).toBeNull();
    expect(cardFace(1).querySelectorAll("svg.ak-face")).toHaveLength(1);
    expect(screen.queryByText(/agents at work · error/)).toBeNull();
  });

  it("a presence read that fails says so and shows nobody — never who was here before", async () => {
    let fail = false;
    const cards = { "1": [agent("w2", "worker-2", "worker")] };
    show({
      cards: [card({ id: 1 })],
      presence: () => {
        if (fail) throw new Error("launcher down");
        return { cards };
      },
    });
    await waitFor(() => expect(sessionsHere(cardFace(1))).toEqual(["w2"]));
    fail = true;
    reduced(true);
    pollNow();
    expect(await screen.findByText(/agents at work · error/)).toHaveAttribute(
      "title",
      expect.stringContaining("launcher down"),
    );
    expect(sessionsHere(cardFace(1))).toEqual([]);
  });
});
