import { readFileSync } from "node:fs";
import { join } from "node:path";

// The board header is one grid (jsdom lays nothing out, so the rules are read from kanban.css):
// one control height on one row pitch, the summary over the filter row, the tools — the small square Workflow button
// among them — at that row's end.
const css = readFileSync(join(__dirname, "..", "src", "styles", "kanban.css"), "utf8");
const rule = (selector: string, from = 0) => {
  const at = css.indexOf(`${selector} {`, from);
  expect(at, selector).toBeGreaterThanOrEqual(0);
  return css.slice(at, css.indexOf("}", at));
};

describe("the board header's grid", () => {
  it("has one control height and two columns: the filter's and the tools'", () => {
    const head = rule(".ak-root .kb-head");
    expect(head).toMatch(/--kb-ctl: 28px/);
    expect(head).toMatch(/gap: var\(--kb-gap\)/);
    expect(head).toMatch(/grid-template-columns: minmax\(0, 1fr\) fit-content\(40%\);/);
    expect(head).toMatch(/grid-template-areas:\s+"sum sum"\s+"filter tools";/);
  });

  it("the Workflow button is a tool like the others: its square chunk then its label, no column or row of its own", () => {
    const square = rule(".ak-root .kb-head .kb-tools > .kb-help");
    expect(square).toMatch(/width: var\(--kb-ctl\)/);
    expect(square).toMatch(/padding: 0/);
    // centred whatever the host's .btn display is
    expect(square).toMatch(/display: inline-flex/);
    expect(square).toMatch(/justify-content: center/);
    const wf = rule(".ak-root .kb-head .kb-tools > .kb-wf-btn");
    expect(wf).toMatch(/display: inline-flex/);
    expect(wf).toMatch(/align-items: center/);
    expect(wf).not.toMatch(/width/);
    expect(css).not.toMatch(/grid-area: mini|--kb-mini/);
    // its picture takes no pointer events and is sized by its own attributes (MINI_PX), never stretched
    const svg = rule(".ak-root .kb-wf-mini");
    expect(svg).toMatch(/pointer-events: none/);
    expect(svg).not.toMatch(/width|height|position/);
  });

  it("summary pills, tool buttons and filter controls share the control height", () => {
    const at = css.indexOf(".ak-root .kb-head .kb-sum > *,");
    expect(at).toBeGreaterThanOrEqual(0);
    const block = css.slice(at, css.indexOf("}", at));
    for (const sel of [
      ".kb-head .kb-tools > .btn",
      ".kb-head .kb-filter > .sel-btn",
      ".kb-head .kb-filter > input.kb-q",
      ".kb-head .kb-flabels > .kb-lchip",
    ])
      expect(block).toContain(sel);
    expect(block).toMatch(/height: var\(--kb-ctl\)/);
  });

  it("on a phone it is one column in reading order: the summary, the filter, the tools on one row", () => {
    const at = css.indexOf("/* narrow: one column in reading order");
    expect(at).toBeGreaterThanOrEqual(0);
    const media = css.slice(at, css.indexOf("\n}\n", at));
    expect(media).toMatch(/@media \(max-width: 760px\)/);
    expect(media).toMatch(/grid-template-areas:\s+"sum"\s+"filter"\s+"tools";/);
    expect(media).toMatch(/grid-template-columns: minmax\(0, 1fr\);/);
  });

  it("uses no colour of its own", () => {
    const from = css.indexOf("/* the board header, one grid");
    const to = css.indexOf(".ak-root .kb-head h1");
    expect(css.slice(from, to)).not.toMatch(/#[0-9a-f]{3,8}\b|rgba?\(/i);
  });
});
