# Contributing to busyyaks_agents_kanban_module

Issues and pull requests are welcome. By contributing you agree that your contribution is licensed under the
project's [Apache License 2.0](LICENSE) (its section 5), and that you follow the [Code of Conduct](CODE_OF_CONDUCT.md).
A security problem goes to [SECURITY.md](SECURITY.md), never to a public issue.

## Setup

Everything runs in Docker; install nothing on the host but git and Docker.

```bash
git clone https://github.com/robertziel/busyyaks_agents_kanban_module && cd busyyaks_agents_kanban_module
# the pre-commit hook: overcommit in Docker (RuboCop, ESLint, Prettier, gitleaks, ShellCheck on the staged files)
git config core.hooksPath .githooks
# sign the hook config: once per clone and per worktree, and after every change to .overcommit.yml or a hook script
scripts/hooks/run sign
```

`.overcommit.yml` is signed: until `scripts/hooks/run sign` has run in this worktree, every commit is refused. Read a
changed `.overcommit.yml` (or `scripts/hooks/*`) before you sign it. Details: [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md).

## Tests

```bash
scripts/ci/test.sh all           # lint · ruby-sqlite · ruby-pg · react · secrets — what CI runs; needs only Docker
scripts/ci/test.sh ruby-sqlite   # one stage: lint | ruby-sqlite | ruby-pg | react | secrets
```

A pull request is reviewed once `scripts/ci/test.sh all` is green: the Ruby port on SQLite **and** Postgres, the
React port, lint and the secrets scan.

## Rules for a change

- **This repo is the source; hosts vendor it.** A host (busyyaks first) copies `ruby/`, `react/src/` and `fixtures/`
  at a pinned commit and never edits its copy. So every module change lands here first, with its tests; each host
  then re-vendors the new commit in a pull request of its own (busyyaks: `scripts/vendor-kanban-engine.sh`).
- **Both ports move together.** A rule in [`SPEC.md`](SPEC.md) holds in Ruby and in React; change the spec, both
  ports and the shared `fixtures/` in the same pull request.
- **Host specifics are config.** No host name, path, column label or model in the module's code: a host difference is
  a key in [`config.example.yml`](config.example.yml) (documented there), and a board shape is data
  ([`board.example.yml`](board.example.yml)).
- **Never exclude a check to make it pass.** A failing test, lint cop, type check or secrets finding is fixed in the
  code. Not accepted: `skip`, `.only`, a `# rubocop:disable` or `eslint-disable`, `@ts-ignore`, a todo / baseline /
  allowlist file, a per-file `Exclude:`, a raised limit or lowered coverage floor, `--no-verify`, `|| true` on a
  gate, a deleted or pending test. A rule that is wrong for the project is changed in its config for everyone, with
  the reason next to it.
- **No fallbacks.** When something required is missing, refuse loudly with the reason (an `Invalid` / `Denied`, a
  status and an error body); never substitute a default or a guess.
- **Tests with the change**, and a line under `Unreleased` in [CHANGELOG.md](CHANGELOG.md) for anything a host or an
  operator would notice.

## Commits and pull requests

- One logical change per commit and per pull request; the history is rebased, not merged.
- Subject: `<type>: <what changes>` (types `feat`, `fix`, `docs`, `ci`, `test`, `refactor`), imperative, at most ~72
  characters, e.g. `fix: refuse a move with no transition for the actor`. The body says why, and what was tested.
- A pull request fills in the [template](.github/PULL_REQUEST_TEMPLATE.md): what and why, how it was tested, the
  screenshots of any change to the board's UI.
