# Changelog

All notable changes to busyyaks_agents_kanban_module are recorded here. The format follows
[Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **The comment box stays at the bottom of the card**: in the card dialog the comment box (with the no-listener warning)
  sits at the card's bottom and stays there while the card scrolls, so writing a comment needs no scrolling; a long draft
  scrolls inside the box. A "Write a comment" button, shown on keyboard focus at the top of the card, jumps to it.

## [0.1.0] - 2026-11-25

The first public release, together with [busyyaks](https://github.com/robertziel/busyyaks) 0.1.0 (its reference host;
the two always carry the same version). Pre-1.0 (0.x): the host config keys, the `Api` / `Tools` surface and the
schema steps may still change, each change recorded here.

### Added

- **A type only its lead starts** (`agent_types[].launchable: false`): the Launch bar never offers it and `Api#launch`
  refuses it; its lead's `kanban_spawn` still starts one. **`launch_label`**: the Launch bar button's own text.
- **An ended lead of an old session name is marked old** on the board's no-lead banner (`lead.ended.old_name`).
- **The running lead hears about its workers**: one ping when a worker on its board asks, hands off,
  blocks or ends holding open cards, and on the progress watch's first step. None on a comment, when the lead acted or
  when no lead runs. A session's pings go one at a time: a row that may already sit in its input, then the operator's own,
  then lead pings, then the rest. Lead pings survive the watchdog's release of the worker.
- **The progress watch covers an approved gate card its agent must carry on**; at its last step the card waits for the
  operator instead of counting as "agent on it".
- **Hermes's dangerous-command panel is a session dialog**: `SessionDialog.parse` reads it from real
  screens (digits answer it; its countdown is never hashed; "Show full command" is shown, never clickable), and the
  notifier's dialog scan also reads a session whose screen shows `blocked` (Hermes keeps no status record).
- **On hold** (schema v15): the operator parks a card where it sits — `Store#hold` / `Api#hold`
  (`cards.on_hold_at` / `on_hold_by`). A held card keeps its column and leaves the flow: the board's normal view (the
  header's "On hold · N" toggle shows the held cards in the same columns), every count, waiting list and watch, and
  every agent's sight (Tools answers "no card N" through any field; `kanban_board` leaves it out). Putting it on hold
  releases its owner session and assignee and drops its pending pings; only the operator moves it; a terminal column
  ends the hold; released, it returns ownerless to the bottom of its column for the lead to adopt. React:
  `KanbanApi.hold?`, `BoardView.onHold?`, the card dialog's Put on hold / Release hold.
- **Attachments as one row of miniatures**: the card dialog's Attachments section is one sideways-scrolling row of
  tiles, newest first (`newestFirst`), the newest marked "latest"; each tile's caption has its file name, time and a
  link to the comment that shows it (`commentOf`); deleting a file a comment shows says that comment keeps a broken
  link. Pictures and videos open the lightbox, which now has a Delete (a picture or video
  tile has no delete of its own); any other file downloads and keeps a ✕ on its tile. An "attached" event whose file no
  comment shows keeps the tile in the timeline, also with details hidden (`eventFiles`). Runs of pictures in markdown
  render as one row (`kb-att-strip`, `AgentsKanban::Markdown#strips`). A tile's comment link (and every comment
  reference) lands on the entry: an instant scroll, top-aligned when the entry is taller than half its scroll box, the
  entry focused; re-aligned while the pictures above it load, for `JUMP_SETTLE_MS` (5 s) or until the reader scrolls,
  taps or types (`jumpTo`, `lib/card.ts`) — a picture loading later no longer moves the view.
