import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  DictationFailed,
  heardWords,
  agreedPrefixLen,
  appendNew,
  openMic,
  composeDictation,
  joinWords,
  LEVEL_SAMPLES,
  levelBars,
  METER_CEIL_DB,
  MAX_WINDOW_SEC,
  METER_FLOOR_DB,
  meterLevel,
  pcmToWav,
  pendingRange,
  rmsLevel,
  startDictation,
  type DictationApi,
  type MicCapture,
  type SttWord,
  type Transcript,
} from "./dictation";

const w = (word: string, start: number, end: number): SttWord => ({ word, start, end });
const RATE = 16000;

// a microphone that "hears" what the test pushes: push = seconds of sound (a steady 0.1), silent = seconds of silence
function fakeMic(): MicCapture & { push: (sec: number) => void; silent: (sec: number) => void; released: number } {
  const chunks: Float32Array[] = [];
  const m = {
    sampleRate: RATE,
    released: 0,
    samples: () => chunks,
    level: () => 0,
    release: () => {
      m.released++;
    },
    push: (sec: number) => chunks.push(new Float32Array(Math.round(sec * RATE)).fill(0.1)),
    silent: (sec: number) => chunks.push(new Float32Array(Math.round(sec * RATE))),
  };
  return m;
}

// answers each pass from a script; records the window length (s) and prompt it got
function fakeApi(answers: (Transcript | Error)[]): DictationApi & { seen: { sec: number; prompt: string }[] } {
  const seen: { sec: number; prompt: string }[] = [];
  return {
    seen,
    shortcut: null,
    transcribe: (wav, prompt) => {
      seen.push({ sec: (wav.size - 44) / 2 / RATE, prompt });
      const a = answers.shift();
      if (!a) return Promise.reject(new Error("no answer scripted"));
      return a instanceof Error ? Promise.reject(a) : Promise.resolve(a);
    },
  };
}

const flush = async () => {
  for (let i = 0; i < 5; i++) await Promise.resolve();
};

