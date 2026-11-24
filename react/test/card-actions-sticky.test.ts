import { readFileSync } from "node:fs";
import { join } from "node:path";

// The actions that move a card (the Approve step, the Transition list) are the rail's LAST block and
// stick to the bottom of the dialog's scroll port, so a long card never hides them. jsdom lays nothing out, so the
// sticky rules are read from kanban.css; board.test.tsx pins which controls are in the block.
const css = readFileSync(join(__dirname, "..", "src", "styles", "kanban.css"), "utf8");
const rules = (selector: string) => {
  const out: string[] = [];
  for (let at = css.indexOf(`${selector} {`); at >= 0; at = css.indexOf(`${selector} {`, at + 1))
    out.push(css.slice(at, css.indexOf("}", at)));
  expect(out.length, selector).toBeGreaterThan(0);
  return out.join("\n");
};

describe("the card dialog's action block", () => {
  it("sticks to the dialog's bottom: sticky, pushed to the rail's end, opaque; no scroll container between it and the dialog", () => {
    const acts = rules(".ak-root .kb-side-acts");
    for (const d of [/position: sticky/, /bottom: 0/, /margin-top: auto/, /background: var\(--ak-panel\)/])
      expect(acts).toMatch(d);
    const side = rules(".ak-root .kb-side");
    expect(side).toMatch(/align-self: stretch/);
    expect(side).toMatch(/flex-direction: column/);
    // overflow hidden/auto on the rail would make it the sticky's scroll port (it never scrolls, so nothing sticks)
    expect(side).not.toMatch(/overflow(-[xy])?: (hidden|auto|scroll)/);
    expect(rules(".ak-root .kb-dbody")).not.toMatch(/overflow/);
    expect(rules(".ak-root .kb-dialog")).toMatch(/overflow-y: auto/);
    // a field focused or scrolled into view lands above the bar (CardDialog sets --kb-acts-h to the bar's height)
    expect(rules(".ak-root .kb-dialog")).toMatch(
      /scroll-padding-bottom: max\(var\(--kb-acts-h, 0px\), var\(--kb-dock-h, 0px\)\)/,
    );
  });

  // the comment box is the main column's last block and sticks the same way
  it("the comment box sticks to the dialog's bottom, opaque, with no scroll container between it and the dialog", () => {
    const dock = rules(".ak-root .kb-comment-dock");
    for (const d of [/position: sticky/, /bottom: 0/, /margin-top: auto/, /background: var\(--ak-panel\)/])
      expect(dock).toMatch(d);
    const main = rules(".ak-root .kb-main");
    expect(main).toMatch(/flex-direction: column/);
    expect(main).toMatch(/align-self: stretch/);
    expect(main).not.toMatch(/overflow(-[xy])?: (hidden|auto|scroll)/);
    // as specific as the dialog's editor rule (max-height: 55vh) and after it: a long draft scrolls inside the box
    const cap = css.indexOf(".ak-root .kb-detail .kb-comment-dock .mde .mde-area > textarea");
    expect(cap).toBeGreaterThan(css.indexOf(".ak-root :is(.kb-add, .ak-root .kb-detail) .mde .mde-area > textarea {"));
    expect(css.slice(cap, css.indexOf("}", cap))).toMatch(/max-height: min\(30vh, 240px\)/);
  });

  it("typing in the comment box never scrolls the card: no scroll padding while focus is inside it", () => {
    expect(rules(".ak-root .kb-dialog:has(.kb-comment-dock:focus-within)")).toMatch(/scroll-padding-bottom: 0;/);
  });

  it("the box and the bar never cover the dialog: capped against the bar, which stays on screen while typing", () => {
    expect(rules(".ak-root .kb-comment-dock")).toMatch(/max-height: 60vh/);
    // the sticky action bar holds while typing: nothing takes the bar out of its sticky place
    expect(css).not.toMatch(/\.kb-side-acts \{\s*position: static;/);
    expect(css).toMatch(/max-height: calc\(100vh - var\(--kb-acts-h, 0px\) - 160px\);/);
    // the warning's headline (<b>) stays while typing: only its details fold
    expect(css).toMatch(
      /\.kb-comment-dock:has\(textarea:focus\) :is\(\.kb-nolisten-warn > :not\(b\), \.kb-delivered\) \{\s*display: none;/,
    );
  });

  it("one column (phone): the comment box rests on the action bar and focus lands above both", () => {
    const at = css.indexOf("@media (max-width: 760px) {\n  .ak-root .kb {");
    const media = css.slice(at, css.indexOf("\n}\n", at));
    expect(media).toMatch(/\.ak-root \.kb-main \{\s*display: contents;/);
    expect(media).toMatch(/\.ak-root \.kb-comment-dock \{\s*order: 1;\s*bottom: var\(--kb-acts-h, 0px\);/);
    expect(media).toMatch(/\.ak-root \.kb-side > \.kb-side-acts \{\s*order: 2;/);
    expect(media).toMatch(/scroll-padding-bottom: calc\(var\(--kb-acts-h, 0px\) \+ var\(--kb-dock-h, 0px\)\)/);
  });

  it("one column (phone): the rail's blocks join the body's flex column, so the full-width bar sticks over the whole card", () => {
    const at = css.indexOf("@media (max-width: 760px) {\n  .ak-root .kb {");
    expect(at).toBeGreaterThanOrEqual(0);
    const media = css.slice(at, css.indexOf("\n}\n", at));
    expect(media).toMatch(/\.ak-root \.kb-dbody \{\s*display: flex;\s*flex-direction: column;\s*align-items: stretch;/);
    expect(media).toMatch(/\.ak-root \.kb-side \{\s*display: contents;/);
    expect(media).toMatch(
      /\.ak-root \.kb-side > \.kb-side-acts \{\s*max-width: none;\s*margin: 0 calc\(-1 \* var\(--kb-gutter\)\) calc\(-1 \* var\(--kb-gutter-bottom\)\);/,
    );
    expect(media).toMatch(/\.ak-root \.kb-side-main \{\s*grid-template-columns: repeat\(2, minmax\(0, 1fr\)\);/);
  });
});
