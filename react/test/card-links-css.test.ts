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

  it("a tagged row's label wraps instead of ending in an ellipsis (two repos that differ at the end stay apart)", () => {
    expect(rule(".ak-root .kb-links li.kb-link-row > a .kb-link-label")).not.toMatch(/nowrap|ellipsis/);
    expect(rule(".ak-root .kb-links li.kb-link-row > a")).toMatch(/flex: 1 1 0/);
  });

  it("on a phone the grouped rail spans the side's two columns", () => {
    expect(css).toMatch(/\.ak-root \.kb-side h4,\n\s+\.ak-root \.kb-side \.kb-link-groups,/);
  });

  it("the × reads >= 4.5:1 when hovered / open (its tone mixed towards the ink), and a disabled × takes no hover tint", () => {
    const hover = rule(
      '.ak-root .kb-links li.kb-link-row > .kb-link-unassign:hover:not(:disabled),\n.ak-root .kb-links li.kb-link-row > .kb-link-unassign[aria-expanded="true"]',
    );
    expect(hover).toMatch(/color: color-mix\(in srgb, var\(--ak-bad\) 70%, var\(--ak-ink\)\)/);
  });

  it("the reason form takes the row's whole width, box and button on one line; history is one line; chip text is its tone mixed towards the ink", () => {
    expect(rule(".ak-root .kb-unassign-form")).toMatch(/flex: 1 0 100%/);
    expect(rule(".ak-root .kb-unassign-form input")).toMatch(/flex: 1 1 0/);
    expect(rule(".ak-root .kb-links li.kb-link-row.struck > a .kb-link-label")).toMatch(/white-space: nowrap/);
    expect(rule(".ak-root .kb-links li.kb-link-row.struck .kb-link-name wbr")).toMatch(/display: none/);
    expect(rule(".ak-root .kb-link-tag")).toMatch(/color: color-mix\(in srgb, var\(--tag\) 70%, var\(--ak-ink\)\)/);
  });
});