- **Video player in attachments**: mp4 and webm attachments (`video/webm` is a new allowlist type, recognised by its
  EBML header's `webm` DocType; Matroska is refused) carry `video: true` in the attachment JSON and are served inline
  (`AttachmentPolicy::INLINE_VIDEOS`, `INLINE`). The card dialog shows each as a first-frame thumbnail with a play
  button; a click, or a click on its file chip in a comment, plays it in the lightbox with the browser's controls. A
  host's page CSP needs `media-src 'self'`; answering `Range` lets the player seek.
- **Workflow miniature**: the board header's Workflow button shows a small square icon (24 px, the button one header
  control high) before its "Workflow" label: a chunk of the board's real workflow tree, for illustration — the editor's
  own drawing (`layoutGraph`: the column cards with their type tiles, the arrows) through a square window on the
  board's first two columns (`miniCrop`); its title gives the counts. `WorkflowMini`, `miniCrop`, `miniLayout`,
  `MINI_PX` (24) exported.
- **Approve with rebase**: an approval whose green CI answer carries `rebase: {state, base, base_sha}` (the PR
  conflicts with its base) is accepted and marked needs rebase (card JSON `needs_rebase`); the one approve ping tells
  the owner to rebase, re-run CI and merge on green; its onward move waits until the step's checks are green with no
  conflict (`Store#rebase_watch_pass` clears the mark on the watch pass). A forced approval marks nothing.
- **Approved and carried on**: a gate card the operator approved whose next step is its agent's named transition
  (Awaiting merge after the final Approve) no longer counts as waiting for the operator. The boards, `Api#waiting` and
  `Store#waiting_counts` / `#waiting_cards` carry it apart as `approved`; card JSON `carried_on`; `Board#agent_next`;
  the board header says "N approved · agent on it" and the card face "✓ approved · <owner> merging". SPEC § 9.
- **Force approve**: the card dialog shows a **Force · skip CI** button (a dashed warning-hue pill with a skip icon)
  beside every approve button on a host with `approval.requires_green_ci` — the same approval without the green-CI
  gate. `Store#approve(force: true)`, `Api#approve` body `force: true` (operator only; no MCP tool; an agent move with
  `force` is `Denied`; refused on a host without the gate); the activity ends "(forced: CI not asked)" and the owner's
  ping says to take the next step only once the PR's checks are green. `KanbanApi.approve(id, approved, force?)`.
  SPEC § 4 + § 6.
- **Card-face picture**: decorated cards carry `media` = their newest live picture attachment (`{id, filename, url}`;
  png / jpeg / gif / webp, newest by `created_at` then id; `null` when none). The board face shows it under the cover
  at a fixed height, lazily loaded. SPEC § 4.
- **Working glow**: the optional `KanbanApi.boardLive(slug)` port (one answer for the whole board, polled every 3 s)
  makes a card whose owner session is working with a phase read off its screen (thinking · tool · writing · subagents)
  glow blue (`.kb-card.agent-working`, new token `--ak-working`). No glow without that evidence, for a card in a
  `done` / `cancelled` column, after a failed poll (the header shows `agents · <reason>`), after a board switch until
  the new board answers, or when no answer came for 2 polls (`agents · live state unknown`); needs-you wins; steady
  under reduced motion. `useLivePoll` takes `{key, staleAfter}`. SPEC § 1.
- **Agent faces**: `AgentFace` draws every agent identity as two eyes on a disc in its type's colour
  (`--ak-face-type-<type|role>`), its mood from the live state shown by the eyes alone (CSS only; a still pose under
  reduced motion). `Avatar`: an agent wears its face; a person shows their picture from `avatar_url`, else the initials.
  The card and board JSON carry `agents` (agent name → registered type; the newest registration wins); `owned_cards`
  adds `agent` and `type`.
- **Presence**: `Store#presence(slug, live:)` = the registered sessions at work on each card now (`why`: `blocked` on a
  dialog there · `tool` its running tool names the card · `activity` it wrote on the card this turn; ownership alone is
  not presence). The card dialog shows one small label per present agent (`AgentsAtWork`); the optional
  `KanbanApi.boardPresence(slug)` port puts their faces on the card faces. SPEC § 9.
- **The PR watch**: a `ci:` port that answers the optional `closed_prs(card)` → `[{role, number, closed_at, why} |
  {error}]` has every unarchived card outside a terminal column asked on each notifier watch pass
  (`Store#pr_watch_pass`, `Notifier#pr_watch`); a PR closed without merging is told ONCE per close (`ci_watches` kind
  `pr_closed:<role>`, ref = `closed_at`): a comment by `system_author` on the card and a `pr_closed` ping to the owner
  session, with the host's reason. A PR the port could not read (`{error}`) is said beside the closes; a close with no
  positive `closed_at` or a blank `why` is refused, never told. SPEC § 9.
