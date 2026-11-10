# shellcheck shell=bash
# Sourced by scripts/ci/badges and scripts/ci/github: GitHub REST calls whose token never reaches a command line.
#
#   gh_token_ok <var> <hint>      refuse a token that is empty or not GitHub-token shaped — the message never holds it
#   gh_curl <var> <curl args>…    curl with "Authorization: Bearer $<var>" read from a pipe (-H @<(…): printf is a
#                                 builtin, argv shows /dev/fd/N) plus GitHub's Accept + API-version headers
#
# /proc/*/cmdline (ps) is readable by every uid; the token's env copy (/proc/*/environ) only by the same uid.

gh_token_ok() {
  local var=$1 hint=$2
  [ -n "${!var:-}" ] || { echo "$var is empty — $hint" >&2; return 1; }
  [[ "${!var}" =~ ^[A-Za-z0-9_]+$ ]] || { echo "$var has characters a GitHub token never has — $hint" >&2; return 1; }
}

gh_curl() {
  local var=$1; shift
  curl -H @<(printf 'Authorization: Bearer %s' "${!var}") -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" "$@"
}