describe("dictation helpers", () => {
  it("agreement is the common word prefix, case and punctuation ignored", () => {
    expect(agreedPrefixLen([w(" Hello", 0, 1), w(" world", 1, 2)], [w(" hello,", 0, 1), w(" word", 1, 2)])).toBe(1);
    expect(agreedPrefixLen([], [w(" a", 0, 1)])).toBe(0);
  });

  it("joins whisper words (leading spaces) into one line", () => {
    expect(joinWords([w(" Hello", 0, 1), w(" world.", 1, 2)])).toBe("Hello world.");
  });

  it("puts the spoken text at the caret with one space on each side", () => {
    expect(composeDictation("Fix:", "done", "the login", "page")).toBe("Fix: the login page done");
    expect(composeDictation("", "", "hi", "")).toBe("hi");
    expect(composeDictation("a ", " b", "x", "")).toBe("a x b");
    expect(composeDictation("keep", "", "", "")).toBe("keep");
  });

  it("finds the pending words in the composed text", () => {
    const cases: [string, string, string, string][] = [
      ["Fix:", "done", "the login", "page"],
      ["Fix: ", "", "the login", "page"],
      ["Fix:", "", "", "the login"],
      ["", "after", "", "hello there"],
      ["line\n", "", "", "hi"],
    ];
    for (const [before, after, confirmed, pending] of cases) {
      const r = pendingRange(before, confirmed, pending)!;
      expect(composeDictation(before, after, confirmed, pending).slice(r[0], r[1])).toBe(pending);
    }
    expect(pendingRange("Fix:", "the login", "")).toBeNull();
  });

  it("the level is the RMS of the samples: 0 for silence or none, 1 at full scale", () => {
    expect(rmsLevel(new Float32Array(512))).toBe(0);
    expect(rmsLevel(new Float32Array(0))).toBe(0);
    expect(rmsLevel(new Float32Array(512).fill(-1))).toBe(1);
    expect(rmsLevel(new Float32Array([0.5, -0.5, 0.5, -0.5]))).toBeCloseTo(0.5, 6);
    const sine = Float32Array.from({ length: 1600 }, (_, i) => Math.sin((2 * Math.PI * i) / 160));
    expect(rmsLevel(sine)).toBeCloseTo(Math.SQRT1_2, 3);
    expect(rmsLevel([2, 2])).toBe(1); // clipped input never reads above full scale
  });

  it("the meter maps decibels onto 0 … 1 between its floor and ceiling", () => {
    const rms = (db: number) => 10 ** (db / 20);
    expect(meterLevel(0)).toBe(0);
    expect(meterLevel(Number.NaN)).toBe(0);
    expect(meterLevel(rms(METER_FLOOR_DB - 10))).toBe(0);
    expect(meterLevel(rms(METER_CEIL_DB + 6))).toBe(1);
    expect(meterLevel(rms((METER_FLOOR_DB + METER_CEIL_DB) / 2))).toBeCloseTo(0.5, 6);
    expect(meterLevel(rms(-30))).toBeGreaterThan(meterLevel(rms(-40)));
  });

  it("the level bars ripple from the centre: the middle bar is the newest reading, the edges older and lower", () => {
    expect(levelBars([], 5)).toEqual([0, 0, 0, 0, 0]);
    const steady = levelBars(new Array<number>(16).fill(1), 7);
    expect(steady[3]).toBe(1);
    expect(steady).toEqual([...steady].reverse()); // symmetric
    expect(steady[0]!).toBeLessThan(steady[1]!);
    expect(steady[1]!).toBeLessThan(steady[2]!);
    expect(steady[0]!).toBeGreaterThan(0);
    // one loud reading, then silence: it has left the centre and reached the bars one step out (lag 2)
    const pulse = levelBars([0, 0, 0, 1, 0, 0], 5, 2);
    expect(pulse[2]).toBe(0);
    expect(pulse[1]).toBeGreaterThan(0);
    expect(pulse[3]).toBe(pulse[1]);
    expect(pulse[0]).toBe(0);
  });

  it("a window's first words that repeat the confirmed tail are dropped (the seam), nothing else", () => {
    expect(appendNew("Please fix the login page and", "and the tests before Friday")).toBe(
      "Please fix the login page and the tests before Friday",
    );
    expect(appendNew("fix the login page", "Login page, then deploy")).toBe("fix the login page then deploy");
    expect(appendNew("go to the", "the store")).toBe("go to the store");
    expect(appendNew("a b c d", "e f")).toBe("a b c d e f");
    expect(appendNew("", "hi")).toBe("hi");
    expect(appendNew("hi", "")).toBe("hi");
    expect(composeDictation("", "", "page and", "and more")).toBe("page and more");
  });

  it("heard words: a zero-length word or a pass that is the prompt's tail is not speech", () => {
    expect(heardWords([w(" a", 0, 0), w(" b", 0.2, 0.5)], "")).toEqual([w(" b", 0.2, 0.5)]);
    expect(heardWords([w(" the", 0, 0.2), w(" pause.", 0.2, 0.6)], "before the pause")).toEqual([]);
    expect(heardWords([w(" pause", 0, 0.4), w(" then", 0.4, 0.7)], "before the pause")).toHaveLength(2);
  });

  it("writes a 16 kHz mono 16-bit WAV", () => {
    const buf = pcmToWav(new Float32Array([0, 1, -1]));
    const v = new DataView(buf);
    expect(buf.byteLength).toBe(44 + 6);
    expect(String.fromCharCode(...new Uint8Array(buf, 0, 4))).toBe("RIFF");
    expect(v.getUint32(24, true)).toBe(16000);
    expect(v.getUint16(22, true)).toBe(1);
    expect(v.getInt16(46, true)).toBe(0x7fff);
    expect(v.getInt16(48, true)).toBe(-0x8000);
  });
});

