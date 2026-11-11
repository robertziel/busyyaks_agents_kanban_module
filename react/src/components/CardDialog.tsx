// The Trello-style card modal (?card=<id>, &panel=labels|due|members|checklist|cover opens a sidebar panel).
// Main: title, members/labels/due, markdown description, checklists, activity with markdown comments (author edits/deletes).
// Sidebar: move, members, labels, checklist, due, cover, priority, copy link, archive. Every write is one api call and a
// reload; errors are shown. Markdown is rendered by the server only (description_html, body_html, api.markdownPreview).
// The host injects the api and the viewer (host.tsx); the board config (columns, gates) comes with the board JSON.
// Attachments: the sidebar Attach button, a file dropped anywhere on the dialog, or pasted / dropped into an editor (which
// inserts the snippet) — each upload shows its progress and, on failure, the server's reason. Pictures open in a lightbox.
import { useEffect, useRef, useState, type FormEvent, type ReactNode } from "react";
import { errMsg } from "../api";
import { colLabel as labelOf, useKanbanHost } from "../host";
import { dragHasFiles, filesOf, formatBytes } from "../lib/attachments";
import { dueLabel, dueState, fromLocalInput, ownerSessionAllowed, toLocalInput } from "../lib/board";
import { activityAnchor, activityAnchorId, jumpNeedsDetails, SPOKEN } from "../lib/card";
import { useFetch } from "../lib/fetch";
import { isoAt } from "../lib/format";
import { pingLine } from "../lib/listen";
import { useLiveRev } from "../lib/live";
import type { Attachment, BoardData, BoardLabel, CardData, CardFull, Checklist } from "../types";
import { AgentLinks, Avatar, ErrorState, Html, Loading } from "./Bits";
import { CardLinks } from "./CardLinkRow";
import { KbIcon, type IconName } from "./KbIcon";
import { MarkdownEditor, UploadChips } from "./MarkdownEditor";
import { approvedNext, approveLabel, approveTitle, operatorMoves, stepAt } from "../lib/workflow";
import { Select } from "./Select";

export type Panel = "labels" | "due" | "members" | "checklist" | "cover" | null;
export const PANELS: Panel[] = ["labels", "due", "members", "checklist", "cover"];
type DialogProps = {
  id: number;
  slug: string;
  board: BoardData;
  panel: Panel;
  setPanel: (p: Panel) => void;
  onClose: () => void;
  onChanged: () => void;
  projectHref: string | null;
};

export function CardDialog(props: DialogProps) {
  const ref = useRef<HTMLDialogElement>(null);
  // The modal opens once per card id, not on every render: the host passes a new onClose closure each time, so Esc
  // reads the CURRENT one from a ref instead of re-running the effect (which would close and reopen the dialog).
  const onClose = useRef(props.onClose);
  onClose.current = props.onClose;
  const { id } = props;
  useEffect(() => {
    const d = ref.current;
    if (!d) return;
    if (!d.open) d.showModal();
    const onCancel = (e: Event) => {
      e.preventDefault();
      if (d.querySelector(".kb-lightbox")) return; // Esc closes the picture first (its own key handler), not the card
      onClose.current();
    };
    d.addEventListener("cancel", onCancel);
    return () => {
      d.removeEventListener("cancel", onCancel);
      if (d.open) d.close();
    };
  }, [id]);
  return (
    <dialog
      ref={ref}
      className="kb-dialog"
      aria-label="Card"
      onClick={(e) => {
        if (e.target === ref.current) props.onClose();
      }}
      onKeyDown={(e) => e.stopPropagation()}
    >
      <CardDetail key={props.id} {...props} />
    </dialog>
  );
}

function Section({
  icon,
  title,
  children,
  extra,
}: {
  icon: ReactNode;
  title: string;
  children: ReactNode;
  extra?: ReactNode;
}) {
  return (
    <section className="kb-sec">
      <h3>
        <span className="kb-sec-ico" aria-hidden="true">
          {icon}
        </span>
        {title}
        {extra}
      </h3>
      {children}
    </section>
  );
}

