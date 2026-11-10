// The JSON the ruby engine sends (AgentsKanban::Store#card_json, Api#board / #card_body), the host config and the
// project's board shape. Column keys are strings: a board's columns come from the server (`board`), never a union here.

export type ColumnKey = string;

// AgentsKanban::HostConfig#to_h — the host's SETTINGS (SPEC.md § 2). The boards are not here: a project's columns (typed)
// and workflow arrive as `board` in the board JSON (BoardShapeData), kept by the engine in its database.
export type HostConfig = {
  priorities: string[];
  label_colors: string[];
  system_author: string;
  attachment_url_prefix: string;
  // the commands that start a session; an agent type names which of them it runs and what is typed / which model
  launchers: { key: string; label: string; command: string; args: string[]; via_shell: boolean }[];
  agent_types: AgentTypeConfig[];
  // registered agent sessions running at once on the host, every type and project together
  concurrency: { max_sessions: number | null };
  // the sessions a card may be owned by, as globs (the owner picker lists only these); null = every session the host lists
  owner_sessions: string[] | null;
  idle_watch: { ci_ping_after_minutes: number; ci_comment_after_minutes: number; owner_idle_hours: number } | null;
  // the handoff gate's requirements on a board with a handoff column; null = no handoff gate on this host
  handoff: {
    requires_pr_url: boolean;
    requires_ci_url: boolean;
    qa_min_chars: number;
    ui_change_needs_screenshots: boolean;
  } | null;
  // the approval gate: requires_green_ci = an approval step is refused until the card's PR checks are green; null = no gate
  approval: { requires_green_ci: boolean } | null;
  dependencies: boolean;
  // the cross-cutting card flags (needs_operator / blocked_external): one reminder comment after that many hours
  flags: { reminder_hours: number };
  // the agent review loop: entries into one review column before it must end at a gate; the label a handoff then carries
  review_loop: { max_rounds: number; unresolved_label: string; unresolved_color: string; columns: string[] } | null;
  table_prefix: string;
  theme: Record<string, string>;
};

// AgentsKanban::ColumnTypes — what a column DOES; a board names one per column and every rule derives from it.
export type ColumnTypeKey = "parked" | "queued" | "working" | "review" | "gate" | "done" | "cancelled";
export type ColumnType = {
  key: ColumnTypeKey;
  label: string;
  summary: string;
  hide_after_hours: number;
  waiting: boolean;
  listened: boolean;
  operator_only: boolean;
  agent_no_create: boolean;
  finishes: boolean;
  terminal: boolean;
  singleton: boolean;
};
// AgentsKanban::Board#to_h — a project's board as declared: columns (key, label, type; order = board order) + transitions — no
// graph position: the editor lays the graph out every time (SPEC § 2)
// hide_after_hours: a card with no update for that long is folded behind the list's "Load older" (0 = never); the server
// fills the type's default when a column omits it and always sends it back
export type BoardColumnDef = {
  key: ColumnKey;
  label: string;
  type: ColumnTypeKey;
  hide_after_hours: number;
};
export type BoardShape = { columns: BoardColumnDef[]; transitions: WorkflowTransition[] };
// one approval step: the operator's move from → to approves; `then` = where its agent takes the card next (null = no single way)
export type ApprovalStep = { from: ColumnKey; to: ColumnKey; name: string | null } & (
  { final: true; then: ColumnKey } | { final: false; then: ColumnKey | null }
);
// AgentsKanban::Board#rules — the same derivation the engine enforces, for the client to render from
export type BoardRules = {
  default_column: ColumnKey;
  waiting: ColumnKey[];
  listened: ColumnKey[];
  operator_only: ColumnKey[];
  agent_no_create: ColumnKey[];
  // the terminal columns (done, cancelled): the work is over, the owner watchdog leaves the card alone
  terminal: ColumnKey[];
  gates: {
    // the GATE columns (agents enter only with kanban_handoff) + the host's requirements; null = no gate on this board
    handoff: {
      columns: ColumnKey[];
      requires_pr_url: boolean;
      requires_ci_url: boolean;
      qa_min_chars: number;
      ui_change_needs_screenshots: boolean;
    } | null;
    // every approval step (Board#approvals): per gate its ONE forward operator exit; final = the agent then finishes
    approvals: ApprovalStep[];
    watchdog: { from: ColumnKey; to: ColumnKey } | null;
  };
  dependencies: {
    done: ColumnKey[];
    blocked: ColumnKey[];
    promote: { from: ColumnKey[]; to: ColumnKey } | null;
  } | null;
  idle_column: ColumnKey | null;
  // the review columns: review rounds are counted per column (Card.review_round)
  review_columns: ColumnKey[];
  spawn_columns: ColumnKey[];
  hide_after_hours: Record<ColumnKey, number>;
};
// Api#board_shape / Store#board_json: the shape + its rules + the type set + who saved it (the graph editor's data)
export type BoardShapeData = BoardShape & {
  rules: BoardRules;
  types: ColumnType[];
  updated_by: string | null;
  updated: string | null;
};

