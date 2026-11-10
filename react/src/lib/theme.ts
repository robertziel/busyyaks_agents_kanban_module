// The board's --ak-* tokens as they resolve at an element. A portalled menu carries .ak-root for the
// primitives, and .ak-root re-declares every token's DEFAULT (kanban.css, incl. its prefers-color-scheme: dark set) — so
// without this the menu drops the host's theme (the inline style on the Board's root, or a host :root rule) and draws
// the engine's defaults: white text on a light host menu when the OS is dark. The trigger's resolved values are the
// truth; the portal gets exactly those. Read by NAME: browsers do not enumerate custom properties in getComputedStyle.
// AK_TOKENS = the tokens kanban.css's .ak-root block declares (test/theme-tokens.test.ts keeps the two equal).
export const AK_TOKENS = [
  "--ak-accent",
  "--ak-accent-rgb",
  "--ak-bad",
  "--ak-bad-rgb",
  "--ak-done",
  "--ak-ink",
  "--ak-ink-dim",
  "--ak-ink-faint",
  "--ak-line",
  "--ak-line-strong",
  "--ak-mat-blur",
  "--ak-mat-card",
  "--ak-mat-fill",
  "--ak-mat-fill-2",
  "--ak-menu-shadow",
  "--ak-mono",
  "--ak-ok",
  "--ak-ok-rgb",
  "--ak-panel",
  "--ak-panel-2",
  "--ak-radius-band",
  "--ak-radius-card",
  "--ak-radius-chip",
  "--ak-radius-ctl",
  "--ak-radius-ctl-sm",
  "--ak-radius-pill",
  "--ak-row-rule",
  "--ak-sans",
  "--ak-shadow-card",
  "--ak-shadow-thumb",
  "--ak-surface-3",
  "--ak-track",
  "--ak-vivid-blue",
  "--ak-vivid-green",
  "--ak-vivid-orange",
  "--ak-vivid-pink",
  "--ak-vivid-purple",
  "--ak-vivid-red",
  "--ak-vivid-teal",
  "--ak-vivid-yellow",
  "--ak-warn",
  "--ak-warn-rgb",
] as const;

export type TokenSource = Pick<CSSStyleDeclaration, "getPropertyValue">;

export function akTokens(cs: TokenSource): [string, string][] {
  const out: [string, string][] = [];
  for (const name of AK_TOKENS) {
    const value = cs.getPropertyValue(name).trim();
    if (value) out.push([name, value]);
  }
  return out;
}