function CardDetail({ id, slug, board, panel, setPanel, onClose, onChanged, projectHref }: DialogProps) {
  const { api, me, config, board: shape } = useKanbanHost();
  const colLabel = (k: string) => labelOf(shape, k);
  const gates = shape.rules.gates;
  const { data, error, loading, reload } = useFetch<CardData>(() => api.card(id), [id]);
  const [title, setTitle] = useState<string | null>(null);
  const [desc, setDesc] = useState<string | null>(null); // null = not editing
  const [comment, setComment] = useState("");
  const [editing, setEditing] = useState<{ id: number; body: string } | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [copied, setCopied] = useState<string | null>(null);
  const [delivered, setDelivered] = useState<string | null>(null); // the last comment's `delivered`: who it pinged, or why nobody
  // live: comments, checklist ticks and moves by agents appear while the card is open, also while you type a
  // comment (drafts are local state, a refresh never touches them). Paused only while a save is in flight.
  // (The title input is always seeded, so `title !== null` must never pause: it froze polling for good.)
  const pause = useRef(false);
  pause.current = busy;
  const seenTitle = useRef<string | null>(null);
  useLiveRev(
    () => api.cardRev(id),
    () => void reload(),
    { paused: () => pause.current },
  );
  const [details, setDetails] = useState(true);
  const [uploads, setUploads] = useState<{ key: number; name: string; pct: number; error?: string }[]>([]);
  const [dragging, setDragging] = useState(false);
  const [lightbox, setLightbox] = useState<{ url: string; name: string; a?: Attachment } | null>(null);
  const picker = useRef<HTMLInputElement>(null);
  const seq = useRef(0);
  // a comment-reference chip (href "#a-<id>") was clicked: scroll that activity entry into view and glow it. Runs
  // after the render that switched details on, so a hidden event is in the DOM by then.
  const [jump, setJump] = useState<{ id: number; seq: number } | null>(null);
  useEffect(() => {
    if (!jump) return;
    const el = document.getElementById(activityAnchorId(jump.id));
    if (!el) return;
    el.scrollIntoView({ block: "center", behavior: "smooth" });
    el.classList.remove("kb-glow");
    void el.offsetWidth; // restart the animation on a second click
    el.classList.add("kb-glow");
    const t = window.setTimeout(() => el.classList.remove("kb-glow"), 2200);
    return () => {
      window.clearTimeout(t);
      el.classList.remove("kb-glow");
    };
  }, [jump]);

  // One file → api.attach; the card (and the board face) reload after it lands.
  const uploadFile = async (file: File, onProgress: (f: number) => void) => {
    const a = await api.attach(id, file, onProgress);
    void reload();
    onChanged();
    return a;
  };
  const attachFiles = (files: File[]) => {
    for (const f of files) {
      const key = ++seq.current;
      setUploads((u) => [...u, { key, name: f.name, pct: 0 }]);
      uploadFile(f, (pct) => setUploads((u) => u.map((x) => (x.key === key ? { ...x, pct } : x)))).then(
        () => setUploads((u) => u.filter((x) => x.key !== key)),
        (e: unknown) => setUploads((u) => u.map((x) => (x.key === key ? { ...x, error: errMsg(e) } : x))),
      );
    }
  };

  useEffect(() => {
    if (!data) return;
    // seed once; afterwards follow a title changed elsewhere unless you have edited it here
    if (title == null || (title === seenTitle.current && data.card.title !== seenTitle.current))
      setTitle(data.card.title);
    seenTitle.current = data.card.title;
  }, [data, title]);

  const run = async (fn: () => Promise<unknown>) => {
    setErr(null);
    setBusy(true);
    try {
      await fn();
      await reload();
      onChanged();
      return true;
    } catch (e) {
      setErr(errMsg(e));
      return false;
    } finally {
      setBusy(false);
    }
  };
  const patch = (body: Parameters<typeof api.update>[1]) => run(() => api.update(id, body));
  // a comment (or an answer option): the server says who it pings — shown under the box, never silent
  const sendComment = (body: string, clear: boolean) =>
    run(async () => {
      const r = await api.comment(id, body);
      setDelivered(r.delivered ?? null);
      if (clear) setComment("");
    });

  if (loading || title == null) return <Loading what={`card #${id}`} />;
  if (error && !data) return <ErrorState error={error} what={`card #${id}`} retry={() => void reload()} />;
  if (!data) return null;
  const c = data.card;
  // The Transition list: the card's own column + the OPERATOR's transitions out of it ("Start work → In progress"),
  // each sent as {transition, column} — the board's workflow decides, never a column list of this file.
  // the approval step this card is at: waiting in its `from` (a gate), approved in its `to`, or unapproved in a `to`
  // that is a gate (dragged there: approved in place)
  const at = stepAt(gates.approvals, gates.handoff?.columns ?? [], c.column, !!c.approved);
  const step = at?.step ?? null;
  const transitionMoves = operatorMoves(
    c.transitions ?? [],
    gates.approvals.find((a) => a.from === c.column) ?? null,
    !!config.approval?.requires_green_ci,
  );
  const moveOptions = [
    { value: c.column, label: colLabel(c.column) },
    ...transitionMoves.map(({ value, label }) => ({ value, label })),
  ];
  const moveTo = (v: string) => {
    if (v === c.column) return;
    const m = transitionMoves.find((t) => t.value === v);
    if (m) void run(() => api.move(id, m.move));
  };
  const colorOf = new Map(board.labels.map((l) => [l.name, l.color]));
  const ds = dueState(c.due, c.due_done, Date.now());

  const saveTitle = () => {
    const t = title.trim();
    if (t && t !== c.title) void patch({ title: t });
    else setTitle(c.title);
  };
  const copyLink = () => {
    if (!navigator.clipboard) return setCopied("Clipboard needs HTTPS");
    navigator.clipboard.writeText(window.location.href).then(
      () => setCopied("Link copied"),
      () => setCopied("Copy refused by the browser"),
    );
  };
  const comments = [...data.activity].reverse().filter((e) => details || SPOKEN.has(e.kind));
  const press = (key: string) => void run(() => api.dialogAnswer(id, key));
  const options = c.question_options ?? [];
  const files = c.attachments;
  const pictures = files.filter((a) => a.image);
  const others = files.filter((a) => !a.image);
  const del = (a: Attachment) => void run(() => api.attachmentDelete(a.id));
  // the gate the card sits in (the handoff box is named after it); elsewhere a past handoff is shown as "Check"
  const handoffCol = gates.handoff?.columns.includes(c.column) ? c.column : null;

  return (
    <article
      className={`kb-detail${dragging ? " dragging" : ""}`}
      data-card={id}
      onClick={(e) => {
        if (e.defaultPrevented) return;
        const n = activityAnchor((e.target as HTMLElement).closest?.("a")?.getAttribute("href"));
        if (n == null) return;
        e.preventDefault();
        const need = jumpNeedsDetails(data.activity, n, details);
        if (need === null) return;
        if (need) setDetails(true);
        setJump({ id: n, seq: ++seq.current });
      }}
      onDragOver={(e) => {
        if (!dragHasFiles(e.dataTransfer)) return;
        e.preventDefault();
        e.dataTransfer.dropEffect = "copy";
        if (!dragging) setDragging(true);
      }}
      onDragLeave={(e) => {
        if (!e.currentTarget.contains(e.relatedTarget as Node | null)) setDragging(false);
      }}
      // capture: a nested drop target (the markdown editor) stops propagation, and the overlay must still go
      onDropCapture={() => setDragging(false)}
      onDrop={(e) => {
        if (!dragHasFiles(e.dataTransfer)) return;
        e.preventDefault();
        attachFiles(filesOf(e.dataTransfer));
      }}
      onClickCapture={(e) => {
        // an attachment picture inside a description / comment opens the lightbox instead of navigating
        const a = (e.target as HTMLElement).closest<HTMLAnchorElement>("a.kb-att-img");
        if (!a || e.metaKey || e.ctrlKey || e.shiftKey || e.button !== 0) return;
        e.preventDefault();
        const att = files.find((x) => String(x.id) === a.dataset.attachment);
        setLightbox({
          url: a.getAttribute("href") ?? "",
          name: att?.filename ?? a.querySelector("img")?.alt ?? "attachment",
          a: att,
        });
      }}
    >
      {dragging && (
        <div className="kb-dropzone" aria-hidden="true">
          <KbIcon name="clip" />
          Drop to attach to #{id}
        </div>
      )}
      {c.cover && <div className={`kb-cover lc-${c.cover}`} aria-hidden="true" />}
      <header className="kb-dhead">
        <span className={`kb-pill kb-c-${c.column}`}>
          <i />
          {colLabel(c.column)}
        </span>
        <span className="mono muted">#{id}</span>
        {projectHref ? (
          <a href={projectHref} className="muted" onClick={onClose}>
            {slug}
          </a>
        ) : (
          <span className="muted">{slug}</span>
        )}
        {c.archived && <span className="tag">archived {isoAt(c.archived)}</span>}
        <span className="spacer" />
        <button type="button" className="btn small" onClick={onClose} aria-label="Close">
          ✕
        </button>
      </header>
      {err && (
        <div className="flash bad" role="alert">
          <i className="dot bad" />
          <span>{err}</span>
        </div>
      )}
      <textarea
        className="kb-ttl"
        rows={1}
        maxLength={200}
        aria-label="Title"
        value={title}
        onChange={(e) => setTitle(e.target.value)}
        onBlur={saveTitle}
        onKeyDown={(e) => {
          if (e.key === "Enter") {
            e.preventDefault();
            (e.target as HTMLTextAreaElement).blur();
          }
        }}
      />

      <div className="kb-dbody">
        <div className="kb-main">
          <div className="kb-facts">
            {c.assignee && (
              <div>
                <span className="kb-fact-h">Member</span>
                <button type="button" className="kb-member" onClick={() => setPanel("members")}>
                  <Avatar name={c.assignee} email={c.assignee} />
                  <span>{c.assignee}</span>
                </button>
              </div>
            )}
            {c.labels.length > 0 && (
              <div>
                <span className="kb-fact-h">Labels</span>
                <div className="kb-lchips">
                  {c.labels.map((l) => (
                    <button
                      type="button"
                      key={l}
                      className={`kb-lchip lc-${colorOf.get(l) ?? "missing"}`}
                      onClick={() => setPanel("labels")}
                    >
                      {l}
                    </button>
                  ))}
                </div>
              </div>
            )}
            {c.due && (
              <div>
                <span className="kb-fact-h">Due</span>
                <label className={`kb-due-chip d-${ds}`}>
                  <input
                    type="checkbox"
                    checked={c.due_done}
                    disabled={busy}
                    onChange={(e) => void patch({ due_done: e.target.checked })}
                    aria-label="Due date complete"
                  />
                  <button type="button" onClick={() => setPanel("due")}>
                    {dueLabel(c.due, Date.now())}
                  </button>
                  {ds === "overdue" && <b>overdue</b>}
                  {ds === "soon" && <b>due soon</b>}
                  {ds === "done" && <b>complete</b>}
                </label>
              </div>
            )}
            {c.priority && (
              <div>
                <span className="kb-fact-h">Priority</span>
                <span className={`kb-prio p-${c.priority}`}>{c.priority}</span>
              </div>
            )}
          </div>

          {(c.handoff || (handoffCol && c.column === handoffCol) || !!step) && (
            <section
              className={`kb-handoff${c.handoff ? "" : " missing"}`}
              aria-label={`${handoffCol ? colLabel(handoffCol) : "Check"} handoff`}
            >
              <header>
                <b>{handoffCol ? colLabel(handoffCol) : "Check"} handoff</b>
                {c.handoff ? (
                  <span className="muted">
                    by {c.handoff_by} · {isoAt(c.handoff)}
                  </span>
                ) : (
                  <span className="kb-handoff-warn">
                    missing — the agent did not hand it over (no QA steps, PR or CI link)
                  </span>
                )}
              </header>
              {c.handoff && (
                <>
                  <div className="kb-handoff-links">
                    {c.pr_url && (
                      <a className="gh-ref gh-pr" href={c.pr_url} target="_blank" rel="noopener">
                        GitHub PR
                        {(c.pr_url.match(/\/pull\/(\d+)/) ?? [])[1] ? ` #${c.pr_url.match(/\/pull\/(\d+)/)![1]}` : ""} ↗
                      </a>
                    )}
                    {c.ci_url && (
                      <a className="gh-ref gh-ci" href={c.ci_url} target="_blank" rel="noopener">
                        CI build ↗
                      </a>
                    )}
                    {c.ui_change ? (
                      <span className="kb-ui-flag">
                        UI change · {pictures.length} screenshot{pictures.length === 1 ? "" : "s"}
                      </span>
                    ) : (
                      <span className="muted">no UI change</span>
                    )}
                  </div>
                  <div className="kb-handoff-qa">
                    <span className="kb-fact-h">How to QA</span>
                    <Html className="md" html={c.qa_html ?? ""} />
                  </div>
                  {c.ui_change && pictures.length > 0 && (
                    <div className="kb-handoff-shots">
                      {pictures.map((a) => (
                        <button
                          type="button"
                          key={a.id}
                          className="kb-shot"
                          onClick={() => setLightbox({ url: a.url, name: a.filename, a })}
                          title={a.filename}
                        >
                          <img src={a.url} alt={a.filename} loading="lazy" />
                        </button>
                      ))}
                    </div>
                  )}
                  {c.ui_change && pictures.length === 0 && (
                    <p className="kb-handoff-warn">
                      UI change without screenshots — ask the agent for before/after shots
                    </p>
                  )}
                </>
              )}
            </section>
          )}

          {c.needs_operator && (
            <section className={`kb-question${c.question ? "" : " missing"}`} aria-label="Question for you">
              <header>
                <b>Question for you</b>
                {c.question ? (
                  <span className="muted">
                    {c.asked_by} · {isoAt(c.asked)} · in {colLabel(c.column)}
                  </span>
                ) : (
                  <span className="kb-handoff-warn">no question recorded — flagged without kanban_ask</span>
                )}
              </header>
              {c.question && <Html className="md" html={c.question_html ?? ""} />}
              {c.dialog && (
                <div className="kb-q-opts" role="group" aria-label="Dialog options">
                  {c.dialog.options.map((o) => (
                    <button
                      type="button"
                      key={o.key}
                      className="btn kb-q-opt"
                      disabled={busy || o.free}
                      onClick={() => press(o.key)}
                      title={
                        o.free
                          ? `free text: type it in the session — ${config.system_author} never types into a dialog`
                          : `Press ${o.key} in ${c.dialog!.session} (only if this dialog is still on its screen)`
                      }
                    >
                      <kbd>{o.key}</kbd> {o.label}
                    </button>
                  ))}
                  {c.dialog.escape && (
                    <button
                      type="button"
                      className="btn kb-q-opt"
                      disabled={busy}
                      onClick={() => press("esc")}
                      title={`Press Esc in ${c.dialog.session}`}
                    >
                      <kbd>Esc</kbd> cancel
                    </button>
                  )}
                </div>
              )}
              {!c.dialog && options.length > 0 && (
                <div className="kb-q-opts" role="group" aria-label="Answer options">
                  {options.map((o) => (
                    <button
                      type="button"
                      key={o}
                      className="btn kb-q-opt"
                      disabled={busy}
                      onClick={() => void sendComment(o, false)}
                      title="Post this as your answer"
                    >
                      {o}
                    </button>
                  ))}
                </div>
              )}
              <p className="kb-q-foot muted">
                {c.dialog ? (
                  <>
                    Pressed in <b className="mono">{c.dialog.session}</b> only while this dialog is still on its screen
                    → the flag clears, the card stays in {colLabel(c.column)}
                    {c.dialog.free_text ? " · free text is typed in the session itself" : ""}
                  </>
                ) : (
                  <>
                    {options.length > 0 ? "Click a choice or comment below" : "Answer with a comment below"} → the flag
                    clears, the card stays in {colLabel(c.column)} ·{" "}
                  </>
                )}
                {c.dialog ? null : c.owner_session ? (
                  <>
                    typed into <b className="mono">{c.owner_session}</b>
                  </>
                ) : (
                  <b className="err">no owner session: nobody hears it</b>
                )}
              </p>
            </section>
          )}

          {c.blocked && (
            <section className="kb-blocked-ext" aria-label="Blocked (external)">
              <header>
                <b>Blocked (external)</b>
                <span className="muted">
                  {c.blocked.by} · {isoAt(c.blocked.at)} · in {colLabel(c.column)}
                </span>
              </header>
              <p className="kb-blocked-reason">{c.blocked.reason}</p>
              {c.blocked.url && (
                <a className="gh-ref" href={c.blocked.url} target="_blank" rel="noopener">
                  {c.blocked.url} ↗
                </a>
              )}
              <p className="kb-q-foot muted">
                The card waits for something outside the board (CI, an API, a person); its agent clears the flag with
                kanban_unblock once it is gone. Agents do not move it meanwhile.
              </p>
            </section>
          )}

          <Section
            icon={<KbIcon name="desc" />}
            title="Description"
            extra={
              desc == null && c.description?.trim() ? (
                <button type="button" className="btn small kb-sec-act" onClick={() => setDesc(c.description ?? "")}>
                  Edit
                </button>
              ) : null
            }
          >
            {desc != null ? (
              <form
                className="kb-edit"
                onSubmit={(e) => {
                  e.preventDefault();
                  void patch({ description: desc }).then((ok) => ok && setDesc(null));
                }}
              >
                <MarkdownEditor
                  value={desc}
                  onChange={setDesc}
                  onUpload={uploadFile}
                  ariaLabel="Description"
                  rows={8}
                  autoFocus
                  onSubmit={() => void patch({ description: desc }).then((ok) => ok && setDesc(null))}
                  onCancel={() => setDesc(null)}
                  placeholder="Markdown: **bold**, `code`, - lists, - [ ] tasks, @name"
                />
                <div className="kb-row">
                  <button className="btn primary small" disabled={busy}>
                    Save
                  </button>
                  <button type="button" className="btn small" onClick={() => setDesc(null)}>
                    Cancel
                  </button>
                  <span className="muted kb-hint">Ctrl+Enter save · Esc cancel</span>
                </div>
              </form>
            ) : c.description?.trim() ? (
              <div className="kb-md" onDoubleClick={() => setDesc(c.description ?? "")}>
                <Html html={c.description_html ?? ""} className="md kb-md-body" />
              </div>
            ) : (
              <button type="button" className="kb-placeholder" onClick={() => setDesc("")}>
                Add a more detailed description…
              </button>
            )}
          </Section>

          {(files.length > 0 || uploads.length > 0) && (
            <Section
              icon={<KbIcon name="clip" />}
              title={`Attachments · ${files.length}`}
              extra={
                <button type="button" className="btn small kb-sec-act" onClick={() => picker.current?.click()}>
                  Add
                </button>
              }
            >
              <UploadChips uploads={uploads} dismiss={(k) => setUploads((u) => u.filter((x) => x.key !== k))} />
              {pictures.length > 0 && (
                <ul className="kb-thumbs">
                  {pictures.map((a) => (
                    <li key={a.id} className="kb-thumb" data-attachment={a.id}>
                      <button
                        type="button"
                        className="kb-thumb-img"
                        onClick={() => setLightbox({ url: a.url, name: a.filename, a })}
                        aria-label={`Open ${a.filename}`}
                      >
                        <img src={a.url} alt={a.filename} loading="lazy" />
                      </button>
                      <div className="kb-thumb-meta">
                        <span className="kb-att-name" title={a.filename}>
                          {a.filename}
                        </span>
                        <span className="muted">
                          {formatBytes(a.size)} · {a.uploaded_by} · {isoAt(a.created)}
                        </span>
                        <span className="kb-att-acts">
                          <a href={a.download_url} download className="linklike">
                            Download
                          </a>
                          <span aria-hidden="true">·</span>
                          <ConfirmButton label="Delete" confirm="Delete?" onConfirm={() => del(a)} />
                        </span>
                      </div>
                    </li>
                  ))}
                </ul>
              )}
              {others.length > 0 && (
                <ul className="kb-files">
                  {others.map((a) => (
                    <li key={a.id} data-attachment={a.id}>
                      <span className="kb-file-ico" aria-hidden="true">
                        <KbIcon name="file" />
                        <b>{a.filename.split(".").pop()?.slice(0, 4)}</b>
                      </span>
                      <span className="kb-file-main">
                        <a href={a.download_url} download className="kb-att-name" title={a.filename}>
                          {a.filename}
                        </a>
                        <span className="muted">
                          {formatBytes(a.size)} · {a.uploaded_by} · {isoAt(a.created)}
                        </span>
                      </span>
                      <span className="kb-att-acts">
                        <a
                          href={a.download_url}
                          download
                          className="btn small kb-ico-btn"
                          aria-label={`Download ${a.filename}`}
                          title="Download"
                        >
                          <KbIcon name="download" />
                        </a>
                        <ConfirmButton label="Delete" confirm="Delete?" onConfirm={() => del(a)} />
                      </span>
                    </li>
                  ))}
                </ul>
              )}
            </Section>
          )}

          {(c.checklists ?? []).map((cl) => (
            <ChecklistView key={cl.id} cl={cl} busy={busy} run={run} />
          ))}

          <Section
            icon={<KbIcon name="activity" />}
            title="Activity"
            extra={
              <button
                type="button"
                className="btn small kb-sec-act"
                aria-pressed={!details}
                onClick={() => setDetails(!details)}
              >
                {details ? "Hide details" : "Show details"}
              </button>
            }
          >
            {!c.owner_session && (
              <div className="kb-nolisten-warn" role="status">
                <b>Nobody is listening: no session owns this card</b>
                <span>
                  Comments reach no agent{c.assignee ? ` — ${c.assignee} is assigned but has no session` : ""}. Owner
                  session:
                </span>
                <OwnerSelect card={c} data={data} busy={busy} run={run} id={id} />
                {data.sessions_error && <span className="ag-err">sessions: {data.sessions_error}</span>}
              </div>
            )}
            <form
              className="kb-comment"
              onSubmit={(e: FormEvent) => {
                e.preventDefault();
                if (!comment.trim()) return;
                void sendComment(comment, true);
              }}
            >
              <Avatar name={me} email={me} />
              <div className="kb-comment-box">
                <MarkdownEditor
                  value={comment}
                  onChange={setComment}
                  onUpload={uploadFile}
                  ariaLabel="Comment"
                  rows={2}
                  placeholder="Write a comment… (markdown, @name)"
                  onSubmit={() => {
                    if (comment.trim()) void sendComment(comment, true);
                  }}
                />
                {comment.trim() && (
                  <div className="kb-row">
                    <button className="btn primary small" disabled={busy}>
                      Save
                    </button>
                    <span className="muted kb-hint">Ctrl+Enter</span>
                  </div>
                )}
              </div>
            </form>
            {delivered && (
              <p className={`kb-delivered${delivered.startsWith("none") ? " none" : ""}`} role="status">
                last comment · {delivered}
              </p>
            )}
            <ol className="kb-activity">
              {comments.map((e) =>
                e.kind === "question" || e.kind === "answer" ? (
                  <li
                    className={`c q${e.kind === "answer" ? " a" : ""}`}
                    key={e.id}
                    id={activityAnchorId(e.id)}
                    data-question={e.id}
                  >
                    <Avatar name={e.author} email={e.author} />
                    <div className="kb-cbody">
                      <div className="kb-ameta">
                        <b>{e.author}</b> <span className="kb-q-tag">{e.kind}</span>{" "}
                        <span className="muted" title={e.at}>
                          {isoAt(e.at)}
                        </span>
                      </div>
                      <div className="kb-cbubble kb-qbubble">
                        {e.body_html ? <Html html={e.body_html} className="md kb-md-body" /> : <span>{e.body}</span>}
                      </div>
                    </div>
                  </li>
                ) : e.kind === "comment" ? (
                  <li className="c" key={e.id} id={activityAnchorId(e.id)} data-comment={e.id}>
                    <Avatar name={e.author} email={e.author} />
                    <div className="kb-cbody">
                      <div className="kb-ameta">
                        <b>{e.author}</b> <AgentLinks who={e.author} card={c} links={data.session_links} />
                        <span className="muted" title={e.at}>
                          {isoAt(e.at)}
                        </span>
                        {e.edited && (
                          <span className="muted kb-edited" title={`edited ${isoAt(e.edited)}`}>
                            (edited)
                          </span>
                        )}
                      </div>
                      {editing?.id === e.id ? (
                        <form
                          className="kb-edit"
                          onSubmit={(ev) => {
                            ev.preventDefault();
                            void run(() => api.commentUpdate(e.id, editing.body)).then((ok) => ok && setEditing(null));
                          }}
                        >
                          <MarkdownEditor
                            value={editing.body}
                            onChange={(b) => setEditing({ id: e.id, body: b })}
                            onUpload={uploadFile}
                            ariaLabel="Edit comment"
                            rows={3}
                            autoFocus
                            onCancel={() => setEditing(null)}
                            onSubmit={() =>
                              void run(() => api.commentUpdate(e.id, editing.body)).then((ok) => ok && setEditing(null))
                            }
                          />
                          <div className="kb-row">
                            <button className="btn primary small" disabled={busy}>
                              Save
                            </button>
                            <button type="button" className="btn small" onClick={() => setEditing(null)}>
                              Cancel
                            </button>
                          </div>
                        </form>
                      ) : (
                        <div className="kb-cbubble">
                          <Html html={e.body_html ?? ""} className="md kb-md-body" />
                        </div>
                      )}
                      {e.author === me && editing?.id !== e.id && (
                        <div className="kb-cacts">
                          <button
                            type="button"
                            className="linklike"
                            onClick={() => setEditing({ id: e.id, body: e.body })}
                          >
                            Edit
                          </button>
                          <span aria-hidden="true">·</span>
                          <ConfirmButton
                            label="Delete"
                            confirm="Delete comment?"
                            onConfirm={() => void run(() => api.commentDelete(e.id))}
                          />
                        </div>
                      )}
                    </div>
                  </li>
                ) : (
                  <li className="ev" key={e.id} id={activityAnchorId(e.id)}>
                    <Avatar name={e.author} email={e.author} />
                    <span>
                      <b>{e.author}</b> <span className="kb-ev">{e.kind}</span> {e.body}{" "}
                      <span className="muted">{isoAt(e.at)}</span>
                    </span>
                  </li>
                ),
              )}
            </ol>
          </Section>
        </div>

        <aside className="kb-side" aria-label="Card actions">
          {data.links && data.links.length > 0 && (
            <>
              <h4>Links · {data.links.length}</h4>
              <CardLinks links={data.links} />
            </>
          )}
          <h4>Owner session</h4>
          <OwnerPanel card={c} data={data} busy={busy} run={run} id={id} />
          <h4>Add to card</h4>
          <SideBtn
            icon="user"
            label="Members"
            on={panel === "members"}
            onClick={() => setPanel(panel === "members" ? null : "members")}
          />
          {panel === "members" && (
            <MembersPanel
              current={c.assignee}
              candidates={board.assignees ?? []}
              me={me}
              busy={busy}
              onPick={(a) => void run(() => api.assign(id, a ?? ""))}
            />
          )}
          <SideBtn
            icon="tag"
            label="Labels"
            on={panel === "labels"}
            onClick={() => setPanel(panel === "labels" ? null : "labels")}
          />
          {panel === "labels" && (
            <LabelsPanel
              slug={slug}
              board={board}
              chosen={c.labels}
              busy={busy}
              run={run}
              onToggle={(ls) => void patch({ labels: ls })}
            />
          )}
          <SideBtn
            icon="check"
            label="Checklist"
            on={panel === "checklist"}
            onClick={() => setPanel(panel === "checklist" ? null : "checklist")}
          />
          <SideBtn icon="clip" label="Attach" onClick={() => picker.current?.click()} />
          <input
            ref={picker}
            type="file"
            multiple
            hidden
            aria-label="Attach files"
            data-testid="attach-input"
            onChange={(e) => {
              attachFiles(Array.from(e.target.files ?? []));
              e.target.value = "";
            }}
          />
          {panel === "checklist" && (
            <ChecklistPanel
              busy={busy}
              onAdd={(t) => void run(() => api.checklistCreate(id, t)).then((ok) => ok && setPanel(null))}
            />
          )}
          <SideBtn
            icon="clock"
            label="Due date"
            on={panel === "due"}
            onClick={() => setPanel(panel === "due" ? null : "due")}
          />
          {panel === "due" && (
            <DuePanel
              due={c.due}
              done={c.due_done}
              busy={busy}
              onSave={(due, done) => void patch({ due, due_done: done }).then((ok) => ok && setPanel(null))}
              onClear={() => void patch({ due: "", due_done: false }).then((ok) => ok && setPanel(null))}
            />
          )}
          <SideBtn
            icon="cover"
            label="Cover"
            on={panel === "cover"}
            onClick={() => setPanel(panel === "cover" ? null : "cover")}
          />
          {panel === "cover" && (
            <div className="kb-panel">
              <div className="kb-swatches">
                {board.label_colors.map((col) => (
                  <button
                    type="button"
                    key={col}
                    className={`kb-swatch lc-${col}`}
                    aria-pressed={c.cover === col}
                    title={col}
                    aria-label={`cover ${col}`}
                    onClick={() => void patch({ cover: col })}
                  />
                ))}
              </div>
              <button type="button" className="btn small" disabled={!c.cover} onClick={() => void patch({ cover: "" })}>
                Remove cover
              </button>
            </div>
          )}

          {step && (
            <div className="kb-approve">
              {c.approved ? (
                <>
                  <p className="kb-approved-now">
                    ✓ Approved by <b>{c.approved_by}</b> · {isoAt(c.approved)} — {approvedNext(step, colLabel)}
                  </p>
                  <button
                    type="button"
                    className="btn small"
                    disabled={busy}
                    onClick={() => void run(() => api.approve(id, false))}
                    title={`Withdraw: the card goes back to ${colLabel(step.from)}`}
                  >
                    Withdraw approval
                  </button>
                </>
              ) : (
                <button
                  type="button"
                  className="btn kb-approve-btn"
                  disabled={busy}
                  onClick={() => void run(() => api.approve(id, true))}
                  title={approveTitle(step, colLabel, at?.inPlace)}
                >
                  {approveLabel(step, colLabel, at?.inPlace)}
                </button>
              )}
              {!c.owner_session && !c.approved && (
                <p className="muted">no owner session — nobody will be pinged; set one above</p>
              )}
            </div>
          )}
          <h4>Actions</h4>
          <label
            className="kb-side-field"
            title={transitionMoves.length === 0 ? "no transition out of this column for you" : undefined}
          >
            <span id={`kb-list-${id}`}>Transition</span>
            <Select
              options={moveOptions}
              value={c.column}
              onChange={moveTo}
              ariaLabelledBy={`kb-list-${id}`}
              disabled={!!c.archived || busy || transitionMoves.length === 0}
            />
          </label>
          <label className="kb-side-field">
            <span id={`kb-prio-${id}`}>Priority</span>
            <Select
              options={[{ value: "", label: "—" }, ...board.priorities.map((p) => ({ value: p, label: p }))]}
              value={c.priority ?? ""}
              onChange={(v) => void patch({ priority: v })}
              ariaLabelledBy={`kb-prio-${id}`}
              disabled={busy}
            />
          </label>
          <SideBtn icon="link" label={copied ?? "Copy link"} onClick={copyLink} />
          <SideBtn
            icon="archive"
            label={c.archived ? "Restore" : "Archive"}
            onClick={() => void run(() => api.archive(id, !c.archived))}
          />
          {(c.parent || c.children > 0) && (
            <p className="kb-side-meta muted kb-deps">
              {c.parent && (
                <>
                  waits for card #{c.parent}
                  {c.blocked_by.length > 0 ? <b className="err"> · not done</b> : " · done"}
                  <br />
                </>
              )}
              {c.children > 0 && (
                <>
                  {c.children} card{c.children === 1 ? "" : "s"} wait for this one
                </>
              )}
            </p>
          )}
          <p className="kb-side-meta muted">
            created {isoAt(c.created)} · {c.created_by}
            <br />
            updated {isoAt(c.updated)}
          </p>
        </aside>
      </div>
      {lightbox && <Lightbox {...lightbox} onClose={() => setLightbox(null)} />}
    </article>
  );
}

