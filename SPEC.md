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
| checkout (git) | `git:` on `CardLinks.build` (required, no default — the engine runs no git): `branches(project)` → Set of branch names (local + remote-tracking, remote dropped), `default_ref(project)` → the checked-out branch ("HEAD" when detached / unborn), `files_at(project, refs, files)` → `{file => first ref that has it}` (paths with `..` are never asked); a port that cannot read the checkout raises | — |
| navigation | `card_path:` on `CardLinks::Refs`; `card_url: ->(slug, id) { absolute URL }` on Tools (required): every card a tool returns carries it as `url` | `navigate`, `projectHref`, `cardHref` props; `view` / `onView` own the URL |
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

**Column types** (`ColumnTypes`): what a column DOES. Changing a column's type changes its rules.

| type | flags | the rules it carries |
|---|---|---|
| `parked` | — | nobody listens; agents may create here; a gone owner is released in place; `dependencies.promote.from` (Backlog, Waiting) |
| `queued` | listened · one per board | released work cards return here (`gates.watchdog.to`); `dependencies.promote.to`; a spawner type's cards (To do, Queued) |
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

**Actors** are not a column field: who acts in a column follows from its type and its transitions' `by` — a gate is
the operator's (only the operator's step leaves it), a review / working column belongs to whoever holds the named
agent edges out of it (the host's prompts name the Reviewer Agent for an agent-review column, the Author Agent for an
author-response column), parked is the operator's, queued the lead's / spawned worker's. Local v3: Backlog —
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
`review_columns`; the watchdog's watched columns = the listened ones; `spawn_columns` = the columns of the types some
agent type `spawns_for` (in a gate only an APPROVED card is spawned for — an unapproved one waits for the operator).

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

### 2b. The host config — `HostConfig` (all keys required; `idle_watch` / `handoff` / `approval` / `owner_sessions` / `review_loop` may be null)