describe("startDictation", () => {
  beforeEach(() => vi.useFakeTimers());
  afterEach(() => vi.useRealTimers());
  const tick = async () => {
    await vi.advanceTimersByTimeAsync(100);
    await flush();
  };
  const secs = (api: { seen: { sec: number }[] }) => api.seen.map((x) => Math.round(x.sec * 10) / 10);

  it("confirms the stable words two passes agree on; the next window re-hears 0.4 s and the overlap is dropped", async () => {
    const mic = fakeMic();
    const words = [w(" Fix", 0, 0.5), w(" the", 0.5, 0.8), w(" login", 0.8, 1.4), w(" page", 1.4, 2.4)];
    const api = fakeApi([
      { text: "", words },
      { text: "", words: [...words, w(" and", 2.6, 3.5)] },
      { text: "", words: [w(" page", 0, 0.4), w(" and", 0.6, 1.5), w(" the", 1.5, 1.8), w(" tests", 1.8, 2.6)] },
    ]);
    const updates: [string, string][] = [];
    const d = startDictation({ api, mic, onUpdate: (c, p) => updates.push([c, p]), onError: () => {}, submitMs: 100 });
    mic.push(3);
    await tick();
    expect(updates.at(-1)).toEqual(["", "Fix the login page"]); // nothing agreed yet: all pending
    mic.push(1);
    await tick();
    expect(updates.at(-1)).toEqual(["Fix the login page", "and"]); // "and" ends inside the last second: not yet
    mic.push(1);
    await expect(d.stop()).resolves.toBe("Fix the login page and the tests");
    expect(secs(api)).toEqual([3, 4, 3]); // the last window starts 0.4 s before "page" ended (2.4 s)
    expect(api.seen[2]!.prompt).toBe("Fix the login page");
    expect(mic.released).toBe(1);
  });

  it("a word that ends within the window's last second is not confirmed, even when two passes agree", async () => {
    const mic = fakeMic();
    const late = [w(" three", 0, 0.6), w(" fifteen", 0.7, 1.7)];
    const api = fakeApi([
      { text: "", words: late },
      { text: "", words: late },
    ]);
    const updates: [string, string][] = [];
    const d = startDictation({ api, mic, onUpdate: (c, p) => updates.push([c, p]), onError: () => {}, submitMs: 100 });
    mic.push(1.8);
    await tick();
    await tick();
    expect(updates.at(-1)).toEqual(["three", "fifteen"]);
    d.cancel();
  });

  it("waits for a second of unconfirmed audio before the first pass", async () => {
    const mic = fakeMic();
    const api = fakeApi([]);
    const d = startDictation({ api, mic, onUpdate: () => {}, onError: () => {}, submitMs: 100 });
    mic.push(0.6);
    await vi.advanceTimersByTimeAsync(300);
    expect(api.seen).toEqual([]);
    d.cancel();
    expect(mic.released).toBe(1);
  });

  it("a silent window is never sent: its audio is dropped but its last second, so the window stays bounded", async () => {
    const mic = fakeMic();
    const api = fakeApi([{ text: "", words: [w(" Ship", 1.0, 1.4), w(" it.", 1.4, 1.9)] }]);
    const d = startDictation({ api, mic, onUpdate: () => {}, onError: () => {}, submitMs: 100 });
    mic.silent(40); // longer than any server limit
    await tick();
    expect(api.seen).toEqual([]);
    mic.push(1.5);
    await expect(d.stop()).resolves.toBe("Ship it.");
    expect(secs(api)).toEqual([2.9]); // 40 s of silence → its last second (+ the 0.4 s overlap) + 1.5 s of speech
  });

  it("silence that the model answers with its prompt is ignored: zero-length words, or the prompt's tail", async () => {
    const mic = fakeMic();
    const first = [
      w(" First", 0, 0.4),
      w(" part", 0.4, 0.8),
      w(" before", 0.8, 1.2),
      w(" the", 1.2, 1.4),
      w(" pause", 1.4, 1.9),
    ];
    const api = fakeApi([
      { text: "", words: first },
      { text: "", words: [...first, w(" uh", 2.0, 2.2)] },
      // the gap: the model echoes the prompt with zero-length words, then with real-looking timings
      { text: "", words: first.map((x) => w(x.word, 0, 0)) },
      { text: "", words: first },
      { text: "", words: [w(" Second", 0.6, 1.0), w(" part", 1.0, 1.4)] },
    ]);
    const updates: [string, string][] = [];
    const d = startDictation({ api, mic, onUpdate: (c, p) => updates.push([c, p]), onError: () => {}, submitMs: 100 });
    mic.push(3.2);
    await tick();
    mic.push(0.1);
    await tick();
    expect(updates.at(-1)![0]).toBe("First part before the pause");
    mic.push(3);
    await tick();
    expect(updates.at(-1)).toEqual(["First part before the pause", ""]);
    mic.push(1);
    await tick();
    expect(updates.at(-1)).toEqual(["First part before the pause", ""]);
    mic.push(1);
    await expect(d.stop()).resolves.toBe("First part before the pause Second part");
  });

  it("a long window with no agreement confirms its stable words", async () => {
    const mic = fakeMic();
    const api = fakeApi([{ text: "", words: [w(" one", 0, 10), w(" two", 10, 24), w(" three", 25.5, 26)] }]);
    const updates: [string, string][] = [];
    const d = startDictation({ api, mic, onUpdate: (c, p) => updates.push([c, p]), onError: () => {}, submitMs: 100 });
    mic.push(26);
    await tick();
    expect(updates.at(-1)).toEqual(["one two", "three"]);
    d.cancel();
  });

  it("a forced confirm keeps only the window's last second: a slow answer cannot grow the next window past the limit", async () => {
    const mic = fakeMic();
    let answer: (t: Transcript) => void = () => {};
    const api: DictationApi & { seen: { sec: number; prompt: string }[] } = {
      seen: [],
      shortcut: null,
      transcribe: (wav, prompt) => {
        api.seen.push({ sec: (wav.size - 44) / 2 / RATE, prompt });
        return new Promise((r) => (answer = r));
      },
    };
    const d = startDictation({ api, mic, onUpdate: () => {}, onError: () => {}, submitMs: 100 });
    mic.push(26);
    await tick(); // the 26 s window is sent; its answer is slow
    mic.push(20); // 20 s more arrive meanwhile
    answer({ text: "", words: [w(" early", 0, 2)] }); // no agreement, a window over 25 s: forced
    await flush();
    await tick();
    expect(secs(api)).toEqual([26, 21.4]); // from 25 s (the window's end − 1 s) − 0.4 s overlap, not from 2 s
    d.cancel();
  });

  it("no window is longer than MAX_WINDOW_SEC: a server failing while you talk gets the oldest 30 s, which confirms", async () => {
    const mic = fakeMic();
    const api = fakeApi([
      new Error("speech server down"),
      new Error("speech server down"),
      { text: "", words: [w(" first", 0, 10), w(" half", 10, 28.5)] }, // no agreement, a window over 25 s: forced
      { text: "", words: [w(" rest", 0.5, 4)] },
    ]);
    const updates: [string, string][] = [];
    const errors: string[] = [];
    const d = startDictation({
      api,
      mic,
      onUpdate: (c, p) => updates.push([c, p]),
      onError: (m) => errors.push(m),
      submitMs: 100,
    });
    mic.push(20);
    await tick(); // fails: 20 s
    mic.push(20);
    await tick(); // fails: 40 s heard, 30 s sent
    mic.push(5);
    await tick(); // 45 s heard, the oldest 30 s sent: confirmed up to its last second
    expect(errors).toEqual(["speech server down", "speech server down"]);
    expect(updates.at(-1)![0]).toBe("first half");
    await expect(d.stop()).resolves.toBe("first half rest");
    expect(secs(api)).toEqual([20, MAX_WINDOW_SEC, MAX_WINDOW_SEC, 16.4]); // from 29 s − 0.4 s overlap to 45 s
  });

  it("stop() sends a long unconfirmed tail in windows of at most MAX_WINDOW_SEC; retry() goes on from the one that failed", async () => {
    const mic = fakeMic();
    const api = fakeApi([
      { text: "", words: [w(" one", 0, 20), w(" two", 20, 28)] },
      new Error("timed out"),
      { text: "", words: [w(" three", 0.5, 20), w(" four", 20, 28)] },
      { text: "", words: [w(" five", 0.5, 5)] },
    ]);
    const d = startDictation({ api, mic, onUpdate: () => {}, onError: () => {}, submitMs: 60_000 });
    mic.push(70); // no pass ran: 70 s unconfirmed at stop
    const e = await d.stop().catch((x: unknown) => x);
    expect(e).toBeInstanceOf(DictationFailed);
    const failed = e as DictationFailed;
    expect(failed.confirmed).toBe("one two"); // the first window confirmed its stable words before the second failed
    await expect(failed.retry()).resolves.toBe("one two three four five");
    // 0–30 s (stable to 28 s, kept from 29 s), 28.6–58.6 s twice (failed, then retried), from 57.6 s − 0.4 s to 70 s
    expect(secs(api)).toEqual([MAX_WINDOW_SEC, MAX_WINDOW_SEC, MAX_WINDOW_SEC, 12.8]);
    expect(api.seen.every((x) => x.sec <= MAX_WINDOW_SEC)).toBe(true);
  });

  it("a failed pass is reported and retried; a failed final pass keeps its audio: retry() sends it again", async () => {
    const mic = fakeMic();
    const api = fakeApi([
      new Error("speech server down"),
      { text: "", words: [] },
      new Error("timed out"),
      { text: "", words: [w(" Ship", 0, 0.5), w(" it.", 0.5, 1)] },
    ]);
    const errors: string[] = [];
    const d = startDictation({ api, mic, onUpdate: () => {}, onError: (m) => errors.push(m), submitMs: 100 });
    mic.push(1.2);
    await tick();
    expect(errors).toEqual(["speech server down"]);
    await tick();
    expect(api.seen).toHaveLength(2);
    const e = await d.stop().catch((x: unknown) => x);
    expect(e).toBeInstanceOf(DictationFailed);
    const failed = e as DictationFailed;
    expect(failed.message).toBe("timed out");
    expect(failed.confirmed).toBe("");
    await expect(failed.retry()).resolves.toBe("Ship it.");
    expect(secs(api).slice(-2)).toEqual([1.2, 1.2]); // the same audio, sent again
  });
});

