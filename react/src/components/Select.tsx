// Custom select: a trigger + a frosted listbox portalled to <body>, or to the open <dialog> it sits in (so no overflow clips it, and the top layer does not hide it). Keyboard: arrows,
// Home/End, Enter/Space, Escape, Tab, type-ahead. One open at a time; closes on outside pointer, scroll, resize.
// (busyyaks's Select, ported; the portal carries .ak-root for the primitives, and the trigger's resolved --ak-* tokens —
// .ak-root alone would reset them to the engine defaults, not the host's theme.)
import {
  useCallback,
  useEffect,
  useId,
  useLayoutEffect,
  useRef,
  useState,
  type KeyboardEvent,
  type ReactNode,
} from "react";
import { createPortal } from "react-dom";
import { akTokens } from "../lib/theme";

export type Option = { value: string; label: string };
type Props = {
  options: Option[];
  value: string;
  onChange: (value: string) => void;
  ariaLabel?: string;
  ariaLabelledBy?: string;
  align?: "start" | "end";
  className?: string; // trigger class: "sel-btn" (default) or "btn primary small split-menu"
  disabled?: boolean;
  children?: ReactNode; // trigger content; default = selected label + chevron
};

let closeOpen: (() => void) | null = null;

// The open <dialog> a trigger sits in (its menu is portalled there), or null.
const dialogOf = (el: HTMLElement | null): HTMLDialogElement | null =>
  (el?.closest("dialog[open]") as HTMLDialogElement | null) ?? null;

