// The card dialog's attachments (card #542): ONE row of miniatures, newest first, the latest marked; each tile names
// the comment that shows it; a file no comment shows sits on its "attached" event, which stays visible with the
// details hidden (rendering with details hidden once threw: the event join was read before it was declared).
import { act, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { Board, type KanbanApi } from "../src";
import type { Activity, Attachment, Card, CardData } from "../src/types";
import { boardData, fixture } from "./fixtures";

const coding = fixture("coding");
const theCard = {
  id: 7,
  project: "g/r",
  owner_session: "s1",
  owner_socket: null,
  approved: null,
  approved_by: null,
  column: "doing",
  position: 0,
  title: "Talk",
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
} as Card;

const file = (id: number, created: string, o: Partial<Attachment> = {}): Attachment => ({
  id,
  card_id: 7,
  comment_id: null,
  filename: `shot${id}.png`,
  content_type: "image/png",
  size: 2048,
  sha256: "x",
  image: true,
  video: false,
  uploaded_by: "agent-1",
  created,
  url: `/api/attachments/${id}`,
  download_url: `/api/attachments/${id}/download`,
  markdown: `![shot${id}.png](/api/attachments/${id})`,
  ...o,
});

const files = [
  file(1, "2026-11-18T10:00:00Z"), // in no comment: shown on its event
  file(2, "2026-11-18T11:00:00Z", { comment_id: 20 }),
  file(3, "2026-11-18T12:00:00Z", { filename: "run.log", content_type: "text/plain", image: false }),
];
const activity: Activity[] = [
  { id: 10, at: "2026-11-18T10:00:00Z", kind: "attachment", author: "agent-1", body: "attached shot1.png (2.0 KB)" },
  { id: 11, at: "2026-11-18T10:30:00Z", kind: "move", author: "agent-1", body: "moved to In progress" },
  {
    id: 20,
    at: "2026-11-18T11:00:00Z",
    kind: "comment",
    author: "agent-1",
    body: "![shot2.png](/api/attachments/2)",
    body_html: "<p>see</p>",
  },
  { id: 30, at: "2026-11-18T12:00:00Z", kind: "attachment", author: "agent-1", body: "attached run.log (2.0 KB)" },
];

const deleted: number[] = [];

function fakeApi(): KanbanApi {
  const cardData: CardData = {
    card: { ...theCard, attachments: files, description: "", description_html: "", checklists: [] },
    activity,
    pings: [],
    links: [],
  };
  const data = boardData(coding, [theCard]);
  const known: Partial<KanbanApi> = {
    board: () => Promise.resolve(data),
    boardRev: () => Promise.resolve("r1"),
    card: () => Promise.resolve(cardData),
    cardRev: () => Promise.resolve("c1"),
    markdownPreview: () => Promise.resolve("<p>preview</p>"),
    attachmentDelete: (id) => {
      deleted.push(id);
      return Promise.resolve(cardData);
    },
  };
  return new Proxy({} as KanbanApi, {
    get: (_t, k: string) => (known as Record<string, unknown>)[k] ?? (() => Promise.resolve({})),
  });
}

const renderDialog = () =>
  render(
    <Board api={fakeApi()} me="me" slug="g/r" view={{ card: 7, panel: null, archived: false }} onView={() => {}} />,
  );

describe("card attachments", () => {
  it("one row of miniatures, the latest first and marked, each naming the comment that shows it", async () => {
    renderDialog();
    const row = await screen.findByRole("list", { name: "Attachments, newest first" });
    const tiles = within(row).getAllByRole("listitem");
    expect(tiles.map((t) => t.getAttribute("data-attachment"))).toEqual(["3", "2", "1"]);
    expect(tiles[0]).toHaveClass("latest");
    expect(within(tiles[0] as HTMLElement).getByText("latest")).toBeInTheDocument();
    expect(
      within(tiles[1] as HTMLElement).getByRole("link", { name: "Show comment 20 for shot2.png" }),
    ).toHaveAttribute("href", "#a-20");
    expect(within(tiles[2] as HTMLElement).queryByRole("link", { name: /Show comment/ })).toBeNull();
    expect(within(tiles[0] as HTMLElement).getByRole("button", { name: "Delete run.log" })).toBeInTheDocument();
    // each tile names its file on screen too (touch has no hover)
    expect(tiles.map((t) => t.querySelector(".kb-tile-name")?.textContent)).toEqual([
      "run.log",
      "shot2.png",
      "shot1.png",
    ]);
  });

  it("with the details hidden: the events of files no comment shows stay, with their miniature; others go", async () => {
    renderDialog();
    fireEvent.click(await screen.findByRole("button", { name: "Hide details" }));
    const ev = document.getElementById("a-10");
    expect(ev).not.toBeNull();
    expect(within(ev as HTMLElement).getByRole("button", { name: "Open shot1.png" })).toBeInTheDocument();
    expect(document.getElementById("a-30")).not.toBeNull(); // run.log: in no comment either
    expect(document.getElementById("a-11")).toBeNull(); // a plain event: hidden
    expect(document.getElementById("a-20")).not.toBeNull(); // the comment
  });

  it("a picture opens the lightbox with Download and Delete; Delete asks, then deletes that file and closes", async () => {
    renderDialog();
    const row = await screen.findByRole("list", { name: "Attachments, newest first" });
    fireEvent.click(within(row).getByRole("button", { name: "Open shot2.png" }));
    const box = screen.getByRole("dialog", { name: "shot2.png" });
    expect(within(box).getByRole("link", { name: /Download/ })).toHaveAttribute("href", "/api/attachments/2/download");
    fireEvent.click(within(box).getByRole("button", { name: "Delete" }));
    expect(deleted).toEqual([]); // asked first
    // shot2.png is shown by comment 20: the confirm says that comment keeps a broken link
    expect(within(box).getByText(/^Delete\? comment #20 keeps a broken link/)).toBeInTheDocument();
    fireEvent.click(within(box).getByRole("button", { name: "Yes" }));
    await waitFor(() => expect(deleted).toEqual([2]));
    expect(screen.queryByRole("dialog", { name: "shot2.png" })).toBeNull();
  });

  it("a tile's comment link brings the comment into view: centred, top-aligned when tall, re-aligned while pictures load", async () => {
    const calls: { id: string; block?: ScrollLogicalPosition; behavior?: ScrollBehavior }[] = [];
    const original = Object.getOwnPropertyDescriptor(Element.prototype, "scrollIntoView");
    Element.prototype.scrollIntoView = function (this: Element, o?: boolean | ScrollIntoViewOptions) {
      const opts = typeof o === "object" ? o : {};
      calls.push({ id: this.id, block: opts.block, behavior: opts.behavior });
    };
    // every observer by what it watches: the comment list's is the jump's re-align
    const watching = new Map<Element, () => void>();
    vi.stubGlobal(
      "ResizeObserver",
      class {
        private els: Element[] = [];
        constructor(private cb: () => void) {}
        observe(el: Element) {
          this.els.push(el);
          watching.set(el, this.cb);
        }
        disconnect() {
          for (const e of this.els) if (watching.get(e) === this.cb) watching.delete(e);
        }
        unobserve() {}
      },
    );
    const resized = () => watching.get(document.getElementById("a-20")!.parentElement!)?.();
    try {
      renderDialog();
      const link = await screen.findByRole("link", { name: "Show comment 20 for shot2.png" });
      fireEvent.click(link);
      await waitFor(() => expect(calls.filter((c) => c.id === "a-20")).toHaveLength(1));
      expect(calls.at(-1)).toEqual({ id: "a-20", block: "center", behavior: "instant" }); // instant, centred
      expect(document.activeElement).toBe(document.getElementById("a-20")); // focused: a screen reader hears it
      // the comment is now taller than its box (jsdom's box: the window), its pictures loaded: top-aligned, again
      const el = document.getElementById("a-20")!;
      el.getBoundingClientRect = () => ({ height: window.innerHeight }) as DOMRect;
      act(() => resized());
      expect(calls.at(-1)).toEqual({ id: "a-20", block: "start", behavior: "instant" });
      // the reader scrolls: no more re-aligning
      fireEvent.wheel(window);
      act(() => resized());
      expect(calls.filter((c) => c.id === "a-20")).toHaveLength(2);
    } finally {
      if (original) Object.defineProperty(Element.prototype, "scrollIntoView", original);
      else delete (Element.prototype as Partial<Element>).scrollIntoView;
      vi.unstubAllGlobals();
    }
  });
});
