// One row of the card dialog's Links rail: kind chip · label · the host's tags as small tone chips. A link with `detail`
// gets a popover (key / value rows + the url) on hover and keyboard focus; on touch a tap on the chips pins it open
// (the label itself navigates). The popover is position: fixed and placed by lib/links.ts so neither the rail's nor
// the dialog's scroll box clips it. A link without tags / detail is the plain row it always was.
import { useEffect, useId, useLayoutEffect, useRef, useState, type FocusEvent, type PointerEvent } from "react";
import {
  GROUP_FOLD,
  groupLinks,
  hasDetail,
  hasTags,
  linkTitle,
  placePopover,
  toneClass,
  type Placement,
} from "../lib/links";
import type { CardLink } from "../types";

export const LINK_KIND: Record<string, string> = {
  repo: "repo",
  branch: "branch",
  site: "site",
  url: "url",
  commit: "commit",
  file: "file",
  pr: "PR",
  ci: "CI",
};

// grouped: the row sits under its section's header (CardLinks), which names the kind — the kind chip is left out.
export function CardLinkRow({ link: l, grouped = false }: { link: CardLink; grouped?: boolean }) {
  const popId = useId();
  const detail = hasDetail(l);
  const tags = hasTags(l);
  const [hover, setHover] = useState(false);
  const [pinned, setPinned] = useState(false);
  const open = detail && (hover || pinned);
  const row = useRef<HTMLLIElement>(null);
  const pop = useRef<HTMLDListElement>(null);
  const [at, setAt] = useState<Placement | null>(null);

  const close = () => {
    setHover(false);
    setPinned(false);
  };
  // the details' text (e.g. "read 1 min ago") may change while open: re-place on it
  const detailKey = JSON.stringify(l.detail ?? null);
  useLayoutEffect(() => {
    if (!open || !row.current || !pop.current) {
      setAt(null);
      return;
    }
    const place = () => {
      if (!row.current || !pop.current) return;
      const r = row.current.getBoundingClientRect();
      // the box that scrolls: the grouped rail (CardLinks), or a bare list
      const box = (row.current.closest(".kb-link-groups") ?? row.current.closest(".kb-links"))?.getBoundingClientRect();
      if (box && (r.bottom < box.top || r.top > box.bottom)) return close(); // its row scrolled out of the rail
      const p = pop.current.getBoundingClientRect();
      setAt(
        placePopover(r, { width: p.width, height: p.height }, { width: window.innerWidth, height: window.innerHeight }),
      );
    };
    place();
    window.addEventListener("resize", place);
    window.addEventListener("scroll", place, true);
    return () => {
      window.removeEventListener("resize", place);
      window.removeEventListener("scroll", place, true);
    };
  }, [open, detailKey]);

  // open: a press outside the row closes it (touch has no hover-out, Safari never focuses the button), Escape closes it
  // — only it, not the dialog around it
  useEffect(() => {
    if (!open) return;
    const down = (e: globalThis.PointerEvent) => {
      if (row.current && e.target instanceof Node && !row.current.contains(e.target)) close();
    };
    const key = (e: KeyboardEvent) => {
      if (e.key !== "Escape") return;
      e.preventDefault();
      e.stopPropagation();
      close();
    };
    document.addEventListener("pointerdown", down, true);
    document.addEventListener("keydown", key, true);
    return () => {
      document.removeEventListener("pointerdown", down, true);
      document.removeEventListener("keydown", key, true);
    };
  }, [open]);
  // hover = a mouse only: a tap fires mouseenter too, which would open it with no way to close
  const enter = (e: PointerEvent) => e.pointerType === "mouse" && setHover(true);
  const leave = (e: PointerEvent) => e.pointerType === "mouse" && setHover(false);
  // focus opens it for the keyboard only: a click focuses the link, and coming back from its tab would reopen it
  const focusIn = (e: FocusEvent<HTMLElement>) => {
    if (e.currentTarget.matches(":focus-visible")) setHover(true);
  };

  const blur = (e: FocusEvent<HTMLElement>) => {
    if (row.current && e.relatedTarget instanceof Node && row.current.contains(e.relatedTarget)) return;
    close();
  };
  const anchor = (
    <a
      className={grouped ? "kb-link-bare" : undefined}
      href={l.url}
      target={l.url.startsWith("/") ? undefined : "_blank"}
      rel="noopener"
      title={linkTitle(l)}
      aria-describedby={open ? popId : undefined}
      onFocus={detail ? focusIn : undefined}
      onBlur={detail ? blur : undefined}
    >
      {!grouped && <span className={`kb-link-kind k-${l.kind}`}>{LINK_KIND[l.kind]}</span>}
      <span className="kb-link-label">{l.label}</span>
    </a>
  );
  if (!tags && !detail) return <li>{anchor}</li>;

  const chips = (l.tags ?? []).map((t, i) => (
    <span key={i} className={`kb-link-tag ${toneClass(t.tone)}`}>
      {t.text}
    </span>
  ));
  return (
    <li
      ref={row}
      className={`kb-link-row${open ? " open" : ""}`}
      onPointerEnter={detail ? enter : undefined}
      onPointerLeave={detail ? leave : undefined}
    >
      {anchor}
      {tags &&
        (detail ? (
          <button
            type="button"
            className="kb-link-tags"
            aria-label={`Details of ${l.label}`}
            aria-expanded={open}
            aria-describedby={open ? popId : undefined}
            onClick={() => (open ? close() : setPinned(true))}
            onFocus={focusIn}
            onBlur={blur}
          >
            {chips}
          </button>
        ) : (
          <span className="kb-link-tags">{chips}</span>
        ))}
      {open && (
        <dl
          ref={pop}
          id={popId}
          role="tooltip"
          className={`kb-link-pop s-${at?.side ?? "left"}`}
          style={at ? { left: at.left, top: at.top, visibility: "visible" } : { left: 0, top: 0, visibility: "hidden" }}
        >
          {(l.detail ?? []).map((d, i) => (
            <div key={i} className="kb-link-pop-row">
              <dt>{d.label}</dt>
              <dd>{d.value}</dd>
            </div>
          ))}
          <div className="kb-link-pop-row kb-link-pop-url">
            <dt>URL</dt>
            <dd>{l.url}</dd>
          </div>
        </dl>
      )}
    </li>
  );
}

