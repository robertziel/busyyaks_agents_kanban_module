# Changelog

All notable changes to busyyaks_agents_kanban_module are recorded here. The format follows
[Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed (breaking for hosts)

- **`launchers[].kind` is required**: the CLI family the command is, one of `Launch::KINDS` —
  `claude_code` (the argv every launcher had so far: `--model`, the prompt, `--remote-control <session>` LAST) or
  `hermes` (`-m <model>`, `-q <prompt>`, no remote control). A host config without it fails `HostConfig` with
  `launchers[<key>].kind must be one of claude_code, hermes (got nil)`. **Migrating:** add `kind: claude_code` to
  every launcher — the argv stays byte for byte what it was. `Launch.argv` takes the prompt as `prompt:` (a host
  that passed it in `extra:` gets the same argv for `claude_code`; `hermes` needs `prompt:`), and `Launch.plan`
  carries `kind` + `remote_control` (what the host checks came up).

### Changed

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

## [1.0.0-beta.1] - 2026-11-10

Everything below ships as **1.0.0-beta.1**, the first public release, together with
[busyyaks](https://github.com/robertziel/busyyaks) 1.0.0-beta.1, its reference host. A beta (a SemVer pre-release):
the host config keys, the `Api` / `Tools` surface and the schema steps may still change before 1.0.0, each change
recorded here.

### Changed (breaking for hosts)

- **`CardLinks` runs no git.** `CardLinks.build` takes a required `git:` port (`branches`, `default_ref`, `files_at`;
  SPEC § 1): a checkout's repo config can make the git CLI run programs (filter drivers, textconv, fsmonitor), so how
  a host reads it — and inside which limits — is the host's. `CardLinks.branches`, `file_at?`, `default_ref` and
  `GIT_ENV` are gone; a host that passes no port fails on the first build (`ArgumentError`).

### Added

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

[Unreleased]: https://github.com/robertziel/busyyaks_agents_kanban_module/commits/main
[1.0.0-beta.1]: https://github.com/robertziel/busyyaks_agents_kanban_module/releases/tag/v1.0.0-beta.1
