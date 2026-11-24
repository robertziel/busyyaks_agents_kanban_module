# agents_kanban — the contract

One kanban engine for boards that agents and an operator share, embedded by any host app (the suites cover Sequel on
SQLite and on Postgres, React 18; one host may mount several React apps). Nothing in it is a
server, a route, a daemon or a deploy; the host owns transport, auth, identity and capture. Where this file and the
code disagree, `ruby/` + `fixtures/` win and the fix starts there.

## 1. Ports (what a host injects)

| port | ruby | react |
|---|---|---|
| database | a Sequel `db` handle; tables from `AgentsKanban::Schema.migrate!(db, prefix:)`, run by the HOST's migration | — |
| host config | `AgentsKanban::HostConfig.load(path)` (YAML or JSON, § 2b) | arrives inside the board JSON (`config`) |
| boards | in the engine's tables (§ 2a): the host's data migration calls `BoardRepo#seed!` once with its template (`board.example.yml`) and its project slugs; `Store#board_of(slug)` from then on | arrives inside the board JSON (`board`: shape + rules + types) |
| markdown | any object with `card(md)` / `inline(md)` → HTML; `AgentsKanban::Markdown.new(attachment_url_prefix:)` is the shipped one (commonmarker, raw HTML dropped) | never renders markdown; shows `*_html` |
| clock | `clock: -> { epoch seconds }` on Store / Attachments / Notifier | `Date.now()` |
| projects | `boards: ->(slug) { exists? }` on Store (also the only slugs a board is instantiated for); `projects: ->(slug) { {slug:, path:, remote:} \| nil }` on Tools / Api; `backlog: ->(project, board) { BacklogMd.read(path, board:, status_map:) \| nil }` — the status map's values are column TYPES; a status whose type the board has no column of is an error on the task, never a refusal of the board read | the `slug` prop |
| identity | the ENTRY POINT: `Api` = the operator (`by:` = their name), `Tools` = agents (`author`), `Store` flags `agent:` / `operator:` | `me` prop (the operator's name) |
| delivery | `client` on Notifier / `sessions` on Tools and Api (`-> [live tmux session names]`): `notify(session:, socket:, text:)`, `agents`, `dialog(session:, socket:)`; raises `Delivery::Unavailable` / `Refused` | — |
| launch | `launcher:` on Api: `name(project:)` → a free tmux session name; `start(session:, project:, type:, launcher:, argv:, prompt_template:, vars:)` → the host's result Hash (it renders the prompt with `Launch.render(template, dir: …, **vars)` and types it); raises `Delivery::*`. `grace:` = seconds a registered session counts as running before it is live (the watchdog grace) | `LaunchApi` prop of `<LaunchBar>`: `launches(slug)`, `launch(slug, {type, launcher})` |
| dialog press | `press: ->(session:, socket:, hash:, key:)` on Api (the host's launcher `answer` op) | `api.dialogAnswer` |
| attachments | `root:` directory + `AttachmentPolicy.new(max_bytes:, types:)` from the host's settings | `api.attach` |
| transport | — | the `api: KanbanApi` prop (react/src/api.ts): every call the board makes |
| dictation | — | optional `dictation: DictationApi` prop of `<Board>` (react/src/lib/dictation.ts): `shortcut` (a `KeyCombo` or null, lib/shortcut.ts) + `transcribe(wav, prompt)` → `{text, words: [{word, start, end}]}` (16 kHz mono 16-bit WAV; `prompt` = the text confirmed so far), rejecting with the server's reason. The host's own route to its speech server (e.g. an OpenAI-compatible `/v1/audio/transcriptions`); absent = no mic anywhere |
| live agent line | — | optional `api.sessionsLive(id)` → `{sessions: {name → SessionLive}}` (react/src/types.ts): what the card's agent sessions do now — `state`, and while working `phase` (thinking · tool · writing · subagents), `elapsed_s`, `tokens`, `tool`, the `card` a comment tool writes on, `subagents`; a field the host cannot read is null. The open card dialog polls it every 3 s (`useLivePoll`); absent = no live line |
| board working glow | — | optional `api.boardLive(slug)` → `{sessions: {name → SessionLive}}` (`BoardLive`: no `present` — who is at work on a card is `boardPresence`), ONE answer for the whole board (at least each card's owner session): the board polls it every 3 s (`useLivePoll`); a card whose owner session is `working` with a `phase` glows blue (`.kb-card.agent-working`, token `--ak-working`); the answer is keyed on the slug (a board switch drops it at once) and dropped after 2 polls with no newer one ("live state unknown"); absent = no glow |
| checkout (git) | `git:` on `CardLinks.build` (required, no default — the engine runs no git): `branches(project)` → Set of branch names (local + remote-tracking, remote dropped), `default_ref(project)` → the checked-out branch ("HEAD" when detached / unborn), `files_at(project, refs, files)` → `{file => first ref that has it}` (paths with `..` are never asked); a port that cannot read the checkout raises | — |
| navigation | `card_path:` on `CardLinks::Refs`; `card_url: ->(slug, id) { absolute URL }` on Tools (required): every card a tool returns carries it as `url` | `navigate`, `projectHref`, `cardHref` props; `view` / `onView` own the URL |
| PR roles | `prs:` on Store (**required**, `ArgumentError` without it; a host whose cards carry no PRs answers `{}`): `pr_roles(card)` → `{role => {repos: ["owner/name", …] \| nil, required: bool, error: nil \| "why"}}` (`repos` = every repo a PR of that role may be on — a card may change several repos, e.g. a host and an engine it vendors; `nil` = any; `error` = the role takes no PR now: an assignment under it is refused with it) (raises `Delivery::Unavailable` with the reason when the host cannot say) — the roles `kanban_pr_assign` takes on that card, and the ones an agent must have at least one PR of before it moves the card out of a working column into review / a gate / done | `CardLink.group` (a sub-section of the rail: a PR's role) |
| launch plan | `AgentsKanban::Launch.plan(config, type:, session:, slug:, launcher:, cards:)` → `{argv, agent, prompt_template, vars, model}`; `Launch.render` | — |

## 2. Boards (in the database) and the host config (`config.example.yml`; `HostConfig`)

### 2a. A project's Board — `Board`, kept by `BoardRepo` (tables `boards`, `board_columns`, `board_transitions`)

A project's board is **data in the engine's tables**, edited by the operator in the graph editor (React `BoardEditor`,
the board's Workflow button) through `Api#board_shape` / `#board_shape_save` / `#board_shape_reset`, read by agents with
`kanban_workflow`. It is the value object every rule reads (`Store#board_of(slug)`); the host config carries settings only.

```
{ "columns":     [ { "key": "todo", "label": "To do", "type": "queued", "hide_after_hours": 72 }, … ],   # board order = list order
  "transitions": [ { "name": "Start work", "from": "todo", "to": "doing", "by": "any" }, … ] }
```

**Fold** (`hide_after_hours`): a card in the column with no update (`cards.updated_at`) for that many hours
is folded behind its list's "Load older" in the Board — a VIEW rule: nothing is archived, moved or hidden from agents.
Optional on input (absent = the type's default: `done` 24, `parked` 168, every other type 72), an integer
0..`Board::MAX_HIDE_HOURS` (0 = never folded), always present in `to_h`, `rules.hide_after_hours` ({key => hours}) and
`Api#board`'s `columns[].hide_after_hours`; edited per column in `BoardEditor` ("Fold after (h)"). The Board's default
order is "Last modified" (`updated` desc), drawn in day groups (Today / Yesterday / a date); a filter shows folded
matches too.

**Green CI** (`requires_green_ci`, a GATE column's own setting — was the host config's
`approval.requires_green_ci`): `true` = the approval step leaving this gate (`Board#approvals`, `from` = the gate) asks
the host's `ci:` port before it approves, and a `kanban_handoff` into the gate asks it before anything is written (both
below, host config `approval` row → "the green-CI gate"); the prefetch, the gate hold, the gate watch and the Force
button exist only for such a gate. Optional on input, **absent = `false` = CI is never asked there** (the default: a
board asks CI only where its workflow says so); `true` on a column of any other type is refused; `to_h` carries it only
when `true`; `rules.green_ci` = the gated columns; stored in `board_columns.requires_green_ci` (Schema v16, 0/1);
edited per gate in `BoardEditor` ("Requires green CI"; the gate's card then says "waits for you · CI"). A Store with no
`ci:` port answering `approval_checks` refuses to save a board that sets it (`Store#board_save`), and raises
`ConfigError` if a stored one asks it. How to set one up: README § Use case: a gate that waits for green CI.

**Column types** (`ColumnTypes`): what a column DOES. Changing a column's type changes its rules.

| type | flags | the rules it carries |
|---|---|---|
| `parked` | — | nobody listens; agents may create here; a gone owner is released in place; `dependencies.promote.from` (Backlog, Waiting) |
| `queued` | listened · one per board | released work cards return here (`gates.watchdog.to`); `dependencies.promote.to`; the lead's ownerless work, each card started by the lead's `kanban_spawn` (To do, Queued) |
| `working` | listened | a work column — several per board (In progress, Author response); the FIRST one is `gates.watchdog.from` and `idle_column`; a released card in any other working column stays |
| `review` | listened | a further work column, an agent's or the system's; no watchdog move; review ROUNDS are counted per LOOP column (`review_loop.columns`; Agent review) |
| `gate` | waiting · listened · operator-only | the card waits for the OPERATOR: agents enter only with `kanban_handoff` (the host's `handoff` requirements); the gate's ONE forward operator exit is an approval step (`gates.approvals`); an agent leaves only along a named agent transition, once approved (Human review, Local deploy check, Awaiting merge, Human Check, Ready to merge) |
| `done` | operator-only · agents cannot create · finishes · terminal · one | `dependencies.done`; agents enter only from a gate, approved (a board without a gate: anyone may finish a card) and never leave; keeps owner / assignee as history (Done, Merged) |
| `cancelled` | operator-only · agents cannot create · terminal · one | stopped: only the operator moves a card in or out; finishes nothing (a child of a cancelled parent still waits); keeps owner / assignee as history (Cancelled) |

**Flags on a card, not types** (SPEC § 4): `needs_operator` (`kanban_ask`, a dialog on the owner's screen; the
operator's comment clears it) and `blocked_external` (`kanban_block(reason, url)` / `kanban_unblock`; the operator's
comment clears it too). A flagged card keeps its column and refuses agent moves; a `needs_operator` card counts as
waiting for the operator wherever it sits, a card only `blocked_external` waits for the world (another card, CI, a third
party) and is never counted as waiting for the operator — not even in a gate (`external`); a move into a terminal column
(Done, Cancelled) clears both.

**On hold, the operator's** (v15; `Store#hold`): the operator parks a card where it sits — it keeps its column
and leaves the flow: the board's normal view, every count and waiting list, every watch, and every agent's sight (§ 4).

**Actors** are not a column field: who acts in a column follows from its type and its transitions' `by` — a gate is
the operator's (only the operator's step leaves it), a review / working column belongs to whoever holds the named
agent edges out of it (the host's prompts name the Reviewer Agent for an agent-review column, the Author Agent for an
author-response column), parked is the operator's, queued the lead's (it starts a worker per card with `kanban_spawn`). Local v3: Backlog —
operator · To do — Team Lead · In progress, Local / Public: Author response — Author Agent · Local / Public: Agent
review — Reviewer Agent · Local: Merged — the Author Agent's merge + deploy (system) · Local / Public: Human review,
Local: Deploy check, Awaiting merge — operator.

**Derived** (`Board#rules`, the one derivation; the client gets the same JSON): `default_column` = the FIRST column;
`waiting` / `listened` / `operator_only` / `agent_no_create` / `terminal` = the columns whose type carries the flag;
`gates.handoff` = the gate columns (`columns`) + the host's parameters; `gates.approvals` = the approval STEPS, each
`{from, to, then, name, final}`: for every gate, its ONE named `by: operator` transition FORWARD (into a non-terminal
column later in board order — two or more forward exits are a choice of route, a backward exit (Changes requested,
Rework) or Cancel is never an approval: no step); `then` = the ONE named transition agents may take out of `to` that
is not into a working column (else null); `final` = `then` is the done column (the agent merges and finishes). Local
v4: Local: Human review → Local: Merged (then Local: Deploy check), Local: Deploy check → Public: Create PR ("Open
public PR"; then Public: Agent review), Public: Human review → Awaiting merge (then Done, final); coding board: Human Check → Ready to merge (then Merged, final).
`gates.watchdog` = the first working column → the queued column; `dependencies` (only when the host enforces them) =
done / blocked (queued + working + review) / promote (parked → queued); `idle_column` = the first working column;
`review_columns`; the watchdog's watched columns = the listened ones. (No spawn columns since lead-first boards: the
engine starts no session on its own.)

**Validation** (`Invalid` with the reason; an operator's save refused; a stored board the host no longer fits raises
on READ naming the project — never a stand-in): ≥ 1 column; keys `[a-z][a-z0-9_]{0,39}` unique; labels non-empty; a known
type each (a v2 type — `asks_operator`, `handoff`, `approved` — is named with the pointer to `BoardRepo#migrate_v3!`);
no graph position (an `x` / `y` is an unknown key, refused — the editor lays the graph out every time); at most one column of each singleton type (queued, done, cancelled); a gate column needs
the host's `handoff` (not null); two gates approving into one column refused; **exactly one done column** on every
board (what "finished" means: a card there finishes a parent, a session whose cards all sit there is finished —
`Store#owned_cards`); the transitions as `Workflow` validates them (below).

**Workflow** (`Workflow`): `{name, from, to, by}` — `from` a column key, a list or `"*"`; `to` a key or `"*"` (a fan-out,
named together with its column); `by` operator | agent | any. Refused: unknown column / actor, duplicate edge, one name →
two targets from one column (case-insensitive like the lookup), > 200. Every move (web, MCP, handoff, ask, approve) needs
an edge for the actor (`Store#move_check!`: agent gates → workflow → parent dependency; ask / handoff run it BEFORE
writing, so a refusal leaves nothing behind); `move(transition: "Start work")` resolves a name. The engine's own moves
bypass the graph (watchdog release, answer-by-comment, dialog question / expiry, dependency promotion). A card JSON
carries `transitions: [{name, to, to_label, by}]` out of its column.

**Repository** (`BoardRepo.new(db, tables:, host:, known:)`): `fetch(slug)` = the project's rows, else — only for a
slug the host's `known` port confirms is a project (never a ghost row) — the TEMPLATE (slug `""`) instantiated as the
project's own rows (an INSERT of the `boards` row: two processes racing on a first read both end up with the winner's
rows; recorded as the system author's copy; no template → `Invalid`); `save` validates the whole board,
refuses to drop a column that still holds cards (live or archived — a card references its key) naming them, then
replaces the rows in one transaction; `reset` = the template again (same refusal); `seed!(template:, projects:, by:)` =
**the migration**: the template row, a board for every
project without one — the template's columns + the project's legacy `workflows` row (the first workflow version) when
there is one, else the template's transitions — then the legacy table dropped; `migrate_v3!(cards_t:, activity_t:,
by:, reshape:)` = **the workflow v3 migration** (every stored board, the template too: the ask column removed and its
cards returned to the column of their last move into it, flagged; handoff / approved → gate; stale questions cleared;
`reshape` {slug => {board, cards: {old key => new key}}} replaces a board's shape and moves its cards; one transaction,
`Invalid` names any card or board it cannot place). `Store#board_json(slug)` →
`{columns, transitions, rules, types, updated_by, updated}`.

### 2b. The host config — `HostConfig` (all keys required; `idle_watch` / `handoff` / `approval` / `owner_sessions` / `review_loop` / `session_boards` may be null)

| key | the rule it drives |
|---|---|
| `priorities`, `label_colors` | the enums (`gray` required) |
| `system_author` | signs engine entries (`watchdog`, `ping`, dialog `question`, the template's copies), prefixes pings `[name]` |
| `attachment_url_prefix` | `<prefix>/<id>` (view) and `<prefix>/<id>/download` in JSON, snippets, rendered markdown and the comment→attachment claim |
| `launchers` `[{key,label,kind,command,args,via_shell}]` | the COMMANDS: `Launch.argv(config, type:, launcher:, prompt:)` is built by the launcher's `kind` (`Launch::KINDS`, one class per CLI family): `claude_code` = `[command, *args, ("--model", model), *extra, prompt, "--remote-control", session]`; `hermes` = `[command, *args, ("-m", model), *extra, ("-q", prompt)]` (no remote control); wrapped in `bash -ic` when `via_shell`. `args` / `extra` may set no option the kind sets itself (claude_code: `--model`, `--remote-control`; hermes: `-m`/`--model`, `-q`/`--query`/`--query-file`); claude_code's appended pair is LAST and wins (Claude Code takes a repeated option's last value — measured on 2.1.317). `Launch.plan` carries `kind` + `remote_control` (what the host checks came up) |
| `agent_types` `[{key,label,launchers,model,prompt,agent_name,session_name,takes,max,max_per_project,under?}]` | WHAT a session is (the library ships none). `launchers`: the keys it may run (no default: a start names one — the UI's menu, `Api#launch`'s `launcher`, `kanban_register`'s `launcher` — or the type has only one; several and none named → `Invalid` with the keys: nothing picks one); `model`: `--model` value or null, or a map launcher key → value / null naming every launcher of the type (`AgentType#model_for`: a gateway launcher picks its own model); `prompt`: template typed after the start or null, placeholders `{slug} {dir} {session} {agent} {type} {cards}`; `agent_name`: the author name the session acts as, must contain `{session}` (`Store#session_for_author` resolves it back); `session_name`: the tmux name (must contain `{slug}`); `takes`: column TYPES whose ownerless cards the session ADOPTS at registration and from then on (the intake rule, `Store#adopt_ownerless`, on every board's columns of those types; fewest owned cards wins; the new owner is pinged) — on a lead-first host the lead takes the work types too, so an ownerless card is the lead's (one `assigned` ping) and it decides who works it; `under` (optional; LEAD-FIRST BOARDS): the lead type a session of this type runs under — such a session exists ONLY while the board's lead RUNS: started by the operator's `Api#launch` or by the lead's `kanban_spawn`, or registered by hand (`kanban_register`) while a lead the host started runs — the host vouches for it, the agent passes no key; it runs the lead's launcher (`Store#launcher_for!`: another one asked for → `Denied` 422, never swapped) and its registration carries `lead_id` = the lead's (Schema v12's `CHECK (needs_lead = 0 OR lead_id IS NOT NULL)` refuses the row without one); no lead running → `Denied` "launch the lead first", from the operator too. The lead type must have `max_per_project: 1`, list no launcher the type lacks, and be under none and not standalone (one level). `standalone` (optional, bool): a PLAIN session that runs without a lead — `prompt: null` and `takes: []` required. EVERY type is a lead (some type is `under` it), `under` one, or `standalone` — anything else is a `ConfigError` (no type runs leaderless by omission: a revision that drops `under` is refused when saved, when loaded and by the host's launcher). `spawns_for` / `spawn_launcher` / `launcher_follows` are REMOVED (`ConfigError` naming what replaced them): the engine starts nothing on its own; `max` / `max_per_project`: caps (null / 0 = none) |
| `concurrency` `{max_sessions}` | registered agent sessions running at once on the host: `Store#launch_check!` refuses the (N+1)th with who runs; `Store#concurrency` is the UI's `running / cap` |
| `owner_sessions` | `null` or session-name globs: `Store#set_owner` / `#claim` refuse a session that matches none; the React owner picker lists only matching sessions |
| `progress_watch` | `{stale_minutes}` (the key required; `null` = off, else an integer ≥ 1): the progress watch (§ 4 Progress watch, `Store#progress_watch_pass`) |
| `idle_watch` | `null` or `{ci_ping_after_minutes (N), ci_comment_after_minutes (M), owner_idle_hours (X)}` on every board's WORKING column (`Store#idle_watch_pass`, needs the host's `ci:` port): PR checks all finished and no non-system activity for N min → ONE owner ping per CI completion, M min later still silent → ONE comment by `system_author`; a live owner with no activity and no commit for X h → ONE comment per idle stretch |
| `handoff` | `null` or `{requires_pr_url, requires_ci_url, qa_min_chars, ui_change_needs_screenshots}`: what `Store#handoff` requires on a board with a gate column (`qa` ≥ `qa_min_chars`, http(s) URLs required per flag, ≥ 1 picture attached when `ui_change` and the flag). A gate column on a host with `null` is refused on read |
| (`approval`) | **removed** (the key is refused, naming the move): whether a step asks CI is its gate column's `requires_green_ci` (§ 2). **The green-CI gate**: at a gate with `requires_green_ci`, every explicit approval (`Store#approve` = the Approve button, or `Store#move` with the step's own transition name) asks the host's `ci:` port (`Store.new(ci:)`, `approval_checks(card, step)` → the `pr_checks` answer for the PR that step is about; `step` = `{from, to, then, name, final}`) and is refused (`Invalid`, nothing moved or logged) unless `state` is `success` (an answer's `reason:` = the host's own refusal, e.g. a prerequisite PR not merged, said instead of the CI wording): no PR, `pending`, `failure`, `stuck` (the host's word for a check pending longer than it allows: red like `failure` — the gate watch pings the owner once per `finished_at`, the moment it became stuck), not read yet, no checks, or the port raising `Delivery::Unavailable` → the refusal names the step, the PR and what it saw. A board that sets it is refused on save by a Store without that port. **Prefetch** (Approve never waits for a CI read): the same question is asked, its answer discarded, for a card handed off into a gate an approval step leaves from (`Store#handoff`: see **Handoff on green CI**) and, on every `Notifier#watch` pass, for every unarchived card the operator can Approve — sitting in such a gate, or UNAPPROVED in a gate an approval step leads into (`Store#approve` approves it in place; card #511: such a card was never asked) (`Store#approval_pending`, the list `Store#approval_pending_cards` → `[[card, step]]` for a host's freshness guard; `Store#approval_prefetch_pass` → `[[id, state \| "no PR" \| "unavailable: <why>" \| "failed: <error>" \| "skipped: <why>"]]`; an unavailable or failed one (the port raised: the pass goes on to the next card) is logged once per change of reason and once when it answers again, the others still asked; every other gate card (approved, or a gate with no step) is listed `skipped` and logged once per change of why — nothing in a gate is silent) — a host that answers asynchronously (a poller answering recent requests) keeps every gated card's answer fresh; a card that left the gate is no longer asked; the same pass is the gate watch (§ 9, Schema v10: approvable now). **Handoff on green CI**: a `kanban_handoff` into a gate an approval step leaves from asks the same question BEFORE anything is written, for the card as it will sit there (the gate's column, the handoff's `pr_url`, and `handoff_ci_url` = its `ci_url` — a key only a handoff carries: a host may refuse a `ci_url` that is not the build of the head handed over, while an Approve or a watch pass asks only about the head's CI, so a rebuild never parks a card), and is refused (`Invalid`, nothing written) unless `state` is `success`: `not handed off (→ <gate>): <PR> of card #N — <state>; hand off once CI is green` (unread → "CI not read yet (asked now — hand off again in a minute)", the port unavailable → "CI state … is unknown"). So a card in such a gate is green when it arrives, and the operator's Approve answers at once. **Needs rebase** (card 497): a green answer may carry `rebase: {state, base, base_sha}` — the PR's checks are green and nothing else refuses it, but it conflicts with its base (the host's word in `state`, e.g. `conflicts`; a rebase: missing any of the three strings is the port's error → refused). An explicit approval is then ACCEPTED: the card moves along the step (or is approved in place), a `ci_watches` row kind `rebase` records the mark (gate activity "needs rebase: PR #N conflicts with <base> (<sha7>) — approved; …"), card JSON gains `needs_rebase` = `{pr, state, base, base_sha, at}` (null = none), and the ONE approve ping says "approved: rebase onto <base> (<sha7>), re-run CI, then merge" — merge the base in, resolve keeping both sides, run the gates and a reviewer on the resolution, merge only once CI is green on the new head; a conflict it cannot resolve is a `kanban_ask` naming the files. While marked, any agent move out of the column but back to a working column (the next handoff, the move to done) asks the step's checks live and is refused (`Denied`, with what holds it: the conflict, CI pending / red / unknown) until they are green with no `rebase:` — then the mark clears ("needs rebase cleared: CI green at <head7> …") and the move goes on; every `Notifier#watch` pass asks each marked card the same (`Store#rebase_watch_pass` → `[[id, :cleared \| "held: <why>"]]`, logged once per change); a clear by the watch pass sends the owner ONE ping (reason `rebase_cleared`: "needs rebase cleared on PR #N …: CI green on <head7> — merge now, then …"), none while it holds, none when the agent's own move cleared it. The hold runs after every other move rule — the agent rules, the workflow, the blocks (a move refused anyway asks no CI and clears no mark); the mark's `ref` (the card's nth) is allocated in a savepoint and retried on a unique-key collision. Any move out of the column ends the mark. Every other refusal (draft, base, auto-merge, computing, red / pending / unread CI) is unchanged; a drag or a Force (CI not asked) marks nothing; a HANDOFF of a conflicting PR is still refused (`… — PR #N conflicts with <base> (<sha7>): rebase it and re-run CI; hand off once CI is green`): only the approval moves conflicts after it. A host answers a marked card (it carries `needs_rebase`) whose step PR has since merged with that merge's CI, so a card merged before a watch pass cleared its mark is not held for good |
| `dependencies` | `true` = parent dependencies are ENFORCED on every board (`Board#rules.dependencies`); `false` = parents are recorded and shown only |
| `flags` | `{reminder_hours}`: a card flagged `needs_operator` / `blocked_external` that long gets ONE reminder comment by `system_author` (+ a ping to its owner) per flag (`Store#flag_reminders`, the notifier's watch pass) |
| `review_loop` | `null` or `{max_rounds, unresolved_label, unresolved_color, columns}`: `columns` = the LOOP columns (review column keys; any other review column — a coding board's QA — counts no rounds and has no limit). Entering a loop column from a work column or a gate counts a ROUND for it (`cards.review_rounds`; entering a work column by any move other than a named agent edge of the REVIEW column left — Rework out of a review column or a gate, Deploy failed, Start work (also after the operator parked a card at the limit in To do / Backlog) — starts over); at `max_rounds` an agent's loop move (loop → work, work → loop) is `Denied` naming the gate to hand the card to, and a handoff out of the loop column must give `review_summary` — the reviewer's SUMMARY counts `{fixed, resolved_by_argument, needs_human, open}`, integers ≥ 0, exactly those keys (missing or malformed → `Invalid`): it puts `unresolved_label` on the card (created on the board with `unresolved_color` when missing) only when `needs_human + open` is above 0, and the handoff line names the counts. The operator's move from a gate into the work column a loop column feeds by a named agent edge (Changes requested) allows exactly ONE more round of that loop (`review_rounds._rereview`), then the card goes back to the gate without the label; so does the operator's drag from the loop column itself into that work column once the rounds are used up (no gate is reachable from the work column: the limit would leave the author no move) — below the limit that drag changes nothing. The "0 open threads" exit is the agents' rule (the host's prompts): the engine counts rounds, it reads no review threads. `null` = every review column counts rounds, nothing limited |
| `session_boards` | `null` or `{slug_prefix, idle_hours, board}`: a board of ONE agent session, attached to no project. `slug_prefix` `[a-z][a-z0-9_-]*:` (e.g. `session:`); the board's slug = prefix + the tmux session name (`Store::SESSION`); a host project slug starting with the prefix is shadowed. `board` = its shape `{columns, transitions}`, validated as a Board when the Store starts (`ConfigError`; a gate column refused: nobody but its session acts on it). MCP `kanban_session_board(tmux_session, author)` (listed only when configured; the session must be live) → `Store#session_board!` creates it from `board` on the first call (never from the project template: `BoardRepo`'s `known` refuses a session slug), brings an archived one back (its cards stay archived) or touches it → the `kanban_board` JSON + `session`, `state` (`created` \| `restored` \| `touched`). Every tool touching a session board through ANY field (`project`, `id`, `parent`, `comment_id`, `checklist_id`, `item_id`, `attachment_id` — each record read by its own id) is `Denied` unless the caller IS the session: `tmux_session` = it, verified live (the `sessions` port), else `author` = the agent name (or session name) of its OPEN registration — a bare author string names nobody. Both given and `author` is the agent of ANOTHER open registration → `Denied` (one call names one caller); `kanban_session_board` opens only the caller's own board by the same rule. Identity stays what every kanban tool trusts (one MCP bearer): this keeps sessions apart, it is no defence against a hostile agent. `kanban_register` / `kanban_pr_assign` / `kanban_pr_unassign` / `kanban_ask` / `kanban_block` / `kanban_unblock` on one → `Invalid` (nobody but its session acts there); the operator's `Api` is READ-ONLY on its records (`Api::SESSION_READ_ONLY`: every card / comment / checklist / item / attachment / label mutation → 422); its shape is not saved / reset (`Invalid`). The watchdog, the intake, the idle watch, a failed launch's release and the dialog question's card choice skip session boards (`Store#project_cards`): their cards stay their session's. Activity = the `boards` row's `updated_at` (created / restored / opened) and any activity entry on its cards NOT by `system_author` (pings, reminders, archive lines are the engine's, not the session's); flag reminders skip session cards; the pass re-reads the activity inside its transaction (a touch in between keeps the board); `idle_hours` without any → `Store#session_boards_expire_pass` (the notifier's watch pass) archives every live card (an `archive` entry by `system_author`) and sets `boards.archived_at` — nothing is deleted; a card tool on it then says it was archived and how to open it again. Operator: `Api#session_boards(archived:)` → `{idle_hours, slug_prefix, session_boards: [{slug, session, archived, last_activity, expires, columns, cards}]}` (404 when off); React `SessionBoards` draws it read-only (`focus: {session, card}` marks a board and a card and scrolls the card into view: a session card's link) |
| `table_prefix` | `""` or `[a-z][a-z0-9_]*_`; the engine's tables are `<prefix>cards` … |
| `theme` | `{"--ak-*": value}` (an allowlist of CSS value characters, quotes paired, parentheses balanced, no `/*`; refused at load) applied as inline custom properties on the board's `.ak-root` and copied onto every Select menu from its trigger; `--ak-board-height` fixes the board's height; `--ak-step-overhang` (default 12px) = how far the left / right step buttons hang outside the lists, `0px` for a host with no gutter beside the board |

`HostConfig#digest` = sha256 of the canonical JSON the client receives (`to_h`); a host may pin it.

## 3. Tables (`Schema`, v16)

`cards` (+ `parent_id`, `metadata` JSON text since v2), `card_activity`, `board_labels`, `checklists`,
`checklist_items`, `card_pings`, `card_attachments`, `session_dialogs`, `agent_sessions` (v3: `session`, `socket`,
`project_slug`, `type_key`, `launcher_key`, `agent_name`, `launched_by`, `launched_at`, `last_seen_at`, `ended_at`,
`end_reason`), `ci_watches` (v4), `boards` / `board_columns` / `board_transitions` (v6, § 2a; `project_slug ""` = the
template; v7 adds `board_columns.hide_after_hours`, null = the type's default; v8 adds the card FLAGS — `blocked_at`,
`blocked_author`, `blocked_reason`, `blocked_url`, `flag_reminded_at` (`needs_operator` is `asked_at`) — and
`review_rounds` (JSON `{review column => entries}`); v9 drops `board_columns.x` / `y` (the editor lays the graph out,
nothing about it is stored); v10 adds `cards.gate_head` (the approval PR's head the handoff's green answer carried) and
`cards.gate_state` (the last watch pass's view of the card's gate: `ready` or its hold); v11 adds `boards.archived_at` (a session board hidden after `session_boards.idle_hours` idle, § 2b); v12 adds
`agent_sessions.lead_id` (the lead registration a session runs under), `needs_lead` (0/1: its type is `under` a lead),
`lead_key_digest` (a lead's key, SHA-256 hex) and the CHECK `needs_lead = 0 OR lead_id IS NOT NULL`; v13 adds the progress watch's stretch on the card — `cards.progress_at`, `progress_marks` (JSON `{kind => {key, text, at}}`), `progress_pinged_at`, `progress_commented_at`, `progress_stale_at`, `progress_error`; v14 is a data step (no DDL): `cards.metadata.prs` becomes a list (§ 9 v14); v15 adds `cards.on_hold_at` /
`on_hold_by` (§ 9 v15); v16 adds `board_columns.requires_green_ci` (0/1, null = 0: a gate asks CI only where its board says so, § 2 Green CI — no data step, every gate starts at 0); v5's `workflows` is carried over and dropped by `BoardRepo#seed!`) — epochs as integers. `migrate!(db, prefix:,
to: VERSION)`: a host migration is PINNED to the step it introduced (`to: 5` still creates `workflows`, `to: 6` the
boards tables), so a fresh DB replays the host's migrations step by step and a rollback lands on that version's shape, JSON as text, done flags 0/1, portable DDL (`text: true` where > 255 chars may occur). `migrate!` is idempotent by introspection; the
host's own ledger records each run. Prefix `""` = the unprefixed table names (a host whose tables already carry them needs no data move).

## 4. Store rules that are NOT config

- Limits: title 200, labels 12 × 40, assignee 80, item 1000, question 8000, options ≤ 8 × 200, metadata 8000 JSON chars.
- A comment's `*_html` is the markdown port's output; agents (Tools) get markdown only (`*_html` stripped).
- The shipped markdown renders a body whose FIRST line is the review loop's header (`[<Role> Agent] · STATUS · round n ·
  key: value …`, then ` — note`) as a badge strip `div.ak-chead` (`data-role`; `.ak-chead-status` `data-tone` ok / bad / warn /
  human / info; `.ak-chead-tag` `data-key`, `data-severity` blocker / major / minor / nit; `.ak-chead-note`), escaped; the
  stored markdown is unchanged. `CardLinks.linkify` shows a GitHub PR / issue / commit URL written out as its own link text
  as a chip on that same URL (`repo#61`, `repo@abc1234`); a link with its own text stays as written.
- Card mentions: a `card` chip carries `data-card-id="<id>"`; `CardLinks.card_mention_parts(text, refs)` splits a PLAIN
  text (a question's option) at the cards it names by the same rule (`[{text}, {text, card}]`, joined = the text), sent by
  the host as the card's `question_option_parts`. The React `CardPeek` (mounted once by the host with its card read,
  listening on the document) opens a panel with that card's title, column, flags, labels, who, the start of its
  description for anything carrying `data-card-id` — the chips, the option buttons, the dialog's dependency line, and
  whatever the host marks; one read per card per ttl, a failed read shown as its reason.
- A card face (`decorate`d card JSON) carries `media` = its newest live picture attachment `{id, filename, url}` (an
  inline image type; newest by created, then id; none → null); the React face shows it under the cover so a card is
  found by its picture.
- Attachment JSON carries `image` (png / jpeg / gif / webp: an `<img>`) and `video` (`AttachmentPolicy::INLINE_VIDEOS`:
  mp4 / webm, recognised by their bytes — WebM = an EBML header with DocType `webm`, Matroska is refused): both are
  served inline (`Api#attachment_file` `inline`, `AttachmentPolicy::INLINE`); every other type only downloads. The
  React dialog shows a video as a thumbnail (its first frame, `preload="metadata"`) with a play button; a click — or a
  click on its file chip in rendered markdown — plays it in the lightbox with the browser's controls. The host's page
  CSP must allow `media-src` its own origin, and the host should answer `Range` requests so the player can seek.
- A comment claims the author's own unlinked attachments it references; deleting the comment unlinks, never deletes.
- Pings: one pending per card + session (a burst coalesces into the newest row nothing may have been typed from: any other may sit in the session's input, recognised by its exact text, so its text never changes; past `MAX_PING_TEXT` it opens the next pending row, no event is cut). **Delivery** (`Store#next_pings`): per session ONE attempt per pass; the order is (a) a row something may already have been typed from, (b) the operator's own rows (`answer`, `approve`, the operator's comment, `move`, `relay`), (c) lead events, (d) the rest, oldest first within each; the later rows wait for it, the give-up (counted from when the row could first be tried) releases the next, and a waiting row's `ping_json` carries `queued_behind: N` (the owner panel: "queued behind N earlier pings"). The `notify` port's answer may carry `typed: false` = nothing reached the session's input; absent or anything else, and a call that raised `Delivery::Unavailable`, counts as typed; never to the owner's own author; `relay` when a card
  gains an owner (the operator's undelivered comments since the last agent comment).
- **The running lead hears about its workers** (`Store::LEAD_PINGS`): one ping to the OPEN lead registration
  (`lead_id` of the owner's registration) when a card's worker asks (`lead_ask`), hands off (`lead_handoff`), blocks
  (`lead_block`), when its session ends holding open cards (`lead_session_end`: one ping on the first, naming all, for
  `kanban_spawn` only those a worker can act on, the rest as waiting for the operator; a session holding none is not told), and on the progress watch's first step (`lead_progress`). Never on a comment; none
  when the lead is the actor, the card is on hold or no lead runs. A row of its own for the lead's session: it does not
  wait for the worker's turn, `next_pings` serves sessions holding a lead ping first, and the watchdog's release fails only the gone
  session's pending pings.
- Session dialogs: one `question` per (session, hash); an answered one is not re-posted within 120 s; a key is pressed
  only through the host's `press` and only while the hash still matches (the launcher re-reads the screen). The hash leaves out Claude Code's
  ticking "will automatically block this request in M:SS" countdown — it is not the dialog.
  A dialog is asked only once it has stayed on the screen `session_dialogs.settle_seconds` (the Notifier's first read
  → a read that much later, same hash); never on a card in an operator-only column (the pending ping's card, else the
  session's newest card outside them; none → nothing is asked); it FLAGS the card `needs_operator` where it sits (no
  move); the question quotes the owner's latest agent comment on that card within `session_dialogs.context_minutes`,
  or says the agent gave no reason. While any dialog is on the screen a ping waits — asked or not, it is never typed
  into the dialog. A pressed key (`answer_dialog`) or an expired dialog clears the flag; the card stays.
- Approval steps (`gates.approvals`): the operator's move of a card from a step's `from` (a gate) into its `to`
  (`Store#approve` = that move; a drag along any edge does the same) sets `approved_at` / `approved_by`, logs an
  `approve` entry and pings the owner (`approve` reason: a final step's "Merge it now…", another's "it moved A → B. Do
  the next step now, then move the card to `then`…"); an ownerless card is the lead's (its `takes`). The operator's drag
  (a column, or the catch-all edge) is never refused by the green-CI gate (`requires_green_ci`): it approves, and the `approve`
  entry ends "(dragged: CI not asked)"; an Approve the gate refuses ends ". A drag into <to> approves without asking
  CI". **Force** (`Store#approve(force: true)`, `Api#approve` body `force: true`, the operator's only — no MCP tool;
  `Store#move(force:, agent: true)` → `Denied`): the same approval, move (or in-place approval) and ping without the
  green-CI gate (no CI or PR-state question); every other refusal stays; the `approve` entry ends "(forced: CI not
  asked)" and the owner's ping says it was approved with Force and CI was not asked — read the PR's checks first, and
  take the next step (a final step: the merge) only once they are green (a drag along the step pings the same).
  `force: true` with `approved: false`, not a boolean, or at a gate without `requires_green_ci` (its Approve
  asks no CI) → 422. A move into `to`
  from anywhere else approves nothing — when `to` is itself a GATE (Awaiting merge, Ready to merge: agents never leave
  one unapproved) `Store#approve` approves the card IN PLACE: the step's CI question, `approved_at` / `approved_by`, the
  `approve` entry ending "(approved in <to>)", the same ping, no move (an approved card there: `Invalid` "already
  approved"); in a `to` that is no gate nothing holds an agent, so there is nothing to approve. `Store#unapprove`
  moves a card in a step's `to` back to its gate while it is still approved — the operator's undo: it needs no workflow
  edge back, the move entry ends "(approval withdrawn)"; not in a step's `to`, or not approved → `Invalid` saying which
  (never a silent no-op). Moving an approved card anywhere but a terminal column withdraws the approval (terminal:
  history); a gate re-entered by a drag holds no `approved_at`, `gate_head` or `gate_state` of an earlier visit.
- **The operator is never stuck** (`ruby/test/operator_unstuck_test.rb`): on a board with the
  operator's catch-all edge a drag between any two columns goes through — a flagged card (`needs_operator` /
  `blocked_external` hold agents only; the operator's comment clears both), at the review round limit, with CI red.
  What still refuses an operator, each with the reason and the way out: an archived card (restore it), a move the
  board's own workflow has no operator edge for (the workflow is the operator's data: the board editor), a child
  entering a blocked column while its parent is unfinished on a host with `dependencies: true` (the refusal names a
  parent that is archived or in a terminal column that finishes nothing — "never finishes" — and ends "clear the
  card's parent to end the wait").
  An agent is refused the move `from` → `to` of every step ("that is the approval"); `kanban_*` has no approve tool.
- A gate: an agent enters only with `kanban_handoff` (the gate the card's column has a named agent transition into;
  several → `transition` / `column`; none → `Denied` naming the board's gates) and leaves only along a named (not
  catch-all) agent transition, only while `approved_at` is set; else "only the operator moves a card out of …" / "sits
  in … without the operator's approval". Agents enter a done column only that way, and never a cancelled one.
- FLAGS (`needs_operator`, `blocked_external`): `Store#ask` sets `question` / `asked_at` / `asked_by` and moves
  NOTHING (an owner session is required; a question on a terminal card is refused); the operator's comment on a card
  with an open question (and no dialog) is the ANSWER: `clear_question`, an `answer` entry, ONE `answer` ping, the
  card stays. `Store#block(reason:, url:)` sets `blocked_*` (both required, http(s) URL), `#unblock(note:)` clears; so
  does the operator's comment on a blocked card (a `flag` entry); a move into a terminal column clears both flags.
  While either flag is set an agent's move (any, handoff included) is `Denied`; the operator moves freely; the watchdog releases a flagged
  card like any other (it stays flagged). `Store#flag_reminders` (every watch pass): a card flagged for
  `flags.reminder_hours` with `flag_reminded_at` null gets ONE `comment` by `system_author` + a ping; a new ask / block
  resets the reminder. `Store#flagged_counts(slugs)` = `needs_operator` cards outside the waiting columns per project;
  `Store#needs_operator?(card)` = an open question; `Store#external?(card)` = blocked_external with no open question
  (`Store#waiting_counts` `external` = those per project — the one count `Api#board` and `#boards` both carry).
- ON HOLD (`Store#hold(id, by:, on_hold:)`, the operator's only — `Api#hold`; no MCP tool): sets `on_hold_at` /
  `on_hold_by` and releases the card's owner session + assignee (logged `hold` "put on hold in <column> — owner session
  … released"), drops its pending pings (`failed`, "card put on hold"). A held card is out of `Store#live` (the board,
  `counts`, `waiting_*`, `flagged_counts`, `owned_cards`, `adopt_ownerless`, the spawn pool, terminal events) and of every
  watch (`watch_owners`, `flag_reminders`, the idle / progress / PR / rebase watches, the approval prefetch, the session
  dialog's card): `Store#board(slug, on_hold: true)` is its only view, `on_hold_count(slug)` the toggle's count.
  `delivery` = "none: on hold"; `set_owner` refuses it ("release it first"); an agent's `move` / `claim` gets
  `no card N`. Tools answers every call that reaches a held card through any field (`id`, `parent`, `comment_id`,
  `checklist_id`, `item_id`, `attachment_id`) with `no card N` / `no comment N` / … — the words of a missing record —
  and `kanban_board` (archived too) leaves it out. The operator moves it by hand (it stays on hold); a move into a
  terminal column ends the hold with the flags. Released → `on_hold_at` null, at the bottom of its column, ownerless
  (`adopt_ownerless`: the lead takes it like any ownerless card). Refused on an archived card, a terminal column's card
  and a session board's card, and while any unarchived card (a held one too) waits for it as its parent ("finish or detach them first"); a held
  card is never a parent (`parent!`: "on hold: release it first"), never in `children` / a card's `children` count, never
  in `members` or agents-at-work presence, and `kanban_pr_assign` of a PR it holds is refused without its id ("the PR of
  another card").
- An agent never creates a card in an operator-only column (`Board#agent_closed?`: the gates, cancelled and — on a
  board with a gate — the done column): it creates, works, then `kanban_handoff`s.
- `kanban_handoff` and `kanban_ask` speak in normal comments: a handoff logs its one-line `handoff` event (PR · CI) AND a
  `comment` by the agent ("**Handed to <column>** · PR · CI" + the QA); an ask logs a `comment` ("**Question for the
  operator:**" + the question + options) and a `flag` entry — no `question` entry (that kind is the session-dialog
  relay's). The waiting list shows a handed-off card's first QA line (`handoff_first_line`), a question's first line
  (`question_first_line`), a blocker's (`blocked_first_line`).
- The board editor refuses to retype a column that holds cards into a waiting type (a gate) — the cards would wait for
  the operator unasked — like it refuses removing one.
- Watchdog: a card is released only when its owner session is GONE from a fresh snapshot for `grace` seconds; a
  stale snapshot releases nothing. Every column of their board but the terminal ones is scanned
  (`Board#owner_watched_columns`; parked included — a released parked card only loses owner + assignee); only a card in
  the FIRST working column moves (→ the queued column): a finished or cancelled card keeps its owner and assignee as
  history.
- Parent: same board, live, not self, no cycle; `blocked_by` = the unfinished parents (0 or 1 today).
- Agent sessions (`agent_sessions`): one open registration per session name (`Store#register_session`, refused twice);
  registering ADOPTS the board's ownerless live cards in the type's `takes` columns (owner = the session, assignee =
  its agent name, logged, the operator's undelivered comments relayed); `sessions_sync(live, grace:)` ends a
  registration not in a fresh live list once it is older than `grace`; running = open AND (live OR younger than
  `grace`); `launch_check!` refuses in this order: `concurrency.max_sessions`, the type's `max`, its `max_per_project`;
  the watchdog ends the registration of a session whose cards it releases; a failed start ends the registration and
  releases what it adopted (`release_session_cards`).
- A card an agent creates is owned by its session: `Store#create(owner_session:)` (Tools: `tmux_session`, or an
  `author` that is a registered agent name) — `Tools` refuse an agent `kanban_create` that resolves to no session.
  Only on the board that session is registered for: a card it creates on ANOTHER project's board is ownerless (the
  creator is `created_by` only; that project's intake and sessions take it), and `Store#claim` refuses a session
  registered for another project. An unregistered session cannot be checked.
- PR references (`PR #N`, `pull/N`) resolve against the handoff `pr_url`'s repo, else the host's `project[:remote]` —
  which the host sets to the repo the work is PUSHED to (e.g. the branch's push remote), not necessarily origin.
- **Progress watch** (`progress_watch.stale_minutes` = N; `Store#progress_watch_pass`, Notifier watch step 3e — the
  watchers beside the watchdog, the flag reminders, the idle watch and the PR watch): every unarchived project card in a
  `working` or `review` column that is not flagged. Progress = its newest activity entry of the kinds `comment`, `move`,
  `checklist`, `attachment` not by `system_author` (`Store::PROGRESS_KINDS`: an edit, an owner change, a terminal event,
  an archive / restore or a flag is not progress), or a change in the evidence of the Store's `ci:` port —
  `progress(card)` → `[{kind:, key:, text:}]` (each kind once; `key` = the state, e.g. a sha; `text` = how a human
  reads it) and `progress_kinds` → `[String]`, both or neither (else `ConfigError`); a key that differs from the stored
  one, or a kind not stored before, is progress at that pass (`progress_marks`). A kind the port stops answering is kept,
  marked `gone` (never shown as evidence): back with the same key it is no progress. The stretch only moves FORWARD
  (`progress_at` grows): a vanished mark or a deleted comment never restarts the steps. A port without them → card activity
  only; the board JSON's `progress_watch` says so (`{stale_minutes, evidence: ["card activity", …kinds], port}`, null
  = off). No progress for N min → ONE `progress` ping to the owner naming the last evidence ("last: comment #N at
  HH:MM · PR o/r#5 head abc1234 since HH:MM · …") and a `progress` entry (no owner → said there); N min after the ping
  → ONE `comment` by `system_author`; N min after the comment → `progress_stale_at`: the card waits for the operator
  (`waits_for_operator?`, the counts, `waiting_cards` with `since` = that step; card JSON / waiting card
  `progress_stale` = "no progress for M min (since HH:MM)"; a `⌛` badge on the face). Each step once per stretch;
  progress starts a new stretch (read at the next pass). A card leaving the scope forgets its stretch and marks; a card
  the port cannot answer (ANY error it raises, or a malformed list) is skipped and said (`"unavailable: <why>"`, the
  Notifier logs it once per change of reason; `cards.progress_error` = card JSON `progress_error` until it answers
  again), its stretch kept.
- **Approved gate cards**: the watch also covers a card its agent must carry on (`Store#agents_next_step?`:
  approved, owned, unflagged, in a waiting gate with an agent's named way on; a CI hold does not take it out). Its
  stretch starts no earlier than the approval. At the last step it waits for the operator and stops being `carried_on`.
- **The nudge on an approved card**, in any column an approval puts it (review, working or gate): the first ping asks the
  CI of the step that approved it (`approval_into`); red, pending or conflicting is said as a hold, a row not read yet (`unpolled`, in the port's `reason:` words when it gives one)
  or a port that cannot answer as unread ("read its checks before its next step"), never "take its next step". A step whose
  gate has no `requires_green_ci` asks nothing and says so. Each `Notifier#watch` pass asks that step for every such card
  (`Store#approved_ci_pass`, the answer discarded), so a host that polls only recent requests keeps its rows read.
- **One voice per quiet card**: on a card the progress watch covers (on, and in its scope) the idle watch never
  comments — neither its CI comment nor its idle-owner comment; its CI ping ("CI finished — hand off or fix") still
  goes. Off, or outside the scope, the idle watch comments as before.
- **Watchers never abort the watch pass**: after the watchdog, each watcher (flag reminders, session boards, idle watch,
  approval prefetch, PR watch, progress watch, dialog scan) runs on its own — one that raises is logged
  `<watcher> skipped: <class>: <message>` for that pass; the others still run and `Notifier#watch` returns the released
  cards.
- Open session-dialog questions are expired (`expire_dialogs`) when the session's screen no longer shows that dialog
  (clear, a different dialog, the session gone): closed by the system author, the card's dialog, question and flag
  cleared; the card stays where it is. An unreadable screen is not a verdict.

## 5. JSON shapes

Card: `Store#card_json` (board face) + `description`, `description_html`, `qa_html`, `question_html`, `checklists`
on a single card; `parent`, `children`, `blocked_by` (the unfinished parents), `metadata`, `transitions`,
`needs_operator` (bool), `blocked` (`{reason, url, by, at}` | null), `review_round` (the rounds in the card's current
review column | null) always. Board: `Api#board` — `columns:
[{column,label,type,operator_only,cards}]`, `labels`, `config` (the host config), `board` (§ 2a: `{columns, transitions,
rules, types, updated_by, updated}`), `agents` (`Store#agent_types`: agent name → the type key it registered as on this project, the newest registration winning; also on the card body — a name no session registered under is absent, its face drawn with no type colour), `archived?`, `backlog_md`, `columns_order`, `waiting_columns`, `listened_columns`,
`priorities`, `label_colors`, `waiting` (the waiting columns' cards + the `needs_operator` cards elsewhere; never a held
or an `external` one), `held`, `external` (cards only blocked_external, any column), `flagged` + the
host's `board_extras`; 422 `{error}` when the stored board no longer fits the host.
`Api#boards` → `{columns, columns_order, waiting_columns (the template's), waiting, held, external, boards: [{project,
columns, columns_order, waiting_columns, counts, total, waiting, held, external, flagged, backlog_md}]}`; `Api#waiting` → `{waiting_columns,
total, projects: [{slug, count, waiting_columns, cards: [{id, title, column, column_label, since, needs_operator,
blocked, question_first_line, blocked_first_line, handoff_first_line}]}]}` (flagged cards first — in any column —
then each board's waiting columns; projects with a question first), `held` (the gate cards waiting for CI),
`external` (the cards only blocked_external, oldest block first; `Store#waiting_cards` `external`), both `[{slug, count,
cards}]` and never in `total`, and
`launch_failures: [{id, session, project, type, launcher, launched_by, ended, reason}]` = `Store#launch_failures`: the
registrations on those projects whose start failed (end_reason `start failed: …` — a launch or a lead's spawn whose claude
never came up) in the last `LAUNCH_FAILURE_WINDOW_S` (a day), the newest `LAUNCH_FAILURES_SHOWN` (10), newest first — a new one
changes the rev; and `lead_ends: [{id, session, project, type, launcher, ended, reason}]` = `Store#lead_ends`: the boards
whose LEAD ended on its own (end_reason `Store::GONE`, "gone from the host's session list": killed, crashed, closed —
never the operator's stop) in the same window with no registration of that type since (lead-first boards:
nothing relaunches it, the operator presses Launch); the React `LaunchFailureAlert` (its `leadEnds`) opens a modal `<dialog>` (top layer) for the ids the viewer has not dismissed (a per-viewer id set in localStorage), with the host's `--ak-*` tokens resolved on `<html>`. Board shape: `Api#board_shape` / `#board_shape_save {columns,
transitions}` / `#board_shape_reset` → `Store#board_json`. Single card:
`{card (attachments = list), activity, pings}` + `card_extras`. Launches: `Api#launches(slug)` → `{types: [{key, label,
launchers: [{key,label,model}], model, takes, max, max_per_project, prompt, running, running_here, under, follows: {type,session,launcher} | null}], concurrency: {max_sessions,
running, free, sessions, types} | null, sessions_error}` (`follows` = the running lead a type `under` one runs under; null
with `under` set = no lead runs: the bar greys it); `Api#launch(slug, {type, launcher?}, by:)` → `Team#start` → 201
`{session, type, launcher, agent, lead (the lead session it runs under | null), adopted: [card], result (the host's),
concurrency}` · 422 refused (the cap, an unknown type) · 503 the
port unreachable; `Api#sessions` → `{concurrency, registered, ended, sessions_error}`. Every refusal: `{error}` with 404 / 413 / 422 / 503.

## 6. React

`<Board api me slug view onView onChanged? navigate? projectHref? cardHref? dictation? cardTerminals? summary? className? />` renders the board (its
columns from `board.columns`, never a constant) and the card dialog inside `.ak-root` with `config.theme` inline; the
Workflow button opens `BoardEditor`: an SVG graph (`lib/graph.ts`) of the columns as typed nodes and the transitions
as labelled arrows, **laid out by dagre** (`@dagrejs/dagre`, the React port's one runtime dependency, MIT): **top to
bottom** along the board order (every edge is oriented along it; an arrow against it is drawn back up, dashed; columns
reached from one column and not from each other sit side by side in one rank — a branch; a column nothing comes down
into hangs under the one before it), each node a card (its type's icon in a tinted tile, its full label — wrapped at words
onto as many lines of `MAX_LINE` characters as it needs, never cut —, the type line in mono, a status pill from its type's rules: "waits for you" for a
waiting column, "✓ done" for one that finishes, "✕ closed" for another terminal one — `typeBadge`), on a dotted
canvas. Every route is **orthogonal** (`Route.back` marks one against the board order): it leaves its source on the top
or bottom side facing it and ends on its target's (ends on one side spread apart), runs vertically, and turns only in
the gaps between ranks, each horizontal run on a track of its own (a gap too crowded for its tracks lays the graph out
again, the ranks apart by what it lacked; still crowded after the retries → `Layout.warnings` names the gap and
the editor shows it — never a silently degraded drawing; a column type the editor has no icon for shows
"unknown type: <key>" on its card), so no two transitions run along one line; every edge label is a mono pill on its route's
vertical run, a box of its own in the layering so it never sits on a node or another label. Hubs: a transition with
one or two sources is one labelled arrow per source; `BUNDLE_FROM` (3) or more sources, up to half the columns, join a
junction pill carrying the one label with a single arrow into the target; more than half the columns ("Cancel from
every state") is a note on the target node, no lines; `"*"` ones are listed, not drawn. **The layout is automatic and
nothing about the drawing is stored** (schema v9 dropped `board_columns.x` / `y`): every open lays the graph out again.
The graph is as wide as its widest rank and runs down: the default view is its whole width at a zoom (≤ 1) never below
`MIN_TEXT_ZOOM` = 11 px ÷ the smallest graph font, i.e. no text under 11 px; the box scrolls down; − / + leave that
zoom, Fit returns to it. A node can be dragged aside for the session only (the arrows follow, Auto-layout puts it
back; never saved) — add / rename / retype (Select) / delete a column (the server's refusal with the card ids shown
verbatim), connect two nodes by dragging from a node's port (on its right side; shown and live on the card hovered, focused or selected) or "+ Transition", click an arrow, bundle
or note to edit name / from / to / by or delete it, ↑ ↓ for the board order
(= the graph's top-to-bottom order), Save (the whole draft, validated server-side) / Discard / Reset to template; on a
phone the graph scrolls and zooms above the lists. A board read refused (422) shows the reason and a reset button. The card dialog's
"Transition" list = the operator's transitions out of the card's column (`operatorMoves`), sent as `{transition, column}`: one per target, the first declared name — and, at a gate with `requires_green_ci` (`rules.green_ci`), in a step's `from` BOTH edges into the step's `to`: the step's own (asks CI) and the first other one, labelled "… (CI not asked)" (the free move is never hidden behind the gated one). A card in an approval step's `from` shows the primary approve button (the gate:
"✓ Approve to merge"; a step: "✓ Approve → <to label>"; the tooltip names `to` and `then` from the board); approved in
its `to`, who / when + "Withdraw approval"; beside the approve button, at a gate with `requires_green_ci`, a
**Force · skip CI** button (`kb-force-btn`: a dashed warning-hue pill with a skip icon, never green; `forceTitle`) sends
`approve(id, true, true)` — no confirm: the approval is withdrawn in one click and the agent is told to wait for green CI;
unapproved in a `to` that is a gate, the same button approving in place ("the card stays in <to>"; `lib/workflow.ts` `stepAt` / `approveLabel` / `approveTitle` / `approvedNext`). A collapsed list is a drop target: a card dropped on its strip lands at the bottom of that column. `view` = `{card, panel, archived}` — the host keeps it
(e.g. `?card=&panel=&archived=`). `KanbanApi` (react/src/api.ts) is the full list of calls. `<LaunchBar api slug onLaunched? compact? />` renders one split pill
per agent type (the type's launchers in its menu) and `running / cap` from `Api#launches`; a pill is greyed with the cap
it hits (`lib/launch.ts`), the server's 422 shown verbatim. No `innerHTML` except `Html` injecting the server's `*_html`. Styles: `kanban.css` (required) + `base.css` (the `.btn/.tag/.flash/…`
primitives, for a host without its own).

## 7. Invariants (break one and a suite fails)

1. No column key, label, tool wording, URL prefix, table name, author name or launcher command is a literal in the
   engine or the components — every one is read from the host config or the project's board; a column's rules derive
   from its TYPE in one place (`Board#rules`; fixtures prove two boards on one engine).
2. The suite passes on SQLite and Postgres unchanged (same tests, `DATABASE_URL`).
3. `config.example.yml` carries every `HostConfig::KEYS` key and `board.example.yml` is a valid board on it (`host_config_test`).
4. The ruby `Tools` names and the React badge rules read the same gate keys.
5. `--remote-control <session>` is the LAST pair of every `claude_code` launch argv, named after the session, never configurable away (a `hermes` launcher has no remote control; its host checks the pane runs the command) — the one effective name even when a profile function adds its own.
6. The library ships no agent type, no model id, no prompt: `agent_types` is the host's (`config_test`); a template with an unknown placeholder, or one rendered with a value missing, raises.
7. No card an agent creates through `Tools` is ownerless; no session is counted as running that the engine did not register; no launch exceeds `concurrency.max_sessions` (`store_test`, `api_test`, `tools_test`).

## 8. Session rules — why (failures seen on the first host)

| what went wrong | the rule that makes it impossible or loud |
|---|---|
| 1 after a reboot the watchdog released a project's cards; the next session for it listened to nothing until somebody claimed by hand | a launch REGISTERS the session for its project and type before it starts; registration adopts the project's ownerless cards in the type's `takes` columns (engine, not prompt); the prompt's `{cards}` tells the agent what it owns |
| 2 an agent created a card and never claimed it; the operator's moves reached nobody | `kanban_create` by an agent is owned by its session from the insert (`tmux_session`, or the registered `agent_name` as author) — or refused |
| 3 an agent asked in plain chat; the card never reached Human input | the ask gate takes `tmux_session` (claim + ask in one call); `Tools#instructions` is the MCP server's instruction text, worded from the config, for every host; the type's prompt template carries the same rule. What the engine cannot see (a question typed in chat) it cannot move — the prompt is the remaining lever, now config |
| 4 a dialog question from the day before still attached to a card | `expire_dialogs` runs before every delivery and in every watch pass: a dialog no longer on the screen closes its question and returns the card to work |
| 5 three uncoordinated sessions for one project | `concurrency.max_sessions` + `agent_types[].max` / `max_per_project` refuse the launch with who runs; the UI greys the pill with the cap it hits |
| 6 the agent's picture of the board was wrong (column) | `column_label` on every card JSON; the registration result and the prompt name each adopted card with its column |
| 7 a board's lead was killed (systemd-oomd, 2026-11-15) and the engine spawned 7 workers for its cards over 19 h — a team with nobody leading it, and nobody told | LEAD-FIRST: the engine starts no session on its own (`Team#start` is the one caller of the host's `start`, reached only by the operator's `Api#launch` and the lead's `kanban_spawn`; `test/no_leadless_spawn_test.rb`); a session `under` a lead needs the running lead (`CHECK (needs_lead = 0 OR lead_id IS NOT NULL)`); every type is a lead, under one or a declared standalone plain session; a lead's key is held by the host's launcher (its state, never the session, a JSON answer or a log) and checked by the host when the lead calls `kanban_spawn` — the agent handles no key; a guard against cooperative agents, not authentication (one MCP bearer can name any tmux session); any lead end but the operator's stop is `lead_ends`; a lead gone on its own is `lead_ends` on the waiting list and the board says "no lead: press Launch" — nothing relaunches it |
| 8 five cards sat 1–3 h with their builder subagents idle; the owner (the lead running them) stayed alive and busy, so no watcher fired | the progress watch looks at the CARD, not the session: no card activity and no new PR head / CI / branch commit for N min → owner ping, then a comment, then the card waits for the operator |

## 9. Breaking changes for hosts (config / API)

Newest first; a heading names the `Schema::VERSION` step when the change brought one.

### Schema v16 — green CI is a gate column's setting

- `board_columns.requires_green_ci` (Integer 0/1, null = 0) — what the host config's `approval.requires_green_ci` was,
  now per gate column (§ 2 Green CI). No data step: after the migration NO gate asks CI until the operator (or the
  board's file, on a host that keeps one) sets it on the gates that should. `HostConfig` refuses the `approval` key,
  naming the move.

### Schema v15 — On hold

- `cards.on_hold_at` (Integer) + `on_hold_by` (String): a host migration calls `migrate!(db, prefix:, to: 15)`; its
  rollback drops the two columns (a held card becomes a live card again).
- `Api#hold(id, {on_hold: true|false}, by:)` → the card body (422 on an unknown field, a non-boolean, an archived or a
  finished card); the host routes it (busyyaks: `POST /api/cards/:id/hold`). `Api#board` / `#board_rev` take
  `on_hold:` (the On hold view) and the board JSON carries `view` (`board` | `on_hold`) + `on_hold_count`; card JSON
  `on_hold: {at, by} | null`.
- React: `KanbanApi.hold?(id, onHold)` (optional: absent = no toggle, no button), `board` / `boardRev` opts
  `onHold?`, `BoardView.onHold?` (busyyaks binds it to the URL). The header's "On hold · N" toggle swaps the columns
  for the held cards (no composer there); the card dialog's Put on hold / Release hold.
- Agents: no tool, no wording — a held card does not exist for them.

### Schema v14 — a card's PRs are a list (kanban_pr_assign adds, kanban_pr_unassign removes)

- `kanban_pr_assign(id, pr_url, role, author)` → `Store#assign_pr(id, url:, role:, by:)`: the agent that opened a PR
  assigns it to its card. The card's metadata `prs` is a **list** `[{url, repo, number, role, by, at}]` (oldest first),
  any number per role and per repo; assigning ADDS — the same URL under the same role (any case) is a no-op, nothing is
  replaced or dropped. Logged as an `update` line `PR <role>: <url>`. `pr_url` must be
  `https://github.com/<owner>/<repo>/pull/<n>`, `role` a lowercase word (`a-z 0-9 _ -`, ≤ 32). The MCP `instructions`
  tell agents to assign every PR, on every repo the card changes, at once. A host reads a card's PRs from this list only,
  never from branch names or PR numbers in text.
- Refused (`Invalid`), nothing written: a role the `prs:` port does not list for the card ("role … is not one this
  project reads (<roles>)"); a PR whose `owner/name` (any case) is in none of the role's `repos` ("a <role> PR is on
  <repos>, not on <other>"); the role's `error`; the URL already on this card under another role ("kanban_pr_unassign it
  first"); the URL already a PR of another unarchived card whose column is not of type `cancelled` (naming that card: a
  PR belongs to one card); the port raising ("the PR roles of card #N cannot be read: <why>"); the metadata growing past
  `MAX_METADATA` ("… with its PRs — unassign the PRs that are not this card's"). Every check runs inside the writer's
  transaction (a refusal rolls back, then raises).
- `kanban_pr_unassign(id, pr_url, author, reason)` → `Store#unassign_pr(id, url:, by:, reason:, agent: true)`, and the
  operator's `Api#pr_unassign(id, {pr_url, reason}, by:)` (`agent: false`): the ONLY way a PR leaves a card. `reason`
  required (≤ 500). The entry moves to metadata `prs_removed` (`+ removed_by, removed_at, reason`), logged
  `PR <role> unassigned: <url> — <reason>`. An agent unassigns only a PR whose `by` is itself, or any on a card whose
  assignee it is (`Denied` otherwise, naming who may); the operator any. Not on a session board (`PROJECT_ONLY`).
- An agent move (`kanban_move`, `kanban_handoff`) from a `working` column into a `review` / `gate` / `done` one is
  `Denied` while a `required` role has no PR in the list ("card #N has no <role> PR assigned — … kanban_pr_assign(…)
  before it leaves <column>"); a PR of any of the role's repos counts. The operator's drag is never refused by it — its
  move line says what it skipped (`In progress → QA (dragged: no local PR)`, or `(dragged: PR roles unknown — <why>)`).
- Metadata `prs` / `prs_removed` (and the never-released `prs_replaced`) are written only by these two: `Store#create` /
  `#update` with any of them → `Invalid` (agents and the operator alike); an update that replaces the metadata keeps the
  card's own PR keys (`metadata: null` clears everything else). A `prs` in the pre-list `{role => url}` shape, or that
  is not a list of `{url, role}`, is refused with what it is (never read as empty).
- Data step (no DDL): `Schema.migrate!(db, prefix:, to: 14, prs:)` runs `Schema.prs_to_lists!` (`prs:` = the Store's
  PR roles port, required once a card holds the old shape) — each `{role => value}` becomes one entry per PR the value
  names: a full PR URL, or text naming several (every full PR URL, and a bare `/pull/N` after one = the same repo; the
  remaining prose dropped only when it holds no other `github.com` / `/pull/` / `http` link, else raise); a role the
  port does not list for that card (an old `engine` / `mirror` key) is mapped to the ONE port role whose `repos` holds
  that PR's repo (several → raise naming the card, the value and the candidates; none → raise, unless the port answers
  the optional `unread_reason(card, role, repo)` with a reason: then the PR becomes a `prs_removed` entry, removed_by
  `migration`, that reason, and the card gets an `update` line "PR <role> removed by the v14 migration: <url> —
  <reason>" — kept and visible, never active; `migrate!(…, now:)` dates it). Then `by` / `at` = the author / time of the card's newest `PR <role>: <url>` line (`null` when none
  says: never guessed); a `prs_replaced` entry becomes a `prs_removed` one (reason "replaced under the one-PR-per-role
  rule"); idempotent; a value that is no PR URL raises and no card is written. The host's rollback:
  `Schema.prs_to_roles!` — an entry whose role `up` mapped (an old `engine` key, `local` on a plain project that reads
  only `pr`; the same PR under several old keys is ONE entry) carries `from_roles` = the old keys and goes back under
  them exactly — refused (`ArgumentError` naming the cards, nothing written) while a card would hold two PRs under one
  key or holds any `prs_removed`.
- `Store#unassigned_pr_mentions` → `[{card, project, column, url, seen}]`: a report for a human to confirm, never acted
  on — the PR URLs each open card (not archived, not done / cancelled, not a session board) names in its `pr_url`,
  description, comments and handoffs that are not in its `prs` (`seen` = where first named). Reads only.
- The `ci:` port's answer `head` may name several PRs' heads joined by `+` (one per PR, the host's order); a hold says
  each shortened to 7.
- React: `CardLink.unassign` (a row the host marks as an assigned PR) + the optional `KanbanApi.prUnassign(id, prUrl,
  reason)` → the rail's row gets an "×" (`Unassign <label>`, `aria-expanded`) that opens ONE line IN the row: the
  reason box (required: blank → Unassign disabled, nothing sent) + Unassign; Enter sends the trimmed reason, Escape or
  the × again closes it (Escape never reaches the dialog; neither while a request runs); the call's refusal is said
  under the box (`role="alert"`), the form stays, the caret back in the box (read-only while sent, the × disabled);
  done → the card reloads and the focus goes to the rail. No browser prompt / confirm. No `prUnassign` on the port =
  no action. `CardLinks`' `onUnassign(link, reason)` resolves to `null` (done) or the refusal's text.
- React: `CardLink.group` — the Links rail lists a link with a group in its own sub-section of its family's, named by
  the family's short name ("PRs · local", "PRs · public"), in first-seen order; a grouped row leaves out the tag that
  only repeats its group (`rowTags`; never its only tag); `LinkGroup.fold` — the PR sections never fold behind
  "+N more" (every PR of the card is listed).
- React: a PR row's label `#N <repo>` is drawn as the number (strong) + the repo, which wraps at `_ - . /` instead of
  ending in an ellipsis (`prLabelParts`; the link's accessible name stays the whole label). `CardLink.struck` — history (a PR
  taken off the card): the label struck through, on one line. Chip text = its tone mixed 70 % towards the ink (≥ 4.5:1
  on its tint). On a phone the grouped rail spans the dialog's side columns.

### Schema v13 — the progress watch

- New REQUIRED host config key `progress_watch: {stale_minutes: N | null}` (null = off; a missing key, a missing or extra
  sub-key, or a value that is not null or an integer ≥ 1 → `ConfigError`). A host adds it, and a migration calling
  `migrate!(db, prefix:, to: 13)` (the stretch columns on `cards`).
- The Store's `ci:` port may answer `progress(card)` + `progress_kinds` (both or neither, § 4 Progress watch).
- `Notifier#watch` step 3e logs `progress watch: card N <step>` / `card N: <why>` (once per reason) / `card N answered again`.
  Every watcher after the watchdog is guarded on its own: a raising one logs `<watcher> skipped: <class>: <message>`
  (before, a Delivery error in any of them logged `watchdog skipped` and returned no released cards).
- Card JSON: `progress_error` (string | null).
- Card JSON + `Api#waiting` cards: `progress_stale` (string | null); board JSON: `progress_watch`. React: `Card.progress_stale`
  (`⌛` badge `.kb-stale` on the face and in `CardPeek`), `BoardData.progress_watch`.

### Schema v12 — lead-first boards

- `agent_types[].spawns_for`, `spawn_launcher` and `launcher_follows` are REMOVED: `ConfigError` names what
  replaced them. `Api#spawn_pass`, `Store#spawn_queue` / `spawn_backoff?` / `spawn_note`, `Store#followed_launcher`,
  `Board#spawn_columns` / `spawner_for`, `HostConfig#spawn_types`, `Notifier.new(spawner:)` and `rules.spawn_columns`
  are gone. The engine starts NO session on its own.
- New `agent_types[].under: <lead type>` (replaces `launcher_follows`): a session of the type exists only under the
  board's RUNNING lead, on its launcher. New `standalone: true` (a plain session: `prompt: null`, `takes: []`). Every type
  must be a lead, `under` one, or standalone (`ConfigError` otherwise).
- A lead's ownerless work: give the lead type the work column types in `takes` (e.g. `[queued, working, review, gate]`)
  — it adopts ownerless cards (one `assigned` ping) and starts a worker per card with the new MCP tool
  `kanban_spawn(id, type, tmux_session, author)` (listed only on a host with a lead type; `Tools.new` takes
  `launcher:` — the same LAUNCH port as `Api` — and raises `ArgumentError` on a `kanban_spawn` without it).
- The host's launcher port: `start` now also gets `lead_key:` (a lead: its key — the host KEEPS it, in its own state,
  never in the session's environment, a log or an answer; nil otherwise) and `lead:` (the lead's tmux session a session
  under a lead runs under, nil otherwise — the host refuses the start unless it started that lead, for that project, and
  it runs); and the port answers `lead_key(session:)` → the key it keeps for a lead it started, or raises
  `Delivery::Refused`. `kanban_spawn` / `kanban_register` ask it and `Store#lead_by_key!` compares the digest
  (constant time); the agent never sees or passes a key. This is a guard against cooperative agents starting sessions
  without their lead, NOT authentication (residual below).
- `kanban_register` of a type `under` a lead: refused unless the board's lead runs and the host vouches for it; a lead
  registered by hand gets NO key (no `key_to`: it cannot `kanban_spawn` — a lead that starts its team is started from
  the Launch bar). `Store#register_session(lead_id:, from_owner:, key_to:)`: `key_to` receives a lead's key (never the
  returned Hash); a type under a lead without the open lead registration → `Denied`.
- `Store#lead_ends`: every lead end in the window but `Store::OPERATOR_STOP` ("stopped by the operator" — a host's Stop
  passes it to `end_session`) and a failed start (that is a launch failure).
- Residual: `tmux_session` names the caller (one MCP bearer on localhost) — a session that names the lead's tmux session
  is not told apart from the lead; the key shows the named lead is the one the host started, not who calls. Binding
  a caller to its session needs per-session MCP credentials (not in this schema step).
- `AgentType#launcher!(nil)`: the type's only launcher, else `Invalid` (no `spawn_launcher`).
- `Api#waiting` adds `lead_ends`; `Api#board` adds `lead` (`Store#lead_state`: `{type, label, session, ended}`; `error`
  when the sessions port is down; null on a host with no lead type or an Api without a sessions port); `Api#launches`
  types carry `under` (not `launcher_follows`); `Api#launch` answers `lead`.
- `Schema::VERSION` 12: a host migration calling `migrate!(to: 12)` (adds the three `agent_sessions` columns + the CHECK).
- React: `AgentTypeConfig.under` (not `spawns_for` / `launcher_follows` / `spawn_launcher`), `LaunchType.under`,
  `AgentTypeConfig.standalone`, `BoardRules` without `spawn_columns`, `BoardData.lead` (`BoardLead`: the board's "no lead:
  press Launch" line), `LeadEnd` + `LaunchFailureAlert leadEnds`, `RegisteredSession.lead_id`, `LaunchResult.lead`;
  `launchBlocked` greys a type under a lead while none runs.

### No schema step — the board's working glow (React only)

- New optional `KanbanApi.boardLive(slug)` (§ 1): the board polls it every 3 s (`useLivePoll`, as the live agent line) —
  one call for the whole board, never one per card. A card whose OWNER session is `working` with a phase read off its
  screen (thinking · tool · writing · subagents; `lib/agentLive.ts` `workingPhase`) gets `.kb-card.agent-working`: a
  blue frame + a soft pulsing glow in the new token `--ak-working` (light `#0a84ff`, dark `#409cff`; a host maps it in
  its `theme`), steady under `prefers-reduced-motion`, its aria-label "— its agent is thinking / running a tool /
  writing / waiting on its subagents". No glow for a working session with no phase (no evidence), an idle / blocked / unknown
  one, no owner, a card in a `done` / `cancelled` column (finished work), or before the first answer; a board switch drops the old
  board's answer at once (`useLivePoll` `key`), an answer with no newer one for 2 polls is dropped (`staleAfter`: the header
  shows `agents · live state unknown: no answer for 6 s`); a failed poll clears every glow (the last answer is never shown) and the
  header shows `agents · <the reason>` (`.kb-agents-err`). A card that needs the operator (`waiting`) shows only its red
  highlight: needs-you wins. Nothing changes for a host without the port.

### No schema step — the PR watch

- The `ci:` port on Store may answer `closed_prs(card)` → `[{role:, number:, repo: (optional), closed_at: epoch, why:
  String} | {error: String}]`: the PRs assigned to the card that are closed WITHOUT merging, `why` = the host's words
  (e.g. `base deleted`, `head deleted`, `by <login>`), and one `{error:}` per assigned PR it could not read — said next
  to the closes, so a closed PR never hides another PR's failed read; asking also keeps every PR assigned to the card
  watched by the host. It raises `Delivery::Unavailable` / `Refused` when it cannot say at all. A port without it → no
  PR watch. A close whose `closed_at` is not a positive Integer, whose `why` is blank, or with no `role` / `number` is
  refused as the port's error (logged like an `{error:}`), never told: a host that does not know a close's time or
  reason yet answers nothing for that PR until it does.
- `Notifier#watch` step 3d (`Store#pr_watch_pass` → `[[id, :closed | :closed_nobody | "unavailable: <why>"]]`): every
  unarchived project card outside its board's terminal columns is asked. Each close is told ONCE (`ci_watches` kind
  `pr_closed:<role>:<repo>#<n>` — a card holds several PRs per role —, ref = `closed_at`: a reopened PR
  closed again is a new close; one recorded under the older `pr_closed:<role>` key is not told again): a `comment` by
  `system_author` "PR <repo>#N (<role>) closed without merging (<why>) — pinged <owner>" (or "no owner session to ping") and a `pr_closed`
  ping to the owner session. A close told while the card had no owner session is not pinged when an owner adopts the
  card later (the comment stays on the card; the relay carries only the operator's comments). A card the port cannot
  read is logged once per change of reason (`pr watch: card N: <why>`, every reason of the card in one line), the other
  cards and the card's other PRs are still watched.

### No schema step — card terminals

- `Store#card_sessions(id)` → the open registrations working on a card (its owner session, then each registration whose
  agent name is the assignee; `session_json` + `owner`), and `Store#terminal_event(session:, socket:, by:, text:)` → one
  `terminal` event by the operator on every live card the session works on — owns, or is assigned to its agent
  name (a session with no open registration: `Denied`).
  A host that shows an agent session's screen records each open / take control / release with it.
- New optional `<Board cardTerminals>` prop, `(card: CardFull) => ReactNode`: the card dialog shows what it renders for
  the open card in a **Terminals** section (after the description); absent, or `null` for that card = no section. The
  engine renders nothing of its own there — the host draws its live terminals of the card's agent sessions.
  `KanbanHostValue.cardTerminals` (null when absent; a host that builds the value itself adds it).

### No schema step — folded summary, compact launch bar (React only)

- New optional `<Board summary>`: `"full"` (default: a pill per column, then total, waiting for you, waiting for CI) or
  `"folded"`: waiting for you, waiting for CI and blocked externally first; then the non-empty columns, consecutive
  columns whose labels share a `<Group>: ` prefix (≥ 2 columns on the board) as one pill naming its non-empty members
  (`lib/summary.ts` `foldSummary`); the empty columns behind one `+N empty` toggle (`aria-expanded`; unfolded = every
  column in board order); total last. Groups come from the board's labels only.
- New optional `<LaunchBar compact>`: smaller `＋ <Type>` buttons (the `＋` is `aria-hidden`: the accessible names are the
  type labels), the launcher label short and mono. Behaviour unchanged.

### No schema step — agent faces

- Board JSON and the card body carry `agents` (agent name → registered type key). The React `Avatar` draws any
  identity that is not an email address (and not the operator, `me`) as a face (`AgentFace`, `lib/face.ts`): two eyes,
  their shape hashed from the name, on a disc coloured by the TYPE; a person keeps the initials. Moods (sleeping · idle ·
  working · thinking · tool · writing · subagents · blocked) come from the host's `SessionLive` and are shown by the eyes
  alone (blink, look up, squint, read along, glance, wide, closed); static under `prefers-reduced-motion`.
- Host config `face_roles` (required; null or `{role: [name globs]}`): a face whose name no session registered (a
  subagent's own name) wears the colour of the first role whose glob matches it (`faceType`: the registered type, else
  the role, else none). Config, never a name the code knows.
- Host config `avatar_url` (required; null or an https template with `{sha256}`): a PERSON's picture, the hex SHA-256
  of the trimmed, lower-cased email (Gravatar's scheme); the image shows when the URL answers one, else the initials
  (no picture on record). null = initials only, no request leaves the page.
- `SessionsLive.present: PresentAgent[]` (required once a host has `sessionsLive`; the engine never derives it — no owner stand-in; a failed poll shows nobody) (`{session, agent, type, live, why: blocked|tool|activity}`): the card's agents
  at work on it NOW — `Store#presence(slug, live:)` from the host's live reading: an open registration of the project,
  live state working or blocked, whose running tool names the card (`why: tool`) or whose agent name wrote on the card
  since its turn began (now − `elapsed_s`; no elapsed → no activity rule; `why: activity`), or — stopped on a
  dialog (state blocked) — the card it last wrote on since it registered (`why: blocked`); ownership alone is not
  presence; the card dialog shows them as a "here now" row. New optional
  `KanbanApi.boardPresence(slug)` → `{cards: {id → PresentAgent[]}}`: the board polls it and shows the present agents'
  faces on each card face, entering and leaving as they come and go. Absent port → no presence, never guessed.

### No schema step — the live agent line (React only)

- New optional `KanbanApi.sessionsLive(id)` (§ 1): the open card dialog polls it every 3 s (`lib/live.ts` `useLivePoll`:
  tab visible, a poll in flight not overlapped until it has been pending for 5 intervals (a stalled connection then no
  longer blocks the next), the last good value kept beside a failed poll's error; n failed polls in a row wait
  `pollDelay` = 3 s × 2^n, at most 30 s, until one succeeds). A screen reader hears only the state when it changes
  (`liveAnnounce`: "<session> is working / is waiting for you / is idle", in a visually hidden `aria-live` span), never
  the counter. Above the newest comment, the
  owner session's line (`li.kb-agent-live`): its name and what it does — `thinking… · 42s`,
  `writing… · 1m 5s · ↓ 1.2k tokens` (the host names writing only from evidence, e.g. a rising token count), `running Bash`, `waiting for its subagents · 1 subagent` (no turn of its own), `writing a comment on this card` (a comment tool whose `card` is
  this card), `waiting for you (a dialog or question)` (blocked), `idle`, `state unknown`, `· N subagents`
  (`lib/agentLive.ts` `liveLine`); a failed poll shows `live status: <the reason>`. A pulsing dot (`.kb-live-dot.on`)
  marks the newest comment of each session whose turn runs now (`liveDots`: the author resolved to its session as the
  agent links do — its own name, or the card's assignee → its owner session). Nothing changes for a host without the port.

### No schema step — dictation (React only)

- New optional `<Board dictation>` prop (`DictationApi`, § 1): the card dialog's comment box gets a mic button, and
  `DictationApi.shortcut` (a `KeyCombo` the host's user picks, or null = the button only) anywhere in an open card
  is push-to-talk, caught on the window in the capture phase while a card is open (wherever the focus is: an editor that keeps its keys, a menu, the body; the key's own character, e.g. ⌥M's "µ", prevented): held = recording, released (the key or one of its modifiers, or the window losing the focus) =
  stopped; key auto-repeat ignored; released before the mic opened = stopped once it opens. Matched by key position (`KeyboardEvent.code`, so ⌥M still matches where Option+M types "µ").
  `lib/shortcut.ts`: `matchesCombo`, `comboLabel` (⌥M / Alt+M), `comboRefusal` (combos the browser, the OS or the
  editor owns — ⌘S, ⌘M, Ctrl+W, … — and plain keys that would fire while typing), `parseCombo`.
  Windows (`startDictation`): each re-hears `OVERLAP_SEC` (0.4 s) before the last confirmed word's end (the overlap is
  dropped again, `appendNew`); only words ending `STABLE_SEC` (1 s) before the window's end are confirmed; a window below
  `SILENCE_RMS` is never sent; zero-length words and a pass that is the prompt's tail are the model's echo, not speech
  (`heardWords`); no window is longer than `MAX_WINDOW_SEC` (30 s, the least a host's size limit must accept): a server
  that failed or answered slowly while you talked gets the oldest 30 s, which then confirms (over `FORCE_CONFIRM_SEC`),
  and stop() sends a longer unconfirmed tail in windows of at most 30 s. A failed final pass rejects with
  `DictationFailed` (`confirmed`, `retry()` goes on from the window that failed).
  The editor: Save / Ctrl+Enter wait while it dictates (Ctrl+Enter stops it), Esc and the backdrop stop it instead of
  closing the card, a failed final pass keeps the recording and offers Retry or Discard (the confirmed words stay, the
  rest is dropped) — until then the text is read-only and Save / Ctrl+Enter / uploads / a new recording wait —; no dictation
  starts while an upload runs, no upload while it dictates; a recording that heard nothing says so (`onDictatingChange`). The words appear at
  the caret while you speak (`lib/dictation.ts`: a 2.5 s sliding window, LocalAgreement-2 confirms the words two passes
  agree on, a 25 s window with no agreement is confirmed whole, stop sends the rest once); the text is read-only while it
  records; a failed pass shows the reason and retries, a failed final pass is shown and keeps the text confirmed so far.
  `KanbanHostValue.dictation` (null when absent; a host that builds the value itself adds it), `MarkdownEditor`
  `dictate` / `dictateToggle` (a `DictateHandle {toggle, hold}`), `openMic`, `startDictation`, `composeDictation`, `pcmToWav`.
- The control (`components/MicButton.tsx`, phases `idle starting rec stt done` on `data-phase`): while it listens the
  mic is a pill — a stop square, 7 level bars and the elapsed time — and the formatting tools and the paperclip are
  disabled and step aside (the text is read-only). The bars and the pill's halo show the REAL microphone level:
  `MicCapture.level()` = the RMS of the newest `LEVEL_SAMPLES` (512) samples (an AnalyserNode; 0 once released), read
  once per animation frame while recording only, mapped by `meterLevel` (dB, `METER_FLOOR_DB` … `METER_CEIL_DB` → 0 … 1)
  and spread by `levelBars` (the middle bar = the newest reading, the edges older and lower). The words not confirmed
  yet are tinted behind the text (`.mde-ghost`, placed by `pendingRange`); `stt` = a turning ring and a wave; a
  dictation that ended without an error settles as `done` (a check, the text glows once) for 1.4 s — a failed one
  never does. Accessible names unchanged ("Dictate" / "Stop dictation", `aria-pressed`; `aria-disabled` while
  starting / transcribing, so the keyboard focus stays on it). `prefers-reduced-motion`: the same states, still.
  `comboKeys` (lib/shortcut.ts) = a combination's keys one by one, for key caps.

### Schema v11 — session boards

- New REQUIRED host key `session_boards` (`null` = off, the old behaviour): § 2b. A host adds the key and a migration
  `Schema.migrate!(db, prefix:, to: 11)` (`boards.archived_at`).
- New MCP tool `kanban_session_board` (only listed when configured), `Api#session_boards`, React `SessionBoards` +
  `sessionBoardLanes` / `secondsLeft` / `leftLabel`, types `SessionBoard*`. `Tools#call` refuses another session's use of
  a session board (`Denied`). `Attachments#card_id_of`, `Store#comment_card_id` / `#checklist_card_id` / `#item_card_id`.
- The `card_url` port is called with a session board's slug too (`<prefix><session>`): the host links it to its own
  page for session boards.

### PRs assigned to cards: the idle watch (no schema step)

- `Store#idle_watch_pass`: a card whose PR the `ci:` port cannot answer (`pr_checks` raising `Delivery::Unavailable` /
  `Refused`, e.g. a bad assignment) is skipped and returned as `[id, "CI skipped: <why>"]` (the notifier logs
  `idle watch: CI skipped: <why> on card N`); the other cards are still watched. It used to end the whole pass
  (`idle watch skipped: <why>`); `last_commit_at` raising still does.

### Approved and carried on is not waiting for the operator (no schema step)

- A card in a waiting gate the operator APPROVED (`approved_at`), whose next step is its agent's named transition
  (`Board#agent_next(column)`: the gate's one agent way on, not back to a work column — Awaiting merge → Merge → Done on
  `local_v4`), waits for its agent, not for the operator (`Store#carried_on?`): `Api#board` / `#boards` `waiting` and
  `Api#waiting` `total` / `projects` leave it out and carry it as `approved` (a count on the boards; `[{slug, count,
  cards}]` in `Api#waiting`; `since` = the approval); `Store#waiting_cards` gains `approved`, `Store#waiting_counts` `approved`; card JSON
  `carried_on` = `{next_column, next_label, final}` | null, `waiting` false. Every `Api#waiting` card carries
  `approved`, `approved_by`, `owner_session` and `carried_on` (`Store#carried_on_json`, the one predicate). Precedence:
  needs_operator (a question) → waiting; blocked_external → `external`; a CI hold → `held`; no owner session → waiting
  (nobody carries it on: "approved · no agent"); else `approved`. An unapproved card in the same gate still waits (the
  operator's Approve in place). Leaving the gate (the agent's move, or the operator's withdraw) ends it.
- React: `Card.carried_on` (a "✓ approved · <owner> merging" / "→ <next>" badge, `carriedOnText`), `BoardData.approved`
  ("N approved · agent on it" beside "waiting for you").

### blocked_external is not waiting for the operator (no schema step)

- A card flagged only `blocked_external` waits for the world (another card, CI, a third party), not for the operator:
  `Api#board` / `#boards` `waiting` and `Api#waiting` `total` / `projects` leave it out — in a gate too — and carry it as
  `external` (a count on the boards, `[{slug, count, cards}]` in `Api#waiting`); `Store#waiting_cards` gains
  `external`, `Store#waiting_counts` `external`, `Store#flagged_counts` counts `needs_operator` only. A card that is
  blocked AND asks still waits for the operator (the question does). Agents still cannot move a blocked card, the spawn
  queue still skips it, the reminder still fires.
- React: `BoardData.external` ("N blocked externally" beside "waiting for you").

### Public: Create PR on the local board (no schema step)

- Fixture `local_v4.board.json` = the private local-repo board: `local_v3` + column `public_create_pr` "Public:
  Create PR" (type working) between Local: Deploy check and Public: Agent review. The operator's "Open public PR"
  now goes Local: Deploy check → Public: Create PR (its approval step's `then` = Public: Agent review); the agent
  builds, audits and opens the public PR there, then takes the new agent transition "Public PR opened" → Public:
  Agent review (round 1 of the public loop: entered from a work column). Cancel and Rework list the new column.
  `local_v3.board.json` stays, frozen: the column rename's target, read by hosts' pinned migrations. A board is
  data: a host reshapes a stored board with the editor's own call (`BoardRepo#save`).
- "Public PR opened" is a plain agent transition: the engine checks no PR on a move (no transition carries a
  condition). The public PR is enforced one step on, where it matters: the handoff into Public: Human review is
  refused until the final approval step's checks — the public PR's — are read and green (§ 2 `approval`, Handoff
  on green CI), so no card reaches the operator's public review without an open public PR. The scope, accepted: the
  agent review loop (Public: Agent review ↔ Author response) can be entered before a public PR exists, by an agent
  that takes the transition early; the host's worker prompt orders it after the PR is opened, and nothing it does
  there reaches the operator before that check.
- The card dialog's approve button names its step: `✓ <transition name> → <column>` ("✓ Open public PR →
  Public: Create PR"; a final step `✓ <name> to merge`), `approveLabel` in `lib/workflow`; the tooltip starts with
  the name.
- `foldGraph(base, maxWidth, maxHeight = Infinity)` / `layoutGraph` `maxHeight`: the editor passes its box
  height (read again 120 ms after a resize settles); splits whose rows are wider than the box are skipped undrawn.

### Card URLs for agents; the links rule

- `Tools.new` takes a required `card_url: ->(slug, id) { the absolute URL that opens the card on the host's board }`
  (missing → `ArgumentError` at boot). Every card a tool returns (`kanban_card`'s `card`, `kanban_board`'s cards and
  `archived`, every card row a mutation answers) gains `url`.
- `Tools#instructions` ends with `Tools::LINKS`: per reference, decide what it is and link to where it lives, read from
  data (a card → its `url`, a PR → its own repo, a commit → the repo that holds it, …); in chat no `#` before a number.

### Column rename (no schema step)

- New `BoardRepo#rename_columns!(columns:, transitions:, cards_t:, activity_t:, by:, slugs:)`: a host's data
  migration renames columns (`{old key => {"key" => new key, "label" => new label}}`, either or both) and transitions
  (`{old name => new name}`, on the boards holding a renamed column) on every stored board (the template too), or on
  `slugs` only. Cards (archived too), their `review_rounds` keys and their move / create entries follow; a board that
  already holds a new key is refused. Its down calls it again with the inverse maps.
- Fixtures: `local_v3.board.json` was the private local-repo board (now `local_v4`, above; keys `local_agent_review`, `local_author`,
  `local_human_review`, `local_merged_pr`; labels `Local: …`; transition `Open local PR`). `mirror_v3.board.json` stays,
  frozen: the workflow v3 migration's target, read by hosts' pinned v3 migrations. `mirror_v2*.board.json` are now
  `legacy_v2*.board.json`. A host whose `review_loop.columns` named `mirror_agent_review` renames it with its boards.

### Schema v10 — approvable now; the review SUMMARY counts at the round limit

- A card in an approval gate counts as waiting for the operator only while its Approve would pass NOW (`Store#gate_hold`
  → nil, else why: the step's checks not green / unreadable, or its PR moved on from the head the handoff saw). A held
  card is "waiting for CI": `Api#board` / `#boards` `waiting` leave it out and carry `held` (the count); `Api#waiting`
  and `Store#waiting_cards` move it from the list to `held`; card JSON gains `gate_hold`. A flagged card counts as
  before. The ci: port's answer may carry `head:` (the PR head sha); the handoff stores it (`cards.gate_head`) and
  `cards.gate_state = "ready"`; the operator's Approve on a PR that moved on from that head is refused ("… hand it back
  for review"). Any move but the handoff clears both. Reads take `gate_state` (the watch pass's last view, so a change
  shows within one watch pass and a read asks the port nothing); only a card with nothing recorded is asked live.
- The notifier's prefetch pass is also the gate watch: an answer in state `failure` (whatever the host's `reason:`) →
  ONE `gate_red` ping to the owner per CI completion (`ci_watches` kind `gate_red`, ref = its `finished_at`); a hold
  cleared → one `gate` activity "ready for your approval". `Store#approval_prefetch_pass` rows gain a third element
  (the event: `:red`, `:red_nobody` — no owner session —, `:ready` or nil).
- `kanban_handoff` / `Store#handoff` take `review_summary` (the reviewer's SUMMARY counts `{fixed, resolved_by_argument,
  needs_human, open}`, integers ≥ 0): required at the review round limit (missing / malformed → `Invalid`); the
  `unresolved` label goes on only when `needs_human + open` is above 0; the handoff line names the counts.
- A host pins it with a new migration (`Schema.migrate!(to: 10)`).
- React: `Card.gate_hold` (a "⏳ <why>" badge), `BoardData.held` ("N waiting for CI" beside "waiting for you").
- Card JSON `waiting` (decorated cards): the card waits for the operator NOW — `Store#waits_for_operator?`, the one rule
  `waiting_counts` counts by (a question open, wherever it sits; or in a waiting column, approvable now and not only
  blocked_external). React highlights it (`cardFaceClass` → `kb-card needs-you`: red frame + tint, a "needs you" badge),
  so the cards the "N waiting for you" count names stand out on the board itself.

### No default launcher

- A start that names no launcher no longer runs the type's FIRST one. `AgentType#launcher!(nil)` → the type's new
  optional `spawn_launcher`, else its only launcher, else `Invalid` ("agent type X runs a, b and none was named …").
  Hit by: `Api#spawn_pass` with no session to follow (the card waits, owner note `spawn refused: …`), `Api#launch`
  without `launcher` (422), `Launch.argv` / `plan` without `launcher:`. A host whose spawning types list several
  launchers adds `spawn_launcher: <key>` to them.
- `kanban_register` / `Store#register_session` (a session started elsewhere): new optional `launcher`; none named →
  the type's only launcher, else refused (`AgentType#registered_launcher!`) — `spawn_launcher` never applies.
- `HostConfig#launcher(key)`: the key is required (nil / "" → `Invalid` with the keys).
- React: `AgentTypeConfig.spawn_launcher?`.

### Schema v9 — the workflow graph lays itself out

- `board_columns.x` / `y` are dropped: a board column is `{key, label, type, hide_after_hours?}`; an `x` / `y` in a
  save is refused as an unknown key; `Board.auto_layout` is gone. A host pins it with a new migration
  (`Schema.migrate!(to: 9)`; rollback `Schema.restore_xy!`, which puts the v8 shape back).
- React: `BoardEditor` lays the graph out with dagre on every open, folded into rows that fit its box, at the zoom that
  shows the whole graph (never below `MIN_TEXT_ZOOM`); Save sends no position; a drag is a nudge for the session.
  `lib/graph` exports `layoutGraph(columns, transitions, {typeLabel, maxWidth, maxHeight})` = `foldGraph(rankGraph(columns,
  transitions, {typeLabel}), maxWidth, maxHeight)` (dagre runs in `rankGraph`, once per draft; a resize only re-folds), `withMoved`,
  `pathOf` (a polyline with rounded corners), `MIN_TEXT_ZOOM`; `@dagrejs/dagre` is the port's one runtime dependency.

### Schema v8 — workflow v3: a fixed type set, gates, flags, review loops

- Column types: `asks_operator`, `handoff` and `approved` are GONE; `gate` and `cancelled` are new; `working` is no
  longer a singleton (the first working column is the watchdog's / idle watch's). A stored board with a v2 type
  refuses to load: the host's data migration runs `Schema.migrate!(to: 8)` then `BoardRepo#migrate_v3!(cards_t:,
  activity_t:, by:, reshape:)` once (SPEC § 2a). `ColumnTypes::LEGACY` names the mapping.
- `rules.gates.ask` and `rules.gates.approve` are gone; `rules.gates.handoff` is `{columns: [...], …}` (a list, not
  one column); `rules.gates.approvals` is derived per gate (§ 2a); new `rules.terminal`, `rules.review_columns`.
  `Board#ask` / `#approve` / `#ask_column` / `#handoff_column` are gone (`#gate_columns`, `#handoff_targets`,
  `#terminal?`, `#gate?`, `#working?`, `#review?`).
- `HostConfig`: new required keys `flags` ({reminder_hours}) and `review_loop` (nullable; `columns` = its loop columns); `agent_types[].takes` /
  `spawns_for` name the new types (e.g. a lead: `[queued, working, review, gate]`).
- `Schema::VERSION` 8 (the card flags + `review_rounds`): a host migration pinned `to: 8`.
- Store: `ask` flags the card and moves nothing (`move(ask:)` is gone); `handoff(transition:, column:)` picks the gate;
  new `block` / `unblock` / `flag_reminders` / `flagged_counts` / `flagged?`; the operator's comment answers a flagged
  card in place; `unapprove` only while approved. Card JSON: `needs_operator`, `blocked`, `review_round`.
- Api: `board` / `boards` carry `waiting` (flagged included) and `flagged`; `waiting` rows carry `needs_operator`,
  `blocked`, `blocked_first_line`. Tools: `kanban_ask` is always listed (no column needed); new `kanban_block` /
  `kanban_unblock`; `kanban_handoff` takes `transition` / `column`. Notifier: the watch pass runs `flag_reminders`.
- React: `ColumnTypeKey` / `BoardRules` follow; a host that built `rules` itself drops `ask` / `approve` and adds
  `terminal`, `review_columns`, `handoff.columns`.

### Approval steps

- `rules.gates.approvals` (new, always a list) carries every approval step; `rules.gates.approve` is unchanged. The
  React `BoardRules` type requires it — a host that builds `rules` itself (tests) adds it. `Api#approve` / the
  `approve(id, approved)` port are unchanged: the step is the card's column. A host that read `gates.approve` to show
  an approve button reads `gates.approvals` instead.

### Boards in the database (Schema 6)

- `BoardConfig` is gone: `AgentsKanban::HostConfig.load(path)` loads the host config (§ 2b). The keys `columns`,
  `default_column`, `waiting`, `listened`, `operator_only`, `agent_no_create`, `gates`, `workflow` are REFUSED at
  load (they live in the database now); `idle_watch` lost `column`; new required keys `handoff` (the gate's
  parameters or null) and `dependencies` (true / false); `agent_types[].takes` / `spawns_for` name column TYPES.
- `Schema::VERSION` 6: a host migration calling `migrate!` again (adds `boards`, `board_columns`, `board_transitions`),
  then `BoardRepo.new(db, tables:, host:).seed!(template:, projects:, by:)` ONCE with the host's template board
  (`board.example.yml`'s shape, e.g. `fixtures/boards/coding.board.json`) and its project slugs — every existing project gets its
  own rows (its `workflows` row's transitions when it had one), the `workflows` table is dropped. A project added later
  gets the template's copy on first use. No template row = every board read raises.
- Store: `config:` is a `HostConfig`; `Store#board_of(slug)` / `#boards_for` / `#board_template` / `#board_json(slug, board:)` /
  `#board_save` / `#board_reset`; `#counts(slug = nil, slugs:, boards:)`, `#empty_counts(slug)`, `#waiting_cards(slugs)` →
  `WaitingCards(by_slug, boards)` (replaces `in_column`; the boards it read, the template included, for the caller to reuse);
  `#owned_cards(slugs)` → `{[session, socket] => {project_slug, since, cards: [light rows + column_type, finishes]}}` per
  OPEN registration — only the cards it came to own since it registered (a reused tmux name inherits nothing); a session
  with no open registration is absent (unknown). A host's "is this session finished?" = ≥ 1 card and all of them finish;
  `workflow*` methods gone. A page reads each board ONCE (`Api#board`, `#boards`, `#waiting`: one `board_transitions` query).
- `Schema.migrate!(db, prefix:, to:)`: pin every host migration to its step (SPEC § 3); `BacklogMd.read(path, board:,
  status_map:)` maps statuses to column TYPES.
- Api: `workflow` / `workflow_save` / `workflow_reset` → `board_shape` / `board_shape_save {columns, transitions}` /
  `board_shape_reset`; `boards` and `waiting` answer per-board columns; `board` carries `board` and 422s when the stored
  board no longer fits the host (`workflow_error` gone); the `backlog:` port takes `(project, board)`.
- Tools: `kanban_workflow` returns the board shape (+ rules, types); `column` arguments carry no enum (a project's
  columns differ); `kanban_handoff` / `kanban_ask` are always listed and refuse on a board without the column; the
  descriptions are worded from the TEMPLATE board. `BacklogMd.read(path, board:, status_map:)`.
- Content boards: `Done` is now a `done` column (operator-only: agents may still finish a card there — no approved
  column — but never move one out of it, and cannot create there); `Queued` and `Blocked` are listened (watched by the
  watchdog, "no listener" on the face); the board runs a catch-all transition (`Move: * → *`) in place of "no workflows".
- React: `BoardConfig` → `HostConfig`; `BoardData.board` (`BoardShapeData`); `Card.transitions` always present;
  `KanbanApi.workflow*` → `boardShape` / `boardShapeSave` / `boardShapeReset`; `WorkflowEditor` → `BoardEditor`;
  `useKanbanHost().board`; `colLabel(board, key)`; `LaunchType.takes` are column types.

### Agent types and the session registry (Schema 3)

- `launchers[]` lost `prompt`; `agent_types` (non-empty) and `concurrency` are required keys → `BoardConfig.load` fails until added.
- `Launch.argv(config, session:, key:)` → `Launch.argv(config, type:, session:, launcher:)`; new `Launch.plan` / `Launch.render`.
- `Schema::VERSION` 3: a host migration calling `migrate!` again (adds `agent_sessions`).
- `Tools`: `kanban_create` by an agent needs `tmux_session` or a registered author (else refused); new `kanban_register`; `kanban_ask` takes `tmux_session`; `Tools#instructions`; `Tools.new(grace:)`.
- `Api.new(sessions:, launcher:, grace:)` for `launches` / `launch` / `sessions` (optional: a host without them keeps the rest).
- React: `BoardConfig.launchers` shape, `agent_types`, `concurrency`; new `LaunchBar`, `LaunchApi`, `lib/launch.ts`.

## 10. Select menus inside a modal `<dialog>`

Select menus inside a modal `<dialog>` portal into that dialog (the top layer hid a `<body>` menu) and stay inside its box.