// AgentsKanban::BoardConfig::AgentType — what a launched session IS (SPEC.md § Board config)
export type AgentTypeConfig = {
  key: string;
  label: string;
  launchers: string[];
  model: string | null | Record<string, string | null>; // one value, or per launcher key
  prompt: string | null;
  agent_name: string;
  session_name: string;
  takes: ColumnTypeKey[]; // column TYPES whose ownerless cards a session of this type adopts
  max: number | null;
  max_per_project: number | null;
  spawns_for?: ColumnTypeKey[];
  launcher_follows?: string | null; // runs the launcher of the board's running session of this type
  spawn_launcher?: string | null; // the launcher a start that names none runs (absent + several launchers = refused)
};
// Api#launches: the Launch bar's data — the types with their launchers and who runs now against the cap
export type LaunchType = {
  key: string;
  label: string;
  launchers: { key: string; label: string; model?: string | null }[];
  model: string | null | Record<string, string | null>;
  takes: ColumnTypeKey[];
  max: number | null;
  max_per_project: number | null;
  prompt: boolean;
  running: number | null;
  running_here: number | null;
  sessions_here?: string[] | null;
  launcher_follows?: string | null;
  // the board's running session this type follows (Store#followed_launcher): its launcher is the only one a launch may use
  follows?: { type: string; session: string; launcher: string } | null;
};
export type RegisteredSession = {
  id: number;
  session: string;
  socket: string;
  project: string;
  type: string;
  launcher: string;
  agent: string;
  launched_by: string;
  launched: string;
  last_seen: string | null;
  ended: string | null;
  end_reason: string | null;
  live: boolean | null;
  cards: number;
};
export type Concurrency = {
  max_sessions: number | null;
  running: number;
  free: number | null;
  sessions: RegisteredSession[];
  types: Record<string, { running: number; max: number | null; max_per_project: number | null }>;
};
export type LaunchesData = { types: LaunchType[]; concurrency: Concurrency | null; sessions_error: string | null };
// Api#waiting `launch_failures`: the registrations whose start failed (claude never came up) in the last day, newest
// first — a launch from the bar or a spawn for a card; `reason` = the host's, verbatim
export type LaunchFailure = {
  id: number;
  session: string;
  project: string;
  type: string;
  launcher: string | null;
  launched_by: string;
  ended: string;
  reason: string;
};
// Api#launch 201: the registration + what the host's start answered (`result`, the host's own shape)
export type LaunchResult = {
  session: string;
  type: string;
  launcher: string;
  agent: string;
  adopted: Card[];
  result: Record<string, unknown>;
  concurrency: Concurrency;
};

export type SessionDialogInfo = {
  id: number;
  session: string;
  keys: string[];
  escape: boolean;
  free_text: boolean;
  options: { key: string; label: string; free: boolean }[];
  posted: string;
};