export function Select({
  options,
  value,
  onChange,
  ariaLabel,
  ariaLabelledBy,
  align = "start",
  className = "sel-btn",
  disabled,
  children,
}: Props) {
  const id = useId();
  const btn = useRef<HTMLButtonElement>(null);
  const menu = useRef<HTMLUListElement>(null);
  const [open, setOpen] = useState(false);
  const [active, setActive] = useState(-1);
  const [pos, setPos] = useState<{ left: number; top: number; minWidth: number } | null>(null);
  const typed = useRef({ s: "", at: 0 });
  const current = options.find((o) => o.value === value);

  const close = useCallback((refocus: boolean) => {
    setOpen(false);
    setPos(null);
    setActive(-1);
    if (closeOpen === closeRef.current) closeOpen = null;
    if (refocus) btn.current?.focus({ preventScroll: true });
  }, []);
  const closeRef = useRef<() => void>(() => close(false));
  closeRef.current = () => close(false);

  const openMenu = () => {
    if (disabled || open) return;
    closeOpen?.();
    closeOpen = closeRef.current;
    setOpen(true);
    const i = options.findIndex((o) => o.value === value);
    setActive(i < 0 ? 0 : i);
  };

  useLayoutEffect(() => {
    if (!open || !btn.current || !menu.current) return;
    const r = btn.current.getBoundingClientRect();
    const m = menu.current;
    // the menu's own .ak-root resets every token to the engine default: give it the theme the trigger sees.
    // A snapshot at open: a skin / OS-scheme change while it is open shows at the next open — the menu is transient (any
    // outside pointer, scroll, resize or another Select closes it).
    for (const [name, value] of akTokens(getComputedStyle(btn.current))) m.style.setProperty(name, value);
    const minWidth = Math.max(160, Math.round(r.width));
    m.style.minWidth = `${minWidth}px`;
    const mw = m.offsetWidth;
    const mh = m.offsetHeight;
    let left = align === "end" ? r.right - mw : r.left;
    left = Math.max(8, Math.min(left, window.innerWidth - mw - 8));
    let top = r.bottom + 4;
    if (top + mh > window.innerHeight - 8 && r.top - mh - 4 > 8) top = r.top - mh - 4;
    // Inside a modal <dialog> (the card dialog: showModal = the top layer) the menu is portalled INTO the dialog — a menu in
    // <body> would sit under the top layer, invisible — and positioned against it; elsewhere against the page.
    const host = dialogOf(btn.current);
    if (host) {
      const h = host.getBoundingClientRect();
      left = Math.max(h.left + 8, Math.min(left, h.right - mw - 8)); // the dialog clips its overflow: keep the menu inside it
      setPos({
        left: Math.round(left - h.left - host.clientLeft + host.scrollLeft),
        top: Math.round(top - h.top - host.clientTop + host.scrollTop),
        minWidth,
      });
    } else {
      setPos({ left: Math.round(left + window.scrollX), top: Math.round(top + window.scrollY), minWidth });
    }
    m.focus({ preventScroll: true });
  }, [open, align]);

  useEffect(() => {
    if (!open) return;
    const onDown = (e: PointerEvent) => {
      const t = e.target as Node;
      if (!menu.current?.contains(t) && !btn.current?.contains(t)) close(false);
    };
    const onScroll = (e: Event) => {
      if (!(e.target instanceof Element && menu.current?.contains(e.target))) close(false);
    };
    const onResize = () => close(false);
    document.addEventListener("pointerdown", onDown);
    document.addEventListener("scroll", onScroll, true);
    window.addEventListener("resize", onResize);
    return () => {
      document.removeEventListener("pointerdown", onDown);
      document.removeEventListener("scroll", onScroll, true);
      window.removeEventListener("resize", onResize);
    };
  }, [open, close]);

  useEffect(() => {
    // Scroll the MENU only (scrollIntoView would also scroll the dialog the menu sits in — and a scroll outside the menu closes it).
    const m = menu.current;
    const li = open && active >= 0 ? (m?.children[active] as HTMLElement | undefined) : undefined;
    if (!m || !li) return;
    if (li.offsetTop < m.scrollTop) m.scrollTop = li.offsetTop;
    else if (li.offsetTop + li.offsetHeight > m.scrollTop + m.clientHeight)
      m.scrollTop = li.offsetTop + li.offsetHeight - m.clientHeight;
  }, [active, open]);

  const choose = (i: number) => {
    const o = options[i];
    if (o) onChange(o.value);
    close(true);
  };

  const typeahead = (ch: string) => {
    const now = Date.now();
    const t = typed.current;
    t.s = now - t.at > 500 ? ch : t.s + ch;
    t.at = now;
    const same = t.s.length > 1 && t.s.split("").every((c) => c === t.s[0]);
    const needle = same ? t.s[0]! : t.s;
    const n = options.length;
    for (let k = 0; k < n; k++) {
      const i = (active + 1 + k) % n;
      if (options[i]!.label.trim().toLowerCase().startsWith(needle)) return setActive(i);
    }
  };

  const onMenuKey = (e: KeyboardEvent<HTMLUListElement>) => {
    const n = options.length;
    switch (e.key) {
      case "ArrowDown":
        e.preventDefault();
        setActive((a) => Math.min(n - 1, a + 1));
        break;
      case "ArrowUp":
        e.preventDefault();
        setActive((a) => Math.max(0, a - 1));
        break;
      case "Home":
      case "PageUp":
        e.preventDefault();
        setActive(0);
        break;
      case "End":
      case "PageDown":
        e.preventDefault();
        setActive(n - 1);
        break;
      case "Enter":
      case " ":
        e.preventDefault();
        choose(active);
        break;
      case "Escape":
        e.preventDefault();
        e.stopPropagation();
        close(true);
        break;
      case "Tab":
        close(false);
        break;
      default:
        if (e.key.length === 1 && !e.ctrlKey && !e.metaKey && !e.altKey) {
          e.preventDefault();
          typeahead(e.key.toLowerCase());
        }
    }
  };

  return (
    <>
      <button
        ref={btn}
        type="button"
        className={className}
        aria-haspopup="listbox"
        aria-expanded={open}
        aria-controls={`${id}-menu`}
        aria-label={ariaLabel}
        aria-labelledby={ariaLabelledBy}
        disabled={disabled}
        onClick={() => (open ? close(true) : openMenu())}
        onKeyDown={(e) => {
          if (e.key === "ArrowDown" || e.key === "ArrowUp") {
            e.preventDefault();
            openMenu();
          }
        }}
      >
        {children ?? (
          <>
            <span className="sel-label">{current?.label ?? "—"}</span>
            <span className="chev" aria-hidden="true" />
          </>
        )}
      </button>
      {open &&
        createPortal(
          <ul
            ref={menu}
            id={`${id}-menu`}
            className="menu ak-root"
            role="listbox"
            aria-label={ariaLabel}
            tabIndex={-1}
            aria-activedescendant={active >= 0 ? `${id}-${active}` : undefined}
            style={
              pos ? { left: pos.left, top: pos.top, minWidth: pos.minWidth } : { left: 0, top: 0, visibility: "hidden" }
            }
            onKeyDown={onMenuKey}
            onBlur={(e) => {
              const t = e.relatedTarget as Node | null;
              if (!t || (!menu.current?.contains(t) && t !== btn.current)) close(false);
            }}
          >
            {options.map((o, i) => (
              <li
                key={o.value}
                id={`${id}-${i}`}
                role="option"
                className={`item${i === active ? " active" : ""}`}
                aria-selected={o.value === value}
                tabIndex={-1}
                onMouseMove={() => active !== i && setActive(i)}
                onClick={(e) => {
                  e.preventDefault();
                  choose(i);
                }}
              >
                {o.label}
              </li>
            ))}
          </ul>,
          dialogOf(btn.current) ?? document.body,
        )}
    </>
  );
}
