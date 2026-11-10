# Development

Everything runs in Docker; the host needs only git and docker. `scripts/ci/test.sh all` runs every gate below at once.

## Tests

```bash
docker build -t agents-kanban-ruby:dev ruby

# Ruby suite on SQLite, one worker per CPU
docker run --rm -v "$PWD":/app -w /app/ruby agents-kanban-ruby:dev bundle exec rake test:parallel

# Ruby suite on Postgres (one database ak_w<i> per worker)
docker run -d --name ak-pg -e POSTGRES_PASSWORD=t -e POSTGRES_DB=ak postgres:16-alpine
IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' ak-pg)
docker run --rm -v "$PWD":/app -w /app/ruby -e DATABASE_URL=postgres://postgres:t@$IP/ak \
  agents-kanban-ruby:dev bundle exec rake test:parallel

# React: install, then vitest, tsc, ESLint and Prettier (whole repo mounted: the tests read fixtures/)
docker build -t agents-kanban-react:dev react
docker run --rm -v "$PWD/react":/app -w /app node:22-slim npm install
docker run --rm -v "$PWD":/repo -w /repo/react agents-kanban-react:dev npx vitest run
docker run --rm -v "$PWD":/repo -w /repo/react agents-kanban-react:dev npx tsc --noEmit
docker run --rm -v "$PWD":/repo -w /repo/react agents-kanban-react:dev \
  npx eslint --max-warnings 0 --report-unused-disable-directives .
docker run --rm -v "$PWD":/repo -w /repo/react agents-kanban-react:dev npm run format:check

# Lint
scripts/lint/rubocop        # RuboCop 1.92.2 over the whole tree (-a autocorrects the safe offenses)
scripts/lint/shellcheck     # ShellCheck v0.10.0 -S style over every tracked shell script, found by shebang
```

- `rake test:parallel` = one worker process per CPU (`Etc.nprocessors`), each on its own SQLite file or Postgres
  database `<db>_w<i>` (created and dropped by the task). `TEST_WORKERS=files` = one worker per test file whatever the
  CPU count, `TEST_WORKERS=<n>` = n (anything else is refused).
- **Coverage**: every worker records SimpleCov line + branch coverage; the task merges them, prints
  `coverage: line … · branch …` and fails below the floor in `ruby/test/test_coverage.rb` (line 98 % / branch 85 %,
  never lowered; only `test/` filtered).
- `rake test` = the same files serially, unmeasured (`TEST=<file>` for one).
- vitest uses `maxWorkers = availableParallelism()` (`react/vitest.config.ts`).
- ESLint: `eslint.config.js` = typescript-eslint `recommendedTypeChecked` + react-hooks; an `eslint-disable` comment
  has no effect and fails the run.

## Formatting

Prettier, pinned in `react/package.json`, config `.prettierrc.json` (`printWidth: 120`, the rest Prettier's defaults)
and `.editorconfig` (utf-8, LF, final newline, 2-space indent) at the root, over every TS/TSX/JS/CSS/JSON file
(`react/` + `fixtures/`). `.prettierignore` lists only `package-lock.json` (npm writes it). Markdown and YAML are not
formatted. No ESLint rule conflicts with it (`recommendedTypeChecked` + react-hooks carry no stylistic rules), so
there is no `eslint-config-prettier`. `npm run format` rewrites the files.

## Lint

The same rules as busyyaks:

- **RuboCop 1.92.2** + rubocop-performance / -rake / -sequel / -thread_safety (`ruby/Gemfile` `:lint` group — the
  suite image skips it, `BUNDLE_WITHOUT=lint`). Rules = Cookpad's Ruby style guide copied verbatim to
  `config/rubocop/cookpad.yml` (© Cookpad Inc., CC BY 3.0) + `.rubocop.yml` (the four plugin departments on;
  `ThreadSafety/NewThread` off, with its reason). Runs in the `agents-kanban-lint:<hash>` image (`scripts/lint/image`:
  `ruby/Gemfile` + `Gemfile.lock` + `scripts/lint/Dockerfile`).
- **ShellCheck v0.10.0** `-S style` over every shell script found by its shebang (`scripts/lint/shell-files`), no
  `.shellcheckrc`.
- **0 offenses**: a new one is fixed, never disabled, excluded or baselined. The only Excludes are not Ruby code:
  `react/**`, `ruby/tmp`, `ruby/.bundle`.

## CI

`scripts/ci/test.sh lint|ruby-sqlite|ruby-pg|react|audit|secrets|all` — the gates, Docker only, databases in RAM.
`audit` = `bundle-audit check --update` on `ruby/Gemfile.lock` + `npm audit --audit-level=low` on
`react/package-lock.json`; any advisory fails it, fixed by upgrading, never ignored. Two runners run `all`: GitHub
Actions ([`.github/workflows/ci.yml`](../.github/workflows/ci.yml), every pull request — forks included — and every
push to `main`, on public repositories only unless the repository variable `CI_ON_PRIVATE` is `true`; check
`gates` (workflow `ci`)) and Jenkins, the maintainer's runner, on the default branch and the repository's own PRs (at the PR head), posting the `jenkins/ci` status
(any multibranch Jenkins job that reads the `Jenkinsfile`). While a repository is private the check shows as skipped, and a skipped check
satisfies a required one: there, require `gates` only with `CI_ON_PRIVATE` set.

**Trust**: the script needs the Docker daemon, and access to it (`/var/run/docker.sock` or the docker group) is root on
that host; the Ruby stages run the checkout's code as root in a container with the checkout bind-mounted. Run it on a
disposable machine (a GitHub-hosted runner) or a CI host that builds trusted branches only — never a stranger's fork on
a host you care about.

**Gate scripts' tests**: `ruby/test/ci_gates_test.rb` drives `scripts/ci/test.sh` and `scripts/hooks/run` against
throwaway git repos with a stub `docker` and checks every refusal (shallow clone, in-tree `.gitleaks.toml` /
`.gitleaksignore`, a checkout on no mount of the container, no `docker`, `extensions.worktreeConfig` off — each before
any container starts), the argv a passing run hands to Docker, and that a failing container fails its stage (`audit`:
either half) and `all`.

**Badges**: the README's tests / coverage / branch-coverage badges show the last green build of the default branch.
After `scripts/ci/test.sh all` passes there (never on another branch), `scripts/ci/badges` reads the Ruby suite's
`TOTAL … runs` and `coverage: …` lines (the lowest of SQLite and Postgres) and vitest's `Tests … passed` from that
build's log and writes shields.io endpoint JSON into a public gist (`Jenkinsfile` `BADGE_GIST_ID`, with the Secret Text
credential `BADGE_CREDENTIAL`, a token with `gist` scope). A missing line or a refused update fails the build. A fork
points both at its own gist, or the badges stay upstream's.