// The Links rail: the card's links in sections (lib/links LINK_GROUPS), each a small header with its count, then the rows
// without their kind chip; a section longer than GROUP_FOLD folds the rest behind "+N more".
export function CardLinks({ links }: { links: CardLink[] }) {
  const [unfolded, setUnfolded] = useState<Record<string, boolean>>({});
  return (
    <div className="kb-link-groups">
      {groupLinks(links).map((g) => {
        const open = unfolded[g.key] || g.links.length <= GROUP_FOLD + 1; // never fold a single row behind "+1 more"
        const shown = open ? g.links : g.links.slice(0, GROUP_FOLD);
        return (
          <section key={g.key} className={`kb-link-group g-${g.key.replace(/[^a-z0-9-]/gi, "-")}`} aria-label={g.label}>
            <h5>
              {g.label} <span className="kb-link-count">{g.links.length}</span>
            </h5>
            <ul className="kb-links">
              {shown.map((l) => (
                <CardLinkRow key={l.url} link={l} grouped />
              ))}
            </ul>
            {g.links.length > GROUP_FOLD + 1 && (
              <button
                type="button"
                className="kb-link-more"
                aria-expanded={open}
                onClick={() => setUnfolded((u) => ({ ...u, [g.key]: !open }))}
              >
                {open ? "Show less" : `+${g.links.length - GROUP_FOLD} more`}
              </button>
            )}
          </section>
        );
      })}
    </div>
  );
}
