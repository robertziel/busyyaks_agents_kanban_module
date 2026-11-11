// The Board and the CardDialog in jsdom over a FAKE KanbanApi: the columns come from the BOARD the api sends, the
// theme lands as --ak-* custom properties on .ak-root, a quick-add goes through api.createCard, a comment through
// api.comment, the gates' UI follows the board (a card flagged needs_operator shows its question box in any column; a
// board without an approval step shows no approve button), and a card waiting for a parent shows the badge.
import { fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { useState } from "react";
import { describe, expect, it, vi } from "vitest";
import { Board, type BoardView, type KanbanApi } from "../src";
import type { Attachment, BoardData, Card, CardData } from "../src/types";
import { boardData, fixture } from "./fixtures";

const coding = fixture("coding");
const content = fixture("content");
const localV4 = fixture("local_v4");

const card = (o: Partial<Card>): Card => ({
  id: 1,
  project: "g/r",
  owner_session: null,
  owner_socket: null,
  approved: null,
  approved_by: null,
  column: "todo",
  position: 0,
  title: "Fix login",
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
  blocked: null,
  review_round: null,
  metadata: null,
  created_by: "op",
  created: "2026-11-01T10:00:00Z",
  updated: new Date().toISOString(),
  archived: null,
  transitions: [{ name: "Move", to: "qa", to_label: "QA", by: "any" }],
  ...o,
});

function fakeApi(data: BoardData, cards: Card[]): KanbanApi & { calls: string[] } {
  const calls: string[] = [];
  const cardData = (id: number): CardData => {
    const c = cards.find((x) => x.id === id)!;
    return {
      card: { ...c, attachments: [], description: "", description_html: "", checklists: [] },
      activity: [],
      pings: [],
      links: [],
    };
  };
  const note = <T,>(what: string, v: T): Promise<T> => {
    calls.push(what);
    return Promise.resolve(v);
  };
  return {
    calls,
    board: () => note("board", data),
    boardRev: () => note("boardRev", "r1"),
    card: (id) => note(`card ${id}`, cardData(id)),
    cardRev: (id) => note(`cardRev ${id}`, "c1"),
    createCard: (slug, body) => note(`createCard ${slug} ${body.column} ${body.title}`, cardData(1)),
    move: (id, body) =>
      note(`move ${id} ${body.column}${body.transition ? ` via ${body.transition}` : ""}`, {
        card: cards[0]!,
        counts: {},
        delivered: null,
      }),
    update: (id) => note(`update ${id}`, cardData(id)),
    assign: (id, a) => note(`assign ${id} ${a}`, cardData(id)),
    archive: (id, a) => note(`archive ${id} ${a}`, cardData(id)),
    setOwner: (id, s) => note(`setOwner ${id} ${s}`, cardData(id)),
    approve: (id, a) => note(`approve ${id} ${a}`, cardData(id)),
    dialogAnswer: (id, k) => note(`dialogAnswer ${id} ${k}`, cardData(id)),
    comment: (id, body) => note(`comment ${id} ${body}`, { ...cardData(id), delivered: "queued: s1" }),
    commentUpdate: (id) => note(`commentUpdate ${id}`, cardData(1)),
    commentDelete: (id) => note(`commentDelete ${id}`, cardData(1)),
    checklistCreate: (id, t) => note(`checklistCreate ${id} ${t}`, cardData(id)),
    checklistUpdate: (id) => note(`checklistUpdate ${id}`, cardData(1)),
    checklistDelete: (id) => note(`checklistDelete ${id}`, cardData(1)),
    itemCreate: (id) => note(`itemCreate ${id}`, cardData(1)),
    itemUpdate: (id) => note(`itemUpdate ${id}`, cardData(1)),
    itemDelete: (id) => note(`itemDelete ${id}`, cardData(1)),
    itemConvert: (id) => note(`itemConvert ${id}`, cardData(1)),
    labelCreate: (s, n, c) => note(`labelCreate ${s} ${n} ${c}`, {}),
    labelUpdate: (id) => note(`labelUpdate ${id}`, {}),
    labelDelete: (id) => note(`labelDelete ${id}`, {}),
    attach: (id, f) => note(`attach ${id} ${f.name}`, {} as Attachment),
    attachmentDelete: (id) => note(`attachmentDelete ${id}`, cardData(1)),
    markdownPreview: (b) => note(`markdownPreview ${b}`, `<p>${b}</p>`),
    boardShape: (slug) => note(`boardShape ${slug}`, data.board),
    boardShapeSave: (slug, s) => note(`boardShapeSave ${slug}`, { ...data.board, ...s }),
    boardShapeReset: (slug) => note(`boardShapeReset ${slug}`, data.board),
  };
}

// A host like busyyaks: the view in state (busyyaks keeps it in the URL).
function Host({
  api,
  view: initial = { card: null, panel: null, archived: false },
}: {
  api: KanbanApi;
  view?: BoardView;
}) {
  const [view, setView] = useState<BoardView>(initial);
  return (
    <Board
      api={api}
      me="me"
      slug="g/r"
      view={view}
      onView={(c) => setView((v) => ({ ...v, ...c }))}
      projectHref="/projects/g/r"
    />
  );
}

describe("Board", () => {
  it("lists the latest change first in day groups and folds cards past the column's hide_after_hours behind Load older", async () => {
    const H = 3600 * 1000;
    const at = (h: number) => new Date(Date.now() - h * H).toISOString();
    const cards = [
      card({ id: 1, column: "todo", title: "two hours", updated: at(2) }),
      card({ id: 2, column: "todo", title: "two days", updated: at(48) }),
      card({ id: 3, column: "todo", title: "four days", updated: at(96) }), // To do: 72 h
      card({ id: 4, column: "merged", title: "merged 30h", updated: at(30) }), // Merged: 24 h
      card({ id: 5, column: "backlog", title: "backlog 5d", updated: at(120) }), // Backlog: a week
    ];
    render(<Host api={fakeApi(boardData(coding, cards), cards)} />);
    await screen.findByText("two hours");
    const todo = screen.getByRole("list", { name: "To do" });
    expect(within(todo).queryByText("four days")).toBeNull();
    expect(
      within(todo)
        .getAllByText(/two (hours|days)/)
        .map((e) => e.textContent),
    ).toEqual(["two hours", "two days"]);
    expect(todo.querySelector(".kb-day span")!.textContent).toBe(
      new Date(at(2)).toDateString() === new Date().toDateString() ? "Today" : "Yesterday",
    ); // the browser's day
    expect(screen.queryByText("merged 30h")).toBeNull();
    expect(screen.getByText("backlog 5d")).toBeTruthy();
    fireEvent.click(within(todo).getByRole("button", { name: "Load older · 1" }));
    expect(within(todo).getByText("four days")).toBeTruthy();
    expect(
      within(screen.getByRole("list", { name: "Merged" })).getByRole("button", { name: "Load older · 1" }),
    ).toBeTruthy();
  });

  it("the board's height is FIXED — a theme token or the window below it; the lists scroll inside (never grows with cards)", () => {
    // whitespace collapsed: the rules are matched by content, not by how the file is laid out (Prettier)
    const css = readFileSync(join(__dirname, "..", "src", "styles", "kanban.css"), "utf8").replace(/\s+/g, " ");
    const rule = css.match(/\.ak-root \.kb \{ height: ([^;]+);/)?.[1];
    expect(rule).toBe("var(--ak-board-height, max(420px, calc(100dvh - var(--kb-top, 300px) - 12px)))");
    expect(css).toMatch(/\.ak-root \.kb-col \{ max-height: none; height: 100%; min-height: 0; \}/);
    expect(css).toMatch(/\.ak-root \.kb-list \{[^}]*overflow-y: auto/);
    expect(css).toMatch(/\.ak-root \.kb-list > \* \{ flex-shrink: 0; \}/); // rows keep their height: the list scrolls, a card is never squeezed
    expect(css).toMatch(/@media \(max-width: 600px\) \{ \.ak-root \.kb \{ height: var\(--ak-board-height, /);
  });

  // card #248: a gate card whose Approve would not pass now is waiting for CI, not for the operator
  it("a held gate card says why and is counted as waiting for CI, not for you", async () => {
    const cards = [
      card({ id: 1, column: "human_check", title: "Green" }),
      card({ id: 2, column: "human_check", title: "Pending", gate_hold: "PR #7: CI is still running" }),
    ];
    const api = fakeApi(boardData(coding, cards), cards);
    render(<Host api={api} />);
    await screen.findByText("Pending");
    expect(screen.getByText(/waiting for you/).textContent).toMatch(/^1 waiting for you/);
    expect(screen.getByText(/waiting for CI$/).textContent).toBe("1 waiting for CI");
    expect(screen.getByText("⏳ PR #7: CI is still running")).toBeInTheDocument();
  });

  // a card blocked on the world (another card, CI, a third party) is not waiting for the operator
  it("a blocked_external card is counted as blocked externally, not as waiting for you", async () => {
    const blocked = { reason: "waits for card #3", url: "https://ci/1", by: "lead", at: "2026-11-11T00:00:00Z" };
    const cards = [
      card({ id: 1, column: "human_check", title: "Green" }),
      card({ id: 2, column: "doing", title: "Held back", blocked }),
      card({ id: 3, column: "human_check", title: "Gate, blocked", blocked }),
    ];
    const api = fakeApi(boardData(coding, cards), cards);
    render(<Host api={api} />);
    await screen.findByText("Held back");
    expect(screen.getByText(/waiting for you/).textContent).toMatch(/^1 waiting for you/);
    expect(screen.getByText(/blocked externally$/).textContent).toBe("2 blocked externally");
  });

  it("draws the configured columns, the theme tokens and a card's badges", async () => {
    const cards = [
      card({ id: 1, column: "todo" }),
      card({
        id: 2,
        column: "doing",
        title: "Ask",
        needs_operator: true,
        question: "Which?",
        question_options: ["A", "B"],
        asked_by: "lead",
      }),
    ];
    const api = fakeApi(boardData(coding, cards, { "--ak-ink": "rgb(1, 2, 3)" }), cards);
    const { container } = render(<Host api={api} />);
    await screen.findByText("Fix login");
    const heads = container.querySelectorAll(".kb-col h2");
    expect(Array.from(heads).map((h) => h.textContent)).toEqual([
      "Backlog",
      "To do",
      "In progress",
      "QA",
      "Human Check",
      "Ready to merge",
      "Merged",
    ]);
    const root = container.querySelector(".ak-root") as HTMLElement;
    expect(root.style.getPropertyValue("--ak-ink")).toBe("rgb(1, 2, 3)");
    expect(screen.getByText("? 2 choices")).toBeInTheDocument();
    // the flagged card sits in In progress and still counts (the server's `waiting`)
    expect(screen.getByText(/waiting for you/).textContent).toMatch(/^1 waiting for you/);
  });

  it("card markdown: a link to another server opens in a new tab, a link on this site or an unparseable one stays in this tab", async () => {
    const here = window.location.origin;
    const cards = [
      card({
        id: 2,
        column: "qa",
        needs_operator: true,
        question: "links",
        question_html:
          `<p><a href="https://github.com/o/r/pull/5">pr</a> <a href="${here}/projects/g/r?card=3">abs</a> ` +
          `<a href="/projects/g/r?tab=board&amp;card=3">rel</a> <a href="#a-9">jump</a> ` +
          `<a href="mailto:x@y.z">mail</a> <a href="https://ci.example/1" rel="nofollow">ci</a> ` +
          `<a href="http://[">broken</a></p>`,
        asked_by: "lead",
        asked: "2026-11-09T10:00:00Z",
        owner_session: "s1",
      }),
    ];
    const api = fakeApi(boardData(coding, cards), cards);
    render(<Host api={api} view={{ card: 2, panel: null, archived: false }} />);
    const q = await screen.findByRole("region", { name: "Question for you" });
    const at = (name: string) => {
      const a = within(q).getByRole("link", { name });
      return [a.getAttribute("target"), a.getAttribute("rel")];
    };
    expect(at("pr")).toEqual(["_blank", "noopener"]);
    expect(at("ci")).toEqual(["_blank", "nofollow noopener"]);
    for (const same of ["abs", "rel", "jump", "mail", "broken"]) expect(at(same)).toEqual([null, null]);
  });

  it("a flagged card shows its question box in its own column; the answer stays there", async () => {
    const cards = [
      card({
        id: 2,
        column: "qa",
        title: "Ask",
        needs_operator: true,
        question: "Which?",
        question_html: "<p>Which?</p>",
        question_options: ["A", "B"],
        asked_by: "lead",
        asked: "2026-11-09T10:00:00Z",
        owner_session: "s1",
      }),
    ];
    const api = fakeApi(boardData(coding, cards), cards);
    render(<Host api={api} view={{ card: 2, panel: null, archived: false }} />);
    const q = await screen.findByRole("region", { name: "Question for you" });
    expect(within(q).getByText(/the flag clears, the card stays in QA/)).toBeInTheDocument();
    fireEvent.click(within(q).getByRole("button", { name: "A" }));
    await waitFor(() => expect(api.calls).toContain("comment 2 A"));
  });

  it("a blocked card shows the badge on its face and the section in the dialog; a review card its round", async () => {
    const cards = [
      card({
        id: 3,
        column: "doing",
        title: "CI down",
        blocked: {
          reason: "Jenkins is offline",
          url: "https://ci.example/job/1",
          by: "worker",
          at: "2026-11-09T10:00:00Z",
        },
      }),
      card({ id: 4, column: "qa", title: "Round two", review_round: 2 }),
    ];
    const api = fakeApi(boardData(coding, cards), cards);
    render(<Host api={api} view={{ card: 3, panel: null, archived: false }} />);
    await screen.findByText("Round two");
    expect(screen.getByText("⛔ blocked: Jenkins is offline")).toBeInTheDocument();
    expect(screen.getByText("round 2/3")).toBeInTheDocument();
    expect(screen.getByText(/waiting for you/).textContent).toMatch(/^0 waiting for you/); // the world, not you
    expect(screen.getByText(/blocked externally$/).textContent).toBe("1 blocked externally");
    const sec = await screen.findByRole("region", { name: "Blocked (external)" });
    expect(within(sec).getByText("Jenkins is offline")).toBeInTheDocument();
    expect(within(sec).getByRole("link")).toHaveAttribute("href", "https://ci.example/job/1");
  });

  it("quick-add creates through the api and a parent-blocked card shows its badge", async () => {
    const cards = [card({ id: 3, column: "waiting", title: "translation", parent: 2, blocked_by: [2] })];
    const api = fakeApi(boardData(content, cards), cards);
    render(<Host api={api} />);
    await screen.findByText("translation");
    expect(screen.getByText("⧗ waits for #2")).toBeInTheDocument();
    fireEvent.click(screen.getAllByText("+ Add a card")[0]!);
    const ta = screen.getByLabelText("New card title in Waiting");
    fireEvent.change(ta, { target: { value: "article: japan" } });
    fireEvent.keyDown(ta, { key: "Enter" });
    await waitFor(() => expect(api.calls).toContain("createCard g/r waiting article: japan"));
  });

  it("a file dropped into the comment box clears the dialog's drop overlay and uploads once", async () => {
    const cards = [card({ id: 1, column: "todo" })];
    const api = fakeApi(boardData(coding, cards), cards);
    const { container } = render(<Host api={api} view={{ card: 1, panel: null, archived: false }} />);
    const dialog = (await waitFor(() => {
      const d = container.querySelector(".kb-detail");
      expect(d).not.toBeNull();
      return d;
    })) as HTMLElement;
    const file = new File(["x"], "shot.png", { type: "image/png" });
    const dataTransfer = { types: ["Files"], files: [file], items: [], dropEffect: "none" };
    fireEvent.dragOver(dialog, { dataTransfer });
    expect(container.querySelector(".kb-dropzone")).not.toBeNull();
    const box = dialog.querySelector(".mde textarea") as HTMLElement;
    fireEvent.dragOver(box, { dataTransfer });
    fireEvent.drop(box, { dataTransfer });
    await waitFor(() => expect(api.calls.filter((c) => c.startsWith("attach 1 shot"))).toHaveLength(1));
    expect(container.querySelector(".kb-dropzone")).toBeNull();
  });

  it("opens a card: the ask box with option buttons posts the choice; no approve button without an approval step", async () => {
    const cards = [
      card({
        id: 2,
        column: "running",
        title: "Ask",
        needs_operator: true,
        question: "Which?",
        question_html: "<p>Which?</p>",
        question_options: ["A", "B"],
        asked_by: "lead",
        owner_session: "s1",
      }),
    ];
    const api = fakeApi(boardData(content, cards), cards);
    render(<Host api={api} view={{ card: 2, panel: null, archived: false }} />);
    const q = await screen.findByLabelText("Question for you");
    expect(within(q).getByText("Which?")).toBeInTheDocument();
    fireEvent.click(within(q).getByRole("button", { name: "A" }));
    await waitFor(() => expect(api.calls).toContain("comment 2 A"));
    expect(screen.queryByText("✓ Approve to merge")).toBeNull();
    expect(screen.getByText(/the card stays in Running/)).toBeInTheDocument();
  });

  it("a card on a workflow board moves by TRANSITION: the list holds the operator's transitions and sends the name", async () => {
    const cards = [
      card({
        id: 6,
        column: "doing",
        title: "WF",
        transitions: [
          { name: "Send for QA", to: "qa", to_label: "QA", by: "any" },
          { name: "Hand over", to: "human_check", to_label: "Human Check", by: "agent" },
        ],
      }),
    ];
    const api = fakeApi(boardData(coding, cards), cards);
    render(<Host api={api} view={{ card: 6, panel: null, archived: false }} />);
    fireEvent.click(await screen.findByRole("button", { name: "Transition" })); // the select is labelled by "Transition"
    const list = await screen.findByRole("listbox");
    expect(
      within(list)
        .getAllByRole("option")
        .map((o) => o.textContent),
    ).toEqual(["In progress", "Send for QA → QA"]); // no agent-only "Hand over"
    fireEvent.click(within(list).getByRole("option", { name: "Send for QA → QA" }));
    await waitFor(() => expect(api.calls).toContain("move 6 qa via Send for QA"));
  });

  it("a card with no transition out of its column for the operator has its Transition list disabled, saying so", async () => {
    const cards = [
      card({
        id: 7,
        column: "doing",
        title: "Stuck",
        transitions: [{ name: "Hand over", to: "human_check", to_label: "Human Check", by: "agent" }],
      }),
    ];
    const api = fakeApi(boardData(coding, cards), cards);
    render(<Host api={api} view={{ card: 7, panel: null, archived: false }} />);
    const btn = await screen.findByRole("button", { name: /Transition/ });
    expect(btn).toBeDisabled();
    expect(btn.closest("label")!.getAttribute("title")).toMatch(/no transition out of this column/);
  });

  it("a board the host no longer fits (422 on read) shows the reason and a reset to the template", async () => {
    const cards = [card({ id: 1 })];
    const api = fakeApi(boardData(coding, cards), cards);
    let broken = true;
    api.board = () =>
      broken
        ? Promise.reject(
            Object.assign(
              new Error(
                "the stored board of g/r no longer fits this host (column human_check is a gate but the host config has handoff: null)",
              ),
              { status: 422 },
            ),
          )
        : Promise.resolve(boardData(coding, cards));
    api.boardShapeReset = (slug) => (
      (broken = false),
      api.calls.push(`boardShapeReset ${slug}`),
      Promise.resolve(coding.board)
    );
    render(<Host api={api} />);
    expect(await screen.findByText(/no longer fits this host/)).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Reset this board to the template" }));
    await screen.findByText("Fix login");
    expect(api.calls).toContain("boardShapeReset g/r");
  });

  it("a coding card in Human Check offers the approval and the handoff box names the column", async () => {
    const cards = [card({ id: 5, column: "human_check", title: "HC", owner_session: "s1" })];
    const api = fakeApi(boardData(coding, cards), cards);
    render(<Host api={api} view={{ card: 5, panel: null, archived: false }} />);
    const btn = await screen.findByText("✓ Approve to merge");
    expect(screen.getByText("Human Check handoff")).toBeInTheDocument();
    fireEvent.click(btn);
    await waitFor(() => expect(api.calls).toContain("approve 5 true"));
  });

  // workflow v3 approves at every gate — the button sits on each step and names the target column
  it("a local v3 board offers an approve button on Local: Human review and on Public: Human review", async () => {
    const cards = [
      card({ id: 5, column: "local_human_review", title: "HC", owner_session: "s1" }),
      card({ id: 6, column: "public_human_review", title: "PUB", owner_session: "s1" }),
    ];
    const api = fakeApi(boardData(localV4, cards), cards);
    const { unmount } = render(<Host api={api} view={{ card: 5, panel: null, archived: false }} />);
    const localBtn = await screen.findByText("✓ Approve → Local: Merged");
    expect(localBtn).toHaveAttribute(
      "title",
      "Approve: the card moves Local: Human review → Local: Merged; the owner agent is pinged to carry on and move the card to Local: Deploy check",
    );
    expect(screen.getByText("Local: Human review handoff")).toBeInTheDocument();
    expect(screen.queryByText("✓ Approve to merge")).toBeNull();
    fireEvent.click(localBtn);
    await waitFor(() => expect(api.calls).toContain("approve 5 true"));
    unmount();
    render(<Host api={api} view={{ card: 6, panel: null, archived: false }} />);
    const gate = await screen.findByText("✓ Approve to merge");
    expect(gate).toHaveAttribute(
      "title",
      "Approve for merge: the card moves to Awaiting merge; the owner agent is pinged to merge it and move the card to Done",
    );
    fireEvent.click(gate);
    await waitFor(() => expect(api.calls).toContain("approve 6 true"));
  });

  // card #271: the button names the step — Local: Deploy check's exit is "Open public PR", into Public: Create PR
  it("the approve button on Local: Deploy check names its step: Open public PR → Public: Create PR", async () => {
    const cards = [card({ id: 9, column: "deploy_check", title: "DC", owner_session: "s1" })];
    const api = fakeApi(boardData(localV4, cards), cards);
    render(<Host api={api} view={{ card: 9, panel: null, archived: false }} />);
    const btn = await screen.findByText("✓ Open public PR → Public: Create PR");
    expect(btn).toHaveAttribute(
      "title",
      "Open public PR: the card moves Local: Deploy check → Public: Create PR; the owner agent is pinged to carry on and move the card to Public: Agent review",
    );
    expect(screen.queryByText(/✓ Approve/)).toBeNull();
    fireEvent.click(btn);
    await waitFor(() => expect(api.calls).toContain("approve 9 true"));
  });

  it("an approved card in Awaiting merge shows who approved and withdraws; one dragged in without approval shows nothing", async () => {
    const cards = [
      card({
        id: 7,
        column: "awaiting_merge",
        title: "AM",
        owner_session: "s1",
        approved: "2026-11-09T10:00:00Z",
        approved_by: "op@x",
      }),
      card({ id: 8, column: "awaiting_merge", title: "DR", owner_session: "s1" }),
    ];
    const api = fakeApi(boardData(localV4, cards), cards);
    const { unmount } = render(<Host api={api} view={{ card: 7, panel: null, archived: false }} />);
    expect(await screen.findByText(/its agent merges and moves it to Done/)).toBeInTheDocument();
    const w = screen.getByText("Withdraw approval");
    expect(w).toHaveAttribute("title", "Withdraw: the card goes back to Public: Human review");
    fireEvent.click(w);
    await waitFor(() => expect(api.calls).toContain("approve 7 false"));
    unmount();
    render(<Host api={api} view={{ card: 8, panel: null, archived: false }} />);
    await screen.findAllByText("DR");
    expect(screen.queryByText("Withdraw approval")).toBeNull();
    expect(screen.queryByText(/✓ Approve/)).toBeNull();
  });

  it("shows the api's error verbatim and keeps polling the revision", async () => {
    const cards = [card({ id: 1 })];
    const api = fakeApi(boardData(coding, cards), cards);
    const err = Object.assign(new Error("agents cannot create cards in Merged"), { status: 422 });
    api.createCard = () => Promise.reject(err);
    render(<Host api={api} />);
    await screen.findByText("Fix login");
    fireEvent.click(screen.getAllByText("+ Add a card")[6]!);
    const ta = screen.getByLabelText("New card title in Merged");
    fireEvent.change(ta, { target: { value: "x" } });
    fireEvent.keyDown(ta, { key: "Enter" });
    expect(await screen.findByRole("alert")).toHaveTextContent("422 · agents cannot create cards in Merged");
    vi.useFakeTimers();
    vi.useRealTimers();
    expect(api.calls.filter((c) => c === "boardRev").length).toBeGreaterThanOrEqual(1);
  });

  // after adding a card the composer stays open (Trello) and the board stopped polling, so an
  // agent's move showed only after a page reload.
  it("keeps live updates on while the Add a card composer is open after an add", async () => {
    const cards = [card({ id: 1 })];
    const api = fakeApi(boardData(coding, cards), cards);
    let rev = "r1";
    api.boardRev = () => {
      api.calls.push("boardRev");
      return Promise.resolve(rev);
    };
    vi.useFakeTimers({ shouldAdvanceTime: true });
    try {
      render(<Host api={api} />);
      await screen.findByText("Fix login");
      fireEvent.click(screen.getAllByText("+ Add a card")[1]!);
      const ta = screen.getByLabelText("New card title in To do");
      fireEvent.change(ta, { target: { value: "new one" } });
      fireEvent.keyDown(ta, { key: "Enter" });
      await waitFor(() => expect(api.calls).toContain("createCard g/r todo new one"));
      expect(screen.getByLabelText("New card title in To do")).toBeInTheDocument(); // still open
      await vi.advanceTimersByTimeAsync(3100);
      const boards = api.calls.filter((c) => c === "board").length;
      rev = "r2"; // an agent moved a card
      await vi.advanceTimersByTimeAsync(3100);
      await waitFor(() => expect(api.calls.filter((c) => c === "board").length).toBeGreaterThan(boards));
    } finally {
      vi.useRealTimers();
    }
  });
});

describe("CardDialog's modal (the effect's deps are [id], the host's onClose is read from a ref)", () => {
  it("opens once per card id, Esc calls the host's CURRENT onClose, a new id reopens it", async () => {
    const cards = [card({ id: 1, column: "todo", title: "one" }), card({ id: 2, column: "todo", title: "two" })];
    const api = fakeApi(boardData(coding, cards), cards);
    const showModal = vi.spyOn(HTMLDialogElement.prototype, "showModal");
    const first = vi.fn();
    const second = vi.fn();
    const at = (id: number, onView: (c: Partial<BoardView>) => void) => (
      <Board api={api} me="me" slug="g/r" view={{ card: id, panel: null, archived: false }} onView={onView} />
    );
    const { container, rerender } = render(at(1, first));
    await waitFor(() => expect(container.querySelector(".kb-detail")).not.toBeNull());
    const dialog = container.querySelector<HTMLDialogElement>("dialog.kb-dialog")!;
    expect(showModal).toHaveBeenCalledTimes(1);

    rerender(at(1, second)); // the host renders again: a new onView, so a new onClose closure
    expect(showModal).toHaveBeenCalledTimes(1);
    expect(dialog.open).toBe(true);

    fireEvent(dialog, new Event("cancel", { cancelable: true }));
    expect(first).not.toHaveBeenCalled();
    expect(second).toHaveBeenCalledWith({ card: null, panel: null });

    rerender(at(2, second));
    await waitFor(() => expect(showModal).toHaveBeenCalledTimes(2));
    showModal.mockRestore();
  });
});
