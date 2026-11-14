// A markdown textarea with Write / Preview and a toolbar that inserts markdown (lib/board.ts applyTool).
// Preview is the server's render (api.markdownPreview → the engine's markdown port, raw HTML dropped) — never a JS markdown library.
// With onUpload: a pasted image, a dropped file or the paperclip uploads it; a placeholder holds the caret's place and is
// replaced by the attachment's markdown snippet; a chip shows progress, and a failure stays visible with the server's reason.
// With dictate (and a host that injects a DictationApi): the mic button or the host's shortcut records; the words appear at the caret
// while you speak (lib/dictation.ts), the text is read-only until the recording stops; a failure shows the server's reason.
// While it runs the formatting tools step aside (the text is not editable), the mic is a pill with the live level
// (MicButton.tsx), and the words the transcription has not confirmed yet are tinted behind the text (.mde-ghost).
import {
  useEffect,
  useRef,
  type MutableRefObject,
  useState,
  type ClipboardEvent,
  type DragEvent,
  type KeyboardEvent,
  type ReactNode,
} from "react";
import { errMsg } from "../api";
import { useKanbanHost } from "../host";
import { dragHasFiles, filesOf, insertAt, pastedName, placeholder, replacePlaceholder } from "../lib/attachments";
import { applyTool, type Tool } from "../lib/board";
import {
  composeDictation,
  DictationFailed,
  openMic,
  pendingRange,
  startDictation,
  type Dictation,
  type MicCapture,
} from "../lib/dictation";
import { comboLabel, isMac, matchesCombo, type KeyCombo } from "../lib/shortcut";
import { Html } from "./Bits";
import { KbIcon } from "./KbIcon";
import { MicButton } from "./MicButton";

const TOOLS: { tool: Tool; label: ReactNode; title: string; key?: string }[] = [
  { tool: "bold", label: "B", title: "Bold (Ctrl+B)", key: "b" },
  { tool: "italic", label: "I", title: "Italic (Ctrl+I)", key: "i" },
  { tool: "code", label: "</>", title: "Code (Ctrl+E)", key: "e" },
  { tool: "link", label: <KbIcon name="link" />, title: "Link (Ctrl+K)", key: "k" },
  { tool: "list", label: "•", title: "Bulleted list" },
  { tool: "checklist", label: "☐", title: "Task list (- [ ])" },
];

type Props = {
  value: string;
  onChange: (v: string) => void;
  onSubmit?: () => void; // Ctrl/⌘+Enter (while dictating it stops the dictation instead: the text is not final yet)
  onDictatingChange?: (on: boolean) => void; // the mic is opening / recording / transcribing (the parent's Save waits)
  onCancel?: () => void; // Escape
  placeholder?: string;
  ariaLabel: string;
  rows?: number;
  autoFocus?: boolean;
  inline?: boolean; // checklist item: preview rendered inline
  onUpload?: (file: File, onProgress: (fraction: number) => void) => Promise<{ markdown: string }>;
  dictate?: boolean; // a mic button + the host's shortcut (push-to-talk), when the host injects a DictationApi
  // the parent's handle on this editor's dictation (the card dialog's shortcut while the focus is elsewhere)
  dictateToggle?: MutableRefObject<DictateHandle | null>;
};

// toggle = the mic button's click (start / stop); hold = the shortcut pressed: starts, and stops when it is released
export type DictateHandle = { toggle: () => void; hold: (combo: KeyCombo) => void };

// the key-up that ends a hold: the combo's key, or one of its modifiers
const releases = (e: { code: string }, c: KeyCombo): boolean =>
  e.code === c.code ||
  (c.alt && e.code.startsWith("Alt")) ||
  (c.ctrl && e.code.startsWith("Control")) ||
  (c.meta && (e.code.startsWith("Meta") || e.code.startsWith("OS"))) ||
  (c.shift && e.code.startsWith("Shift"));

type MicState = "idle" | "starting" | "rec" | "stt";
// how long the "landed" settle shows after a dictation's text is in (the check on the mic, the text's glow)
const LANDED_MS = 1400;
// what the tint behind the text copies from the textarea, so both wrap their words at the same places
const GHOST_STYLES = [
  "font",
  "lineHeight",
  "letterSpacing",
  "wordSpacing",
  "textIndent",
  "tabSize",
  "paddingTop",
  "paddingRight",
  "paddingBottom",
  "paddingLeft",
] as const;

export type Upload = { key: number; name: string; pct: number; error?: string };
let uploadSeq = 0;

