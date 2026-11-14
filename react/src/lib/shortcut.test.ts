import { describe, expect, it } from "vitest";
import {
  comboKeys,
  comboLabel,
  comboRefusal,
  isMac,
  keyName,
  matchesCombo,
  parseCombo,
  type KeyCombo,
} from "./shortcut";

const k = (code: string, m: Partial<KeyCombo> = {}): KeyCombo => ({
  code,
  alt: false,
  ctrl: false,
  meta: false,
  shift: false,
  ...m,
});

describe("shortcut", () => {
  it("matches by key position and the exact modifiers", () => {
    const altM = k("KeyM", { alt: true });
    const ev = (code: string, mods: Partial<Record<"altKey" | "ctrlKey" | "metaKey" | "shiftKey", boolean>>) => ({
      code,
      altKey: false,
      ctrlKey: false,
      metaKey: false,
      shiftKey: false,
      ...mods,
    });
    expect(matchesCombo(ev("KeyM", { altKey: true }), altM)).toBe(true);
    expect(matchesCombo(ev("KeyM", { altKey: true, shiftKey: true }), altM)).toBe(false);
    expect(matchesCombo(ev("KeyN", { altKey: true }), altM)).toBe(false);
  });

  it("labels: Mac symbols, words elsewhere", () => {
    const c = k("KeyD", { ctrl: true, alt: true, shift: true, meta: true });
    expect(comboLabel(c, true)).toBe("⌃⌥⇧⌘D");
    expect(comboLabel(c, false)).toBe("Ctrl+Alt+Shift+Win+D");
    expect(comboLabel(k("KeyM", { alt: true }), true)).toBe("⌥M");
    expect(keyName("Digit4")).toBe("4");
    expect(isMac("MacIntel")).toBe(true);
    expect(isMac("Linux x86_64")).toBe(false);
  });

  it("the keys one by one (a cap each), modifiers first; only modifiers while the key is still to come", () => {
    const c = k("KeyD", { ctrl: true, alt: true, shift: true, meta: true });
    expect(comboKeys(c, true)).toEqual(["⌃", "⌥", "⇧", "⌘", "D"]);
    expect(comboKeys(c, false)).toEqual(["Ctrl", "Alt", "Shift", "Win", "D"]);
    expect(comboKeys(k("F2"), false)).toEqual(["F2"]);
    expect(comboKeys(k("", { alt: true, shift: true }), false)).toEqual(["Alt", "Shift"]);
    expect(comboKeys(k(""), true)).toEqual([]);
  });

  it("refuses what the browser, the OS or the editor owns, and keys that would fire while typing", () => {
    expect(comboRefusal(k("KeyM", { alt: true }))).toBeNull();
    expect(comboRefusal(k("KeyD", { ctrl: true, alt: true }))).toBeNull();
    expect(comboRefusal(k("KeyD", { ctrl: true, shift: true }))).toBe("bookmarks all tabs (Chrome)");
    expect(comboRefusal(k("KeyW", { ctrl: true }))).toBe("closes the tab"); // the reason never repeats the combo
    expect(comboRefusal(k("F2"))).toBeNull();
    expect(comboRefusal(k("KeyS", { meta: true }))).toMatch(/saves the page/);
    expect(comboRefusal(k("KeyM", { meta: true }))).toMatch(/minimises/);
    expect(comboRefusal(k("KeyB", { ctrl: true }))).toMatch(/editor/);
    expect(comboRefusal(k("KeyM"))).toMatch(/plain key/);
    expect(comboRefusal(k("KeyM", { shift: true }))).toMatch(/plain key/);
    expect(comboRefusal(k("AltLeft", { alt: true }))).toMatch(/modifier alone/);
    expect(comboRefusal(k("Escape", { alt: true }))).toMatch(/editor and dialogs/);
  });

  it("reads back only a whole combo", () => {
    expect(parseCombo({ code: "KeyM", alt: true, ctrl: false, meta: false, shift: false })).toEqual(
      k("KeyM", { alt: true }),
    );
    for (const bad of [
      null,
      "x",
      {},
      { code: "", alt: true, ctrl: false, meta: false, shift: false },
      { code: "KeyM" },
    ])
      expect(parseCombo(bad)).toBeNull();
  });
});
