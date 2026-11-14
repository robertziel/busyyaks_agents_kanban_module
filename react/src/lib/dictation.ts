// Dictation: speak into an editor, the words land in its text while you talk. The browser records 16 kHz mono PCM;
// the HOST transcribes it (the `DictationApi` port: an OpenAI-compatible /v1/audio/transcriptions behind the host's own
// route — the speech server's URL and token never reach the browser).
//
// Streaming with a sliding window and LocalAgreement-2 (the meeting-transcription technique):
//   - every SUBMIT_MS the UNCONFIRMED audio (confirmed sample → end) is sent with the confirmed text as the prompt;
//   - the words two consecutive passes agree on (a common prefix) are CONFIRMED and their audio is dropped from the
//     window (the window starts at the last confirmed word's end); the rest is the live PENDING tail;
//   - a window longer than FORCE_CONFIRM_SEC with no agreement confirms its whole pass, so nothing is stranded;
//   - a pass that hears no words (silence) drops the window's audio but its last second (a word may be starting), so
//     the window stays bounded;
//   - no window sent is longer than MAX_WINDOW_SEC (which a host's size limit must accept): a server that failed or
//     answered slowly while you talked gets the oldest MAX_WINDOW_SEC, which then confirms (it is over FORCE_CONFIRM_SEC);
//   - stop() sends what is still unconfirmed once more — in windows of at most MAX_WINDOW_SEC — the last one's text as it is.
// A failed pass is reported (onError) and the window is sent again on the next tick; stop() rejects when its final
// pass fails, so the editor shows the server's reason instead of a silently shorter text.

import type { KeyCombo } from "./shortcut";

export type SttWord = { word: string; start: number; end: number };
export type Transcript = { text: string; words: SttWord[] };

// What a host injects to turn speech into text (the Board's `dictation` prop). wav = 16 kHz mono 16-bit PCM WAV;
// prompt = the text confirmed so far (context for the next window). Rejects with the server's reason.
export interface DictationApi {
  transcribe(wav: Blob, prompt: string): Promise<Transcript>;
  // the key that starts / stops it anywhere in an open card (the host's user picks it); null = the mic button only
  readonly shortcut: KeyCombo | null;
}

// The microphone as the stream reads it: every sample captured so far (appended in place), and release.
export interface MicCapture {
  readonly sampleRate: number;
  samples(): Float32Array[]; // the chunks captured since start, oldest first
  level(): number; // how loud the microphone is right now: the RMS of its last LEVEL_SAMPLES samples, 0 (silence) … 1
  release(): void;
}

export const SAMPLE_RATE = 16000;
export const SUBMIT_MS = 2500;
export const FORCE_CONFIRM_SEC = 25;
// the longest window a host must accept: FORCE_CONFIRM_SEC + one SUBMIT_MS + a slow answer's worth of audio
export const MAX_WINDOW_SEC = 30;
export const PROMPT_CHARS = 400;
// the level reader's window: 512 samples = 32 ms at 16 kHz (an AnalyserNode fftSize, a power of two)
export const LEVEL_SAMPLES = 512;

const norm = (w: string) => w.toLowerCase().replace(/[^\p{L}\p{N}]+/gu, "");

// The longest common word prefix of two passes (case and punctuation ignored).
export function agreedPrefixLen(prev: SttWord[], cur: SttWord[]): number {
  let n = 0;
  while (n < prev.length && n < cur.length && norm(prev[n]!.word) === norm(cur[n]!.word)) n++;
  return n;
}

// Whisper's words carry their own leading space; a word without one is glued to the one before.
export const joinWords = (ws: SttWord[]): string =>
  ws
    .map((w) => w.word)
    .join("")
    .replace(/\s+/g, " ")
    .trim();

const glue = (a: string, b: string): string => (a && b ? `${a} ${b}` : a || b);

// a window starts at the last confirmed word's end timestamp, which the server rounds: its first words may repeat the
// tail of the text already confirmed ("… page and" + "and the tests"). The longest such overlap (≤ 3 words, compared
// as agreedPrefixLen does: case and punctuation ignored) is dropped from the new text.
export const SEAM_WORDS = 3;
export function appendNew(confirmed: string, next: string): string {
  const head = confirmed.split(/\s+/).filter(Boolean);
  const tail = next.split(/\s+/).filter(Boolean);
  for (let k = Math.min(SEAM_WORDS, head.length, tail.length); k > 0; k--) {
    const a = head.slice(-k).map(norm);
    const b = tail.slice(0, k).map(norm);
    if (a.every((w, i) => w !== "" && w === b[i])) return glue(confirmed, tail.slice(k).join(" "));
  }
  return glue(confirmed, next);
}