## Git hooks — overcommit, in Docker

`.githooks/pre-commit` runs [overcommit](https://github.com/sds/overcommit) 0.75.0 (`.overcommit.yml`) inside the
`agents-kanban-hooks:<hash>` image (`scripts/hooks/Dockerfile`: overcommit + RuboCop from `ruby/Gemfile.lock`'s
`:lint` group, node 22 + `npm ci` of `react/package-lock.json` (ESLint, Prettier), gitleaks v8.30.1, ShellCheck
v0.10.0). `scripts/hooks/image` tags it by the hash of every input and builds it on first use.

```bash
git config core.hooksPath .githooks   # or a global pre-commit that execs the repo's .githooks/pre-commit
scripts/hooks/run sign                # once per worktree, and after every change to .overcommit.yml (stage it first)
```

| Hook | What it checks |
|---|---|
| Scope | the **staged** tree: the container gets the git dir and a copy of the index and checks the index out into a tmpfs. The working tree is never mounted, so no hook edits a file and overcommit never `git stash`es |
| `EsLintReact` | `scripts/hooks/eslint react`: ESLint (as in CI) on the staged `react/**/*.{ts,tsx}`, type-aware — CI: `test.sh react` |
| `PrettierCheck` | `scripts/hooks/prettier`: `prettier --check` on the staged `*.{ts,tsx,js,css,json}` — CI: `test.sh react` |
| `Gitleaks` | `scripts/hooks/gitleaks`: `gitleaks git --pre-commit --staged --ignore-gitleaks-allow`, default rules; an in-repo `.gitleaks.toml` / `.gitleaksignore` is refused — CI: `test.sh secrets` (full history) |
| `RuboCop` | built-in: `rubocop --force-exclusion` on the staged Ruby files — CI: `test.sh lint` |
| `ShellCheck` | `scripts/hooks/shellcheck`: `shellcheck -S style` on the staged shell scripts — CI: `test.sh lint` |
| Defaults | overcommit's default pre-commit hooks stay on (AuthorName, AuthorEmail, BrokenSymlinks, CaseConflicts, MergeConflicts) |
| No way around | no docker / no daemon / an image that does not build → the commit is refused. `SKIP`, `ONLY`, `OVERCOMMIT_DISABLE` have no effect. Only pre-commit is wired |

### Signed configuration, per worktree

`verify_signatures: true`: a new clone, or any change to `.overcommit.yml`, refuses every commit until it is reviewed
and signed with `scripts/hooks/run sign` (`overcommit --sign` + `--sign pre-commit`, in the image, on the staged file).

Signatures live in each worktree's own config (`git config --worktree`), so worktrees on branches with different
`.overcommit.yml` never re-lock each other: overcommit 0.75.0 uses `--worktree` when `extensions.worktreeConfig` is
on, else the shared `--local`. `scripts/hooks/run sign` turns the extension on (`git config --local`, once per clone);
a hook with it off in the repo's own config is refused (git ignores a global or system value).

`git worktree add` copies the source worktree's `config.worktree`: a new worktree starts with those signatures,
passes only while its `.overcommit.yml` (and ad hoc hooks) hash the same, and is refused until it signs when they
differ or the source was unsigned. Signatures recorded in the shared config before this scheme are no longer read:
sign each worktree again.

## README images

The logo (`docs/images/logo-{light,dark}.svg`, swapped by `<picture>`) and the four screenshots in `docs/images/` are generated by busyyaks, the reference
host, with its [`scripts/readme-images/`](https://github.com/robertziel/busyyaks/tree/main/scripts/readme-images): a
throwaway busyyaks stack on synthetic data, every screenshot in the light skin, the module's part outlined and the host
dimmed. Regenerate them after a visible change to the board, the card dialog, the launch bar or the workflow editor
(busyyaks's `docs/TESTING.md` § README images and the scripts' headers say how), passing this checkout as the module checkout.
