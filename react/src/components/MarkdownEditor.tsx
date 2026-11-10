// A markdown textarea with Write / Preview and a toolbar that inserts markdown (lib/board.ts applyTool).
// Preview is the server's render (api.markdownPreview → the engine's markdown port, raw HTML dropped) — never a JS markdown library.
// With onUpload: a pasted image, a dropped file or the paperclip uploads it; a placeholder holds the caret's place and is
// replaced by the attachment's markdown snippet; a chip shows progress, and a failure stays visible with the server's reason.
import {
  useEffect,
  useRef,
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
import { Html } from "./Bits";
import { KbIcon } from "./KbIcon";

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
  onSubmit?: () => void; // Ctrl/⌘+Enter
  onCancel?: () => void; // Escape
  placeholder?: string;
  ariaLabel: string;
  rows?: number;
  autoFocus?: boolean;
  inline?: boolean; // checklist item: preview rendered inline
  onUpload?: (file: File, onProgress: (fraction: number) => void) => Promise<{ markdown: string }>;
};

export type Upload = { key: number; name: string; pct: number; error?: string };
let uploadSeq = 0;

export function MarkdownEditor({
  value,
  onChange,
  onSubmit,
  onCancel,
  placeholder: hint,
  ariaLabel,
  rows = 4,
  autoFocus,
  inline,
  onUpload,
}: Props) {
  const { api } = useKanbanHost();
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

  const apply = (tool: Tool) => {
    const el = ta.current;
    if (!el) return;
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

  return (
    <div
      className={`mde${dropping ? " dropping" : ""}`}
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
        {tab === "write" &&
          TOOLS.map((t) => (
            <button
              type="button"
              key={t.tool}
              className={`mde-tool t-${t.tool}`}
              title={t.title}
              aria-label={t.title}
              onMouseDown={(e) => e.preventDefault()}
              onClick={() => apply(t.tool)}
            >
              {t.label}
            </button>
          ))}
        {tab === "write" && onUpload && (
          <>
            <button
              type="button"
              className="mde-tool t-attach"
              title="Attach a file (or paste / drop one)"
              aria-label="Attach a file"
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
      {tab === "write" ? (
        <textarea
          ref={ta}
          rows={rows}
          value={value}
          placeholder={hint}
          aria-label={ariaLabel}
          autoFocus={autoFocus}
          onChange={(e) => setText(e.target.value)}
          onKeyDown={onKey}
          onPaste={onPaste}
        />
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
