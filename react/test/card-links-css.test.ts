import { readFileSync } from "node:fs";
import { join } from "node:path";

// The Links rail never grows wider than itself (jsdom lays nothing out, so the rules are read from kanban.css): a host
// may hand a row many chips or a long one (`base: feature/live-agent-status`). Before, the chips
// never wrapped, an auto grid track grew to the widest chip, and on a phone the whole rail scrolled sideways, its
// labels cut off.
const css = readFileSync(join(__dirname, "..", "src", "styles", "kanban.css"), "utf8");
const rule = (selector: string) => {
  const at = css.indexOf(`${selector} {`);
  expect(at, selector).toBeGreaterThanOrEqual(0);
  return css.slice(at, css.indexOf("}", at));
};

describe("the Links rail's width", () => {
  it("its lists' grid track is the rail's width, never a chip's", () => {
    expect(rule(".ak-root .kb-links")).toMatch(/grid-template-columns: minmax\(0, 1fr\)/);
    expect(rule(".ak-root .kb-link-groups")).toMatch(/grid-template-columns: minmax\(0, 1fr\)/);
  });

  it("the chips wrap among themselves, and a chip wider than the row ends in an ellipsis", () => {
    const tags = rule(".ak-root .kb-link-tags");
    expect(tags).toMatch(/flex-wrap: wrap/);
    expect(tags).toMatch(/max-width: 100%/);
    const tag = rule(".ak-root .kb-link-tag");
    for (const d of [/max-width: 100%/, /min-width: 0/, /overflow: hidden/, /text-overflow: ellipsis/])
      expect(tag).toMatch(d);
  });
});