| key | the rule it drives |
|---|---|
| `priorities`, `label_colors` | the enums (`gray` required) |
| `system_author` | signs engine entries (`watchdog`, `ping`, dialog `question`, the template's copies), prefixes pings `[name]` |
| `attachment_url_prefix` | `<prefix>/<id>` (view) and `<prefix>/<id>/download` in JSON, snippets, rendered markdown and the comment→attachment claim |
| `launchers` `[{key,label,kind,command,args,via_shell}]` | the COMMANDS: `Launch.argv(config, type:, launcher:, prompt:)` is built by the launcher's `kind` (`Launch::KINDS`, one class per CLI family): `claude_code` = `[command, *args, ("--model", model), *extra, prompt, "--remote-control", session]`; `hermes` = `[command, *args, ("-m", model), *extra, ("-q", prompt)]` (no remote control); wrapped in `bash -ic` when `via_shell`. `args` / `extra` may set no option the kind sets itself (claude_code: `--model`, `--remote-control`; hermes: `-m`/`--model`, `-q`/`--query`/`--query-file`); claude_code's appended pair is LAST and wins (Claude Code takes a repeated option's last value — measured on 2.1.317). `Launch.plan` carries `kind` + `remote_control` (what the host checks came up) |
| `agent_types` `[{key,label,launchers,model,prompt,agent_name,session_name,takes,max,max_per_project,spawns_for?,launcher_follows?,spawn_launcher?}]` | WHAT a session is (the library ships none). `launchers`: the keys it may run (no default: a start names one — the UI's menu, `Api#launch`'s `launcher`, `kanban_register`'s `launcher`); `model`: `--model` value or null, or a map launcher key → value / null naming every launcher of the type (`AgentType#model_for`: a gateway launcher picks its own model); `prompt`: template typed after the start or null, placeholders `{slug} {dir} {session} {agent} {type} {cards}`; `agent_name`: the author name the session acts as, must contain `{session}` (`Store#session_for_author` resolves it back); `session_name`: the tmux name (must contain `{slug}`); `takes`: column TYPES whose ownerless cards the session ADOPTS at registration and from then on (the intake rule, `Store#adopt_ownerless`, on every board's columns of those types; fewest owned cards wins; the new owner is pinged); `spawns_for`: column TYPES whose ownerless cards each get ONE NEW session of this type (`Api#spawn_pass`: on an operator move into the column at once, and on every notifier pass; in a gate only an APPROVED card — the unapproved ones stay the `takes` sessions'; a full cap → the card waits with a note; a failed start → released, retried after `Store::SPAWN_RETRY_S`; one spawner type per column type); `launcher_follows` (optional): another type whose RUNNING session for the same board decides this type's launcher (`Store#launcher_for!`, in `Api#launch` and `Api#spawn_pass`: the newest running session of that type on the board; another launcher asked for → `Denied` 422, never swapped; none running → the type's own; must list every launcher of the followed type, one level only); `spawn_launcher` (optional): the launcher a start the ENGINE performs runs when none is named (a spawn with no session to follow, `Api#launch` / `Launch.argv` without `launcher`) — never a hand-started session's (`kanban_register` without `launcher` takes the type's only launcher, else is refused: the engine cannot know what runs it); must be one of the type's `launchers`; absent → a type with ONE launcher runs it, a type with several refuses (`Invalid` with the keys; a spawn's card waits with the note `spawn refused: …`) — the engine never picks one of several; `max` / `max_per_project`: caps (null / 0 = none) |
| `concurrency` `{max_sessions}` | registered agent sessions running at once on the host: `Store#launch_check!` refuses the (N+1)th with who runs; `Store#concurrency` is the UI's `running / cap` |
| `owner_sessions` | `null` or session-name globs: `Store#set_owner` / `#claim` refuse a session that matches none; the React owner picker lists only matching sessions |
| `idle_watch` | `null` or `{ci_ping_after_minutes (N), ci_comment_after_minutes (M), owner_idle_hours (X)}` on every board's WORKING column (`Store#idle_watch_pass`, needs the host's `ci:` port): PR checks all finished and no non-system activity for N min → ONE owner ping per CI completion, M min later still silent → ONE comment by `system_author`; a live owner with no activity and no commit for X h → ONE comment per idle stretch |
| `handoff` | `null` or `{requires_pr_url, requires_ci_url, qa_min_chars, ui_change_needs_screenshots}`: what `Store#handoff` requires on a board with a gate column (`qa` ≥ `qa_min_chars`, http(s) URLs required per flag, ≥ 1 picture attached when `ui_change` and the flag). A gate column on a host with `null` is refused on read |
| `approval` | `null` or `{requires_green_ci}`: `true` = every explicit approval (`Store#approve` = the Approve button, or `Store#move` with the step's own transition name) asks the host's `ci:` port (`Store.new(ci:)`, `approval_checks(card, step)` → the `pr_checks` answer for the PR that step is about; `step` = `{from, to, then, name, final}`) and is refused (`Invalid`, nothing moved or logged) unless `state` is `success` (an answer's `reason:` = the host's own refusal, e.g. a prerequisite PR not merged, said instead of the CI wording): no PR, `pending`, `failure`, not read yet, no checks, or the port raising `Delivery::Unavailable` → the refusal names the step, the PR and what it saw. A Store built from such a config without that port raises `ConfigError`. **Prefetch** (Approve never waits for a CI read): the same question is asked, its answer discarded, for a card handed off into a gate an approval step leaves from (`Store#handoff`: see **Handoff on green CI**) and, on every `Notifier#watch` pass, for every unarchived card sitting in such a gate (`Store#approval_prefetch_pass` → `[[id, state \| "no PR" \| "unavailable: <why>"]]`; an unavailable one is logged once per change of reason and once when it answers again, the others still asked) — a host that answers asynchronously (a poller answering recent requests) keeps every gated card's answer fresh; a card that left the gate is no longer asked; the same pass is the gate watch (§ 9, Schema v10: approvable now). **Handoff on green CI**: a `kanban_handoff` into a gate an approval step leaves from asks the same question BEFORE anything is written, for the card as it will sit there (the gate's column, the handoff's `pr_url`), and is refused (`Invalid`, nothing written) unless `state` is `success`: `not handed off (→ <gate>): <PR> of card #N — <state>; hand off once CI is green` (unread → "CI not read yet (asked now — hand off again in a minute)", the port unavailable → "CI state … is unknown"). So a card in such a gate is green when it arrives, and the operator's Approve answers at once |
| `dependencies` | `true` = parent dependencies are ENFORCED on every board (`Board#rules.dependencies`); `false` = parents are recorded and shown only |
| `flags` | `{reminder_hours}`: a card flagged `needs_operator` / `blocked_external` that long gets ONE reminder comment by `system_author` (+ a ping to its owner) per flag (`Store#flag_reminders`, the notifier's watch pass) |
| `review_loop` | `null` or `{max_rounds, unresolved_label, unresolved_color, columns}`: `columns` = the LOOP columns (review column keys; any other review column — a coding board's QA — counts no rounds and has no limit). Entering a loop column from a work column or a gate counts a ROUND for it (`cards.review_rounds`; entering a work column by any move other than a named agent edge of the REVIEW column left — Rework out of a review column or a gate, Deploy failed, Start work (also after the operator parked a card at the limit in To do / Backlog) — starts over); at `max_rounds` an agent's loop move (loop → work, work → loop) is `Denied` naming the gate to hand the card to, and a handoff out of the loop column must give `review_summary` — the reviewer's SUMMARY counts `{fixed, resolved_by_argument, needs_human, open}`, integers ≥ 0, exactly those keys (missing or malformed → `Invalid`): it puts `unresolved_label` on the card (created on the board with `unresolved_color` when missing) only when `needs_human + open` is above 0, and the handoff line names the counts. The operator's move from a gate into the work column a loop column feeds by a named agent edge (Changes requested) allows exactly ONE more round of that loop (`review_rounds._rereview`), then the card goes back to the gate without the label; so does the operator's drag from the loop column itself into that work column once the rounds are used up (no gate is reachable from the work column: the limit would leave the author no move) — below the limit that drag changes nothing. The "0 open threads" exit is the agents' rule (the host's prompts): the engine counts rounds, it reads no review threads. `null` = every review column counts rounds, nothing limited |
| `table_prefix` | `""` or `[a-z][a-z0-9_]*_`; the engine's tables are `<prefix>cards` … |
| `theme` | `{"--ak-*": value}` (an allowlist of CSS value characters, quotes paired, parentheses balanced, no `/*`; refused at load) applied as inline custom properties on the board's `.ak-root` and copied onto every Select menu from its trigger; `--ak-board-height` fixes the board's height |

`HostConfig#digest` = sha256 of the canonical JSON the client receives (`to_h`); a host may pin it.

## 3. Tables (`Schema`, v10)

`cards` (+ `parent_id`, `metadata` JSON text since v2), `card_activity`, `board_labels`, `checklists`,
`checklist_items`, `card_pings`, `card_attachments`, `session_dialogs`, `agent_sessions` (v3: `session`, `socket`,
`project_slug`, `type_key`, `launcher_key`, `agent_name`, `launched_by`, `launched_at`, `last_seen_at`, `ended_at`,
`end_reason`), `ci_watches` (v4), `boards` / `board_columns` / `board_transitions` (v6, § 2a; `project_slug ""` = the
template; v7 adds `board_columns.hide_after_hours`, null = the type's default; v8 adds the card FLAGS — `blocked_at`,
`blocked_author`, `blocked_reason`, `blocked_url`, `flag_reminded_at` (`needs_operator` is `asked_at`) — and
`review_rounds` (JSON `{review column => entries}`); v9 drops `board_columns.x` / `y` (the editor lays the graph out,
nothing about it is stored); v10 adds `cards.gate_head` (the approval PR's head the handoff's green answer carried) and
`cards.gate_state` (the last watch pass's view of the card's gate: `ready` or its hold); v5's `workflows` is carried over and dropped by `BoardRepo#seed!`) — epochs as integers. `migrate!(db, prefix:,
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
- A comment claims the author's own unlinked attachments it references; deleting the comment unlinks, never deletes.
- Pings: one pending per card + session (a burst coalesces); never to the owner's own author; `relay` when a card
  gains an owner (the operator's undelivered comments since the last agent comment).
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
  the next step now, then move the card to `then`…"); an ownerless card is left to the spawn rule. The operator's drag
  (a column, or the catch-all edge) is never refused by `approval.requires_green_ci`: it approves, and the `approve`
  entry ends "(dragged: CI not asked)"; an Approve the gate refuses ends ". A drag into <to> approves without asking
  CI". A move into `to`
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
  While either flag is set an agent's move (any, handoff included) is `Denied`; the operator moves freely; the spawn
  queue skips flagged cards (nobody is started for a card waiting for the operator); the watchdog releases a flagged
  card like any other (it stays flagged). `Store#flag_reminders` (every watch pass): a card flagged for
  `flags.reminder_hours` with `flag_reminded_at` null gets ONE `comment` by `system_author` + a ping; a new ask / block
  resets the reminder. `Store#flagged_counts(slugs)` = `needs_operator` cards outside the waiting columns per project;
  `Store#needs_operator?(card)` = an open question; `Store#external?(card)` = blocked_external with no open question
  (`Store#waiting_counts` `external` = those per project — the one count `Api#board` and `#boards` both carry).
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
- Open session-dialog questions are expired (`expire_dialogs`) when the session's screen no longer shows that dialog
  (clear, a different dialog, the session gone): closed by the system author, the card's dialog, question and flag
  cleared; the card stays where it is. An unreadable screen is not a verdict.

## 5. JSON shapes

Card: `Store#card_json` (board face) + `description`, `description_html`, `qa_html`, `question_html`, `checklists`
on a single card; `parent`, `children`, `blocked_by` (the unfinished parents), `metadata`, `transitions`,
`needs_operator` (bool), `blocked` (`{reason, url, by, at}` | null), `review_round` (the rounds in the card's current
review column | null) always. Board: `Api#board` — `columns:
[{column,label,type,operator_only,cards}]`, `labels`, `config` (the host config), `board` (§ 2a: `{columns, transitions,
rules, types, updated_by, updated}`), `archived?`, `backlog_md`, `columns_order`, `waiting_columns`, `listened_columns`,
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
registrations on those projects whose start failed (end_reason `start failed: …` — a launch or a spawn whose claude never
came up) in the last `LAUNCH_FAILURE_WINDOW_S` (a day), the newest `LAUNCH_FAILURES_SHOWN` (10), newest first — a new one
changes the rev, and the React `LaunchFailureAlert` opens a modal `<dialog>` (top layer) for the ids the viewer has not dismissed (a per-viewer id set in localStorage), with the host's `--ak-*` tokens resolved on `<html>`. Board shape: `Api#board_shape` / `#board_shape_save {columns,
transitions}` / `#board_shape_reset` → `Store#board_json`. Single card:
`{card (attachments = list), activity, pings}` + `card_extras`. Launches: `Api#launches(slug)` → `{types: [{key, label,
launchers: [{key,label,model}], model, takes, max, max_per_project, prompt, running, running_here, launcher_follows, follows: {type,session,launcher} | null}], concurrency: {max_sessions,
running, free, sessions, types} | null, sessions_error}`; `Api#launch(slug, {type, launcher?}, by:)` → 201 `{session, type,
launcher, agent, adopted: [card], result (the host's), concurrency}` · 422 refused (the cap, an unknown type) · 503 the
port unreachable; `Api#sessions` → `{concurrency, registered, ended, sessions_error}`. Every refusal: `{error}` with 404 / 413 / 422 / 503.

## 6. React

`<Board api me slug view onView onChanged? navigate? projectHref? cardHref? className? />` renders the board (its
columns from `board.columns`, never a constant) and the card dialog inside `.ak-root` with `config.theme` inline; the
Workflow button opens `BoardEditor`: an SVG graph (`lib/graph.ts`) of the columns as typed nodes and the transitions
as labelled arrows, **laid out by dagre** (`@dagrejs/dagre`, the React port's one runtime dependency, MIT): left to
right along the board order (an arrow against it is drawn back), nodes sized to their full label (wrapped onto two
lines), every edge label a box of its own in the layering so it never sits on a node or another label. Hubs: a
transition with one or two sources is one labelled arrow per source; `BUNDLE_FROM` (3) or more sources, up to half the
columns, join a junction pill carrying the one label with a single arrow into the target; more than half the columns
("Cancel from every state") is a note on the target node, no lines; `"*"` ones are listed, not drawn. **The layout is
automatic and nothing about the drawing is stored** (schema v9 dropped `board_columns.x` / `y`): every open lays the
graph out again. The ranks are **folded into rows** that fit the graph box (`maxWidth` = box width ÷ `MIN_TEXT_ZOOM`;
`maxHeight` = its height ÷ the same: of every split into the greedy fold's number of rows or one more that keeps the
width — all of them, no cap: a split is grown only from rows that fit the width (`splits(items, k, fits)`) —, the one
that fits the height best), so the default view shows the whole board — no horizontal scroll, the zoom (≤ 1) never below `MIN_TEXT_ZOOM` = 11 px ÷
the smallest graph font, i.e. no text under 11 px; an arrow between two rows runs orthogonally through the gutter
between them (its own lane and channel, its label on the gutter run); − / + leave that zoom, Fit returns to it. A node
can be dragged aside for the session only (the arrows follow, Auto-layout puts it back; never saved) — add / rename / retype (Select) / delete a
column (the server's refusal with the card ids shown verbatim), connect two nodes by dragging from a node's port or
"+ Transition", click an arrow, bundle or note to edit name / from / to / by or delete it, ↑ ↓ for the board order
(= the graph's left-to-right order), Save (the whole draft, validated server-side) / Discard / Reset to template; on a
phone the graph scrolls and zooms above the lists. A board read refused (422) shows the reason and a reset button. The card dialog's
"Transition" list = the operator's transitions out of the card's column (`operatorMoves`), sent as `{transition, column}`: one per target, the first declared name — and, on a host with `approval.requires_green_ci`, in a step's `from` BOTH edges into the step's `to`: the step's own (asks CI) and the first other one, labelled "… (CI not asked)" (the free move is never hidden behind the gated one). A card in an approval step's `from` shows the primary approve button (the gate:
"✓ Approve to merge"; a step: "✓ Approve → <to label>"; the tooltip names `to` and `then` from the board); approved in
its `to`, who / when + "Withdraw approval"; unapproved in a `to` that is a gate, the same button approving in place ("the card stays in <to>"; `lib/workflow.ts` `stepAt` / `approveLabel` / `approveTitle` / `approvedNext`). A collapsed list is a drop target: a card dropped on its strip lands at the bottom of that column. `view` = `{card, panel, archived}` — the host keeps it
(e.g. `?card=&panel=&archived=`). `KanbanApi` (react/src/api.ts) is the full list of calls. `<LaunchBar api slug onLaunched? />` renders one split pill
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

## 9. Breaking changes for hosts (config / API)

Newest first; a heading names the `Schema::VERSION` step when the change brought one.

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
