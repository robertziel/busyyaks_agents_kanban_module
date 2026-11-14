// The comment box's dictation control. One button that changes shape with the dictation's phase:
//   idle      a microphone
//   starting  the microphone inside a turning ring (the browser is opening the mic)
//   rec       a pill: the elapsed time, level bars moved by the REAL microphone level (MicCapture.level, read once per
//             animation frame while recording and never after), and a stop square; in a warning tone while the speech
//             server cannot be reached (warn: the recording goes on, the windows are retried)
//   stt       the same pill, calm: a turning ring and a wave running through the bars (the last words are transcribed)
//   done      a check that draws itself, then the microphone again
// The glyph never moves: the button is anchored at the bar's trailing edge and the pill grows away from it, so the
// stop square is where the microphone was clicked (the editor reserves the place: kanban.css ".mde-dict").
// Every transition is CSS (kanban.css "dictation"); under prefers-reduced-motion the states are static.
import { useEffect, useRef, type CSSProperties } from "react";
import { levelBars, meterLevel, type MicCapture } from "../lib/dictation";

export type MicPhase = "idle" | "starting" | "rec" | "stt" | "done";

export const LEVEL_BARS = 7;
const HISTORY = 16; // readings kept: the outermost bar shows the one 9 frames back
const ATTACK_MS = 45; // the bars rise at once …
const RELEASE_MS = 260; // … and fall slowly, as a level meter does

// m:ss of a duration
export const clock = (ms: number): string => {
  const s = Math.max(0, Math.floor(ms / 1000));
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
};

type Props = {
  phase: MicPhase;
  mic: MicCapture | null; // the open microphone: its level moves the bars (rec only)
  warn?: boolean; // rec only: a window could not be transcribed (it is retried) — the pill takes the warning tone
  keyHint: string | null;
  onToggle: () => void;
};

export function MicButton({ phase, mic, warn, keyHint, onToggle }: Props) {
  const btn = useRef<HTMLButtonElement>(null);
  const bars = useRef<HTMLSpanElement>(null);
  const time = useRef<HTMLSpanElement>(null);

  useEffect(() => {
    const b = btn.current;
    const t = time.current;
    const cells = Array.from(bars.current?.children ?? []) as HTMLElement[];
    if (phase !== "rec" || !mic || !b || !t) return;
    const history = new Array<number>(HISTORY).fill(0);
    const t0 = performance.now();
    let last = t0;
    let smooth = 0;
    let shown = "";
    let raf = 0;
    const frame = (now: number) => {
      const dt = Math.max(0, now - last);
      last = now;
      const target = meterLevel(mic.level());
      smooth += (target - smooth) * (1 - Math.exp(-dt / (target > smooth ? ATTACK_MS : RELEASE_MS)));
      history.push(smooth);
      history.shift();
      levelBars(history, cells.length).forEach((v, i) => cells[i]!.style.setProperty("--ak-bar", v.toFixed(3)));
      b.style.setProperty("--ak-mic-level", smooth.toFixed(3));
      const label = clock(now - t0);
      if (label !== shown) t.textContent = shown = label;
      raf = requestAnimationFrame(frame);
    };
    t.textContent = clock(0);
    raf = requestAnimationFrame(frame);
    return () => {
      cancelAnimationFrame(raf);
      cells.forEach((c) => c.style.removeProperty("--ak-bar"));
      b.style.removeProperty("--ak-mic-level");
    };
  }, [phase, mic]);

  const rec = phase === "rec";
  const busy = phase === "starting" || phase === "stt";
  const hint = keyHint ? ` (${keyHint})` : "";
  return (
    <button
      ref={btn}
      type="button"
      className={`mde-tool t-mic${rec ? " on" : ""}`}
      data-phase={phase}
      title={rec ? "Stop dictation" : phase === "stt" ? "Transcribing…" : `Dictate${hint}`}
      data-warn={rec && warn ? "" : undefined}
      aria-label={rec ? "Stop dictation" : phase === "stt" ? "Transcribing" : "Dictate"}
      aria-pressed={rec}
      aria-disabled={busy || undefined}
      onMouseDown={(e) => e.preventDefault()}
      onClick={onToggle}
    >
      <span className="mic-live" aria-hidden="true">
        <span className="mic-live-in">
          <span className="mic-time" ref={time}>
            0:00
          </span>
          <span className="mic-bars" ref={bars}>
            {Array.from({ length: LEVEL_BARS }, (_, i) => (
              <i key={i} style={{ "--ak-i": i } as CSSProperties} />
            ))}
          </span>
        </span>
      </span>
      <span className="mic-glyph" aria-hidden="true">
        <svg className="g-mic" viewBox="0 0 16 16">
          <path
            className="g-mic-body"
            d="M8 1.7a2.1 2.1 0 0 0-2.1 2.1v3.9a2.1 2.1 0 0 0 4.2 0V3.8A2.1 2.1 0 0 0 8 1.7z"
          />
          <path d="M3.9 7.5a4.1 4.1 0 0 0 8.2 0M8 11.6v2.5M5.7 14.1h4.6" />
        </svg>
        <svg className="g-stop" viewBox="0 0 16 16">
          <rect x="4.4" y="4.4" width="7.2" height="7.2" rx="2" />
        </svg>
        <svg className="g-ring" viewBox="0 0 16 16">
          <circle cx="8" cy="8" r="6.2" pathLength="100" />
        </svg>
        <svg className="g-done" viewBox="0 0 16 16">
          <path d="M3.6 8.5l2.9 2.9 5.9-6.6" pathLength="100" />
        </svg>
      </span>
    </button>
  );
}