describe("openMic", () => {
  it("reads the level from the newest samples, and a released microphone reads 0", async () => {
    const stop = vi.fn();
    let heard = 0.25;
    const node = () => ({ connect: vi.fn(), disconnect: vi.fn() });
    const meter = {
      ...node(),
      fftSize: 0,
      getFloatTimeDomainData: (out: Float32Array) => out.fill(heard),
    };
    vi.stubGlobal("navigator", {
      mediaDevices: { getUserMedia: () => Promise.resolve({ getTracks: () => [{ stop }] }) },
    });
    vi.stubGlobal(
      "AudioContext",
      class {
        sampleRate = RATE;
        destination = {};
        createMediaStreamSource = node;
        createScriptProcessor = () => ({ ...node(), onaudioprocess: null });
        createAnalyser = () => meter;
        resume = () => Promise.resolve();
        close = () => Promise.resolve();
      },
    );
    const mic = await openMic();
    expect(meter.fftSize).toBe(LEVEL_SAMPLES);
    expect(mic.level()).toBeCloseTo(0.25, 6);
    heard = 0;
    expect(mic.level()).toBe(0);
    heard = 0.8;
    expect(mic.level()).toBeCloseTo(0.8, 6);
    mic.release();
    expect(mic.level()).toBe(0);
    expect(stop).toHaveBeenCalledTimes(1);
    vi.unstubAllGlobals();
  });

  it("a failed audio setup stops the microphone's tracks and rejects", async () => {
    const stop = vi.fn();
    vi.stubGlobal("navigator", {
      mediaDevices: { getUserMedia: () => Promise.resolve({ getTracks: () => [{ stop }] }) },
    });
    vi.stubGlobal(
      "AudioContext",
      class {
        constructor() {
          throw new Error("no audio device");
        }
      },
    );
    await expect(openMic()).rejects.toThrow("no audio device");
    expect(stop).toHaveBeenCalledTimes(1);
    vi.unstubAllGlobals();
  });
});
