// The Links rail's rows in jsdom: a plain link is the row it always was (kind · label, title = url); a tagged link shows
// tone chips on the same line and, with detail, a popover on mouse hover, on keyboard focus and pinned by a tap on the chips.
import { act, fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { CardLinkRow, CardLinks } from "../src";
import type { CardLink } from "../src/types";

const pr: CardLink = {
  kind: "pr",
  label: "#5",
  url: "https://github.com/o/r_local/pull/5",
  tags: [
    { text: "alpha", tone: "info" },
    { text: "finished", tone: "done" },
  ],
  detail: [
    { label: "Repo", value: "o/r_local" },
    { label: "State", value: "finished" },
    { label: "Read", value: "2 min ago" },
  ],
};

describe("CardLinkRow", () => {
  it("a link without tags or detail renders as before: kind chip, label, the url as title, no popover", () => {
    const { container } = render(
      <ul>
        <CardLinkRow
          link={{ kind: "branch", label: "card/163-pr-flags", url: "https://github.com/o/r/tree/card/163" }}
        />
      </ul>,
    );
    const a = container.querySelector("li > a")!;
    expect(a.getAttribute("title")).toBe("https://github.com/o/r/tree/card/163");
    expect(a.getAttribute("target")).toBe("_blank");
    expect(Array.from(a.children).map((c) => c.className)).toEqual(["kb-link-kind k-branch", "kb-link-label"]);
    expect(container.querySelector(".kb-link-row")).toBeNull();
    expect(container.querySelector(".kb-link-tags")).toBeNull();
    fireEvent.pointerEnter(container.querySelector("li")!, { pointerType: "mouse" });
    expect(screen.queryByRole("tooltip")).toBeNull();
  });

  it("tags are tone chips beside the label; detail opens a popover on hover with every row and the url, and closes on leave", () => {
    const { container } = render(
      <ul>
        <CardLinkRow link={pr} />
      </ul>,
    );
    const row = container.querySelector("li.kb-link-row")!;
    const chips = Array.from(row.querySelectorAll(".kb-link-tag"));
    expect(chips.map((c) => [c.textContent, c.className])).toEqual([
      ["alpha", "kb-link-tag t-info"],
      ["finished", "kb-link-tag t-done"],
    ]);
    const a = row.querySelector("a")!;
    expect(a.getAttribute("title")).toBeNull(); // the popover carries it: no second tooltip
    expect(screen.queryByRole("tooltip")).toBeNull();
    fireEvent.pointerEnter(row, { pointerType: "touch" }); // a tap's pointerenter: no hover on touch
    expect(screen.queryByRole("tooltip")).toBeNull();
    fireEvent.pointerEnter(row, { pointerType: "mouse" });
    const pop = screen.getByRole("tooltip");
    expect(Array.from(pop.querySelectorAll("dt")).map((d) => d.textContent)).toEqual(["Repo", "State", "Read", "URL"]);
    expect(Array.from(pop.querySelectorAll("dd")).map((d) => d.textContent)).toEqual([
      "o/r_local",
      "finished",
      "2 min ago",
      pr.url,
    ]);
    expect(a.getAttribute("aria-describedby")).toBe(pop.id);
    fireEvent.pointerLeave(row, { pointerType: "mouse" });
    expect(screen.queryByRole("tooltip")).toBeNull();
  });

  it("keyboard focus on the link shows the popover; a click's focus does not", () => {
    const { container } = render(
      <ul>
        <CardLinkRow link={pr} />
      </ul>,
    );
    const a = container.querySelector<HTMLAnchorElement>("li.kb-link-row a")!;
    const visible = (on: boolean) =>
      Object.defineProperty(a, "matches", {
        configurable: true,
        value: (sel: string) => (sel === ":focus-visible" ? on : false),
      });
    visible(false);
    fireEvent.focus(a);
    expect(screen.queryByRole("tooltip")).toBeNull();
    visible(true);
    fireEvent.focus(a);
    expect(screen.getByRole("tooltip")).toBeInTheDocument();
    fireEvent.blur(a, { relatedTarget: document.body });
    expect(screen.queryByRole("tooltip")).toBeNull();
  });

  it("a tap on the chips pins it; the next tap, a press outside or Escape (only the popover, not the dialog) close it", () => {
    const { container } = render(
      <ul>
        <CardLinkRow link={pr} />
      </ul>,
    );
    const row = container.querySelector("li.kb-link-row")!;
    const chips = screen.getByRole("button", { name: "Details of #5" });
    expect(chips.getAttribute("aria-expanded")).toBe("false");
    fireEvent.pointerEnter(row, { pointerType: "touch" });
    fireEvent.click(chips);
    expect(chips.getAttribute("aria-expanded")).toBe("true");
    fireEvent.pointerLeave(row, { pointerType: "mouse" }); // pinned: the mouse leaving does not close it
    expect(screen.getByRole("tooltip")).toBeInTheDocument();
    fireEvent.click(chips);
    expect(screen.queryByRole("tooltip")).toBeNull();
    fireEvent.click(chips);
    fireEvent.pointerDown(document.body);
    expect(screen.queryByRole("tooltip")).toBeNull();
    fireEvent.click(chips);
    const esc = new KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true });
    act(() => {
      document.body.dispatchEvent(esc);
    });
    expect(esc.defaultPrevented).toBe(true);
    expect(screen.queryByRole("tooltip")).toBeNull();
  });

  it("tags without detail are plain chips (no button, no popover); a long value in detail is shown whole", () => {
    const { container } = render(
      <ul>
        <CardLinkRow
          link={{
            kind: "pr",
            label: "#7",
            url: "https://github.com/o/r/pull/7",
            tags: [{ text: "pending", tone: "muted" }],
          }}
        />
        <CardLinkRow
          link={{
            kind: "pr",
            label: "#8",
            url: "https://github.com/o/r/pull/8",
            tags: [{ text: "unknown", tone: "warn" }],
            detail: [
              { label: "Why", value: "GitHub read failed: 401 Bad credentials — the token was rejected by the API" },
            ],
          }}
        />
      </ul>,
    );
    const [first, second] = Array.from(container.querySelectorAll("li.kb-link-row"));
    expect(first!.querySelector("span.kb-link-tags")).not.toBeNull();
    expect(first!.querySelector("button")).toBeNull();
    fireEvent.pointerEnter(first!, { pointerType: "mouse" });
    expect(screen.queryByRole("tooltip")).toBeNull();
    fireEvent.pointerEnter(second!, { pointerType: "mouse" });
    expect(screen.getByRole("tooltip").querySelector("dd")!.textContent).toMatch(
      /^GitHub read failed: 401 Bad credentials/,
    );
  });

  it("CardLinks: sections with a count, rows without the kind chip, a long section folds behind +N more", () => {
    const commits: CardLink[] = [1, 2, 3, 4, 5].map((n) => ({
      kind: "commit",
      label: `c${n}`,
      url: `https://x/c/${n}`,
    }));
    const { container } = render(
      <CardLinks links={[pr, ...commits, { kind: "repo", label: "o/r", url: "https://x/r" }]} />,
    );
    const sections = Array.from(container.querySelectorAll("section.kb-link-group"));
    expect(sections.map((s) => s.querySelector("h5")!.textContent)).toEqual([
      "Pull requests 1",
      "Commits 5",
      "Repo & web 1",
    ]);
    expect(container.querySelector(".kb-link-kind")).toBeNull();
    const commitRows = () => sections[1]!.querySelectorAll("li").length;
    expect(commitRows()).toBe(3);
    fireEvent.click(screen.getByRole("button", { name: "+2 more" }));
    expect(commitRows()).toBe(5);
    fireEvent.click(screen.getByRole("button", { name: "Show less" }));
    expect(commitRows()).toBe(3);
  });
});
