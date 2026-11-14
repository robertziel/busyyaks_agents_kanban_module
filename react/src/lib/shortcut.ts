// A keyboard shortcut a host lets its user choose (the dictation key): a key by its POSITION (KeyboardEvent.code, so ⌥M
// still matches on a Mac where Option+M types "µ") plus the exact modifiers. Pure: matching, the label, and which
// combinations a page cannot own (the browser or the OS takes them first, or they mean something else everywhere).

export type KeyCombo = { code: string; alt: boolean; ctrl: boolean; meta: boolean; shift: boolean };

type KeyLike = { code: string; altKey: boolean; ctrlKey: boolean; metaKey: boolean; shiftKey: boolean };

export const matchesCombo = (e: KeyLike, c: KeyCombo): boolean =>
  e.code === c.code && e.altKey === c.alt && e.ctrlKey === c.ctrl && e.metaKey === c.meta && e.shiftKey === c.shift;

const MODIFIER_CODES = /^(Alt|Control|Meta|Shift|OS)(Left|Right)?$|^CapsLock$|^Fn/;

// "KeyM" → "M", "Digit4" → "4", "Space" → "Space", "F2" → "F2"
export function keyName(code: string): string {
  const m = /^(?:Key|Digit|Numpad)(.+)$/.exec(code);
  return m ? m[1]! : code;
}

// the keys of a combination, one name each, modifiers first: ["⌥", "M"] on a Mac, ["Alt", "M"] elsewhere (a key cap
// per entry). An empty code (only modifiers held so far) gives the modifiers alone.
export function comboKeys(c: KeyCombo, mac: boolean): string[] {
  const names = mac ? ["⌃", "⌥", "⇧", "⌘"] : ["Ctrl", "Alt", "Shift", "Win"];
  const held = [c.ctrl, c.alt, c.shift, c.meta];
  return [...names.filter((_, i) => held[i]), ...(c.code ? [keyName(c.code)] : [])];
}

// ⌃⌥⇧⌘M on a Mac, Ctrl+Alt+Shift+Win+M elsewhere
export const comboLabel = (c: KeyCombo, mac: boolean): string => comboKeys(c, mac).join(mac ? "" : "+");

export const isMac = (platform: string): boolean => /Mac|iPhone|iPad/i.test(platform);

const plain = { alt: false, ctrl: false, meta: false, shift: false };
// taken before the page sees them, or bound to something everywhere: [combo, why] (why without the combo: the page
// shows "<combo> — <why>")
const TAKEN: [KeyCombo, string][] = [
  [{ ...plain, code: "KeyS", meta: true }, "saves the page in every browser"],
  [{ ...plain, code: "KeyS", ctrl: true }, "saves the page in every browser"],
  [{ ...plain, code: "KeyM", meta: true }, "minimises the window (macOS)"],
  [{ ...plain, code: "KeyM", ctrl: true, shift: true }, "switches the browser profile (Chrome)"],
  [{ ...plain, code: "KeyM", meta: true, shift: true }, "opens responsive design mode (Firefox)"],
  [{ ...plain, code: "Space", ctrl: true }, "switches the input source (macOS)"],
  [{ ...plain, code: "Space", meta: true }, "opens Spotlight (macOS)"],
  [{ ...plain, code: "KeyW", meta: true }, "closes the tab"],
  [{ ...plain, code: "KeyW", ctrl: true }, "closes the tab"],
  [{ ...plain, code: "KeyT", meta: true }, "opens a tab"],
  [{ ...plain, code: "KeyT", ctrl: true }, "opens a tab"],
  [{ ...plain, code: "KeyQ", meta: true }, "quits the browser"],
  [{ ...plain, code: "KeyR", meta: true }, "reloads the page"],
  [{ ...plain, code: "KeyR", ctrl: true }, "reloads the page"],
  [{ ...plain, code: "KeyL", meta: true }, "focuses the address bar"],
  [{ ...plain, code: "KeyL", ctrl: true }, "focuses the address bar"],
  [{ ...plain, code: "KeyD", alt: true }, "focuses the address bar (Chrome, Windows / Linux)"],
  [{ ...plain, code: "KeyF", alt: true }, "opens the browser menu (Windows / Linux)"],
  [{ ...plain, code: "KeyE", alt: true }, "opens the browser menu (Windows / Linux)"],
  [{ ...plain, code: "KeyD", ctrl: true, shift: true }, "bookmarks all tabs (Chrome)"],
  [{ ...plain, code: "KeyD", meta: true, shift: true }, "bookmarks all tabs (Chrome, macOS)"],
  [{ ...plain, code: "Tab", alt: true }, "switches windows"],
  [{ ...plain, code: "F4", alt: true }, "closes the window"],
];
// the editors' own keys (Ctrl/⌘ + B I E K Enter)
const EDITOR = ["KeyB", "KeyI", "KeyE", "KeyK", "Enter"];

// why this combination cannot be the shortcut, or null when it can
export function comboRefusal(c: KeyCombo): string | null {
  if (!c.code || MODIFIER_CODES.test(c.code)) return "press a key together with the modifiers, not a modifier alone";
  const fn = /^F([1-9]|1[0-9]|2[0-4])$/.test(c.code);
  if (!fn && !c.alt && !c.ctrl && !c.meta) return "add ⌥ / Alt, ⌃ / Ctrl or ⌘: a plain key would fire while typing";
  if (["Escape", "Enter", "Tab", "Backspace"].includes(c.code))
    return `${keyName(c.code)} is used by the editor and dialogs`;
  if ((c.ctrl || c.meta) && !c.alt && !c.shift && EDITOR.includes(c.code)) return "used by the editor (format / save)";
  const t = TAKEN.find(([k]) =>
    matchesCombo({ code: k.code, altKey: k.alt, ctrlKey: k.ctrl, metaKey: k.meta, shiftKey: k.shift }, c),
  );
  return t ? t[1] : null;
}

// a value read back from storage: a KeyCombo, or null when it is not one
export function parseCombo(v: unknown): KeyCombo | null {
  if (!v || typeof v !== "object") return null;
  const o = v as Record<string, unknown>;
  const ok =
    typeof o.code === "string" &&
    o.code !== "" &&
    ["alt", "ctrl", "meta", "shift"].every((k) => typeof o[k] === "boolean");
  return ok
    ? {
        code: o.code as string,
        alt: o.alt as boolean,
        ctrl: o.ctrl as boolean,
        meta: o.meta as boolean,
        shift: o.shift as boolean,
      }
    : null;
}
