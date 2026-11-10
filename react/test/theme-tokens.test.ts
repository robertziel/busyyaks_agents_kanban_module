import { readFileSync } from "node:fs";
import { join } from "node:path";
import { AK_TOKENS } from "../src/lib/theme";

// AK_TOKENS (what a portalled Select menu copies from its trigger) is exactly the token set
// kanban.css's .ak-root block declares — a token added there and not here would fall back to its default in a menu.
describe("AK_TOKENS", () => {
  it("equals the tokens kanban.css declares on .ak-root", () => {
    const css = readFileSync(join(__dirname, "..", "src", "styles", "kanban.css"), "utf8");
    const block = /^\.ak-root \{([\s\S]*?)^\}/m.exec(css)![1]!;
    const declared = [...new Set([...block.matchAll(/(--ak-[a-z0-9-]+)\s*:/g)].map((m) => m[1]))].sort();
    expect([...AK_TOKENS].sort()).toEqual(declared);
  });
});
