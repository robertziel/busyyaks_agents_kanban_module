#!/usr/bin/env bash
# The engine's CI gates — the same on Jenkins and on any machine with Docker.
#
#   scripts/ci/test.sh lint          RuboCop over the whole tree (scripts/lint/rubocop; .rubocop.yml = Cookpad's guide + the
#                                    performance/rake/sequel/thread_safety departments), then ShellCheck -S style over every
#                                    shell script, found by shebang (scripts/lint/shellcheck)
#   scripts/ci/test.sh ruby-sqlite   the Ruby suite on SQLite (rake test:parallel, one worker per test file)
#                                    + SimpleCov coverage merged across the workers, fails below its floor
#                                    (ruby/test/test_coverage.rb; ruby-pg likewise)
#   scripts/ci/test.sh ruby-pg       the Ruby suite on Postgres 16 (a throwaway server, one database per worker)
#   scripts/ci/test.sh react         the React port: npm ci → tsc --noEmit → eslint (0 warnings) → prettier --check (every
#                                    TS/TSX/JS/CSS/JSON file, react/ + fixtures/) → vitest run, in node:22-slim
#   scripts/ci/test.sh audit         dependency advisories: bundle-audit check --update (ruby/Gemfile.lock, in the
#                                    agents-kanban-lint image) + npm audit --audit-level=low (react/package-lock.json).
#                                    Any finding fails it — never ignored or baselined, fixed by upgrading. Needs network
#                                    (the advisory databases)
#   scripts/ci/test.sh secrets       gitleaks over the full git history; any finding fails it,
#                                    never allowlisted
#   scripts/ci/test.sh all           the six at once, each into its own log, printed one after the other once all
#                                    have finished; fails if any fails
#
# Where it runs: Jenkins (the maintainer's runner, Jenkinsfile) and GitHub Actions (.github/workflows/ci.yml, every
# pull request on the public repo, forks included) run this same script; so does any machine with Docker.
#
# Trust: every stage starts containers on the Docker daemon. On a rootful daemon, access to it (its socket or the docker
# group) is equivalent to root on that host; the Ruby suite also runs the checkout's own code, as root, in a container
# with the checkout bind-mounted. Run it only on code you would run as root, on a host you can afford to give it — a
# disposable VM such as a GitHub-hosted runner, or a CI host that builds trusted branches only (never a stranger's
# fork on the maintainer's Jenkins). On a ROOTLESS daemon (DOCKER_HOST = that user's socket) container root is that
# unprivileged user — the maintainer's Jenkins runs it so (docs/CI-JENKINS.md § Isolation).
#
# Every database lives in RAM (measured on the CI host: on disk every table wipe waits on fsync,
# 10x slower): the SQLite files in a tmpfs /tmp, Postgres with its data dir on tmpfs and fsync=off. The suite is
# I/O-bound, so it runs one worker per test file (TEST_WORKERS=files), not one per CPU.
#
# Nothing here writes to the checkout except the Ruby suite's bind mount; whatever it leaves root-owned is handed back
# to the caller's uid afterwards, so a Jenkins workspace stays deletable.
set -euo pipefail

cd "$(dirname "$0")/../.."
SRC=$PWD
DOCKER_IMAGE=docker:28.5.2-cli   # for the chown (any image with a shell would do; this one is already pulled)
NODE_IMAGE=node:22-slim          # react/Dockerfile's base
PG_IMAGE=postgres:16-alpine      # README § Test
GITLEAKS_IMAGE=zricethezav/gitleaks:v8.30.1