// The editor's text while dictating: what stood before the caret, the dictated words, what stood after it.
export function composeDictation(before: string, after: string, confirmed: string, pending: string): string {
  const spoken = appendNew(confirmed, pending);
  if (!spoken) return before + after;
  const lead = before && !/\s$/.test(before) ? " " : "";
  const tail = after && !/^\s/.test(after) ? " " : "";
  return before + lead + spoken + tail + after;
}

// Where the pending (not yet confirmed) words stand in composeDictation's text: [start, end), or null when there are none.
export function pendingRange(before: string, confirmed: string, pending: string): [number, number] | null {
  if (!pending) return null;
  const start =
    composeDictation(before, "", confirmed, "").length + (confirmed || (before && !/\s$/.test(before)) ? 1 : 0);
  return [start, start + pending.length];
}

// The root mean square of float samples in [-1, 1]: 0 for silence (or no samples), 1 for a full-scale square wave.
export function rmsLevel(samples: ArrayLike<number>): number {
  if (samples.length === 0) return 0;
  let sum = 0;
  for (let i = 0; i < samples.length; i++) sum += samples[i]! * samples[i]!;
  return Math.min(1, Math.sqrt(sum / samples.length));
}

// An RMS as a meter reads it: decibels mapped onto 0 … 1 (METER_FLOOR_DB and below = 0, METER_CEIL_DB and above = 1),
// so quiet speech already moves the bars and a shout does not pin them.
export const METER_FLOOR_DB = -50;
export const METER_CEIL_DB = -6;
export function meterLevel(rms: number): number {
  if (!(rms > 0)) return 0;
  const db = 20 * Math.log10(rms);
  return Math.max(0, Math.min(1, (db - METER_FLOOR_DB) / (METER_CEIL_DB - METER_FLOOR_DB)));
}

// The level bars: `bars` heights (0 … 1) from the meter's recent readings (newest LAST). The middle bar shows the newest
// reading; each bar outwards shows an older one, lower — a sound ripples from the centre to the edges and fades.
export function levelBars(history: readonly number[], bars: number, lag = 3): number[] {
  const mid = (bars - 1) / 2;
  return Array.from({ length: bars }, (_, i) => {
    const d = Math.abs(i - mid);
    const v = history[history.length - 1 - Math.round(d * lag)] ?? 0;
    return v * (1 - (d / (mid + 1)) * 0.7);
  });
}

// 16-bit PCM mono WAV of float samples in [-1, 1].
export function pcmToWav(samples: Float32Array, sampleRate = SAMPLE_RATE): ArrayBuffer {
  const dataSize = samples.length * 2;
  const buf = new ArrayBuffer(44 + dataSize);
  const v = new DataView(buf);
  const ascii = (o: number, s: string) => {
    for (let i = 0; i < s.length; i++) v.setUint8(o + i, s.charCodeAt(i));
  };
  ascii(0, "RIFF");
  v.setUint32(4, 36 + dataSize, true);
  ascii(8, "WAVE");
  ascii(12, "fmt ");
  v.setUint32(16, 16, true);
  v.setUint16(20, 1, true);
  v.setUint16(22, 1, true);
  v.setUint32(24, sampleRate, true);
  v.setUint32(28, sampleRate * 2, true);
  v.setUint16(32, 2, true);
  v.setUint16(34, 16, true);
  ascii(36, "data");
  v.setUint32(40, dataSize, true);
  for (let i = 0; i < samples.length; i++) {
    const s = Math.max(-1, Math.min(1, samples[i]!));
    v.setInt16(44 + i * 2, s < 0 ? s * 0x8000 : s * 0x7fff, true);
  }
  return buf;
}

// The browser's microphone at 16 kHz (rejects when there is none or permission is refused).
export async function openMic(): Promise<MicCapture> {
  if (!navigator.mediaDevices?.getUserMedia)
    throw new Error("this browser gives no microphone access here (https or localhost only)");
  const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
  const chunks: Float32Array[] = [];
  let ctx: AudioContext | null = null;
  try {
    ctx = new AudioContext({ sampleRate: SAMPLE_RATE });
    const source = ctx.createMediaStreamSource(stream);
    // ScriptProcessor (deprecated, still in every engine): an AudioWorklet needs a module URL the host would serve
    const proc = ctx.createScriptProcessor(4096, 1, 1);
    proc.onaudioprocess = (e: AudioProcessingEvent) => {
      chunks.push(new Float32Array(e.inputBuffer.getChannelData(0))); // a copy: the buffer is reused
    };
    source.connect(proc);
    proc.connect(ctx.destination); // pulls the processor; its output is silence
    // the level reader: the newest LEVEL_SAMPLES samples whenever it is asked (a 4096-sample chunk is 256 ms old)
    const meter = ctx.createAnalyser();
    meter.fftSize = LEVEL_SAMPLES;
    source.connect(meter);
    await ctx.resume();
    return micOf(ctx, stream, source, proc, meter, chunks);
  } catch (e: unknown) {
    stream.getTracks().forEach((t) => t.stop()); // a failed setup never leaves the microphone on
    if (ctx) void ctx.close();
    throw e;
  }
}