export function MarkdownEditor({
  value,
  onChange,
  onSubmit,
  onDictatingChange,
  onCancel,
  placeholder: hint,
  ariaLabel,
  rows = 4,
  autoFocus,
  inline,
  onUpload,
  dictate,
  dictateToggle,
}: Props) {
  const { api, dictation } = useKanbanHost();
  const ta = useRef<HTMLTextAreaElement>(null);
  const picker = useRef<HTMLInputElement>(null);
  const [uploads, setUploads] = useState<Upload[]>([]);
  const [dropping, setDropping] = useState(false);
  // the text as of the last change made here or by the parent: uploads finish later and must edit the current text
  const latest = useRef(value);
  latest.current = value;
  const setText = (t: string) => {
    latest.current = t;
    onChange(t);
  };
  const [tab, setTab] = useState<"write" | "preview">("write");
  const [html, setHtml] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const pendingSel = useRef<[number, number] | null>(null);
  const canDictate = !!dictate && dictation != null;
  const keyLabel = dictation?.shortcut ? comboLabel(dictation.shortcut, isMac(navigator.platform)) : null;
  const keyHint = keyLabel ? `hold ${keyLabel}` : null;
  const [held, setHeld] = useState(false); // started by holding the shortcut: its release stops it
  const [mic, setMic] = useState<MicState>("idle");
  const dictating = mic !== "idle"; // the text is read-only: the formatting tools and the paperclip are off
  // a failure under the box: what happened, and (a failed final pass) the kept recording's retry
  const [micErr, setMicErr] = useState<{ text: string; retry?: () => Promise<string> } | null>(null);
  const [warn, setWarn] = useState(false); // a window failed mid-recording: retried on the next one
  const [heardNothing, setHeardNothing] = useState(false);
  const rec = useRef<Dictation | null>(null);
  const [capture, setCapture] = useState<MicCapture | null>(null); // the open microphone: its level moves the bars
  const [pending, setPending] = useState<[number, number] | null>(null); // the unconfirmed words' place in the text
  const [landed, setLanded] = useState(false);
  const landedTimer = useRef<number | null>(null);
  const ghost = useRef<HTMLDivElement>(null);
  const micState = useRef<MicState>("idle");
  micState.current = mic;
  // closing the card releases the mic — also one still opening (alive = false: the opened mic is released at once)
  const alive = useRef(true);
  useEffect(() => {
    alive.current = true;
    return () => {
      alive.current = false;
      if (landedTimer.current != null) window.clearTimeout(landedTimer.current);
      rec.current?.cancel();
      rec.current = null;
    };
  }, []);

  useEffect(() => onDictatingChange?.(dictating), [dictating, onDictatingChange]);

  // the final pass (stop, or a retry of the kept recording): the words land, or the failure keeps the recording
  const settle = async (final: () => Promise<string>, before: string) => {
    setMic("stt");
    setCapture(null);
    setWarn(false);
    setMicErr(null);
    let text: string | null = null;
    try {
      text = await final();
    } catch (e: unknown) {
      if (!alive.current) return;
      if (e instanceof DictationFailed)
        setMicErr({ text: `Couldn't transcribe: ${e.message}. Your recording is kept.`, retry: e.retry });
      else setMicErr({ text: `Couldn't transcribe: ${errMsg(e)}` });
    }
    if (!alive.current) return;
    setPending(null);
    setMic("idle");
    if (text === null) return;
    const flag = text.length > before.length ? setLanded : setHeardNothing; // nothing new: say so, no check
    flag(true);
    landedTimer.current = window.setTimeout(() => flag(false), LANDED_MS);
  };
  const confirmedBefore = useRef("");

  const toggleDictation = async () => {
    if (!dictation) return;
    const state = micState.current;
    if (state === "starting" || state === "stt") return;
    if (state === "rec") {
      const d = rec.current;
      rec.current = null;
      if (d) await settle(() => d.stop(), confirmedBefore.current);
      return;
    }
    setTab("write");
    setMicErr(null);
    setWarn(false);
    setHeardNothing(false);
    confirmedBefore.current = "";
    if (landedTimer.current != null) window.clearTimeout(landedTimer.current);
    setLanded(false);
    setMic("starting");
    // at the caret when the text has the focus, else at the end (the shortcut pressed elsewhere in the card)
    const el = ta.current && document.activeElement === ta.current ? ta.current : null;
    const text = latest.current;
    const before = text.slice(0, el ? el.selectionStart : text.length);
    const after = text.slice(el ? el.selectionEnd : text.length);
    try {
      const m = await openMic();
      if (!alive.current) {
        m.release();
        return;
      }
      rec.current = startDictation({
        api: dictation,
        mic: m,
        onUpdate: (confirmed, pending) => {
          setWarn(false);
          const t = composeDictation(before, after, confirmed, pending);
          const caret = t.length - after.length;
          pendingSel.current = [caret, caret];
          setPending(pendingRange(before, confirmed, pending));
          setText(t);
        },
        onError: () => setWarn(true),
      });
      setCapture(m);
      setMic("rec");
    } catch (e: unknown) {
      const blocked = e instanceof Error && (e.name === "NotAllowedError" || e.name === "SecurityError");
      setMicErr({
        text: blocked
          ? "Microphone blocked — allow it for this site in the browser's site settings (the lock in the address bar)."
          : `Microphone unavailable: ${errMsg(e)}`,
      });
      setMic("idle");
    }
  };
  // push-to-talk: the held shortcut starts it; its key-up (the key or a modifier), or the window losing the focus (a
  // key-up that will never come), stops it — also when released before the microphone finished opening
  const toggleRef = useRef(toggleDictation);
  toggleRef.current = toggleDictation;
  const release = useRef<(() => void) | null>(null);
  const root = useRef<HTMLDivElement>(null);
  const hold = (combo: KeyCombo) => {
    if (micState.current !== "idle" || release.current) return;
    setHeld(true);
    // the shortcut works from anywhere in the card, often far above this box (a long card): bring it on screen, so the
    // listening state and the words are where the user looks
    root.current?.scrollIntoView({ block: "nearest", behavior: "smooth" });
    let done = false;
    const end = () => {
      if (done) return;
      done = true;
      window.removeEventListener("keyup", onUp, true);
      window.removeEventListener("blur", end);
      release.current = null;
      setHeld(false);
      const stopWhenOpen = () => {
        if (!alive.current) return;
        if (micState.current === "starting") window.setTimeout(stopWhenOpen, 50);
        else if (micState.current === "rec") void toggleRef.current();
      };
      stopWhenOpen();
    };
    const onUp = (e: globalThis.KeyboardEvent) => {
      if (releases(e, combo)) end();
    };
    window.addEventListener("keyup", onUp, true);
    window.addEventListener("blur", end);
    release.current = end;
    void toggleRef.current();
  };
  useEffect(() => () => release.current?.(), []);
  const holdRef = useRef(hold);
  holdRef.current = hold;
  useEffect(() => {
    if (!dictateToggle) return;
    dictateToggle.current = canDictate
      ? { toggle: () => void toggleRef.current(), hold: (c) => holdRef.current(c) }
      : null;
    return () => {
      dictateToggle.current = null;
    };
  }, [dictateToggle, canDictate]);

  useEffect(() => {
    if (tab !== "preview") return;
    let live = true;
    setHtml(null);
    setErr(null);
    api.markdownPreview(value, !!inline).then(
      (h) => live && setHtml(h),
      (e: unknown) => live && setErr(errMsg(e)),
    );
    return () => {
      live = false;
    };
  }, [tab, value, inline, api]);

  useEffect(() => {
    const s = pendingSel.current;
    if (s && ta.current) {
      ta.current.focus();
      ta.current.setSelectionRange(s[0], s[1]);
      pendingSel.current = null;
    }
  });

  // the tint sits exactly behind the textarea's text: same box, same type, same scroll position
  const syncGhost = () => {
    const g = ghost.current;
    const el = ta.current;
    if (!g || !el) return;
    const cs = getComputedStyle(el);
    for (const k of GHOST_STYLES) g.style[k] = cs[k];
    g.style.left = `${el.offsetLeft + el.clientLeft}px`;
    g.style.top = `${el.offsetTop + el.clientTop}px`;
    g.style.width = `${el.clientWidth}px`; // without the scrollbar: the text wraps inside it
    g.style.height = `${el.clientHeight}px`;
    g.scrollTop = el.scrollTop;
  };
  useEffect(syncGhost);

  const apply = (tool: Tool) => {
    const el = ta.current;
    if (!el || dictating) return;
    const r = applyTool(value, el.selectionStart, el.selectionEnd, tool);
    pendingSel.current = [r.start, r.end];
    onChange(r.text);
  };

  const upload = (files: File[]) => {
    if (!onUpload) return;
    for (const f of files) {
      const key = ++uploadSeq;
      const name = pastedName(f, new Date());
      const file = name === f.name ? f : new File([f], name, { type: f.type });
      const ph = placeholder(name, key);
      const el = ta.current;
      const r = insertAt(
        latest.current,
        el ? el.selectionStart : latest.current.length,
        el ? el.selectionEnd : latest.current.length,
        ph,
      );
      pendingSel.current = [r.caret, r.caret];
      setText(r.text);
      setUploads((u) => [...u, { key, name, pct: 0 }]);
      onUpload(file, (pct) => setUploads((u) => u.map((x) => (x.key === key ? { ...x, pct } : x)))).then(
        (a) => {
          setText(replacePlaceholder(latest.current, ph, a.markdown));
          setUploads((u) => u.filter((x) => x.key !== key));
        },
        (e: unknown) => {
          setText(replacePlaceholder(latest.current, ph, ""));
          setUploads((u) => u.map((x) => (x.key === key ? { ...x, error: errMsg(e) } : x)));
        },
      );
    }
  };
  const onPaste = (e: ClipboardEvent<HTMLTextAreaElement>) => {
    const files = filesOf(e.clipboardData);
    if (!onUpload || files.length === 0) return;
    e.preventDefault();
    upload(files);
  };
  const onDragOver = (e: DragEvent<HTMLElement>) => {
    if (!onUpload || !dragHasFiles(e.dataTransfer)) return;
    e.preventDefault();
    e.stopPropagation(); // the dialog's own drop zone stays out of it: this file goes into the text
    e.dataTransfer.dropEffect = "copy";
    setDropping(true);
  };
  const onDrop = (e: DragEvent<HTMLElement>) => {
    setDropping(false);
    if (!onUpload || !dragHasFiles(e.dataTransfer)) return;
    e.preventDefault();
    e.stopPropagation();
    upload(filesOf(e.dataTransfer));
  };

  const onKey = (e: KeyboardEvent<HTMLTextAreaElement>) => {
    e.stopPropagation(); // board shortcuts never fire while typing
    if (canDictate && dictation?.shortcut && matchesCombo(e, dictation.shortcut)) {
      e.preventDefault();
      if (!e.repeat) hold(dictation.shortcut); // the key's auto-repeat while held changes nothing
      return;
    }
    if ((e.ctrlKey || e.metaKey) && e.key === "Enter" && micState.current !== "idle") {
      e.preventDefault(); // the text is not final while dictating: stop first, save after
      if (micState.current === "rec") void toggleDictation();
      return;
    }
    if ((e.ctrlKey || e.metaKey) && e.key === "Enter" && onSubmit) {
      e.preventDefault();
      onSubmit();
      return;
    }
    if (e.key === "Escape" && onCancel) {
      e.preventDefault();
      onCancel();
      return;
    }
    if (e.ctrlKey || e.metaKey) {
      const t = TOOLS.find((x) => x.key === e.key.toLowerCase());
      if (t) {
        e.preventDefault();
        apply(t.tool);
      }
    }
  };

  const tint = dictating && pending ? pending : null;
  return (
    <div
      className={`mde${canDictate ? " has-mic" : ""}${dropping ? " dropping" : ""}${dictating ? " dictating" : ""}${
        mic === "rec" && warn ? " is-warn" : ""
      }${landed ? " landed" : ""}`}
      data-dictation={mic}
      ref={root}
      onDragOver={onDragOver}
      onDragLeave={() => setDropping(false)}
      onDrop={onDrop}
    >
      <div className="mde-bar" role="toolbar" aria-label={`${ariaLabel} formatting`}>
        <div className="mde-tabs" role="tablist">
          <button type="button" role="tab" aria-selected={tab === "write"} onClick={() => setTab("write")}>
            Write
          </button>
          <button type="button" role="tab" aria-selected={tab === "preview"} onClick={() => setTab("preview")}>
            Preview
          </button>
        </div>
        <div className="mde-kit">
          {tab === "write" && (
            // while dictating the tools step aside: out of the tab order and of the accessibility tree
            <div className="mde-tools" aria-hidden={dictating || undefined} {...(dictating ? { inert: "" } : {})}>
              {TOOLS.map((t) => (
                <button
                  type="button"
                  key={t.tool}
                  className={`mde-tool t-${t.tool}`}
                  title={t.title}
                  aria-label={t.title}
                  disabled={dictating}
                  onMouseDown={(e) => e.preventDefault()}
                  onClick={() => apply(t.tool)}
                >
                  {t.label}
                </button>
              ))}
              {onUpload && (
                <>
                  <button
                    type="button"
                    className="mde-tool t-attach"
                    title="Attach a file (or paste / drop one)"
                    aria-label="Attach a file"
                    disabled={dictating}
                    onMouseDown={(e) => e.preventDefault()}
                    onClick={() => picker.current?.click()}
                  >
                    <KbIcon name="clip" />
                  </button>
                  <input
                    ref={picker}
                    type="file"
                    multiple
                    hidden
                    aria-hidden="true"
                    tabIndex={-1}
                    onChange={(e) => {
                      upload(Array.from(e.target.files ?? []));
                      e.target.value = "";
                    }}
                  />
                </>
              )}
            </div>
          )}
          {canDictate && (tab === "write" || dictating) && (
            // the mic's place, kept at the bar's trailing edge: the pill and its status grow from it, nothing moves
            <div className="mde-dict">
              {mic === "rec" && (
                <span className={`mde-rec${warn ? " is-warn" : ""}`} role="status">
                  {warn
                    ? "can't reach the speech server — retrying"
                    : `listening…${held && keyLabel ? ` release ${keyLabel} to stop` : " click the mic to stop"}`}
                </span>
              )}
              {mic === "idle" && heardNothing && (
                <span className="mde-rec is-none" role="status">
                  nothing heard
                </span>
              )}
              {mic === "stt" && (
                <span className="mde-rec is-stt" role="status">
                  transcribing…
                </span>
              )}
              <MicButton
                phase={mic === "idle" && landed ? "done" : mic}
                mic={capture}
                warn={warn}
                keyHint={keyHint}
                onToggle={() => void toggleDictation()}
              />
            </div>
          )}
        </div>
      </div>
      {tab === "write" ? (
        <div className="mde-area">
          {tint && (
            <div className="mde-ghost" ref={ghost} aria-hidden="true">
              {value.slice(0, tint[0])}
              <mark key={tint[0]}>{value.slice(tint[0], tint[1])}</mark>
            </div>
          )}
          <textarea
            ref={ta}
            rows={rows}
            value={value}
            placeholder={hint}
            aria-label={ariaLabel}
            autoFocus={autoFocus}
            readOnly={dictating}
            onChange={(e) => setText(e.target.value)}
            onKeyDown={onKey}
            onPaste={onPaste}
            onScroll={syncGhost}
          />
        </div>
      ) : (
        <div className="mde-preview" aria-live="polite">
          {err ? (
            <span className="err">{err}</span>
          ) : html == null ? (
            <span className="muted">rendering…</span>
          ) : html.trim() ? (
            <Html html={html} className="md kb-md-body" />
          ) : (
            <span className="muted">nothing to preview</span>
          )}
        </div>
      )}
      {micErr && (
        <p className="mde-mic-err err" role="alert">
          {micErr.text}
          {micErr.retry && (
            <>
              {" "}
              <button
                type="button"
                className="linklike"
                disabled={mic !== "idle"}
                onClick={() => {
                  const retry = micErr.retry!;
                  void settle(retry, confirmedBefore.current);
                }}
              >
                Retry
              </button>
            </>
          )}
        </p>
      )}
      <UploadChips uploads={uploads} dismiss={(k) => setUploads((x) => x.filter((y) => y.key !== k))} />
    </div>
  );
}

// One row per upload: name + progress, or the failure's reason (stays until dismissed).
export function UploadChips({ uploads, dismiss }: { uploads: Upload[]; dismiss: (key: number) => void }) {
  if (uploads.length === 0) return null;
  return (
    <ul className="mde-uploads" aria-live="polite">
      {uploads.map((u) => (
        <li key={u.key} className={u.error ? "bad" : ""}>
          <KbIcon name="clip" />
          <span className="mde-up-name">{u.name}</span>
          {u.error ? (
            <>
              <span className="err" role="alert">
                {u.error}
              </span>
              <button
                type="button"
                className="linklike"
                aria-label={`Dismiss ${u.name}`}
                onClick={() => dismiss(u.key)}
              >
                ✕
              </button>
            </>
          ) : (
            <>
              <meter min={0} max={1} value={u.pct} aria-label={`uploading ${u.name}`} />
              <span className="mono">{Math.round(u.pct * 100)}%</span>
            </>
          )}
        </li>
      ))}
    </ul>
  );
}