function Lightbox({ url, name, a, onClose }: { url: string; name: string; a?: Attachment; onClose: () => void }) {
  const close = useRef<HTMLButtonElement>(null);
  useEffect(() => close.current?.focus(), []);
  return (
    <div
      className="kb-lightbox"
      role="dialog"
      aria-label={name}
      onClick={(e) => {
        if (e.target === e.currentTarget) onClose();
      }}
      onKeyDown={(e) => {
        if (e.key === "Escape") {
          e.preventDefault();
          e.stopPropagation();
          onClose();
        }
      }}
    >
      <figure>
        <img src={url} alt={name} />
        <figcaption>
          <span className="kb-att-name">{name}</span>
          {a && (
            <span className="muted">
              {formatBytes(a.size)} · {a.uploaded_by} · {isoAt(a.created)}
            </span>
          )}
          <span className="spacer" />
          <a className="btn small" href={a ? a.download_url : `${url}/download`} download>
            <KbIcon name="download" /> Download
          </a>
          <button ref={close} type="button" className="btn small" onClick={onClose} aria-label="Close picture">
            ✕
          </button>
        </figcaption>
      </figure>
    </div>
  );
}

function SideBtn({ icon, label, on, onClick }: { icon: IconName; label: string; on?: boolean; onClick: () => void }) {
  return (
    <button type="button" className="kb-sbtn" aria-expanded={on} onClick={onClick}>
      <KbIcon name={icon} />
      {label}
    </button>
  );
}