- **`<Board summary="folded">`** and **`<LaunchBar compact>`**: a folded header — waiting for you /
  waiting for CI first, the empty columns behind `+N empty`, columns sharing a `<Group>: ` label prefix as one pill
  (`foldSummary`) — and smaller `＋ <Type>` launch buttons. Both optional; the defaults render as before. SPEC § 6.
- **A `stuck` CI answer**: the approval gate's `approval_checks` may answer `state: "stuck"` (a check
  pending longer than the host allows). It holds the gate and is red like `failure`: the gate watch pings the owner once
  per `finished_at`; refusals say "CI is stuck". A handoff asks the port with `handoff_ci_url` (its `ci_url`, not written
  yet) on the card — a key only a handoff carries — so a host can refuse a build URL that is not the head's at the handoff
  and never on an Approve.
- **`<Board cardTerminals>`**: an optional host renderer for the card dialog's **Terminals** section
  (the card's agent sessions as live terminals); absent or `null` for a card = no section. `KanbanHostValue.cardTerminals`.
  `Store#card_sessions(id)` (the open registrations working on a card) and `Store#terminal_event` (a `terminal` audit
  event on every card a registered session owns).
- **The live agent line**: an optional `KanbanApi.sessionsLive(id)` port; the open card dialog
  polls it and shows what the owner session does now (thinking / writing / running a tool / writing a comment on this
  card / waiting for you / idle, with the turn's time and tokens) above the newest comment, and a pulsing dot on each
  running session's newest comment. SPEC § 9.
- **`kanban_pr_assign(id, pr_url, role, author)`**: the agent that opened a PR assigns it to its
  card — metadata `prs.<role>` = the URL, merged into the card's metadata (`Store#assign_pr`). The MCP instructions
  tell agents to call it at once after opening a PR; a host reads a card's PRs from it, never from branch names or text.
- **PR roles port**: `Store.new(prs:)` → `pr_roles(card)` → `{role => {repos:, required:, error:}}`;
  `kanban_pr_assign` refuses a role the host does not read, a PR on a repo its role does not take, a PR already on
  another card; an agent cannot move a card out of a working column into review / a gate / done while a required role
  has no PR (an operator drag is never refused: its move line says `(dragged: no <role> PR)`). SPEC § 1, § 9 (v14).
- **The PR watch keys each PR**: `closed_prs` may name a PR's `repo`; the watch key is
  `pr_closed:<role>:<repo>#<n>` (several PRs of one role are several closes), a close recorded under the older
  `pr_closed:<role>` key is not told again.
- **`kanban_pr_unassign(id, pr_url, author, reason)`** + `Api#pr_unassign`: the only way a PR leaves
  a card; the reason is logged and the entry kept in metadata `prs_removed`. An agent unassigns its own assignment or
  any on a card it is the assignee of; the operator any.
- `Store#unassigned_pr_mentions`: the PR URLs open cards name in their own text but do not hold —
  a read-only report for a human to confirm (a PR is never assigned from text).
- React `CardLink.unassign` + optional `KanbanApi.prUnassign(id, prUrl, reason)`: the operator's
  unassign action on an assigned PR's rail row — the "×" opens one line in the row, reason + Unassign (Enter sends,
  Escape cancels, a refusal is said under the box); no browser prompt / confirm.
- React `CardLink.group` + `LinkGroup.fold`: the rail lists PRs per role ("PRs · local", the tag
  repeating the role left out) and never folds them; a PR row's `#N <repo>` label wraps at `_ - . /` instead of being
  cut; `CardLink.struck` draws history (a removed PR struck through, one line); chip
  text reads ≥ 4.5:1 on its tint; on a phone the rail spans the dialog's side columns.
- **Ruby port** (`AgentsKanban`, Ruby 3.4, Sequel on SQLite or Postgres): `Store` (cards, activity, labels,
  checklists, due dates, covers, parent cards, metadata), `BoardRepo` (each project's board in the database: columns,
  column types, named transitions; seeded from a template), `Schema` (migrations a host pins step by step), `Api` (the
  operator API, every method `[status, body]`), `Tools` (the `kanban_*` MCP tools and their instructions, worded from
  the host's config), `Attachments`, `Markdown` (server-side, raw HTML dropped), `CardLinks`, `BacklogMd` (read-only
  Backlog.md tasks).
- **Column types** that carry every rule (workflow v3, a fixed set): `parked`, `queued`, `working` (several per
  board), `review` (review rounds counted per column, a configurable limit), `gate`, `done`, `cancelled`.
- **Gates**: agents hand work over only through `kanban_handoff` into a gate; a gate's one forward operator exit is
  the approval; an agent leaves a gate only once approved; an approval can wait for green CI. Approval CI is read
  ahead for every gate card (`Store#approval_prefetch_pass`), a handoff into an approval gate is refused until that
  step's checks are green, Approve is refused on commits pushed after the handoff, and a card counts as waiting only
  while its Approve would pass (`Store#gate_hold`, schema v10).
- **Flags** instead of a Human input column: `kanban_ask` flags a card `needs_operator` where it sits (the operator's
  comment answers it), `kanban_block` / `kanban_unblock` flag an external blocker with a reason and a URL; flagged
  cards refuse agent moves, count as waiting for the operator and get one reminder after `flags.reminder_hours`.
  `BoardRepo#migrate_v3!` moves stored v2 boards (ask column → flags, handoff / approved → gate).
- **Column rename**: `BoardRepo#rename_columns!` renames column keys / labels and transitions on every stored board
  that holds them, the cards, their review rounds and their move entries following; the inverse maps undo it.
- **Agent sessions**: a registry of the sessions working each board, launches with concurrency caps per type and
  project, adoption and spawning by column type, a watchdog that releases the cards of a session that is gone.
- **Notifier**: types the operator's comments and answers into the owning session, and turns a session stopped on a
  permission dialog into a question on its card (`SessionDialog`), answered from the board.
- **React port** (React 18, TypeScript): `Board` (drag and drop, filters, list menus, keyboard shortcuts), `CardDialog`,
  `BoardEditor` (the workflow graph, laid out left to right by `@dagrejs/dagre` — the port's one runtime dependency, a
  host adds it to its package.json — with edge labels placed off the nodes and many-to-one transitions drawn as one
  bundle or a note, the ranks folded into rows so the whole board fits its box at ≥ 11 px text; `lib/graph` exports
  `layoutGraph` (= `foldGraph(rankGraph(…), maxWidth)`: dagre once, a fold per box width), `withMoved`, `planTransitions`, `pathOf` (a polyline with rounded corners), `wrapLabel`,
  `MIN_TEXT_ZOOM` in place of the hand-layout helpers `drawableEdges`, `edgePath`, `fitViewBox`, `nextPosition`,
  `NODE_W`, `NODE_H`), `MarkdownEditor`,
  `LaunchBar`, over injected `KanbanApi` / `LaunchApi` ports;
  `kanban.css` themed through `--ak-*` tokens.
- **Schema v9**: `board_columns.x` / `y` dropped — the graph layout is automatic and never stored; a board column is
  `{key, label, type, hide_after_hours?}` (an `x` / `y` is refused as an unknown key; `Board.auto_layout` is gone). A
  host pins it with a new migration (`Schema.migrate!(db, to: 9)`, rollback `Schema.restore_xy!`).
- **Host config** (`config.example.yml`): launchers, agent types, caps, gates, timings, table prefix, theme, every key
  documented and validated at load. The example is generic: no host names, no model names, `max_sessions: 0`. An
  agent type with no launcher given takes its `spawn_launcher`, else its only launcher, else the launch is refused —
  never a launcher the code picks.
- **Quality gates**: `scripts/ci/test.sh all` (RuboCop with Cookpad's style guide, ShellCheck, the Ruby suite on
  SQLite and Postgres with coverage floors, TypeScript, ESLint, Prettier, vitest, dependency audit, gitleaks) in
  Docker; a signed overcommit pre-commit hook; GitHub Actions runs the same `all` on the public repo.
- Community files: [SECURITY.md](SECURITY.md), [CONTRIBUTING.md](CONTRIBUTING.md),
  [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md), issue and pull request templates, and [NOTICE](NOTICE).

### Fixed

- **CI: the React suite runs alone**: `scripts/ci/test.sh all` runs lint, both Ruby suites, audit and secrets at once,
  then `react` with the runner to itself. Beside the two Ruby suites it shared GitHub's 4 vCPUs and random tests timed
  out: runs 44430241873 (`feature/card-pr-lists`, 2026-11-19) and 45395693342 red, 45401030980 green with this change
  (`test.sh all` 2 min 11 s).
- **The Links rail never grows wider than itself**: a row's chips wrap among themselves and a chip
  wider than the row ends in an ellipsis (the popover has the full text); the rail's grid track is its own width. Many
  chips, or a long one (`base: feature/live-agent-status`), scrolled the whole rail sideways on a phone, its labels cut.

### Changed

- **Agent-facing text**: no tool text tells a session that was not launched to register itself: `kanban_register` is
  "only when the operator explicitly asks you to"; a session started by hand works the board only when the operator asks.
- **Green CI is a gate column's setting, off by default**: `requires_green_ci: true` on a GATE
  column (Board, Schema v16 `board_columns.requires_green_ci`, `rules.green_ci`, the editor's "Requires green CI"
  checkbox, the gate's card "waits for you · CI") makes the approval out of that gate and a handoff into it wait for
  green PR checks — the prefetch, gate hold, gate watch and Force exist only there. **Breaking**: the host config's
  `approval` key is removed and refused, naming the move; after the v16 migration no gate asks CI until its board sets
  it. A Store without a `ci:` port refuses to save a board that sets it. README § Use case: a gate that waits for green CI.
- **Board header, one grid**: summary pills, tools and filter controls share one height (28 px) on one row pitch; the
  summary rows sit over the filter row and the tools (live · Archived · Workflow · ?) end that row. Under 760 px it is
  one column: summary, filter, tools on one row. DOM (Tab) order = reading order: summary, filter, tools. The filter
  (`.kb-filter`) and the new `.kb-tools` are children of `.kb-head`; the header's `.spacer` is gone.
- **The idle watch skips only the card whose PR the `ci:` port cannot answer**: `[id, "CI skipped: <why>"]`
  for that card, the others still pinged — one bad assignment no longer silences the watch for every project.
- **Public: Create PR** on the private local-repo board (`fixtures/boards/local_v4.board.json`): "Open public PR" moves
  the card from Local: Deploy check into the new working column Public: Create PR, where the agent opens the public
  PR; the agent's "Public PR opened" moves it on to Public: Agent review; Cancel and Rework list it.
  `local_v3.board.json` is kept, frozen.
- The approve button names its step ("✓ Open public PR → Public: Create PR"), not always "Approve"; `ApprovalStep.name` is a
  `string` (a step is a named transition), no default.
- `splits(items, k, fits?)` has no cap: it yields only the splits whose runs fit, so the height fold searches every
  width-feasible split. `foldRows(base, rows)` is exported (one fold of a given split).
- The workflow graph's fold takes the box height too (`foldGraph(base, maxWidth, maxHeight)`): of the splits into rows
  that keep the width, the one that fits the height best — the 15-column local board shows whole at 1920 × 1080.
  Splits too wide are skipped undrawn; the editor re-folds 120 ms after a resize settles.

### Changed (breaking for hosts)

- **BREAKING: `Store.new` requires `prs:`** — the PR roles port, `pr_roles(card)` →
  `{role => {repos:, required:, error:}}`; without it the Store raises `ArgumentError` at construction. Migration: pass
  `prs:` (a host whose cards carry no PRs passes an object whose `pr_roles` answers `{}`). A host that wrote
  `metadata.prs` itself moves to `kanban_pr_assign` / `Store#assign_pr`.
- **BREAKING: a card's PRs are a list — Schema v14** (a card changes several repos and every
  PR must show). Metadata `prs` was `{role => url}` (one PR per role, re-assigning replaced it); it is now
  `[{url, repo, number, role, by, at}]` and `kanban_pr_assign` ADDS (it never replaces). A host that reads
  `metadata.prs.<role>` reads the list instead (every entry of the role). Migration: a host migration
  `Schema.migrate!(db, prefix:, to: 14, prs: <the Store's PR roles port>)` (= `Schema.prs_to_lists!`: text naming several
  PRs → one entry each, a role key the host does not read → the one host role whose repos hold the PR's repo, a PR in no
  role → `prs_removed` only when the port's optional `unread_reason` says why, anything else raises; rollback `Schema.prs_to_roles!`, refused while a card
  holds what v12 cannot); a `{role => url}` left unconverted is refused on read.
- **`face_roles` and `avatar_url` are required host-config keys** (null allowed; a bad value fails at load):
  `face_roles` = null or `{role: [name globs]}` (a subagent whose name matches wears that role's colour);
  `avatar_url` = null or an https template with `{sha256}` (the SHA-256 of the trimmed, lower-cased email, e.g.
  Gravatar with `d=404`). Add both before upgrading.
- **`SessionsLive.present` is required**: a `sessionsLive` answer without the `present` list is a failed read (the
  dialog says so), never "nobody is here".
- **The workflow graph runs top to bottom, as a flowchart**: `BoardEditor` draws each column as a
  card (type icon tile, label, mono type line, a status pill from `typeBadge`) on a dotted canvas; dagre lays it out
  top to bottom along the board order (branches side by side), every route orthogonal with its label as a pill on the
  line, a route against the board order dashed. `lib/graph`: `layoutGraph(columns, transitions, {typeLabel, badge})`
  is the whole layout (`typeLabel` required; a node dagre leaves unplaced throws; no fold: the graph scrolls down);
  `rankGraph`, `foldGraph`, `foldRows`, `splits` and the
  `maxWidth` / `maxHeight` options are gone; `Layout.rows` is gone; `Route.ortho` is replaced by `Route.back`. `Layout.warnings` lists what the drawing
  could not keep (shown in the editor); `LayoutOpts.retries`; `Layout.tries` counts the dagre layouts it took; `wrapLabel` wraps onto as many lines as a label needs;
  a dragged card's routes stay orthogonal (`withMoved`); the port is on the card's right side, live only on the card in
  focus. New
  exports: `typeBadge`, `labelW`, `nodeH`, `subY` and the card's offsets (`TILE`, `TILE_X`, `TEXT_X`, `TITLE_Y`, …).
- **`launchers[].kind` is required**: the CLI family the command is, one of `Launch::KINDS` —
  `claude_code` (the argv every launcher had so far: `--model`, the prompt, `--remote-control <session>` LAST) or
  `hermes` (`-m <model>`, `-q <prompt>`, no remote control). A host config without it fails `HostConfig` with
  `launchers[<key>].kind must be one of claude_code, hermes (got nil)`. **Migrating:** add `kind: claude_code` to
  every launcher — the argv stays byte for byte what it was. `Launch.argv` takes the prompt as `prompt:` (a host
  that passed it in `extra:` gets the same argv for `claude_code`; `hermes` needs `prompt:`), and `Launch.plan`
  carries `kind` + `remote_control` (what the host checks came up).
- **`CardLinks` runs no git.** `CardLinks.build` takes a required `git:` port (`branches`, `default_ref`, `files_at`;
  SPEC § 1): a checkout's repo config can make the git CLI run programs (filter drivers, textconv, fsmonitor), so how
  a host reads it — and inside which limits — is the host's. `CardLinks.branches`, `file_at?`, `default_ref` and
  `GIT_ENV` are gone; a host that passes no port fails on the first build (`ArgumentError`).

[0.1.0]: https://github.com/robertziel/busyyaks_agents_kanban_module/releases/tag/v0.1.0