function micOf(
  ctx: AudioContext,
  stream: MediaStream,
  source: MediaStreamAudioSourceNode,
  proc: ScriptProcessorNode,
  meter: AnalyserNode,
  chunks: Float32Array[],
): MicCapture {
  const window = new Float32Array(meter.fftSize);
  let released = false;
  return {
    sampleRate: ctx.sampleRate,
    samples: () => chunks,
    level: () => {
      if (released) return 0; // a released microphone hears nothing
      meter.getFloatTimeDomainData(window);
      return rmsLevel(window);
    },
    release: () => {
      released = true;
      proc.onaudioprocess = null;
      proc.disconnect();
      source.disconnect();
      stream.getTracks().forEach((t) => t.stop());
      void ctx.close();
    },
  };
}

export interface Dictation {
  stop(): Promise<string>; // the final text; rejects with DictationFailed when the final pass fails (its audio kept)
  cancel(): void; // release the mic, keep nothing
}

// The final pass failed: the text confirmed so far, and retry() sends the kept audio again (resolves the final text).
export class DictationFailed extends Error {
  constructor(
    message: string,
    readonly confirmed: string,
    readonly retry: () => Promise<string>,
  ) {
    super(message);
    this.name = "DictationFailed";
  }
}

export type DictationOptions = {
  api: DictationApi;
  mic: MicCapture;
  onUpdate: (confirmed: string, pending: string) => void;
  onError: (message: string) => void;
  submitMs?: number;
};

const errText = (e: unknown) => (e instanceof Error ? e.message : String(e));

// A window re-hears this much audio before the last confirmed word's end, so a word the server placed late is not cut
// (its overlap is dropped again by appendNew); only words ending STABLE_SEC before the window's end are confirmed.
export const OVERLAP_SEC = 0.4;
export const STABLE_SEC = 1.0;
// a window whose RMS stays below this is silence: never sent (Whisper answers silence with the prompt, "hallucinated")
export const SILENCE_RMS = 0.004;

// The words a pass really heard: a zero-length word (start = end) is the model echoing its prompt, not speech, and a
// pass whose whole text is the tail of the prompt is the same echo.
export function heardWords(words: SttWord[], prompt: string): SttWord[] {
  const real = words.filter((w) => w.end - w.start > 0.02);
  const text = joinWords(real).split(/\s+/).map(norm).filter(Boolean);
  if (text.length === 0) return [];
  const tail = prompt.split(/\s+/).map(norm).filter(Boolean).slice(-text.length);
  return tail.length === text.length && tail.every((w, i) => w === text[i]) ? [] : real;
}

