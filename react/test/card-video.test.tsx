// Video attachments (mp4 / webm, `video: true`): a thumbnail of the first frame with a play button in the card
// dialog's Attachments section; a click, or a click on its file chip in a comment, plays it in the lightbox with the
// browser's own controls. Pictures keep their <img> lightbox; other files stay download rows.
import { act, fireEvent, render, screen, within } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { Board, type KanbanApi } from "../src";
import type { Attachment, Card, CardData } from "../src/types";
import { boardData, fixture } from "./fixtures";
import { intersect } from "./setup";

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
  attachments: 3,
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

const att = (id: number, filename: string, content_type: string, image: boolean, video: boolean): Attachment => ({
  id,
  card_id: 7,
  comment_id: null,
  filename,
  content_type,
  size: 1234,
  sha256: "x",
  image,
  video,
  uploaded_by: "op",
  created: "2026-11-01T10:00:00Z",
  url: `/api/attachments/${id}`,
  download_url: `/api/attachments/${id}/download`,
  markdown: "",
});

function renderBoard() {
  const cardData: CardData = {
    card: {
      ...theCard,
      attachments: [
        att(1, "shot.png", "image/png", true, false),
        att(2, "rec.webm", "video/webm", false, true),
        att(3, "build.log", "text/plain", false, false),
      ],
      description: "",
      description_html: "",
      checklists: [],
    },
    activity: [
      {
        id: 50,
        kind: "comment",
        author: "op",
        at: "2026-11-01T10:00:00Z",
        body: "see",
        body_html:
          '<p><a class="kb-file-chip" href="/api/attachments/2/download" data-attachment="2" download>rec.webm</a></p>',
      },
    ],
    pings: [],
    links: [],
  };
  const known: Partial<KanbanApi> = {
    board: () => Promise.resolve(boardData(coding, [theCard])),
    boardRev: () => Promise.resolve("r1"),
    card: () => Promise.resolve(cardData),
    cardRev: () => Promise.resolve("c1"),
    markdownPreview: () => Promise.resolve("<p>preview</p>"),
  };
  const api = new Proxy({} as KanbanApi, {
    get: (_t, k: string) => (known as Record<string, unknown>)[k] ?? (() => Promise.resolve({})),
  });
  render(<Board api={api} me="me" slug="g/r" view={{ card: 7, panel: null, archived: false }} onView={() => {}} />);
}

describe("video attachments", () => {
  it("a video is a thumbnail with a play button, not a download row", async () => {
    renderBoard();
    const play = await screen.findByLabelText("Play rec.webm");
    expect(play.querySelector("video")).toBeNull(); // nothing fetched until the thumbnail nears the viewport
    act(() => intersect());
    const v = play.querySelector("video");
    expect(v?.getAttribute("src")).toBe("/api/attachments/2#t=0.1");
    expect(v?.getAttribute("preload")).toBe("metadata");
    expect(screen.getByLabelText("Open shot.png")).toBeInTheDocument();
    expect(document.querySelectorAll(".kb-files > li")).toHaveLength(1); // build.log only
  });

  it("clicking the thumbnail plays it in the lightbox with controls; Esc closes it", async () => {
    renderBoard();
    fireEvent.click(await screen.findByLabelText("Play rec.webm"));
    const lb = document.querySelector<HTMLElement>(".kb-lightbox")!;
    const v = within(lb).getByLabelText("rec.webm");
    expect(v.tagName).toBe("VIDEO");
    expect(v.hasAttribute("controls")).toBe(true);
    expect(v.getAttribute("src")).toBe("/api/attachments/2");
    expect(lb.querySelector("img")).toBeNull();
    expect(lb.querySelector("figcaption a[download]")?.getAttribute("href")).toBe("/api/attachments/2/download");
    fireEvent.keyDown(within(lb).getByLabelText("Close video"), { key: "Escape" });
    expect(document.querySelector(".kb-lightbox")).toBeNull();
  });

  it("a video's file chip in a comment plays it instead of downloading", async () => {
    renderBoard();
    const chip = await screen.findByText("rec.webm", { selector: "a.kb-file-chip" });
    fireEvent.click(chip);
    const lb = document.querySelector<HTMLElement>(".kb-lightbox")!;
    expect(within(lb).getByLabelText("rec.webm").tagName).toBe("VIDEO");
  });

  it("a picture still opens as an image", async () => {
    renderBoard();
    fireEvent.click(await screen.findByLabelText("Open shot.png"));
    const lb = document.querySelector<HTMLElement>(".kb-lightbox")!;
    expect(lb.querySelector("img")?.getAttribute("src")).toBe("/api/attachments/1");
    expect(lb.querySelector("video")).toBeNull();
  });
});