function ConfirmButton({ label, confirm, onConfirm }: { label: string; confirm: string; onConfirm: () => void }) {
  const [ask, setAsk] = useState(false);
  if (!ask)
    return (
      <button type="button" className="linklike" onClick={() => setAsk(true)}>
        {label}
      </button>
    );
  return (
    <span className="kb-confirm">
      {confirm}{" "}
      <button
        type="button"
        className="linklike err"
        onClick={() => {
          setAsk(false);
          onConfirm();
        }}
      >
        Yes
      </button>{" "}
      <button type="button" className="linklike" onClick={() => setAsk(false)}>
        No
      </button>
    </span>
  );
}

type OwnerProps = {
  card: CardFull;
  data: CardData;
  busy: boolean;
  run: (fn: () => Promise<unknown>) => Promise<boolean>;
  id: number;
};

// The owner-session picker: this project's live sessions, narrowed to the board's own (config.owner_sessions — a
// session of another project's host would receive this board's pings; the engine refuses it too). The web user is
// the operator — no live check beyond the list.
function OwnerSelect({ card, data, busy, run, id }: OwnerProps) {
  const { api, config } = useKanbanHost();
  const set = (session: string) => void run(() => api.setOwner(id, session));
  const sessions = (data.project_sessions ?? []).filter((s) => ownerSessionAllowed(config.owner_sessions, s.name));
  return (
    <select
      aria-label="Owner session"
      disabled={busy || !data.project_sessions}
      value={card.owner_session ?? ""}
      onChange={(e) => set(e.target.value)}
    >
      <option value="">— no owner session —</option>
      {card.owner_session && !sessions.some((s) => s.name === card.owner_session) && (
        <option value={card.owner_session}>{card.owner_session} (not in this project)</option>
      )}
      {sessions.map((s) => (
        <option key={`${s.socket}/${s.name}`} value={s.name}>
          {s.name} · {s.engines.join("·")} · {s.state}
        </option>
      ))}
    </select>
  );
}

