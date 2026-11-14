// The Board and the CardDialog in jsdom over a FAKE KanbanApi: the columns come from the BOARD the api sends, the
// theme lands as --ak-* custom properties on .ak-root, a quick-add goes through api.createCard, a comment through
// api.comment, the gates' UI follows the board (a card flagged needs_operator shows its question box in any column; a
// board without an approval step shows no approve button), and a card waiting for a parent shows the badge.
import { fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { useState } from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
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
  waiting: false,
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

  it("an approved card in Awaiting merge shows who approved and withdraws; one dragged in without approval is approved in place", async () => {
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
    // its agent never leaves a gate unapproved — the operator approves it where it sits
    const here = screen.getByText("✓ Approve to merge");
    expect(here).toHaveAttribute(
      "title",
      "Approve for merge: the card stays in Awaiting merge; the owner agent is pinged to merge it and move the card to Done",
    );
    fireEvent.click(here);
    await waitFor(() => expect(api.calls).toContain("approve 8 true"));
  });

  // the step's own transition asks CI (and is refused while it is not green) — the operator's free
  // edge into the same column is listed beside it, never hidden behind it
  it("the Transition list of a gate card offers the free move into the step's target beside the CI-gated one", async () => {
    const cards = [
      card({
        id: 5,
        column: "local_human_review",
        title: "HC",
        transitions: [
          { name: "Approve", to: "local_merged_pr", to_label: "Local: Merged", by: "operator" },
          { name: "Rework", to: "doing", to_label: "In progress", by: "operator" },
          { name: "Move", to: "local_merged_pr", to_label: "Local: Merged", by: "operator" },
          { name: "Move", to: "doing", to_label: "In progress", by: "operator" },
        ],
      }),
    ];
    const api = fakeApi(boardData(localV4, cards), cards);
    render(<Host api={api} view={{ card: 5, panel: null, archived: false }} />);
    fireEvent.click(await screen.findByRole("button", { name: "Transition" }));
    const list = await screen.findByRole("listbox");
    expect(
      within(list)
        .getAllByRole("option")
        .map((o) => o.textContent),
    ).toEqual([
      "Local: Human review",
      "Approve → Local: Merged",
      "Rework → In progress",
      "Move → Local: Merged (CI not asked)",
    ]);
    fireEvent.click(within(list).getByRole("option", { name: "Move → Local: Merged (CI not asked)" }));
    await waitFor(() => expect(api.calls).toContain("move 5 local_merged_pr via Move"));
  });

  // a collapsed list is still a column the operator drags a card into
  it("a card dropped on a collapsed list moves into that column", async () => {
    window.localStorage.setItem("kb-collapsed:g/r", JSON.stringify(["qa"]));
    const cards = [card({ id: 3, column: "doing", title: "Drag me" })];
    const api = fakeApi(boardData(coding, cards), cards);
    const { container } = render(<Host api={api} />);
    const li = (await screen.findByText("Drag me")).closest("li")!;
    const strip = container.querySelector<HTMLElement>('.kb-col.collapsed[data-col="qa"]')!;
    const dataTransfer = { setData: () => {}, effectAllowed: "", dropEffect: "" };
    fireEvent.dragStart(li, { dataTransfer });
    fireEvent.dragOver(strip, { dataTransfer });
    expect(strip.className).toContain("over");
    fireEvent.drop(strip, { dataTransfer });
    await waitFor(() => expect(api.calls).toContain("move 3 qa"));
    window.localStorage.removeItem("kb-collapsed:g/r");
  });

  it("the edge step areas: shown on the side the lists can scroll toward, a click glides one list, off while dragging", async () => {
    const cards = [card({ id: 3, column: "doing", title: "Drag me" })];
    const api = fakeApi(boardData(coding, cards), cards);
    const { container } = render(<Host api={api} />);
    const li = (await screen.findByText("Drag me")).closest("li")!;
    const kb = container.querySelector<HTMLElement>(".kb")!;
    // jsdom lays nothing out: 7 lists 230 px apart in a 1000 px scroller holding 1600 px
    let left = 0;
    Object.defineProperties(kb, {
      scrollWidth: { configurable: true, get: () => 1600 },
      clientWidth: { configurable: true, get: () => 1000 },
      scrollLeft: { configurable: true, get: () => left, set: (v: number) => (left = v) },
      getBoundingClientRect: { configurable: true, value: () => ({ left: 0 }) },
    });
    Array.from(kb.children).forEach((c, i) =>
      Object.defineProperty(c, "getBoundingClientRect", { value: () => ({ left: i * 230 - left }) }),
    );
    const l = container.querySelector<HTMLButtonElement>(".kb-step-l")!;
    const r = container.querySelector<HTMLButtonElement>(".kb-step-r")!;
    // round icon buttons: named by aria-label, the chevron is decoration
    expect(screen.getByRole("button", { name: "Scroll the lists left", hidden: true })).toBe(l);
    expect(screen.getByRole("button", { name: "Scroll the lists right", hidden: true })).toBe(r);
    for (const b of [l, r]) expect(b.querySelector("svg.ico")).toHaveAttribute("aria-hidden", "true");
    expect([l.textContent, r.textContent]).toEqual(["", ""]);
    fireEvent.scroll(kb);
    await waitFor(() => expect(r).toHaveClass("on"));
    expect(l).not.toHaveClass("on");
    expect([l.tabIndex, r.tabIndex]).toEqual([-1, 0]);
    fireEvent.click(r);
    await waitFor(() => expect(left).toBe(230));
    fireEvent.scroll(kb);
    await waitFor(() => expect(l).toHaveClass("on"));
    // Tab reaches the step buttons before any card (a card's focus scroll would carry the lists away first)
    expect(r.compareDocumentPosition(li) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
    // the focused › going off at the far end hands focus to ‹
    r.focus();
    for (const want of [460, 600]) {
      fireEvent.click(r);
      await waitFor(() => expect(left).toBe(want));
      fireEvent.scroll(kb);
    }
    await waitFor(() => expect(r).not.toHaveClass("on"));
    expect(document.activeElement).toBe(l);
    for (const want of [460, 230, 0]) {
      fireEvent.click(l);
      await waitFor(() => expect(left).toBe(want));
      fireEvent.scroll(kb);
    }
    await waitFor(() => expect(l).not.toHaveClass("on"));
    expect(document.activeElement).toBe(r);
    fireEvent.dragStart(li, { dataTransfer: { setData: () => {}, effectAllowed: "", dropEffect: "" } });
    await waitFor(() => expect(r).not.toHaveClass("on"));
    expect([l.tabIndex, r.tabIndex]).toEqual([-1, -1]);
  });

  it("Enter on a focused step button is the button's press, not the hovered card's shortcut", async () => {
    const cards = [card({ id: 3, column: "doing", title: "Under the pointer" })];
    const api = fakeApi(boardData(coding, cards), cards);
    const onView = vi.fn();
    const { container } = render(
      <Board api={api} me="me" slug="g/r" view={{ card: null, panel: null, archived: false }} onView={onView} />,
    );
    const li = (await screen.findByText("Under the pointer")).closest("li")!;
    fireEvent.mouseEnter(li);
    const r = container.querySelector<HTMLButtonElement>(".kb-step-r")!;
    r.focus();
    fireEvent.keyDown(r, { key: "Enter" });
    fireEvent.keyDown(r, { key: " " });
    expect(onView).not.toHaveBeenCalled();
    // the hover shortcut itself still works with nothing focused
    r.blur();
    fireEvent.keyDown(document.body, { key: "Enter" });
    expect(onView).toHaveBeenCalledWith({ card: 3, panel: null });
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

// jsdom lays nothing out: the lists 230 px apart under a 100 px header, each card 60 px under the one before it; the
// board 2000 × 1000; a flying copy, the copies' layer (so no containing-block offset) and everything else at 0,0.
function layout() {
  const rect = (left: number, top: number, width: number, height: number) =>
    ({ left, top, width, height, right: left + width, bottom: top + height, x: left, y: top }) as DOMRect;
  return vi.spyOn(Element.prototype, "getBoundingClientRect").mockImplementation(function (this: Element) {
    if (this.matches(".kb")) return rect(0, 0, 2000, 1000);
    const col = this.closest(".kb-col");
    if (!col || this.matches(".kb-glide")) return rect(0, 0, 0, 0);
    const x = Array.from(col.parentElement!.children).indexOf(col) * 230;
    if (this.matches("ol.kb-list")) return rect(x, 100, 220, 800);
    if (!this.matches("li.kb-card, li.kb-ghost")) return rect(0, 0, 0, 0);
    const row = Array.from(this.parentElement!.querySelectorAll("li.kb-card, li.kb-ghost")).indexOf(this); // a drop slot is a row
    return rect(x, 100 + row * 60, 220, 54);
  });
}

describe("cards glide to their new place", () => {
  beforeEach(() => {
    layout();
  });
  afterEach(() => vi.restoreAllMocks());
  // the board refetches after a quick-add: by then an agent moved card 1 from To do to In progress
  async function moveByAgent() {
    // the list shows the latest change first: card 1 above card 2
    const [t1, t2] = [new Date(Date.now() - 1000).toISOString(), new Date(Date.now() - 2000).toISOString()];
    const before = [card({ id: 1, updated: t1 }), card({ id: 2, title: "Login stays", position: 1, updated: t2 })];
    // the move is card 1's activity: its `updated` changes, card 2 only makes room
    const moved = new Date().toISOString();
    const after = [
      card({ id: 1, column: "doing", updated: moved }),
      card({ id: 2, title: "Login stays", updated: t2 }),
    ];
    const api = fakeApi(boardData(coding, before), before);
    let data = boardData(coding, before);
    api.board = () => Promise.resolve(data);
    const view = render(<Host api={api} />);
    await screen.findByText("Fix login");
    const animate = vi.spyOn(Element.prototype, "animate");
    data = boardData(coding, after);
    fireEvent.click(screen.getAllByText("+ Add a card")[1]!);
    const ta = screen.getByLabelText("New card title in To do");
    fireEvent.change(ta, { target: { value: "new one" } });
    fireEvent.keyDown(ta, { key: "Enter" });
    await waitFor(() => expect(view.container.querySelector('li[data-id="1"]')).toHaveAttribute("data-col", "doing"));
    return { ...view, animate, setCards: (cs: Card[]) => void (data = boardData(coding, cs)) };
  }

  it("the first load moves nothing; a card an agent moved to another list flies there as a copy, removed on landing", async () => {
    const first = vi.spyOn(Element.prototype, "animate");
    const { container, animate } = await moveByAgent();
    expect(first.mock.calls.length).toBe(animate.mock.calls.length); // nothing before the move
    const root = container.querySelector<HTMLElement>(".ak-root")!;
    const moved = container.querySelector<HTMLElement>('li[data-id="1"]')!;
    const shifted = container.querySelector<HTMLElement>('li[data-id="2"]')!;
    const copies = Array.from(root.querySelectorAll<HTMLElement>(":scope > .kb-flights > li.kb-glide"));
    expect(copies).toHaveLength(2);
    const [up, fly] = copies as [HTMLElement, HTMLElement]; // list order: card 2 (To do), then card 1 (In progress)
    // the copy: over the lists, out of the pointer's and the keyboard's way, not a second card 1
    expect(fly).toHaveTextContent("Fix login");
    expect(fly).toHaveClass("kb-card", "kb-fly");
    expect(fly).not.toHaveAttribute("data-id");
    expect(fly).not.toHaveAttribute("tabindex");
    expect(fly).toHaveAttribute("inert");
    expect(fly.style.position).toBe("fixed");
    expect(fly.style.pointerEvents).toBe("none");
    expect(up).not.toHaveClass("kb-fly"); // a row up in its own list: no lift
    expect([moved.style.opacity, shifted.style.opacity]).toEqual(["0", "0"]);
    // To do is the 2nd list (x 230), In progress the 3rd (x 460): card 1 from row 0 there to row 0 here; card 2
    // one row up
    const flights = animate.mock.calls.map(([frames, o]) => [(frames as Keyframe[])[0]!.translate, o]);
    expect(flights).toEqual([
      ["0px 60px", { duration: 214, easing: "cubic-bezier(0.22, 1, 0.36, 1)" }],
      ["-230px 0px", { duration: 346, easing: "cubic-bezier(0.22, 1, 0.36, 1)" }],
    ]);
    expect(fly.style.getPropertyValue("--kb-glide-ms")).toBe("346ms");
    // the card that moved (its data changed, to another list) flies above the card making room
    expect([up.style.zIndex, fly.style.zIndex]).toEqual(["60", "3230"]);
    // landing: the copy goes, the card shows
    const [upAnim, flyAnim] = animate.mock.results.map((r) => r.value as Animation);
    flyAnim!.finish();
    expect(fly.isConnected).toBe(false);
    expect(moved.style.opacity).toBe("");
    expect(up.isConnected).toBe(true);
    upAnim!.finish();
    expect(root.querySelector(".kb-glide")).toBeNull();
    expect(shifted.style.opacity).toBe("");
  });

  it("two cards swapping one row travel as far: the one that moved (its own data changed) flies on top", async () => {
    const [t1, t2] = [new Date(Date.now() - 1000).toISOString(), new Date(Date.now() - 2000).toISOString()];
    const before = [card({ id: 1, updated: t1 }), card({ id: 2, title: "Login stays", position: 1, updated: t2 })];
    // an agent moved card 2 to the top of To do: card 2's activity, so it is the latest change; card 1 goes one row down
    const after = [
      card({ id: 1, position: 1, updated: t1 }),
      card({ id: 2, title: "Login stays", updated: new Date().toISOString() }),
    ];
    const api = fakeApi(boardData(coding, before), before);
    let data = boardData(coding, before);
    api.board = () => Promise.resolve(data);
    const { container } = render(<Host api={api} />);
    await screen.findByText("Fix login");
    data = boardData(coding, after);
    fireEvent.click(screen.getAllByText("+ Add a card")[1]!);
    const ta = screen.getByLabelText("New card title in To do");
    fireEvent.change(ta, { target: { value: "new one" } });
    fireEvent.keyDown(ta, { key: "Enter" });
    const root = container.querySelector<HTMLElement>(".ak-root")!;
    await waitFor(() => expect(root.querySelectorAll(":scope > .kb-flights > li.kb-glide")).toHaveLength(2));
    const [up, down] = Array.from(root.querySelectorAll<HTMLElement>(":scope > .kb-flights > li.kb-glide")) as [
      HTMLElement,
      HTMLElement,
    ];
    expect(up).toHaveTextContent("Login stays"); // the copy added first, under the other by DOM order alone
    expect(down).toHaveTextContent("Fix login");
    expect([up.style.zIndex, down.style.zIndex]).toEqual(["2060", "60"]);
  });

  it("the board's own move names the card that moved, though `updated` (whole seconds) did not change", async () => {
    window.localStorage.setItem("kb-order", JSON.stringify("position"));
    try {
      const t = new Date(Date.now() - 1000).toISOString(); // both cards: the same second, before and after
      const before = [card({ id: 1, updated: t }), card({ id: 2, title: "Login stays", position: 1, updated: t })];
      // the server sends a list in board order
      const after = [
        card({ id: 2, title: "Login stays", position: 0, updated: t }),
        card({ id: 1, position: 1, updated: t }),
      ];
      const api = fakeApi(boardData(coding, before), before);
      let data = boardData(coding, before);
      api.board = () => Promise.resolve(data);
      const { container } = render(<Host api={api} />);
      await screen.findByText("Login stays");
      data = boardData(coding, after);
      const two = container.querySelector<HTMLElement>('li[data-id="2"]')!;
      two.focus();
      fireEvent.keyDown(two, { key: "ArrowUp", altKey: true }); // Alt+↑: card 2 one row up
      const root = container.querySelector<HTMLElement>(".ak-root")!;
      await waitFor(() => expect(root.querySelectorAll(":scope > .kb-flights > li.kb-glide")).toHaveLength(2));
      const copies = Array.from(root.querySelectorAll<HTMLElement>(":scope > .kb-flights > li.kb-glide"));
      const z = Object.fromEntries(copies.map((c) => [c.textContent?.includes("Login stays") ? 2 : 1, c.style.zIndex]));
      expect(z).toEqual({ 2: "2060", 1: "60" });
      expect(api.calls).toContain("move 2 todo");
    } finally {
      window.localStorage.removeItem("kb-order");
    }
  });

  it("a render mid-flight leaves a card that did not move again alone; a new card fades in", async () => {
    const { container, animate } = await moveByAgent();
    const fly = container.querySelector<HTMLElement>(".ak-root > .kb-flights > li.kb-fly")!;
    const flights = animate.mock.calls.length;
    // the board renders again (the filter box): same places
    fireEvent.change(screen.getByLabelText("Filter cards"), { target: { value: "login" } });
    expect(animate.mock.calls.length).toBe(flights);
    expect(fly.isConnected).toBe(true);
    // card 2 is filtered out, then back: it fades in where it is, no copy
    fireEvent.change(screen.getByLabelText("Filter cards"), { target: { value: "fix" } });
    expect(container.querySelector('li[data-id="2"]')).toBeNull();
    expect(container.querySelectorAll(".ak-root > .kb-flights > li.kb-glide")).toHaveLength(1); // card 2's copy went with it
    fireEvent.change(screen.getByLabelText("Filter cards"), { target: { value: "" } });
    const back = container.querySelector<HTMLElement>('li[data-id="2"]')!;
    expect(animate.mock.calls.length).toBe(flights + 1);
    expect(animate.mock.contexts.at(-1)).toBe(back);
    expect(animate.mock.calls.at(-1)![0]).toEqual([{ offset: 0, opacity: 0, scale: 0.97 }]);
    expect(fly.isConnected).toBe(true);
  });

  it("a card dropped in its slot gets a still copy on top while the card making room glides under it", async () => {
    window.localStorage.setItem("kb-order", JSON.stringify("position"));
    try {
      const t = new Date(Date.now() - 1000).toISOString();
      const before = [card({ id: 1, updated: t }), card({ id: 2, title: "Login stays", position: 1, updated: t })];
      const after = [
        card({ id: 2, title: "Login stays", position: 0, updated: t }),
        card({ id: 1, position: 1, updated: t }),
      ];
      const api = fakeApi(boardData(coding, before), before);
      let data = boardData(coding, before);
      api.board = () => Promise.resolve(data);
      const { container } = render(<Host api={api} />);
      await screen.findByText("Login stays");
      data = boardData(coding, after);
      const two = container.querySelector<HTMLElement>('li[data-id="2"]')!;
      const list = two.closest<HTMLElement>("ol.kb-list")!;
      const dataTransfer = { setData() {}, effectAllowed: "", dropEffect: "" };
      fireEvent.dragStart(two, { dataTransfer });
      // jsdom has no DragEvent: a plain event carries the pointer's height
      const over = Object.assign(new Event("dragover", { bubbles: true, cancelable: true }), {
        dataTransfer,
        clientY: 110,
      });
      fireEvent(list, over); // over the top half of row 0: the slot above card 1
      await waitFor(() => expect(list.querySelector("li.kb-ghost")).not.toBeNull());
      fireEvent.drop(list, { dataTransfer, clientY: 110 });
      const root = container.querySelector<HTMLElement>(".ak-root")!;
      await waitFor(() => expect(root.querySelectorAll(":scope > .kb-flights > li.kb-glide")).toHaveLength(2));
      expect(api.calls).toContain("move 2 todo");
      const copies = Array.from(root.querySelectorAll<HTMLElement>(":scope > .kb-flights > li.kb-glide"));
      const z = Object.fromEntries(copies.map((c) => [c.textContent?.includes("Login stays") ? 2 : 1, c.style.zIndex]));
      expect(z).toEqual({ 2: "2000", 1: "60" }); // the dropped card: no way to go, on top of everything else
    } finally {
      window.localStorage.removeItem("kb-order");
    }
  });

  it("a flight lands at once when the window is resized or reduced motion is switched on mid-flight", async () => {
    const { container } = await moveByAgent();
    const layer = () => container.querySelectorAll(".ak-root > .kb-flights > li.kb-glide").length;
    expect(layer()).toBe(2);
    window.dispatchEvent(new Event("resize"));
    expect(layer()).toBe(0);
    expect(container.querySelector<HTMLElement>('li[data-id="1"]')!.style.opacity).toBe("");
  });

  it("reduced motion switched on mid-flight lands every copy", async () => {
    const { container } = await moveByAgent();
    const mq = window.matchMedia("(prefers-reduced-motion: reduce)") as MediaQueryList & { set(m: boolean): void };
    try {
      mq.set(true);
      expect(container.querySelectorAll(".kb-glide")).toHaveLength(0);
    } finally {
      mq.set(false);
    }
  });

  it("a flight moved again goes on from where its copy is now (the eased offset left), not from its scaled box", async () => {
    const { container, animate, setCards } = await moveByAgent();
    const fly = animate.mock.results[1]!.value as Animation & { progress: number };
    fly.progress = 0.5; // card 1 halfway: -230 px → -115 px still to go
    setCards([
      card({ id: 1, updated: new Date().toISOString() }),
      card({ id: 2, title: "Login stays", position: 1, updated: new Date(Date.now() - 2000).toISOString() }),
    ]);
    const one = container.querySelector<HTMLElement>('li[data-id="1"]')!;
    one.focus();
    fireEvent.keyDown(one, { key: "ArrowLeft", altKey: true }); // Alt+←: back to To do
    const isOne = (el: unknown) =>
      el instanceof HTMLElement && el.classList.contains("kb-glide") && el.textContent?.includes("Fix login");
    await waitFor(() => expect(animate.mock.contexts.filter(isOne)).toHaveLength(2));
    const last = animate.mock.contexts
      .map((c, i) => [c, i] as const)
      .filter(([c]) => isOne(c))
      .at(-1)![1];
    const [frames] = animate.mock.calls[last]! as [Keyframe[]];
    // In progress (x 460) → To do (x 230), from 115 px short of In progress: 345 - 230 = +115 px
    expect(frames[0]!.translate).toMatch(/^115px /);
  });

  it("prefers-reduced-motion: reduce → nothing moves", async () => {
    const media = vi
      .spyOn(window, "matchMedia")
      .mockImplementation((q) => ({ matches: true, media: q }) as MediaQueryList);
    const { container, animate } = await moveByAgent();
    expect(media).toHaveBeenCalledWith("(prefers-reduced-motion: reduce)");
    expect(animate).not.toHaveBeenCalled();
    expect(container.querySelector(".kb-glide")).toBeNull();
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
