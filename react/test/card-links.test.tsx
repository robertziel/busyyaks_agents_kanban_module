// The Links rail's rows in jsdom: a plain link is the row it always was (kind · label, title = url); a tagged link shows
// tone chips on the same line and, with detail, a popover on mouse hover, on keyboard focus and pinned by a tap on the chips.
import { act, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
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

  it("CardLinks: every PR is listed (a PR section never folds), one section per PR group (role) in first-seen order", () => {
    const prs: CardLink[] = [1, 2, 3, 4, 5].map((n) => ({
      kind: "pr",
      label: `#${n}`,
      url: `https://github.com/o/r_local/pull/${n}`,
      group: n === 3 ? "public" : "local",
    }));
    const { container } = render(<CardLinks links={[...prs, { kind: "pr", label: "#9", url: "https://x/p/9" }]} />);
    const sections = Array.from(container.querySelectorAll("section.kb-link-group"));
    expect(sections.map((s) => [s.querySelector("h5")!.textContent, s.querySelectorAll("li").length])).toEqual([
      ["PRs · local 4", 4],
      ["PRs · public 1", 1],
      ["Pull requests 1", 1],
    ]);
    expect(screen.queryByRole("button", { name: /more/ })).toBeNull();
    expect(sections[0]!.className).toContain("g-pr-local");
  });

  it("a grouped PR row: number and repo apart (the repo breaks at _), the section's own tag left out, the label's text whole", () => {
    const link: CardLink = {
      kind: "pr",
      label: "#91 busy_kanban_mirror",
      url: "https://github.com/o/busy_kanban_mirror/pull/91",
      group: "local",
      tags: [
        { text: "local", tone: "info" },
        { text: "open", tone: "ok" },
      ],
    };
    const { container } = render(<CardLinks links={[link]} />);
    expect(container.querySelector("h5")!.textContent).toBe("PRs · local 1");
    expect(container.querySelector(".kb-link-ref")!.textContent).toBe("#91");
    expect(container.querySelector(".kb-link-name")!.textContent).toBe("busy_kanban_mirror");
    expect(container.querySelectorAll(".kb-link-name wbr").length).toBe(2);
    expect(screen.getByRole("link", { name: "#91 busy_kanban_mirror" })).toBeTruthy();
    expect(Array.from(container.querySelectorAll(".kb-link-tag")).map((x) => x.textContent)).toEqual(["open"]);
    expect(container.querySelector("li")!.className).toBe("kb-link-row");
  });

  it("history: a struck link — the row marked struck, its chip and popover as any row's, no unassign", () => {
    const gone: CardLink = {
      kind: "pr",
      label: "#88 r_local",
      url: "https://github.com/o/r_local/pull/88",
      group: "removed",
      struck: true,
      tags: [{ text: "11-16", tone: "muted" }],
      detail: [{ label: "Why", value: "replaced by #91" }],
    };
    const { container } = render(
      <CardLinks links={[gone, { ...gone, url: "u2", tags: undefined, detail: undefined }]} />,
    );
    const rows = Array.from(container.querySelectorAll("li"));
    expect(rows.map((r) => r.className)).toEqual(["kb-link-row struck", "kb-link-row struck"]);
    expect(rows[0]!.querySelector(".kb-link-tag")!.textContent).toBe("11-16");
    expect(container.querySelector("h5")!.textContent).toBe("PRs · removed 2");
    expect(screen.queryByRole("button", { name: /Unassign/ })).toBeNull();
  });

  describe("the unassign form", () => {
    const assigned: CardLink = { ...pr, label: "#5 r_local", unassign: true };
    const open = (onUnassign: (l: CardLink, reason: string) => Promise<string | null>) => {
      const view = render(<CardLinks links={[assigned]} onUnassign={onUnassign} />);
      const x = screen.getByRole<HTMLButtonElement>("button", { name: "Unassign #5 r_local" });
      fireEvent.click(x);
      const box = screen.getByRole<HTMLInputElement>("textbox", { name: /Why #5 r_local is not this card's PR/ });
      return { ...view, x, box, go: screen.getByRole<HTMLButtonElement>("button", { name: "Unassign" }) };
    };

    it("× opens it in the row with the caret in the reason box; no reason = nothing to send; Enter sends it trimmed", async () => {
      const sent: string[] = [];
      const { container, x, box, go } = open((l, reason) => {
        sent.push(`${l.url} ${reason}`);
        return Promise.resolve(null);
      });
      expect(container.querySelector("li")!.className).toBe("kb-link-row has-unassign asking");
      expect(x.getAttribute("aria-expanded")).toBe("true");
      expect(document.activeElement).toBe(box);
      expect(go.disabled).toBe(true);
      fireEvent.change(box, { target: { value: "   " } });
      expect(go.disabled).toBe(true);
      fireEvent.submit(box.form!);
      expect(sent).toEqual([]);
      fireEvent.change(box, { target: { value: " opened for card 12 " } });
      expect(go.disabled).toBe(false);
      fireEvent.submit(box.form!);
      await waitFor(() => expect(screen.queryByRole("textbox")).toBeNull()); // done: the form closes
      expect(sent).toEqual(["https://github.com/o/r_local/pull/5 opened for card 12"]);
      expect(document.activeElement).toBe(container.querySelector(".kb-link-groups")); // the focus: the rail, not the page
    });

    it("Escape and a second × close it without sending; Escape stays in the form (the dialog's keys never see it)", () => {
      const onUnassign = vi.fn(() => Promise.resolve(null));
      const outer = vi.fn();
      document.addEventListener("keydown", outer);
      const { x, box } = open(onUnassign);
      fireEvent.change(box, { target: { value: "typed" } });
      const esc = new KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true });
      act(() => void box.dispatchEvent(esc));
      expect(esc.defaultPrevented).toBe(true); // a <dialog> around it does not close
      expect(outer).not.toHaveBeenCalled();
      expect(screen.queryByRole("textbox")).toBeNull();
      expect(document.activeElement).toBe(x); // focus back on the ×
      fireEvent.click(x);
      expect(screen.getByRole<HTMLInputElement>("textbox").value).toBe(""); // a fresh form, not the old text
      fireEvent.click(x); // the × again closes it
      expect(screen.queryByRole("textbox")).toBeNull();
      fireEvent.click(x);
      const onX = new KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true });
      act(() => void x.dispatchEvent(onX)); // Escape with the focus on the ×: the form, never the dialog
      expect(onX.defaultPrevented).toBe(true);
      expect(screen.queryByRole("textbox")).toBeNull();
      expect(onUnassign).not.toHaveBeenCalled();
      document.removeEventListener("keydown", outer);
    });

    it("a refusal is said under the box and the form stays with the reason; busy while it is sent", async () => {
      let answer: (v: string | null) => void = () => {};
      const { box, go, x } = open(() => new Promise((r) => (answer = r)));
      fireEvent.change(box, { target: { value: "not ours" } });
      fireEvent.submit(box.form!);
      expect(go.disabled).toBe(true);
      expect([go.textContent, go.getAttribute("aria-busy")]).toEqual(["Unassign", "true"]);
      expect([box.readOnly, box.disabled]).toEqual([true, false]); // read-only, not disabled: the focus stays in it
      expect(x.disabled).toBe(true); // one request per form: no second × while it runs
      expect(document.activeElement).toBe(box);
      act(() => answer("PR is not assigned to card #2"));
      const alert = await screen.findByRole("alert");
      expect(alert.textContent).toBe("PR is not assigned to card #2");
      expect(box.value).toBe("not ours");
      expect(box.getAttribute("aria-invalid")).toBe("true");
      expect(box.getAttribute("aria-describedby")).toBe(alert.id);
      expect(go.disabled).toBe(false);
      expect([box.readOnly, x.disabled]).toEqual([false, false]);
      expect(document.activeElement).toBe(box); // the caret is where the reason is fixed
    });

    it("sent from its button: Escape does nothing while it is sent, and a refusal brings the caret back to the box", async () => {
      let answer: (v: string | null) => void = () => {};
      const { box, go } = open(() => new Promise((r) => (answer = r)));
      fireEvent.change(box, { target: { value: "not ours" } });
      go.focus();
      fireEvent.click(go);
      expect(go.disabled).toBe(true);
      go.blur(); // the browser drops the focus of a button that gets disabled
      fireEvent.keyDown(box.form!, { key: "Escape" });
      expect(screen.getByRole("textbox")).toBe(box); // still open: the answer has a form to land in
      expect(screen.queryByRole("button", { name: "Cancel" })).toBeNull(); // two controls: the box and Unassign
      act(() => answer("refused"));
      expect((await screen.findByRole("alert")).textContent).toBe("refused");
      expect(document.activeElement).toBe(box);
    });

    it("while it is open the row's detail popover stays shut", () => {
      const { container } = open(() => Promise.resolve(null));
      fireEvent.pointerEnter(container.querySelector("li")!, { pointerType: "mouse" });
      expect(screen.queryByRole("tooltip")).toBeNull();
    });
  });
});