function OwnerPanel({ card, data, busy, run, id }: OwnerProps) {
  const live = data.live_sessions;
  const gone = !!card.owner_session && !!live && !live.includes(card.owner_session);
  const last = data.pings?.[0];
  const line = last ? pingLine(last) : null;
  return (
    <div className="kb-owner-panel">
      {card.owner_session ? (
        <p className={`kb-owner-now${gone ? " gone" : ""}`}>
          <b>{card.owner_session}</b>{" "}
          {gone ? "· gone — the watchdog releases this card" : "· comments are typed into it"}
        </p>
      ) : null}
      {card.owner_session && !gone ? (
        <AgentLinks who={card.owner_session} card={card} links={data.session_links} />
      ) : null}
      {card.owner_session ? null : <p className="muted">none — comments ping nobody</p>}
      {data.sessions_error && <p className="ag-err">sessions: {data.sessions_error}</p>}
      <OwnerSelect card={card} data={data} busy={busy} run={run} id={id} />
      {last && line && (
        <div className={`kb-ping p-${last.status}`}>
          <span>
            last ping ({last.reason}) · {line.text}
          </span>
          <span className="muted">
            {isoAt(last.at)}
            {last.done_at ? ` → ${isoAt(last.done_at)}` : ""}
          </span>
          {line.hint && <span className="kb-ping-hint">{line.hint}</span>}
        </div>
      )}
    </div>
  );
}