# Bind mounts are resolved by the Docker DAEMON. Under Jenkins this script runs inside the controller's container,
# talking to the host's daemon, so it needs the checkout's path on the HOST: the source of the container mount that
# holds $SRC (or any other path given). Not in a container → the path itself. Inside one with no such mount → fail;
# never guess a path.
host_path() {
  local path=$1 dest source
  if [ ! -f /.dockerenv ]; then echo "$path"; return; fi
  while IFS='|' read -r dest source; do
    [ -n "$dest" ] || continue
    case "$path/" in "$dest"/*) echo "$source${path#"$dest"}"; return ;; esac
  done < <(docker inspect "$(hostname)" --format '{{range .Mounts}}{{.Destination}}|{{.Source}}{{"\n"}}{{end}}')
  echo "ci: $path is not on any mount of container $(hostname) — cannot hand it to the Docker daemon" >&2
  exit 1
}
HOST_SRC=$(host_path "$SRC")

# Whom files written by a container's root belong to on the host, as a uid:gid INSIDE a container. Rootful: container
# root is host root, so a run hands them back to the caller (id -u/-g). Rootless: container root IS the caller, and the
# caller's own uid inside the container is a subordinate uid on the host — so the owner to hand back to is 0:0.
# No answer from the daemon → fail here, never assume rootful.
DOCKER_SECURITY=$(docker info --format '{{json .SecurityOptions}}') || {
  echo "ci: docker info failed — no Docker daemon to run the gates on (DOCKER_HOST=${DOCKER_HOST:-unset})" >&2; exit 1
}
case "$DOCKER_SECURITY" in
  *name=rootless*) CALLER_IN_CONTAINER=0:0 ;;
  *) CALLER_IN_CONTAINER="$(id -u):$(id -g)" ;;
esac

# One name per run: concurrent builds of different branches must not share a container or an image tag.
RUN_ID=$(printf '%s' "${BUILD_TAG:-local-$$}" | tr -c 'a-zA-Z0-9_-' '-' | tr '[:upper:]' '[:lower:]')
NAME="ak-ci-${RUN_ID}"

chown_back() {
  docker run --rm -v "$HOST_SRC:/w" "$DOCKER_IMAGE" chown -R "$CALLER_IN_CONTAINER" /w
}

# The suite in this run's own image tag; DATABASE_URL (or none = SQLite) from the caller's extra docker args.
rake_parallel() {
  local tag=$1; shift
  local status=0
  docker build -q -t "$tag" ruby >/dev/null
  docker run --rm --name "$NAME-$(printf '%s' "$tag" | sed 's/.*-//')" --tmpfs /tmp:exec -e TEST_WORKERS=files \
    -v "$HOST_SRC:/app" -w /app/ruby "$@" "$tag" bundle exec rake test:parallel || status=$?
  docker image rm "$tag" >/dev/null 2>&1 || true
  chown_back
  return $status
}

ruby-sqlite_suite() {
  rake_parallel "agents-kanban-ruby:$NAME-sqlite"
}

ruby-pg_suite() {
  local pg="$NAME-postgres" status=0
  docker run -d --rm --name "$pg" --tmpfs /var/lib/postgresql/data -e POSTGRES_PASSWORD=ci -e POSTGRES_DB=ak \
    "$PG_IMAGE" -c fsync=off -c synchronous_commit=off -c full_page_writes=off -c max_connections=500 >/dev/null
  # the suite joins the server's network namespace: localhost, no address to look up, nothing published
  docker run --rm --network "container:$pg" "$PG_IMAGE" sh -c \
    'for i in $(seq 1 60); do pg_isready -q -h 127.0.0.1 -U postgres && exit 0; sleep 1; done; echo "postgres not ready after 60s" >&2; exit 1' \
    || status=$?
  if [ "$status" -eq 0 ]; then
    rake_parallel "agents-kanban-ruby:$NAME-pg" --network "container:$pg" \
      -e DATABASE_URL=postgres://postgres:ci@127.0.0.1/ak || status=$?
  fi
  docker rm -f "$pg" >/dev/null 2>&1 || true
  return $status
}

react_suite() {
  # read-only source, copied in without node_modules: npm ci never touches the checkout (vitest reads ../fixtures;
  # Prettier formats ../fixtures too and reads the root's .prettierrc.json, .prettierignore, .editorconfig)
  docker run --rm --name "$NAME-react" --tmpfs /tmp:exec -v "$HOST_SRC:/src:ro" "$NODE_IMAGE" sh -euc '
    mkdir -p /w/react && cp -r /src/fixtures /w/fixtures
    cp /src/.prettierrc.json /src/.prettierignore /src/.editorconfig /w/
    cd /src/react && tar cf - --exclude=./node_modules . | tar xf - -C /w/react && cd /w/react
    npm ci --no-audit --no-fund
    npx tsc --noEmit
    npm run lint
    npm run format:check
    CI=true npx vitest run'
}

# The lockfiles alone are audited: nothing installed, nothing written to the checkout.
audit_suite() {
  local status=0 tag
  tag=$(scripts/lint/image)
  docker run --rm -u "$(id -u):$(id -g)" -e HOME=/tmp -v "$HOST_SRC:/src:ro" --entrypoint bundle "$tag" \
    exec bundle-audit check --update /src/ruby || status=1
  docker run --rm --name "$NAME-audit" -v "$HOST_SRC/react:/src:ro" "$NODE_IMAGE" sh -euc '
    mkdir /w && cp /src/package.json /src/package-lock.json /w && cd /w
    npm audit --audit-level=low' || status=1
  return $status
}

# gitleaks over the WHOLE git history: every commit on every ref the checkout has, not just the
# tree. Any finding fails it — a leaked secret is rotated and removed, never allowlisted: an in-repo .gitleaks.toml /
# .gitleaksignore (gitleaks would read either from the scanned repo) is refused, and `gitleaks:allow` comments are
# ignored. A shallow checkout cannot show the history, so it fails rather than scan part of it.
secrets_suite() {
  if [ "$(git rev-parse --is-shallow-repository)" = true ]; then
    echo "secrets: shallow checkout ($(git rev-list --count HEAD) commits) — the full history is not here to scan" >&2
    return 1
  fi
  local own common
  own=$(git ls-files | grep -E '(^|/)\.gitleaks(\.toml|ignore)$' || true)
  if [ -n "$own" ]; then
    echo "secrets: refused — $own in the tree; findings are fixed, never allowlisted" >&2
    return 1
  fi
  # a git worktree's .git is a file pointing at the main checkout's git dir: mount that too, at its own path
  local mounts=(-v "$HOST_SRC:/repo:ro")
  common=$(git rev-parse --path-format=absolute --git-common-dir)
  case "$common/" in "$SRC"/*) ;; *) mounts+=(-v "$(host_path "$common"):$common:ro") ;; esac
  echo "secrets: $GITLEAKS_IMAGE over $(git rev-list --all --no-merges --count) commits (merges carry no diff of their own)"
  # -w /tmp: no .gitleaksignore is read from the working dir; safe.directory: the checkout belongs to another uid
  docker run --rm -u "$(id -u):$(id -g)" -w /tmp "${mounts[@]}" \
    -e GIT_CONFIG_COUNT=1 -e GIT_CONFIG_KEY_0=safe.directory -e GIT_CONFIG_VALUE_0='*' \
    "$GITLEAKS_IMAGE" git --redact --verbose --no-banner --exit-code 1 --ignore-gitleaks-allow /repo
}

lint_suite() {
  local status=0
  LINT_SRC=$HOST_SRC scripts/lint/rubocop --format simple || status=1
  LINT_SRC=$HOST_SRC scripts/lint/shellcheck || status=1
  return $status
}

# The given suites at once. Each one's output goes to its own log (interleaved lines would be unreadable), printed
# whole once every suite has finished, with its exit status.
all_suites() {
  local logs name failed=0 status
  local -A pid
  logs=$(mktemp -d)
  for name in "$@"; do "${name}_suite" > "$logs/$name.log" 2>&1 & pid[$name]=$!; done
  for name in "$@"; do
    status=0; wait "${pid[$name]}" || status=$?
    echo "════ $name (exit $status) ════"; cat "$logs/$name.log"
    [ "$status" -eq 0 ] || failed=1
    echo "$name exit $status" >> "$logs/summary"
  done
  echo "ci: $(paste -sd ',' "$logs/summary" | sed 's/,/ · /g')"
  rm -rf "$logs"
  return $failed
}

case "${1:-}" in
  lint) lint_suite ;;
  ruby-sqlite) ruby-sqlite_suite ;;
  ruby-pg) ruby-pg_suite ;;
  react) react_suite ;;
  audit) audit_suite ;;
  secrets) secrets_suite ;;
  all) all_suites lint ruby-sqlite ruby-pg react audit secrets ;;
  *) echo "usage: $0 lint|ruby-sqlite|ruby-pg|react|audit|secrets|all" >&2; exit 2 ;;
esac
