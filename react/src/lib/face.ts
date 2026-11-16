// An agent's face: two eyes on a disc coloured by its agent TYPE. The eyes'
// shape is picked from a hash of the name, so the same agent has the same eyes everywhere; its mood is shown by what the
// eyes do (components/AgentFace.tsx + styles/kanban.css), nothing else is drawn. Pure: never random, never stored.
export const EYES = ["capsule", "round"] as const;

export type Face = { eyes: (typeof EYES)[number] };

// FNV-1a over the name's UTF-8 bytes, 32 bit
export function faceHash(name: string): number {
  let h = 0x811c9dc5;
  for (const b of new TextEncoder().encode(name)) {
    h ^= b;
    h = Math.imul(h, 0x01000193) >>> 0;
  }
  return h >>> 0;
}

export const agentFace = (name: string): Face => ({ eyes: EYES[faceHash(name) % EYES.length]! });

// A person signs in with an email address and keeps the initials; any other identity (an agent, the board's system
// author) wears a face. The identity's form, not a role: the Store never reads a role off a name.
export const wearsFace = (identity: string): boolean => !identity.includes("@");

// What a face is doing. The host's words for a session's state and phase map onto these (moodOf); null = a still face.
export const MOODS = ["sleeping", "idle", "working", "thinking", "tool", "writing", "subagents", "blocked"] as const;
export type Mood = (typeof MOODS)[number];

export const MOOD_WORDS: Record<Mood, string> = {
  sleeping: "sleeping",
  idle: "idle",
  working: "working",
  thinking: "thinking",
  tool: "running a tool",
  writing: "writing",
  subagents: "waiting for its subagents",
  blocked: "waiting for you",
};

// The backdrop's hue is the agent TYPE's (every agent of a type shares it), hashed from the type key — the types are
// the host's data, so none is named here. Two keys may land close on the wheel: a host theme sets --ak-face-type-<key>.
export function typeHue(type: string): number {
  return faceHash(type) % 360;
}

// A type key as a CSS custom-property suffix: --ak-face-type-<this> overrides the hashed colour in a host theme
export const typeToken = (type: string): string => `--ak-face-type-${type.replace(/[^a-zA-Z0-9_-]/g, "-")}`;

// The backdrop a face of this type gets: the host's token when its theme sets one, else the hashed hue. No type (an
// identity the session registry does not know) → undefined: the stylesheet's neutral --ak-face-unknown.
export function typeBackdrop(type: string | null | undefined): string | undefined {
  if (!type) return undefined;
  return `var(${typeToken(type)}, hsl(${typeHue(type)} 62% 58%))`;
}

// A name glob as the host config writes them (`face_roles`, like `owner_sessions`): `*` = any run of characters, `?` =
// one character, everything else literal; the WHOLE name must match.
export function globMatch(glob: string, name: string): boolean {
  const body = glob
    .replace(/[.+^${}()|[\]\\]/g, "\\$&")
    .replace(/\*/g, ".*")
    .replace(/\?/g, ".");
  return new RegExp(`^${body}$`, "s").test(name);
}

// The type a face is coloured by: the agent type its session registered (`agents`: name → type key), else the first
// role of the host's `face_roles` ({role: [name globs]}, in the config's order) one of whose globs matches the name — a
// subagent writing under its own name ("reviewer-<agent>") wears its role's colour —, else null (the neutral disc).
export function faceType(
  name: string,
  agents: Record<string, string> | null | undefined,
  faceRoles: Record<string, string[]> | null | undefined,
): string | null {
  const registered = agents?.[name];
  if (registered) return registered;
  for (const [role, globs] of Object.entries(faceRoles ?? {})) if (globs.some((g) => globMatch(g, name))) return role;
  return null;
}

// A session's live state → the mood its face wears. working: its phase (none read = working); blocked = waiting for
// the operator; idle = asleep at its prompt; finished = awake, nothing to do; any other state = a still face.
export function moodOf(live: { state: string; phase: string | null }): Mood | null {
  if (live.state === "blocked") return "blocked";
  if (live.state === "working") {
    if (live.phase === "thinking" || live.phase === "tool" || live.phase === "writing" || live.phase === "subagents")
      return live.phase;
    return "working";
  }
  if (live.state === "idle") return "sleeping";
  if (live.state === "finished") return "idle";
  return null;
}

// What a screen reader and the tooltip say for a face: the name, its type, its mood in words
export function faceLabel(name: string, type: string | null | undefined, mood: Mood | null | undefined): string {
  return [name, type ? `${type} agent` : null, mood ? MOOD_WORDS[mood] : null]
    .filter((b): b is string => !!b)
    .join(" · ");
}