function MembersPanel({
  current,
  candidates,
  me,
  busy,
  onPick,
}: {
  current: string | null;
  candidates: string[];
  me: string;
  busy: boolean;
  onPick: (a: string | null) => void;
}) {
  const [other, setOther] = useState("");
  const list = [me, ...candidates.filter((x) => x !== me)];
  return (
    <div className="kb-panel" role="group" aria-label="Members">
      <ul className="kb-pick">
        {list.map((m) => (
          <li key={m}>
            <button
              type="button"
              disabled={busy}
              aria-pressed={current === m}
              onClick={() => onPick(current === m ? null : m)}
            >
              <Avatar name={m} email={m} />
              <span>{m}</span>
              {current === m && <b aria-hidden="true">✓</b>}
            </button>
          </li>
        ))}
      </ul>
      <form
        className="kb-row"
        onSubmit={(e) => {
          e.preventDefault();
          if (other.trim()) onPick(other.trim());
          setOther("");
        }}
      >
        <input
          value={other}
          maxLength={80}
          placeholder="other agent / session"
          aria-label="Other assignee"
          onChange={(e) => setOther(e.target.value)}
        />
        <button className="btn small" disabled={busy || !other.trim()}>
          Assign
        </button>
      </form>
      {current && (
        <button type="button" className="btn small" disabled={busy} onClick={() => onPick(null)}>
          Unassign
        </button>
      )}
    </div>
  );
}

