// Dictation into a plain text field (card 662: the quick-add box, the card's title) — the MarkdownEditor has its own,
// richer one (push-to-talk, Retry of a kept recording). The words land after the text typed before the mic opened while
// you speak; once the recording stops the final text is set and onDone runs. `abort` lets the recording and a final pass
// still answering go: nothing they return is written, and onDone's `current()` turns false so an async step that
// finishes later does nothing visible.
import { useEffect, useRef, useState } from "react";
import { errMsg } from "../api";
import {
  composeDictation,
  openMic,
  startDictation,
  type Dictation,
  type DictationApi,
  type MicCapture,
} from "../lib/dictation";
import type { MicPhase } from "./MicButton";

type Options = {
  dictation: DictationApi | null;
  text: string; // the field's text now (the words go after it)
  setText: (t: string) => void;
  onDone: (text: string, current: () => boolean) => void | Promise<void>; // the recording stopped with words heard
};

export type FieldDictation = {
  phase: MicPhase;
  capture: MicCapture | null; // the open microphone (its level moves the pill's bars)
  warn: boolean; // a window failed mid-recording: retried on the next one
  error: string | null; // the last failure (mic refused, transcription failed, nothing heard)
  clearError: () => void;
  toggle: () => Promise<void>;
  abort: () => void;
};

export function useDictation({ dictation, text, setText, onDone }: Options): FieldDictation {
  const [phase, setPhase] = useState<MicPhase>("idle");
  const [capture, setCapture] = useState<MicCapture | null>(null);
  const [warn, setWarn] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const rec = useRef<Dictation | null>(null); // the recording, or its final pass while it is transcribed
  const gen = useRef(0); // bumped by abort: an opening mic or a final pass that answers after it writes nothing
  const phaseRef = useRef<MicPhase>("idle");
  phaseRef.current = phase;
  const latest = useRef({ text, setText, onDone });
  latest.current = { text, setText, onDone };
  const lead = useRef("");

  const abort = () => {
    gen.current += 1;
    rec.current?.cancel();
    rec.current = null;
    setCapture(null);
    setWarn(false);
    setPhase("idle");
  };
  const abortRef = useRef(abort);
  abortRef.current = abort;
  useEffect(() => () => abortRef.current(), []);

  const toggle = async (): Promise<void> => {
    if (!dictation) return;
    const state = phaseRef.current;
    if (state === "starting" || state === "stt") return;
    const g = gen.current;
    const current = () => g === gen.current;
    if (state === "rec") {
      const d = rec.current;
      if (!d) return;
      setPhase("stt");
      setCapture(null);
      setWarn(false);
      let spoken: string;
      try {
        spoken = await d.stop();
      } catch (err) {
        if (!current()) return;
        rec.current = null;
        setPhase("idle");
        setError(`Couldn't transcribe: ${errMsg(err)}`);
        return;
      }
      if (!current()) return;
      rec.current = null;
      setPhase("idle");
      if (!spoken.trim()) {
        setError("Nothing heard.");
        return;
      }
      const final = composeDictation(lead.current, "", spoken, "");
      latest.current.setText(final);
      await latest.current.onDone(final, current);
      return;
    }
    setError(null);
    setPhase("starting");
    const before = latest.current.text;
    const typed = before.trim() ? `${before.replace(/\s+$/, "")} ` : "";
    lead.current = typed;
    try {
      const m = await openMic();
      if (!current()) {
        m.release();
        return;
      }
      rec.current = startDictation({
        api: dictation,
        mic: m,
        onUpdate: (confirmed, pending) => {
          if (!current()) return; // let go: a final pass still answering writes nothing
          setWarn(false);
          latest.current.setText(composeDictation(typed, "", confirmed, pending));
        },
        onError: () => current() && setWarn(true),
      });
      setCapture(m);
      setPhase("rec");
    } catch (err) {
      if (!current()) return;
      const blocked = err instanceof Error && (err.name === "NotAllowedError" || err.name === "SecurityError");
      setError(
        blocked
          ? "Microphone blocked — allow it for this site in the browser's site settings (the lock in the address bar)."
          : `Microphone unavailable: ${errMsg(err)}`,
      );
      setPhase("idle");
    }
  };

  return { phase, capture, warn, error, clearError: () => setError(null), toggle, abort };
}