export type Card = {
  id: number;
  project: string;
  owner_session: string | null;
  owner_socket: string | null;
  approved: string | null;
  approved_by: string | null;
  pr_url?: string | null;
  ci_url?: string | null;
  ui_change?: boolean | null;
  handoff?: string | null;
  handoff_by?: string | null;
  qa_notes?: string | null;
  qa_html?: string | null;
  // kanban_ask: the agent's open question — the needs_operator FLAG (the card keeps its column); options = buttons that
  // post the choice as the answer
  needs_operator: boolean;
  // in an approval gate: why its Approve would not pass now ("PR #7: CI is still running") — waiting for CI, not for
  // the operator; null = approvable now (or no such gate)
  gate_hold?: string | null;
  question?: string | null;
  question_html?: string | null;
  question_options?: string[] | null;
  asked?: string | null;
  asked_by?: string | null;
  // kanban_block: the blocked_external flag — what the card waits for outside the board, and where it is seen
  blocked: { reason: string | null; url: string | null; by: string | null; at: string | null } | null;
  // the review loop: how often the card entered its current review column (null outside one / never)
  review_round: number | null;
  // an owner session blocked on a dialog on its screen (posted by the notifier): only `keys` are pressable
  dialog?: SessionDialogInfo | null;
  // dependencies: the parent this card waits for, how many live children it has, the parents not yet done
  parent: number | null;
  children: number;
  blocked_by: number[];
  // The board's transitions out of the card's column: named edges the actor may take ([] = nobody moves it from here).
  transitions: { name: string; to: string; to_label: string; by: WorkflowActor }[];
  metadata: Record<string, unknown> | null;
  column: ColumnKey;
  column_label?: string; // the column's label as the engine prints it (agents read it; the board uses config)
  position: number;
  title: string;
  labels: string[];
  assignee: string | null;
  priority: string | null;
  comments: number;
  due: string | null;
  due_done: boolean;
  cover: string | null;
  has_description: boolean;
  checklist_done: number;
  checklist_total: number;
  attachments: number; // board faces: the count (a single card carries the list: CardFull)
  created_by: string;
  created: string;
  updated: string;
  archived: string | null;
  description?: string;
  description_html?: string;
  checklists?: Checklist[];
};
export type ChecklistItem = {
  id: number;
  body: string;
  body_html: string;
  done: boolean;
  position: number;
  done_by: string | null;
  done_at: string | null;
};
export type Checklist = { id: number; title: string; position: number; items: ChecklistItem[] };
export type BoardLabel = { id: number; name: string; color: string };
export type Activity = {
  id: number;
  at: string;
  kind: string;
  author: string;
  body: string;
  body_html?: string;
  edited?: string | null;
};
// A link's tags are small tone-coloured chips after the label; `detail` rows show in a popover on hover / focus / a tap on
// the chips. Both optional: a link without them is the plain row.
export type LinkTone = "ok" | "warn" | "bad" | "done" | "muted" | "info";
export type LinkTag = { text: string; tone: LinkTone };
export type CardLink = {
  kind: "repo" | "branch" | "site" | "url" | "commit" | "file" | "pr" | "ci";
  label: string;
  url: string;
  tags?: LinkTag[];
  detail?: { label: string; value: string }[];
};
export type OwnerCandidate = { name: string; socket: string; state: string; engines: string[] };
export type SessionLinks = {
  claude_url: string | null;
  ssh_attach: string;
  terminal_url: string;
  model?: string | null;
};
export type Ping = {
  at: string;
  done_at: string | null;
  session: string;
  reason: string;
  status: "pending" | "sent" | "failed";
  error: string | null;
  attempts: number;
};
export type Attachment = {
  id: number;
  card_id: number;
  comment_id: number | null;
  filename: string;
  content_type: string;
  size: number;
  sha256: string;
  image: boolean; // png/jpeg/gif/webp: shown inline; anything else only downloads
  uploaded_by: string;
  created: string;
  url: string;
  download_url: string;
  markdown: string;
};
export type CardFull = Omit<Card, "attachments"> & { attachments: Attachment[] };
// Api#card_body + whatever the host's card_extras add (links, live sessions, session links, sessions_error)
export type CardData = {
  card: CardFull;
  activity: Activity[];
  pings?: Ping[];
  links?: CardLink[];
  live_sessions?: string[] | null;
  project_sessions?: OwnerCandidate[];
  session_links?: Record<string, SessionLinks>;
  sessions_error?: string | null;
  delivered?: string;
};
export type BoardColumn = {
  column: ColumnKey;
  label: string;
  type: ColumnTypeKey;
  operator_only: boolean;
  hide_after_hours: number;
  cards: Card[];
};
export type BacklogTask = {
  id: string;
  title: string;
  status: string;
  column: ColumnKey | null;
  labels?: string[];
  assignee?: string[] | string;
  priority?: string;
  file: string;
  draft?: boolean;
};
// Api#board + the host's board_extras (assignees, launcher_error, live sessions)
export type BoardData = {
  project: string;
  labels: BoardLabel[];
  label_colors: string[];
  columns: BoardColumn[];
  config: HostConfig;
  board: BoardShapeData;
  archived?: Card[];
  backlog_md: { read_only: string; errors: string[]; tasks: BacklogTask[] } | null;
  columns_order: ColumnKey[];
  waiting_columns: ColumnKey[];
  listened_columns: ColumnKey[];
  // cards waiting for the operator: the waiting columns' cards that are approvable now (or flagged) + the flagged cards
  // elsewhere (server-computed); held = the gate cards waiting for CI instead
  waiting: number;
  held: number;
  flagged: number;
  priorities: string[];
  assignees?: string[];
  launcher_error?: string | null;
  live_sessions?: string[] | null;
  project_sessions?: OwnerCandidate[];
  session_links?: Record<string, SessionLinks>;
  sessions_error?: string | null;
};
export type MoveResult = { card: Card; counts: Record<ColumnKey, number>; delivered: string | null };

// AgentsKanban::Workflow (SPEC.md § 2): a board's named transitions, as declared. `from` = a column key, a list of keys
// or "*" (every column); `to` = a column key or "*" (a fan-out: named together with the column it goes to).
export type WorkflowActor = "operator" | "agent" | "any";
export type WorkflowTransition = { name: string; from: string | string[]; to: string; by: WorkflowActor };