function LabelsPanel({
  slug,
  board,
  chosen,
  busy,
  run,
  onToggle,
}: {
  slug: string;
  board: BoardData;
  chosen: string[];
  busy: boolean;
  run: (fn: () => Promise<unknown>) => Promise<boolean>;
  onToggle: (labels: string[]) => void;
}) {
  const { api } = useKanbanHost();
  const [name, setName] = useState("");
  const [color, setColor] = useState<string | null>(null);
  const [edit, setEdit] = useState<BoardLabel | null>(null);
  return (
    <div className="kb-panel" role="group" aria-label="Labels">
      {board.labels.length === 0 && <p className="muted">0 labels on this board</p>}
      <ul className="kb-pick">
        {board.labels.map((l) =>
          edit?.id === l.id ? (
            <li key={l.id} className="kb-ledit">
              <input
                value={edit.name}
                maxLength={40}
                aria-label="Label name"
                onChange={(e) => setEdit({ ...edit, name: e.target.value })}
              />
              <div className="kb-swatches">
                {board.label_colors.map((col) => (
                  <button
                    type="button"
                    key={col}
                    className={`kb-swatch lc-${col}`}
                    aria-pressed={edit.color === col}
                    title={col}
                    aria-label={col}
                    onClick={() => setEdit({ ...edit, color: col })}
                  />
                ))}
              </div>
              <div className="kb-row">
                <button
                  type="button"
                  className="btn primary small"
                  disabled={busy}
                  onClick={() =>
                    void run(() => api.labelUpdate(l.id, { name: edit.name, color: edit.color })).then(
                      (ok) => ok && setEdit(null),
                    )
                  }
                >
                  Save
                </button>
                <button type="button" className="btn small" onClick={() => setEdit(null)}>
                  Cancel
                </button>
                <ConfirmButton
                  label="Delete"
                  confirm="From every card?"
                  onConfirm={() => void run(() => api.labelDelete(l.id)).then(() => setEdit(null))}
                />
              </div>
            </li>
          ) : (
            <li key={l.id} className="kb-lrow">
              <button
                type="button"
                className={`kb-lchip wide lc-${l.color}`}
                disabled={busy}
                aria-pressed={chosen.includes(l.name)}
                onClick={() =>
                  onToggle(chosen.includes(l.name) ? chosen.filter((x) => x !== l.name) : [...chosen, l.name])
                }
              >
                <span>{l.name}</span>
                {chosen.includes(l.name) && <b aria-hidden="true">✓</b>}
              </button>
              <button
                type="button"
                className="btn small kb-ico-btn"
                aria-label={`Edit label ${l.name}`}
                onClick={() => setEdit(l)}
              >
                ✎
              </button>
            </li>
          ),
        )}
      </ul>
      <form
        className="kb-newlabel"
        onSubmit={(e) => {
          e.preventDefault();
          if (!name.trim() || !color) return;
          void run(() => api.labelCreate(slug, name.trim(), color)).then((ok) => {
            if (ok) {
              setName("");
              setColor(null);
            }
          });
        }}
      >
        <input
          value={name}
          maxLength={40}
          placeholder="New label"
          aria-label="New label name"
          onChange={(e) => setName(e.target.value)}
        />
        <div className="kb-swatches">
          {board.label_colors.map((col) => (
            <button
              type="button"
              key={col}
              className={`kb-swatch lc-${col}`}
              aria-pressed={color === col}
              title={col}
              aria-label={col}
              onClick={() => setColor(col)}
            />
          ))}
        </div>
        <button className="btn small" disabled={busy || !name.trim() || !color}>
          Create
        </button>
      </form>
    </div>
  );
}