export function startDictation({ api, mic, onUpdate, onError, submitMs = SUBMIT_MS }: DictationOptions): Dictation {
  const rate = mic.sampleRate;
  let confirmedSamples = 0; // where the confirmed text's audio ends
  let confirmed = "";
  let prev: SttWord[] = [];
  let inFlight: Promise<void> | null = null;
  let stopped = false;

  const total = () => mic.samples().reduce((n, c) => n + c.length, 0);
  const maxSamples = Math.round(MAX_WINDOW_SEC * rate);
  const windowStart = () => Math.max(0, confirmedSamples - Math.round(OVERLAP_SEC * rate));
  // the audio from `from` to `to`, never more than MAX_WINDOW_SEC: a window the host's size limit accepts, however long
  // the speech server failed or took (the rest is the next window's)
  const slice = (from: number, to = total()): Float32Array => {
    const stop = Math.min(to, total(), from + maxSamples);
    const out = new Float32Array(Math.max(0, stop - from));
    let off = 0;
    let pos = 0;
    for (const c of mic.samples()) {
      const end = pos + c.length;
      if (pos >= stop) break;
      if (end > from) {
        const part = c.subarray(Math.max(0, from - pos), Math.min(c.length, stop - pos));
        out.set(part, off);
        off += part.length;
      }
      pos = end;
    }
    return out;
  };
  const send = (pcm: Float32Array, prompt: string) =>
    api.transcribe(new Blob([pcmToWav(pcm, rate)], { type: "audio/wav" }), prompt);

  const silence = (pcmLength: number, from: number) => {
    confirmedSamples = Math.max(confirmedSamples, from + Math.max(0, pcmLength - rate)); // keep only the last second
    prev = [];
    onUpdate(confirmed, "");
  };

  const pass = async () => {
    let from = windowStart();
    let pcm = slice(from);
    // a silent window with more audio after it (the oldest MAX_WINDOW_SEC of a long stretch): drop it, look at the next
    while (rmsLevel(pcm) < SILENCE_RMS && from + pcm.length < total()) {
      silence(pcm.length, from);
      from = windowStart();
      pcm = slice(from);
    }
    const at = confirmedSamples;
    if (rmsLevel(pcm) < SILENCE_RMS) return silence(pcm.length, from);
    const prompt = confirmed.slice(-PROMPT_CHARS);
    const answer = await send(pcm, prompt);
    if (stopped || at !== confirmedSamples) return;
    const words = heardWords(answer.words, prompt);
    if (words.length === 0) return silence(pcm.length, from);
    const winSec = pcm.length / rate;
    const stable = words.filter((w) => w.end <= winSec - STABLE_SEC).length;
    let n = Math.min(agreedPrefixLen(prev, words), stable);
    const forced = n === 0 && winSec > FORCE_CONFIRM_SEC;
    if (forced) n = stable > 0 ? stable : words.length;
    if (n > 0) {
      confirmed = appendNew(confirmed, joinWords(words.slice(0, n)));
      const wordEnd = Math.min(Math.round(words[n - 1]!.end * rate), pcm.length);
      // a forced confirm also drops what followed its words but the last second (as silence does): the next window
      // stays bounded however slow the answer was
      const end = forced ? Math.max(wordEnd, pcm.length - rate) : wordEnd;
      confirmedSamples = Math.max(confirmedSamples, from + end);
      prev = [];
    } else {
      prev = words;
    }
    onUpdate(confirmed, joinWords(words.slice(n)));
  };

  const tick = () => {
    if (stopped || inFlight || total() - confirmedSamples < rate) return; // ≥ 1 s of unconfirmed audio
    inFlight = pass()
      .catch((e: unknown) => onError(errText(e)))
      .finally(() => {
        inFlight = null;
      });
  };
  const timer = setInterval(tick, submitMs);

  // the rest after stop: everything after the confirmed text (+ the overlap), in windows of at most MAX_WINDOW_SEC.
  // A window with more audio after it confirms its stable words and keeps only its last second (a forced confirm, as in
  // pass), so every window moves on; the last one's text is taken as it is (no agreement). A failure keeps what was
  // confirmed and where: retry() goes on from the window that failed.
  const finish = async (): Promise<string> => {
    for (;;) {
      const from = windowStart();
      const pcm = slice(from);
      const last = from + pcm.length >= total();
      const prompt = confirmed.slice(-PROMPT_CHARS);
      const heard = pcm.length >= rate / 4 && rmsLevel(pcm) >= SILENCE_RMS;
      if (last) {
        if (heard) {
          const answer = await send(pcm, prompt);
          const text = joinWords(heardWords(answer.words, prompt));
          if (text) confirmed = appendNew(confirmed, text);
        }
        onUpdate(confirmed, "");
        return confirmed;
      }
      let end = pcm.length - rate;
      if (heard) {
        const winSec = pcm.length / rate;
        const stable = heardWords((await send(pcm, prompt)).words, prompt).filter((x) => x.end <= winSec - STABLE_SEC);
        if (stable.length > 0) {
          confirmed = appendNew(confirmed, joinWords(stable));
          end = Math.max(end, Math.min(Math.round(stable.at(-1)!.end * rate), pcm.length));
        }
      }
      confirmedSamples = Math.max(confirmedSamples, from + end);
      prev = [];
      onUpdate(confirmed, "");
    }
  };

  return {
    async stop() {
      stopped = true;
      clearInterval(timer);
      mic.release();
      if (inFlight) await inFlight;
      const attempt = (): Promise<string> =>
        finish().catch((e: unknown) => {
          throw new DictationFailed(errText(e), confirmed, attempt);
        });
      return attempt();
    },
    cancel() {
      stopped = true;
      clearInterval(timer);
      mic.release();
    },
  };
}
