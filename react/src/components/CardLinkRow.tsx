// One row of the card dialog's Links rail: kind chip · label · the host's tags as small tone chips. A link with `detail`
// gets a popover (key / value rows + the url) on hover and keyboard focus; on touch a tap on the chips pins it open
// (the label itself navigates). The popover is position: fixed and placed by lib/links.ts so neither the rail's nor
// the dialog's scroll box clips it. A link without tags / detail is the plain row it always was.
// An assigned PR (`unassign`) carries a "×" that opens a one-line form IN the row: the reason (required) + Unassign —
// Enter sends, Escape or the × again cancels (only the form, not the dialog); a refusal is said under it, the form stays.
import {
  Fragment,
  useEffect,
  useId,
  useLayoutEffect,
  useRef,
  useState,
  type FocusEvent,
  type FormEvent,
  type KeyboardEvent as ReactKeyboardEvent,
  type PointerEvent,
} from "react";
import {
  GROUP_FOLD,
  groupLinks,
  hasDetail,
  hasTags,
  linkTitle,
  placePopover,
  prLabelParts,
  rowTags,
  toneClass,
  unassignReason,
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
// onUnassign: a row the host marks `unassign` (an assigned PR) gets the "×" and its reason form; it resolves to null
// once the PR is off the card, or to the refusal's text.
export type Unassign = (l: CardLink, reason: string) => Promise<string | null>;
export function CardLinkRow({
  link: l,
  grouped = false,
  onUnassign,
}: {
  link: CardLink;
  grouped?: boolean;
  onUnassign?: Unassign;
}) {
  const popId = useId();
  const formId = useId();
  const detail = hasDetail(l);
  const tags = hasTags(l);
  const [hover, setHover] = useState(false);
  const [pinned, setPinned] = useState(false);
  // the unassign form: null = closed, else the reason being typed
  const [reason, setReason] = useState<string | null>(null);
  const [sending, setSending] = useState(false);
  const [refused, setRefused] = useState<string | null>(null);
  const asking = reason !== null;
  const dropBtn = useRef<HTMLButtonElement>(null);
  const reasonBox = useRef<HTMLInputElement>(null);
  const open = detail && (hover || pinned) && !asking; // the form has the row: no popover over it
  const row = useRef<HTMLLIElement>(null);
  const pop = useRef<HTMLDListElement>(null);
  const [at, setAt] = useState<Placement | null>(null);

  const parts = prLabelParts(l);
  // the form opens with the caret in its reason box
  useEffect(() => {
    if (asking) reasonBox.current?.focus();
  }, [asking]);
  // a refusal puts the caret back in the box, wherever the form was sent from (its button is disabled while it is
  // sent, which drops the focus to the page) — the reason is what there is to fix
  useEffect(() => {
    if (refused !== null) reasonBox.current?.focus();
  }, [refused]);
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
      aria-label={parts ? l.label : undefined /* the split label reads as the one label it is */}
      aria-describedby={open ? popId : undefined}
      onFocus={detail ? focusIn : undefined}
      onBlur={detail ? blur : undefined}
    >
      {!grouped && <span className={`kb-link-kind k-${l.kind}`}>{LINK_KIND[l.kind]}</span>}
      <span className="kb-link-label">
        {parts ? (
          <>
            <b className="kb-link-ref">{parts.ref}</b>{" "}
            <span className="kb-link-name">
              {parts.name.map((piece, i) => (
                <Fragment key={i}>
                  {i > 0 && <wbr />}
                  {piece}
                </Fragment>
              ))}
            </span>
          </>
        ) : (
          l.label
        )}
      </span>
    </a>
  );
  const ask = () => {
    close();
    setRefused(null);
    setReason("");
  };
  const cancel = () => {
    if (sending) return; // its answer belongs to this form: no closing while it is sent
    setReason(null);
    setRefused(null);
    dropBtn.current?.focus();
  };
  const send = (e: FormEvent) => {
    e.preventDefault();
    const why = unassignReason(reason ?? "");
    if (!why || sending || !onUnassign) return;
    setSending(true);
    setRefused(null);
    void onUnassign(l, why).then((no) => {
      setSending(false);
      if (no === null) setReason(null);
      else setRefused(no);
      // done: CardLinks moves the focus to the rail — this row is gone; refused: the effect below puts the caret back
    });
  };
  // Escape closes the form only — not the dialog around it (its native cancel, its key handlers)
  const formKey = (e: ReactKeyboardEvent) => {
    if (e.key !== "Escape") return;
    e.preventDefault();
    e.stopPropagation();
    cancel();
  };
  const drop =
    l.unassign && onUnassign ? (
      <button
        type="button"
        className="kb-link-unassign"
        ref={dropBtn}
        aria-label={`Unassign ${l.label}`}
        aria-expanded={asking}
        aria-controls={asking ? formId : undefined}
        title={`Unassign ${l.label} from this card`}
        disabled={sending /* one request: its answer belongs to this form */}
        onClick={() => (asking ? cancel() : ask())}
        onKeyDown={asking ? formKey : undefined /* Escape on the × closes the form too, never the dialog */}
      >
        ×
      </button>
    ) : null;
  const form = asking ? (
    <form id={formId} className="kb-unassign-form" onSubmit={send} onKeyDown={formKey}>
      <input
        ref={reasonBox}
        value={reason}
        maxLength={300}
        placeholder="Reason"
        aria-label={`Why ${l.label} is not this card's PR (logged on the card)`}
        aria-invalid={refused !== null}
        aria-describedby={refused !== null ? `${formId}-err` : undefined}
        readOnly={sending}
        onChange={(e) => setReason(e.target.value)}
      />
      <button
        className="btn small danger kb-unassign-go"
        aria-busy={sending}
        disabled={sending || !unassignReason(reason)}
      >
        Unassign
      </button>
      {refused !== null && (
        <span id={`${formId}-err`} className="kb-unassign-err" role="alert">
          {refused}
        </span>
      )}
    </form>
  ) : null;
  const marks = `${drop ? " has-unassign" : ""}${l.struck ? " struck" : ""}${asking ? " asking" : ""}`;
  if (!tags && !detail) {
    return (
      <li className={marks ? `kb-link-row${marks}` : undefined}>
        {anchor}
        {drop}
        {form}
      </li>
    );
  }

  const chips = rowTags(l, grouped).map((t, i) => (
    <span key={i} className={`kb-link-tag ${toneClass(t.tone)}`}>
      {t.text}
    </span>
  ));
  return (
    <li
      ref={row}
      className={`kb-link-row${open ? " open" : ""}${marks}`}
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
      {drop}
      {form}
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

// The Links rail: the card's links in sections (lib/links LINK_GROUPS; a link's group = its own sub-section), each a small
// header with its count, then the rows without their kind chip; a section longer than GROUP_FOLD folds the rest behind
// "+N more" — except the PR sections, which list every PR.
export function CardLinks({ links, onUnassign }: { links: CardLink[]; onUnassign?: Unassign }) {
  const [unfolded, setUnfolded] = useState<Record<string, boolean>>({});
  const rail = useRef<HTMLDivElement>(null);
  // done: the unassigned row left its section (and took the focus with it) — the focus goes to the rail, not the page
  const unassign: Unassign | undefined = onUnassign
    ? async (l, reason) => {
        const no = await onUnassign(l, reason);
        if (no === null) rail.current?.focus();
        return no;
      }
    : undefined;
  return (
    <div ref={rail} className="kb-link-groups" tabIndex={-1}>
      {groupLinks(links).map((g) => {
        const open = !g.fold || unfolded[g.key] || g.links.length <= GROUP_FOLD + 1; // never a single row behind "+1 more"
        const shown = open ? g.links : g.links.slice(0, GROUP_FOLD);
        return (
          <section key={g.key} className={`kb-link-group g-${g.key.replace(/[^a-z0-9-]/gi, "-")}`} aria-label={g.label}>
            <h5>
              {g.label} <span className="kb-link-count">{g.links.length}</span>
            </h5>
            <ul className="kb-links">
              {shown.map((l) => (
                <CardLinkRow key={l.url} link={l} grouped onUnassign={unassign} />
              ))}
            </ul>
            {g.fold && g.links.length > GROUP_FOLD + 1 && (
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