function ChecklistPanel({ busy, onAdd }: { busy: boolean; onAdd: (title: string) => void }) {
  const [t, setT] = useState("Checklist");
  return (
    <form
      className="kb-panel"
      onSubmit={(e) => {
        e.preventDefault();
        if (t.trim()) onAdd(t.trim());
      }}
    >
      <input
        autoFocus
        value={t}
        maxLength={200}
        aria-label="Checklist title"
        onChange={(e) => setT(e.target.value)}
        onFocus={(e) => e.target.select()}
      />
      <button className="btn primary small" disabled={busy || !t.trim()}>
        Add
      </button>
    </form>
  );
}

function DuePanel({
  due,
  done,
  busy,
  onSave,
  onClear,
}: {
  due: string | null;
  done: boolean;
  busy: boolean;
  onSave: (due: string, done: boolean) => void;
  onClear: () => void;
}) {
  const [v, setV] = useState(toLocalInput(due));
  const [d, setD] = useState(done);
  const [err, setErr] = useState<string | null>(null);
  return (
    <form
      className="kb-panel"
      onSubmit={(e) => {
        e.preventDefault();
        try {
          onSave(fromLocalInput(v), d);
        } catch (x) {
          setErr(errMsg(x));
        }
      }}
    >
      <input
        type="datetime-local"
        required
        value={v}
        aria-label="Due date"
        autoFocus
        onChange={(e) => setV(e.target.value)}
      />
      <label className="kb-check">
        <input type="checkbox" checked={d} onChange={(e) => setD(e.target.checked)} /> complete
      </label>
      {err && <span className="err">{err}</span>}
      <div className="kb-row">
        <button className="btn primary small" disabled={busy || !v}>
          Save
        </button>
        <button type="button" className="btn small" disabled={busy || !due} onClick={onClear}>
          Remove
        </button>
      </div>
    </form>
  );
}

function ChecklistView({
  cl,
  busy,
  run,
}: {
  cl: Checklist;
  busy: boolean;
  run: (fn: () => Promise<unknown>) => Promise<boolean>;
}) {
  const { api } = useKanbanHost();
  const [adding, setAdding] = useState<string | null>(null);
  const [edit, setEdit] = useState<{ id: number; body: string } | null>(null);
  const [rename, setRename] = useState<string | null>(null);
  const done = cl.items.filter((i) => i.done).length;
  const pct = cl.items.length ? Math.round((done / cl.items.length) * 100) : 0;
  const add = () => {
    if (!adding?.trim()) return;
    void run(() => api.itemCreate(cl.id, adding)).then((ok) => ok && setAdding(""));
  };
  return (
    <Section
      icon={<KbIcon name="check" />}
      title={cl.title}
      extra={
        <span className="kb-sec-acts">
          <button type="button" className="btn small kb-sec-act" onClick={() => setRename(cl.title)}>
            Rename
          </button>
          <ConfirmButton
            label="Delete"
            confirm="Delete checklist?"
            onConfirm={() => void run(() => api.checklistDelete(cl.id))}
          />
        </span>
      }
    >
      {rename != null && (
        <form
          className="kb-row"
          onSubmit={(e) => {
            e.preventDefault();
            void run(() => api.checklistUpdate(cl.id, rename)).then((ok) => ok && setRename(null));
          }}
        >
          <input
            autoFocus
            value={rename}
            maxLength={200}
            aria-label="Checklist title"
            onChange={(e) => setRename(e.target.value)}
            onKeyDown={(e) => e.key === "Escape" && setRename(null)}
          />
          <button className="btn primary small" disabled={busy}>
            Save
          </button>
        </form>
      )}
      <div className="kb-progress" aria-label={`${done} of ${cl.items.length} done`}>
        <span className="mono">{pct}%</span>
        <meter
          min={0}
          max={Math.max(cl.items.length, 1)}
          value={done}
          className={done === cl.items.length && done > 0 ? "full" : ""}
        />
      </div>
      <ul className="kb-items">
        {cl.items.map((i) => (
          <li key={i.id} className={i.done ? "done" : ""}>
            <input
              type="checkbox"
              checked={i.done}
              disabled={busy}
              aria-label={`done: ${i.body}`}
              onChange={(e) => void run(() => api.itemUpdate(i.id, { done: e.target.checked }))}
            />
            {edit?.id === i.id ? (
              <form
                className="kb-edit"
                onSubmit={(e) => {
                  e.preventDefault();
                  void run(() => api.itemUpdate(i.id, { body: edit.body })).then((ok) => ok && setEdit(null));
                }}
              >
                <MarkdownEditor
                  value={edit.body}
                  onChange={(b) => setEdit({ id: i.id, body: b })}
                  ariaLabel="Item"
                  rows={2}
                  inline
                  autoFocus
                  onCancel={() => setEdit(null)}
                  onSubmit={() =>
                    void run(() => api.itemUpdate(i.id, { body: edit.body })).then((ok) => ok && setEdit(null))
                  }
                />
                <div className="kb-row">
                  <button className="btn primary small" disabled={busy}>
                    Save
                  </button>
                  <button type="button" className="btn small" onClick={() => setEdit(null)}>
                    Cancel
                  </button>
                  <button
                    type="button"
                    className="btn small"
                    disabled={busy}
                    onClick={() => void run(() => api.itemConvert(i.id))}
                  >
                    Convert to card
                  </button>
                  <ConfirmButton
                    label="Delete"
                    confirm="Delete item?"
                    onConfirm={() => void run(() => api.itemDelete(i.id))}
                  />
                </div>
              </form>
            ) : (
              <button
                type="button"
                className="kb-item-body"
                onClick={() => setEdit({ id: i.id, body: i.body })}
                title={i.done_by ? `done by ${i.done_by} ${isoAt(i.done_at)}` : "edit"}
              >
                <Html html={i.body_html} className="md kb-inline" />
              </button>
            )}
          </li>
        ))}
      </ul>
      {adding == null ? (
        <button type="button" className="btn small" onClick={() => setAdding("")}>
          Add an item
        </button>
      ) : (
        <form
          className="kb-edit"
          onSubmit={(e) => {
            e.preventDefault();
            add();
          }}
        >
          <textarea
            autoFocus
            rows={2}
            value={adding}
            placeholder="Add an item (markdown) — Enter adds, Shift+Enter new line"
            aria-label="New checklist item"
            onChange={(e) => setAdding(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === "Enter" && !e.shiftKey) {
                e.preventDefault();
                add();
              } else if (e.key === "Escape") setAdding(null);
            }}
          />
          <div className="kb-row">
            <button className="btn primary small" disabled={busy || !adding.trim()}>
              Add
            </button>
            <button type="button" className="btn small" onClick={() => setAdding(null)}>
              Cancel
            </button>
          </div>
        </form>
      )}
    </Section>
  );
}
